// MARK: - MemStoreCache.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Persists MemoryStore's snapshot dictionaries as JSON so subsequent launches
// can skip the SwiftData fetch entirely on a cache hit. Validates on load by computing a
// lightweight fingerprint (film count, UUID XOR, max lastModified, list/membership counts)
// from cheap SwiftData queries and comparing it against the stored fingerprint; a mismatch
// triggers a full re-read and rewrites the cache. MemoryStore supplies its dictionaries as
// save() arguments at flush time, so this class never retains a long-lived second reference
// to them (which would defeat copy-on-write on every subsequent MemoryStore mutation).

import Foundation
import SwiftData

// MARK: - Cache Payload

/// Bumped whenever the on-disk payload layout changes. A file written by a different
/// version is rejected and treated as a cache miss — which is an ordinary, fully-supported
/// outcome (it already happens every time a film is added), so no migration code is needed.
/// The cost of a format change is exactly one slow launch, after which the cache is rewritten
/// in the new layout.
///
/// Version 3: `ReleaseSnapshot.releaseYear` became `releaseDate` (full release dates). A v2
/// file would also fail to decode for the missing key; the bump states it outright.
///
/// Version 4: the payload is JSON rather than a binary plist (see `MemoryStoreCacheCoding`).
/// A v3 file fails to decode as JSON, so it is a cache miss before the version is read.
private let currentCacheFormatVersion = 4

/// The payload's encoder and decoder. JSON, not a binary plist: measured 2026-10-27 on a
/// 1,400-film library (Release, median of six launches each), the launch decode fell from
/// 317 to 129 ms and the save's encode from 175 to 105 ms, for a file 4.8 MB against
/// 2.6 MB — which costs 1–2 ms more to read even from the SSD, and about half a
/// millisecond more to write. The decode is off the critical path (see `load()`), so first
/// paint is unchanged; what moved is the slack before initializeApp() (170 → 360 ms) and
/// the work of every save. The round trip was checked against the v3 plist on the same
/// library: every film, release and list identical, every Double and Date bit for bit. The fingerprint file stays a plist; it
/// is a few hundred bytes. A non-finite Double, which JSON cannot spell and which
/// JSONEncoder would otherwise refuse (failing the whole save), is written as a string and
/// read back as the same value.
private enum MemoryStoreCacheCoding {
    static let nonFiniteSpellings = (positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: nonFiniteSpellings.positiveInfinity,
            negativeInfinity: nonFiniteSpellings.negativeInfinity, nan: nonFiniteSpellings.nan)
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: nonFiniteSpellings.positiveInfinity,
            negativeInfinity: nonFiniteSpellings.negativeInfinity, nan: nonFiniteSpellings.nan)
        return decoder
    }
}

/// The complete serializable representation of MemoryStore's data.
/// Stored as JSON alongside a fingerprint (a binary plist) for validation.
///
/// Three pieces of redundancy were removed in version 2, each of which cost decode time for
/// no information gained:
///
///   1. `filmToLists` is no longer stored. It is purely the reverse index of `lists[].filmIDs`
///      — `MemoryStore.loadAllDataFromMainContext` builds it in the same loop that builds
///      `lists`, from nothing but those same memberships — so it carries no independent
///      information. Decoding it cost a UUID parse and a `Set` allocation per membership;
///      rebuilding it on load is a single hash insert per membership.
///
///   2. `films` is an array, not `[UUID: FilmSnapshot]`. Every `FilmSnapshot` already contains
///      its own `id`, so the dictionary key duplicated a value that was being decoded anyway.
///
///   3. `lists` is an array, not `[UUID: MemoryList]`, for the same reason (`listID`).
///
/// Points 2 and 3 also avoid a quieter cost: `UUID` is not usable as a `Codable` dictionary
/// key, so Swift does not encode those dictionaries as dictionaries at all — it flattens them
/// into an alternating key/value list, a clumsier structure to walk than a plain array.
///
/// All three dictionaries are reconstructed immediately after decoding, on the same background
/// thread, so MainActor never sees this work and `MemoryStoreCacheResult` is unchanged.
private struct MemoryStoreCachePayload: Codable {
    let version: Int
    let films: [FilmSnapshot]
    let lists: [MemoryList]
}

/// Transport for the fully-reconstructed dictionaries, so the rebuild can happen inside the
/// background decode task rather than on MainActor. Not `Codable` — it is never written.
private struct DecodedStore: Sendable {
    let films: [UUID: FilmSnapshot]
    let lists: [UUID: MemoryList]
    let filmToLists: [UUID: Set<UUID>]
}

/// Result of the speculative payload pipeline — read, decode, and dictionary rebuild, all
/// performed on one background task before the cache's validity is known.
///
/// The failure reason is carried rather than collapsed to `nil` so the caller can log which
/// stage failed from MainActor, without the background task needing to log anything itself.
private struct SpeculativePayloadLoad: Sendable {
    enum Outcome: Sendable {
        case decoded(DecodedStore)
        case readFailed
        case decodeFailed
        case versionMismatch(found: Int)
    }

    let outcome: Outcome
    let byteCount: Int
    let readElapsed: Duration
    let decodeElapsed: Duration
    let rebuildElapsed: Duration
    /// When the read began and the last stage ended, in LaunchTimeline milliseconds.
    var startedAt: Double = 0
    var finishedAt: Double = 0
}

// MARK: - Store Fingerprint

/// A lightweight descriptor of the SwiftData store's state, used to decide whether the
/// on-disk snapshot cache still matches the database.
///
/// Film-layer fields (detects all film adds/deletes/edits):
///   - filmCount:       total number of Film records
///   - xorFingerprint:  commutative XOR of all film UUIDs (no sort needed)
///   - maxLastModified: lexicographic max of all lastModified strings
///
/// List-layer fields (detects list creation/deletion and membership changes):
///   - listCount:       total number of ListObject records
///   - membershipCount: total number of ListMembership records
///
/// List renames and sortFilterOptions changes are not covered intentionally —
/// they are cosmetic, don't affect data integrity, and are recovered immediately
/// on the next save() within the same session.
///
/// This was previously two structurally identical types (a private `LiveFingerprint` for
/// the computed value and a private `StoredFingerprint` for the persisted one) that had to
/// be transcribed field-by-field at both the save and the compare site. They are unified
/// here because the value must now cross an isolation boundary — it is computed inside
/// DataManager's background ModelActor and returned to MainActor — which requires a single
/// `Sendable` type. `Equatable` conformance also replaces the hand-written five-clause
/// comparison in `load()`, so adding a field to the fingerprint can no longer silently
/// leave it out of the validity check.
///
/// The property names are deliberately unchanged from the former `StoredFingerprint`, so
/// the synthesized `Codable` keys match every fingerprint file already written to disk by
/// a previous version — existing caches continue to validate rather than being treated as
/// a miss on the first launch after this change.
struct StoreFingerprint: Codable, Sendable, Equatable {
    let filmCount: Int
    let xorFingerprint: UInt64
    let maxLastModified: String
    let listCount: Int
    let membershipCount: Int

    /// Position-and-identity digest of the Hall of Fame ranking, and of every film's
    /// user rating, respectively.
    ///
    /// WHY THESE EXIST AT ALL. Every other field above is blind to a mutation that does
    /// not bump `Film.lastModified`, and THREE mutation paths in this app deliberately do
    /// not bump it. Two are covered here; the third is knowingly not, and the reason is
    /// recorded below so its absence reads as a decision rather than an oversight.
    ///
    ///   - Hall of Fame rank changes. `MemoryStore.addToHallOfFame`,
    ///     `removeFromHallOfFame`, `restoreHofPositions` and `compactHallOfFamePositions`
    ///     all write `hofPosition` and schedule a save, and none of them touches
    ///     `lastModified`.  → covered by `hofRankFingerprint`.
    ///   - Imported ratings. `DataCoordinator.applyImportedRatingUpdates` writes
    ///     `userRating` directly for the same reason (an import is not a user edit of
    ///     the film record).  → covered by `userRatingFingerprint`.
    ///   - Wishlist positions. `Release.wishlist` mirrors `hofPosition` exactly, and
    ///     `DataManager.updateReleases` — the only writer, reached via
    ///     `persistPendingWishlistReorder` — writes Release rows without touching the
    ///     parent film.  → DELIBERATELY NOT COVERED. See below.
    ///
    /// WHY WISHLIST IS EXCLUDED. Not cost: a
    /// `#Predicate<Release> { $0.wishlist > 0 }` fetch would return only the handful of
    /// wishlisted rows and would be cheap. The blocker is that it would introduce a
    /// PERMANENT cache-miss vector to fix a transient bug, which is a bad trade.
    ///
    /// The stored side of any release-level digest is the `releases` array inside each
    /// cached `FilmSnapshot`; the live side is the `Release` table. Those two disagree in
    /// exactly the ways `DataManager.computeStoreFingerprint` already documents for
    /// memberships — orphaned rows (no parent film) and duplicate rows sharing a UUID,
    /// the latter a real defect this store has seen before and which
    /// `cleanupDuplicateReleases` exists to clean up. Either one makes the live digest
    /// differ from the stored one on every launch, forever, for a library that is
    /// otherwise perfectly healthy: a ~980ms penalty every single time. Closing it would
    /// require replicating the membership machinery — a `film != nil` predicate plus a
    /// deferred de-duplication pass — for a field whose worst-case loss is a wishlist
    /// display order the user can restore with one drag.
    ///
    /// The two fields here carry no such exposure, and that asymmetry is the whole
    /// justification: `hofPosition` and `userRating` are scalar columns ON the Film row,
    /// so the live and stored sides enumerate the identical set by construction. If the
    /// sets ever disagreed, `filmCount` and `xorFingerprint` would already be reporting
    /// it. A film-level digest therefore cannot introduce a mismatch that the existing
    /// fields do not already produce.
    ///
    /// If wishlist coverage is ever wanted, the prerequisite is a release-layer
    /// equivalent of `cleanupOrphanedAndDuplicateMemberships` running before the digest
    /// is trusted — not simply adding a seventh field.
    ///
    /// Either one therefore leaves `filmCount`, `xorFingerprint`, `maxLastModified`,
    /// `listCount` and `membershipCount` byte-for-byte identical. If the process dies
    /// inside `MemoryStore`'s 2s save throttle after such a mutation — a force quit or a
    /// crash, since a normal quit flushes via `performGracefulShutdown` →
    /// `saveImmediately()` — the next launch gets a fingerprint MATCH and serves the
    /// pre-mutation values from the snapshot cache.
    ///
    /// That failure is materially worse than the membership-count case documented in
    /// `load()`, and for a reason worth stating: it does not self-correct. `MemoryStore`
    /// is authoritative in memory, so the next throttled save writes the stale values
    /// back over the cache, and nothing ever re-reads `hofPosition` or `userRating` from
    /// SwiftData to notice the divergence. The stale value silently becomes the truth
    /// and is what the next backup exports.
    ///
    /// WHY A SUM WOULD NOT WORK. The obvious cheap digest — the sum of all `hofPosition`
    /// values — is blind to exactly the mutation most likely to occur: a reorder. Swapping
    /// the films at positions 3 and 7 leaves the sum unchanged. Each film's contribution
    /// must therefore be bound to its own identity, which is what `rankMix` does.
    ///
    /// WHY XOR. Accumulating by XOR keeps the digest commutative, so neither side has to
    /// sort — matching the existing `xorFingerprint` and preserving the property that the
    /// live computation adds no fetch cost (see `DataManager.computeStoreFingerprint`,
    /// where SwiftData already materializes every stored property regardless of
    /// `propertiesToFetch`, so reading two more `Int`s in a loop that already runs is free).
    ///
    /// Both are computed over EVERY film, not only ranked or rated ones. A value of 0 is
    /// a perfectly good input to the mixer, and including all films removes any dependence
    /// on what "unranked" or "unrated" happens to be encoded as — the two sides cannot
    /// disagree about a sentinel they never test.
    let hofRankFingerprint: UInt64
    let userRatingFingerprint: UInt64

    /// Mixes a film's UUID-derived hash with one of its integer fields into a digest that
    /// is safe to XOR-accumulate.
    ///
    /// This is a SplitMix64 finalizer applied to `idHash + value * φ⁻¹·2⁶⁴`. The avalanche
    /// it provides is the whole point: a linear combination (`idHash &* value`, say) would
    /// let a permutation of positions across films cancel out under XOR, which is the exact
    /// case this field exists to catch. With the finalizer, changing any single film's
    /// value — or moving a value from one film to another — changes roughly half the output
    /// bits, so no realistic permutation survives the accumulation.
    ///
    /// Called only from `FilmLayerDigest`, which both the stored side
    /// (`MemoryStoreCache.buildFingerprint`) and the live side
    /// (`DataManager.computeStoreFingerprint`) accumulate through, so the two cannot mix a
    /// film differently.
    ///
    /// `nonisolated` by nature (a static method on a plain `Sendable` struct), so it is
    /// callable from `DataManager`'s `@ModelActor` isolation without a hop.
    static func rankMix(_ idHash: UInt64, _ value: Int) -> UInt64 {
        var z = idHash &+ (UInt64(bitPattern: Int64(value)) &* 0x9E37_79B9_7F4A_7C15)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Cache Result

enum MemoryStoreCacheResult {
    /// Cache hit: use these pre-built dictionaries directly.
    case hit(films: [UUID: FilmSnapshot], lists: [UUID: MemoryList], filmToLists: [UUID: Set<UUID>])
    /// Cache miss: caller must do the full SwiftData fetch.
    case miss
}

// MARK: - MemoryStoreCache

@MainActor
final class MemoryStoreCache: Loggable {
    nonisolated static let logTag = "[MemoryStoreCache]"

    static let shared = MemoryStoreCache()
    private init() {}

    // MARK: - File URLs

    private var payloadURL: URL? {
        Preferences.dataFolderURL?.appendingPathComponent("memorystore-cache.bin")
    }

    private var fingerprintURL: URL? {
        Preferences.dataFolderURL?.appendingPathComponent("memorystore-fingerprint.bin")
    }

    // MARK: - Save

    /// Flushes MemoryStore's current state to disk.
    ///
    /// The dictionaries are passed in at flush time rather than being pushed here after
    /// every mutation. That ordering matters for more than tidiness: holding a second
    /// reference to `films` between mutations makes its storage non-uniquely-referenced, so
    /// the very next `films[id] = snapshot` in MemoryStore triggers a full copy-on-write
    /// copy of the entire dictionary — thousands of large FilmSnapshot structs, each with
    /// dozens of String/Array fields to retain — on the main thread, for every single film
    /// edit. Taking the reference only for the duration of one save (exactly the pattern
    /// MetadataCache.save() already uses) confines that cost to the rare case of a mutation
    /// landing while an encode is genuinely in flight.
    /// `filmToLists` is deliberately not a parameter: it is not persisted (see
    /// `MemoryStoreCachePayload`), and omitting it also spares the caller from taking a second
    /// reference to it for the duration of the write — one less dictionary whose storage is
    /// non-uniquely-referenced while an encode is in flight.
    ///
    /// `contentVersion` is MemoryStore's: it moves on every mutation of `films` or `lists`
    /// (see `MemoryStore.contentVersion`). A save of the version the files already hold is
    /// skipped — the bytes would describe the same store — which is what makes a quit after
    /// no edits, or after the throttled save has already caught up, write nothing (≈105 ms
    /// of encoding and 4.8 MB of disk writes per quit, 2026-10-27).
    ///
    /// Saves run one at a time, in call order. A throttled save already encoding when the
    /// quit save begins is not stopped by canceling its task, and two overlapping writes
    /// could otherwise land in either order — leaving the older payload on disk, and the
    /// version bookkeeping above believing the newer one.
    ///
    /// A save still waiting its turn when `invalidateOnDisk()` runs is dropped: it was asked
    /// for against the files being invalidated (a restore replaces the store under them).
    func save(films: [UUID: FilmSnapshot], lists: [UUID: MemoryList], contentVersion: UInt64) async {
        let previous = saveInFlight
        let requestedEpoch = invalidationEpoch
        let current = Task {
            await previous?.value
            guard requestedEpoch == self.invalidationEpoch else {
                Self.log("Save dropped: snapshot cache invalidated after it was requested")
                return
            }
            await self.write(films: films, lists: lists, contentVersion: contentVersion)
        }
        saveInFlight = current
        await current.value
    }

    /// Records that the files on disk hold exactly this store content — for MemoryStore to
    /// call when it adopts a cache hit, whose dictionaries ARE the file's contents.
    func recordOnDisk(contentVersion: UInt64) {
        onDiskContentVersion = contentVersion
    }

    /// The MemoryStore content version the files on disk hold, or nil when that is not
    /// known (nothing loaded or saved yet, a save failed or is under way, the files were
    /// invalidated).
    private var onDiskContentVersion: UInt64?
    private var saveInFlight: Task<Void, Never>?
    /// Moved by every `invalidateOnDisk()`.
    private var invalidationEpoch = 0

    private func write(films: [UUID: FilmSnapshot], lists: [UUID: MemoryList], contentVersion: UInt64) async {
        guard let payloadURL = payloadURL,
              let fingerprintURL = fingerprintURL else {
            Self.log("Save skipped: URL unavailable")
            return
        }

        let filmCount = films.count

        // Both files must still be there: the version only says what was written, not that
        // nothing has removed it since.
        if contentVersion == onDiskContentVersion,
           FileManager.default.fileExists(atPath: payloadURL.path(percentEncoded: false)),
           FileManager.default.fileExists(atPath: fingerprintURL.path(percentEncoded: false)) {
            Self.log("Save skipped: snapshot cache on disk is current (\(filmCount) films)")
            return
        }
        // Unknown from here until this write succeeds: a failure partway leaves the files in
        // a state no version describes.
        onDiskContentVersion = nil
        let fingerprint = buildFingerprint(films: films, lists: lists)

        // Timed inside the detached task, so the figures are the work and not the wait for it.
        let saved = await Task.detached(priority: .utility) {
            () -> (encode: Duration, write: Duration, bytes: Int)? in
            do {
                let encodeStart = ContinuousClock.now

                // Array construction happens here rather than on MainActor: `Array(_.values)`
                // is an O(N) copy of every FilmSnapshot, and there is no reason for the main
                // thread to pay for it.
                let payload = MemoryStoreCachePayload(
                    version: currentCacheFormatVersion,
                    films: Array(films.values),
                    lists: Array(lists.values)
                )

                let payloadData = try MemoryStoreCacheCoding.encoder().encode(payload)
                let encodeElapsed = ContinuousClock.now - encodeStart
                let writeStart = ContinuousClock.now
                try payloadData.write(to: payloadURL, options: .atomic)

                // Payload first, fingerprint second, and both atomic. A crash or a quit
                // between the two writes must never leave a fingerprint on disk claiming
                // validity for a payload that was not written — so this order is not
                // incidental, and `load()` depends on its mirror image (read the
                // fingerprint, then the payload). See the read-ordering discussion there
                // before changing either side.
                let fingerprintEncoder = PropertyListEncoder()
                fingerprintEncoder.outputFormat = .binary
                let fpData = try fingerprintEncoder.encode(fingerprint)
                try fpData.write(to: fingerprintURL, options: .atomic)

                return (encodeElapsed, ContinuousClock.now - writeStart, payloadData.count)
            } catch {
                return nil
            }
        }.value

        if let saved {
            onDiskContentVersion = contentVersion
            Self.log("""
                Saved snapshot cache: \(filmCount) films (format v\(currentCacheFormatVersion)) — \
                encode: \(saved.encode.formattedMilliseconds) | write: \(saved.write.formattedMilliseconds) | \
                size: \(Fmt.fixed(Double(saved.bytes) / (1_024 * 1_024), 2))MB
                """)
        } else {
            Self.log("ERROR: Failed to save snapshot cache")
        }
    }

    // MARK: - Invalidate

    /// Deletes the cache from disk so the next launch reads SwiftData in full.
    ///
    /// For a store that was replaced wholesale (restore, fresh library). The fingerprint
    /// cannot be trusted to notice: it covers film identities, `lastModified`, ranks,
    /// ratings and the list/membership COUNTS, so a backup differing only in `infoComplete`,
    /// rotation overrides, list names or order, or a membership moved between lists would
    /// validate against the pre-restore cache and be silently replaced by it.
    ///
    /// Fingerprint first: `runPipeline` treats a missing fingerprint as a miss on its own,
    /// so a failure to delete the payload afterward still forces the slow path.
    func invalidateOnDisk() {
        onDiskContentVersion = nil
        invalidationEpoch += 1
        for url in [fingerprintURL, payloadURL].compactMap({ $0 }) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                Self.log("WARNING: Could not delete \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        Self.log("Snapshot cache invalidated on disk")
    }

    // MARK: - Load

    /// Attempts to load MemoryStore data from the snapshot cache.
    /// Validates the cache by comparing a lightweight SwiftData fingerprint against
    /// the stored fingerprint. Returns .hit if valid, .miss otherwise.
    ///
    /// The fingerprint query fetches only Film.id and Film.lastModified — no relationship
    /// faults — making it far cheaper than the full SwiftData fetch it's guarding against.
    /// It nonetheless still instantiates one managed object per film, which is why it runs
    /// inside DataManager's background ModelActor rather than against mainContext (see
    /// `DataManager.computeStoreFingerprint()`); this is the whole reason the caller now
    /// hands a `DataManager` in instead of a `ModelContainer`.
    ///
    /// ## Read ordering is load-bearing
    ///
    /// `save()` writes the payload file first and the fingerprint file second, each
    /// atomically. That ordering is what makes a crash between the two writes safe: the
    /// fingerprint on disk never claims validity for a payload that was not already
    /// written. Its mirror image is an obligation on this method — **the payload must be
    /// read strictly after the fingerprint has been read.** Reading them in that order
    /// guarantees the payload obtained is at least as new as the generation the fingerprint
    /// describes; reading them concurrently does not, and could pair a freshly-written
    /// fingerprint with the previous generation's payload, silently accepting stale film
    /// data as valid.
    ///
    /// The payload read is therefore started only once the fingerprint read has resolved —
    /// but deliberately *before* the comparison verdict is known, so it can still overlap
    /// the live fingerprint computation, which is the long pole here by an order of
    /// magnitude (an O(N) SwiftData fetch versus a ~200-byte file read). That keeps the
    /// payload read off the serial critical path, which is the entire point: it is a
    /// multi-megabyte read on a large library, and paying for it only after validation
    /// added its full latency to the window the launch progress indicator is on screen.
    ///
    /// Only the payload *read* is speculative, not its decode. Reading is pure I/O and
    /// costs one discarded `Data` on a fingerprint mismatch; decoding is the CPU-expensive
    /// half, and on a mismatch the caller immediately begins a full SwiftData fetch that
    /// should not be competing with a decode whose result is already known to be useless.
    ///
    /// This is called exactly once per launch, from Phase 1, before any mutation can have
    /// occurred and therefore before any `save()` can have been scheduled — so no writer
    /// can actually be in flight today. The ordering discipline above is maintained as
    /// defense in depth for any future caller that does not enjoy that guarantee.
    func load(dataManager: DataManager) async -> MemoryStoreCacheResult {
        // Steps 1–3 below have usually been running since FilmTrackerApp.init (see
        // beginEarlyLoad); otherwise they run now. Either way nothing is judged until here.
        let pipeline: CachePipeline
        if let early = earlyPipeline {
            earlyPipeline = nil
            pipeline = await early.value
        } else {
            guard let payloadURL = payloadURL,
                  let fingerprintURL = fingerprintURL else {
                Self.log("Load skipped: URL unavailable")
                return .miss
            }
            pipeline = await Self.runPipeline(payloadURL: payloadURL,
                                              fingerprintURL: fingerprintURL,
                                              dataManager: dataManager)
        }

        let storedFP: StoreFingerprint
        let fingerprintReadElapsed: Duration
        let liveFPResult: StoreFingerprint?
        let payloadTask: Task<SpeculativePayloadLoad, Never>
        switch pipeline {
        case .noCacheFiles:
            Self.log("No snapshot cache on disk — first launch or cache was cleared")
            return .miss

        case .storedFingerprintUnreadable(let elapsed):
            // Three causes, all of which correctly degrade to the slow path:
            //   - No fingerprint file yet (first launch, or the data folder was cleared).
            //   - A corrupt or truncated file.
            //   - A fingerprint written before hofRankFingerprint / userRatingFingerprint
            //     were added to StoreFingerprint. Codable synthesizes those keys as
            //     required, so every file written by an earlier build fails to decode here
            //     exactly once; this session's save rewrites it in the new shape and the
            //     next launch hits normally. A single slow launch on upgrade is the
            //     intended trade for closing the blind spot documented on StoreFingerprint,
            //     and it is the same "slow once, then healed" bargain
            //     DataManager.cleanupOrphanedAndDuplicateMemberships already makes.
            // The three are not distinguished because the recovery is identical for all
            // three; what distinguishes them for a reader is repetition, since only a
            // genuinely unwritable data folder produces this on consecutive launches.
            Self.log("Cache miss: could not read stored fingerprint — absent, unreadable, or "
                + "written by a build with a different fingerprint shape (expected exactly "
                + "once after an upgrade that adds a field; this session's save rewrites it). "
                + "(read took \(elapsed.formattedMilliseconds))")
            return .miss

        case .ready(let stored, let readElapsed, let live, let task, let startedAt, let fingerprintsAt):
            storedFP = stored
            fingerprintReadElapsed = readElapsed
            liveFPResult = live
            payloadTask = task
            LaunchTimeline.mark("snapshotPipelineStart", at: startedAt)
            LaunchTimeline.mark("snapshotFingerprints", at: fingerprintsAt)
        }

        // Step 4: compare. Equatable conformance covers every field, so a field added to
        // StoreFingerprint cannot be left out of the check.
        guard let liveFP = liveFPResult else {
            Self.log("Cache miss: could not compute live fingerprint from SwiftData")
            return .miss
        }

        guard storedFP == liveFP else {
            let detail = "stored \(storedFP.filmCount) films/\(storedFP.listCount) lists/\(storedFP.membershipCount) memberships, "
                + "live \(liveFP.filmCount) films/\(liveFP.listCount) lists/\(liveFP.membershipCount) memberships"

            // Shared precondition for both shape-specific diagnostics below: the film
            // layer's identity fields and the list count all agree, so whatever differs
            // is confined to one narrow layer rather than being an ordinary library
            // change. Written once so the two branches cannot drift apart, and so that
            // adding a field to StoreFingerprint forces a decision here rather than
            // silently widening what "the film layer matches" means.
            let filmIdentityMatches =
                liveFP.filmCount == storedFP.filmCount
                && liveFP.xorFingerprint == storedFP.xorFingerprint
                && liveFP.maxLastModified == storedFP.maxLastModified
                && liveFP.listCount == storedFP.listCount

            // Hoisted rather than written inline in each branch: the first branch needs
            // them true, the second needs them both false, and computing them once makes
            // that complementarity legible instead of leaving two negated copies of the
            // same expressions to be kept in sync by hand.
            let hofDiffers = liveFP.hofRankFingerprint != storedFP.hofRankFingerprint
            let ratingDiffers = liveFP.userRatingFingerprint != storedFP.userRatingFingerprint

            // Rank-or-rating-only divergence. Before hofRankFingerprint and
            // userRatingFingerprint existed this shape was not merely undiagnosed — it was
            // undetectable, and produced a silent false HIT serving stale values (see the
            // discussion on StoreFingerprint). It is called out ahead of the membership
            // branch because it is the more serious of the two: unlike a lost membership
            // edit, a lost rank or rating does not resolve itself on the next save.
            //
            // The cause is always the same and is always benign to recover from: a rank or
            // rating mutation that never reached the snapshot cache because the process was
            // killed inside MemoryStore's 2s save throttle. The slow path that follows
            // reads the correct values straight from SwiftData, so this is self-correcting
            // in one launch — but it should be rare, and repetition means normal shutdown
            // is not running saveImmediately().
            if filmIdentityMatches,
               liveFP.membershipCount == storedFP.membershipCount,
               hofDiffers || ratingDiffers {
                let layers: String
                switch (hofDiffers, ratingDiffers) {
                case (true, true):  layers = "Hall of Fame ranking and user ratings"
                case (true, false): layers = "Hall of Fame ranking"
                default:            layers = "user ratings"
                }
                Self.log("Cache miss: UNVERSIONED-FIELD discrepancy — every count and the "
                    + "film identity layer match exactly, but the \(layers) digest differs "
                    + "between the store and the snapshot. Neither field bumps "
                    + "Film.lastModified, so this is a mutation that never reached the "
                    + "snapshot cache — almost certainly a force quit or crash inside "
                    + "MemoryStore's 2s save throttle, bypassing the saveImmediately() "
                    + "flush in performGracefulShutdown. The slow path below reads the "
                    + "correct values from SwiftData, so this resolves in one launch. "
                    + "Recurrence on consecutive normal quits is a real defect in the "
                    + "shutdown flush and should be investigated. (\(detail))")
                return .miss
            }

            // A mismatch confined to the membership count, with the entire film layer
            // (count, UUID XOR, max lastModified) and the list count all in agreement,
            // is not the ordinary "your library changed since the last run" case. A
            // membership edit alone does not touch Film.lastModified — batchAddFilmsToLists
            // creates rows without writing to the film — so a list add is precisely the
            // change that leaves all four other fields identical, which is why this shape
            // needs calling out rather than assuming a single cause for it.
            //
            // Two conditions produce it, and they are not equally benign:
            //
            //   - Duplicate (film, list) rows, which `MemoryList.filmIDs` collapses into
            //     one Set element. Persistent: recurs on every launch until the store is
            //     corrected, costing the full slow path each time.
            //   - A membership change lost to an abnormal termination inside MemoryStore's
            //     2s save throttle. AppDelegate's applicationWillTerminate calls
            //     saveImmediately(), so this needs a kill that skips that path. Transient:
            //     the next ordinary save resolves it.
            //
            // Orphaned rows cannot produce this shape at all — they are excluded on both
            // sides by the predicate in DataManager.computeStoreFingerprint.
            //
            // Left undistinguished, that condition looks identical in the log to a
            // legitimate change while costing the full ~980ms slow path on every
            // launch, so it is called out explicitly. The deferred
            // cleanupOrphanedAndDuplicateMemberships() pass corrects the store after
            // the UI is ready, so this should appear at most once; seeing it on
            // consecutive launches means that cleanup is not completing and is the
            // signal to investigate rather than a benign repeat.
            if filmIdentityMatches,
               // The new digests must agree too, or this is not a membership-only
               // difference and labeling it as one would send the reader looking for
               // duplicate rows that do not exist.
               !hofDiffers, !ratingDiffers,
               // Strictly greater, not merely unequal. Duplicates and orphans can only
               // ever inflate the live count above the stored one; a live count that is
               // *lower* is a different situation entirely (memberships genuinely
               // removed after the last cache save) and must not be reported as a
               // structural fault — nor be allowed to produce a negative `excess`.
               liveFP.membershipCount > storedFP.membershipCount {
                let excess = liveFP.membershipCount - storedFP.membershipCount
                Self.log("Cache miss: MEMBERSHIP-ONLY discrepancy — film and list layers match "
                    + "exactly but the store holds \(excess) more membership row(s) than the "
                    + "stored snapshot. Two causes produce this shape: duplicate (film, list) "
                    + "rows, which `MemoryList.filmIDs` collapses into one Set element and which "
                    + "recur every launch until cleaned; or a list add/remove that never reached "
                    + "the snapshot cache because the process was killed inside the 2s save "
                    + "throttle without applicationWillTerminate running — a one-off that "
                    + "resolves itself as soon as this session saves. Either way the next launch "
                    + "should hit: deferred cleanup removes duplicates, and a normal save "
                    + "resolves the second case. Recurrence across consecutive launches is what "
                    + "distinguishes the two, and is the signal that cleanup is not completing. "
                    + "(\(detail))")
            } else {
                Self.log("Cache miss: fingerprint mismatch (\(detail))")
            }
            return .miss
        }

        Self.log("Fingerprint match (\(storedFP.filmCount) films, \(storedFP.listCount) lists, \(storedFP.membershipCount) memberships) — loading snapshot cache...")

        // Step 5: join the speculative payload pipeline. On the fast path this has already
        // completed — started from FilmTrackerApp.init, it finishes while AppKit is still
        // building the menu bar and first window — so this await is free.
        let speculative = await payloadTask.value
        LaunchTimeline.mark("snapshotPayloadStart", at: speculative.startedAt)
        LaunchTimeline.mark("snapshotPayloadDone", at: speculative.finishedAt)

        let decoded: DecodedStore
        switch speculative.outcome {
        case .decoded(let store):
            decoded = store
        case .readFailed:
            Self.log("Cache miss: failed to read payload from disk (read attempt took \(speculative.readElapsed.formattedMilliseconds))")
            return .miss
        case .decodeFailed:
            Self.log("Cache miss: failed to decode payload (decode attempt took \(speculative.decodeElapsed.formattedMilliseconds))")
            return .miss
        case .versionMismatch(let found):
            Self.log("Cache miss: payload format v\(found), expected v\(currentCacheFormatVersion)")
            return .miss
        }

        // The decoded dictionaries are handed straight to MemoryStore and deliberately not
        // retained here. Keeping a second reference would leave the films dictionary
        // non-uniquely-referenced from the moment of launch, so the session's very first
        // film edit would pay for a full copy-on-write copy of the entire library for no
        // benefit — save() receives the current state as arguments when it actually runs.
        Self.log("Cache hit: restored \(decoded.films.count) films, \(decoded.lists.count) lists from snapshot cache")

        // Note these segments are not on the launch critical path: read, decode, and rebuild
        // start from FilmTrackerApp.init (beginEarlyLoad) and run while AppKit builds the
        // menu bar and first window. Measured 2026-10-27, 1,400 films, Release (the decode
        // is Foundation's JSONDecoder, so -Onone barely slows it): the live fingerprint takes
        // ~5ms (direct store read), the decode ~130ms, and the pipeline finishes ~360ms
        // before initializeApp() asks for it. The decode is the segment that would reach the
        // critical path first if launch work moved earlier or the library grew severalfold;
        // under a debugger it runs slower (the plist decode ran ~60% slower).
        //
        // The per-item counts normalize cost against library size, and the field total is
        // what actually drives decode cost: every field of every film and every release is
        // one name lookup in the decoder. Both are computed only when logging is on — they
        // are diagnostic-only O(N) passes with no other purpose.
        if Logger.isLoggingEnabled {
            let releaseCount = decoded.films.values.reduce(0) { $0 + $1.releases.count }
            let membershipCount = decoded.lists.values.reduce(0) { $0 + $1.filmIDs.count }
            let reverseIndexEntries = decoded.filmToLists.count
            let approxFieldDecodes = decoded.films.count * 58 + releaseCount * 39
            let sizeMB = Fmt.fixed(Double(speculative.byteCount) / (1_024 * 1_024), 2)

            Self.log("""
                STARTUP BREAKDOWN (snapshot cache, overlapped) — \
                fingerprintRead: \(fingerprintReadElapsed.formattedMilliseconds) | \
                payloadRead: \(speculative.readElapsed.formattedMilliseconds) | \
                payloadDecode: \(speculative.decodeElapsed.formattedMilliseconds) | \
                dictRebuild: \(speculative.rebuildElapsed.formattedMilliseconds) | \
                size: \(sizeMB)MB (format v\(currentCacheFormatVersion)) | \
                films: \(decoded.films.count), releases: \(releaseCount), \
                lists: \(decoded.lists.count), memberships: \(membershipCount), \
                reverseIndexEntries: \(reverseIndexEntries) | \
                ~\(approxFieldDecodes) field decodes
                """)
        }

        return .hit(films: decoded.films, lists: decoded.lists, filmToLists: decoded.filmToLists)
    }

    // MARK: - Early Start

    /// What `load()` needs before it can judge the cache: both fingerprints, and the
    /// speculative payload pipeline still running or finished.
    private enum CachePipeline: Sendable {
        case noCacheFiles
        case storedFingerprintUnreadable(elapsed: Duration)
        case ready(stored: StoreFingerprint, readElapsed: Duration,
                   live: StoreFingerprint?, payload: Task<SpeculativePayloadLoad, Never>,
                   startedAt: Double, fingerprintsAt: Double)
    }

    /// Steps 1–3 of `load()`, started by `beginEarlyLoad` and consumed by `load()`.
    private var earlyPipeline: Task<CachePipeline, Never>?

    /// Starts steps 1–3 of `load()` now, off the main thread, so they overlap the
    /// AppKit/SwiftUI launch work between `FilmTrackerApp.init` and the `.task` that calls
    /// `initializeApp()` — about half a second in which the main thread builds the menu
    /// bar and the first window and the cache files were not being read at all.
    ///
    /// Changes when the work starts, not what it does: the pipeline reads the same two
    /// files in the same order, and every verdict, log line and MainActor assignment still
    /// happens in `load()`. Nothing writes either cache file before `load()` runs — saves
    /// begin only after initialization — so reading them earlier reads the same bytes.
    /// Called once, from `FilmTrackerApp.init`; `load()` falls back to running the steps
    /// itself if it was not.
    func beginEarlyLoad(dataManager: DataManager) {
        guard earlyPipeline == nil,
              let payloadURL = payloadURL,
              let fingerprintURL = fingerprintURL else { return }
        earlyPipeline = Task.detached(priority: .userInitiated) {
            await Self.runPipeline(payloadURL: payloadURL, fingerprintURL: fingerprintURL,
                                   dataManager: dataManager)
        }
    }

    /// Steps 1–3 of `load()`. Nonisolated, and called from a detached task when started
    /// early: SwiftData's model executor runs a DataManager call on the thread that awaits
    /// it, so the live fingerprint must be awaited from here rather than from MainActor.
    private nonisolated static func runPipeline(payloadURL: URL, fingerprintURL: URL,
                                                dataManager: DataManager) async -> CachePipeline {
        guard FileManager.default.fileExists(atPath: payloadURL.path(percentEncoded: false)),
              FileManager.default.fileExists(atPath: fingerprintURL.path(percentEncoded: false)) else {
            return .noCacheFiles
        }
        let pipelineStart = LaunchTimeline.now()

        // Step 1: stored fingerprint read (background thread) and live fingerprint
        // computation (DataManager's background ModelActor), started together. MainActor is
        // free for the whole of this window, so the launch progress indicator keeps
        // animating and the concurrently-running MetadataCache/PosterCache metadata loads
        // can resume their MainActor continuations without waiting behind a SwiftData fetch.
        // Each background segment times itself and returns the measurement alongside its
        // result, rather than logging from inside the detached closure. Two reasons: the
        // segments overlap, so measuring them from the outside would report waiting time
        // rather than work; and keeping all the logging on MainActor avoids introducing any
        // logging calls into detached contexts.
        async let storedFPLoad: (fingerprint: StoreFingerprint?, elapsed: Duration)
            = Task.detached(priority: .userInitiated) {
                () -> (fingerprint: StoreFingerprint?, elapsed: Duration) in
                let segmentStart = ContinuousClock.now
                guard let data = try? Data(contentsOf: fingerprintURL),
                      let fp = try? PropertyListDecoder().decode(StoreFingerprint.self, from: data) else {
                    return (nil, ContinuousClock.now - segmentStart)
                }
                return (fp, ContinuousClock.now - segmentStart)
            }.value

        async let liveFPLoad: StoreFingerprint? = dataManager.computeStoreFingerprint()

        // Step 2: join the fingerprint read first — on its own, ahead of the live
        // fingerprint — because the payload read may not begin until it has completed.
        // See the read-ordering discussion on load().
        let storedFPResult = await storedFPLoad
        guard let storedFP = storedFPResult.fingerprint else {
            return .storedFingerprintUnreadable(elapsed: storedFPResult.elapsed)
        }
        // Step 3: the fingerprint bytes are in hand, so the payload pipeline may now safely
        // begin — read, decode, and dictionary rebuild, all on one background task, started
        // before the validity verdict is known.
        //
        // Decoding speculatively rather than only reading speculatively is what keeps the
        // decode off the critical path. The live fingerprint is now ~5ms (a direct store
        // read; see DataManager.computeStoreFingerprint), so the payload no longer hides
        // behind it; it hides behind AppKit's launch instead, which this whole pipeline
        // overlaps (see beginEarlyLoad). Waiting for the verdict first would only move the
        // ~130ms decode later, toward initializeApp(), for no gain.
        //
        // The objection that a wasted decode would compete with the slow-path SwiftData
        // fetch on a mismatch does not hold either: a mismatch rebuilds from SwiftData,
        // which costs far more than the decode, and it runs on another core.
        //
        // Integrity is unaffected. Decoding early is not the same as trusting early: the
        // result is consumed only after the fingerprint comparison below passes, and the read
        // still begins strictly after the fingerprint file has been read, preserving the
        // ordering invariant described above.
        //
        // Held as an unstructured, detached Task rather than an `async let`: an `async let`
        // must be awaited before its scope exits, so the mismatch return below would block on
        // work whose result is already known to be worthless. `.detached` is required rather
        // than a plain `Task`: an unstructured `Task` created here would inherit MainActor
        // isolation and run the decode on the main thread. On a mismatch the task finishes
        // unobserved and its allocations are released when the task is. No cancellation check
        // is worth adding: on a mismatch the decode is already well under way, and nothing
        // waits on it.
        let payloadTask = Task.detached(priority: .userInitiated) {
            () -> SpeculativePayloadLoad in
            // Stamped for the launch timeline around the whole read-decode-rebuild.
            let startedAt = LaunchTimeline.now()
            var result = { () -> SpeculativePayloadLoad in
            let readStart = ContinuousClock.now
            guard let payloadData = try? Data(contentsOf: payloadURL) else {
                return SpeculativePayloadLoad(outcome: .readFailed, byteCount: 0,
                                              readElapsed: ContinuousClock.now - readStart,
                                              decodeElapsed: .zero, rebuildElapsed: .zero)
            }
            let readElapsed = ContinuousClock.now - readStart

            let decodeStart = ContinuousClock.now
            guard let payload = try? MemoryStoreCacheCoding.decoder()
                .decode(MemoryStoreCachePayload.self, from: payloadData) else {
                return SpeculativePayloadLoad(outcome: .decodeFailed, byteCount: payloadData.count,
                                              readElapsed: readElapsed,
                                              decodeElapsed: ContinuousClock.now - decodeStart,
                                              rebuildElapsed: .zero)
            }
            let decodeElapsed = ContinuousClock.now - decodeStart

            // A payload written by a different format version is rejected rather than
            // reinterpreted. Belt and braces: a v1 file would already fail to decode,
            // because v1 stored `films` as a flattened key/value list where v2 expects a
            // plain array, and v1 had no `version` key at all.
            guard payload.version == currentCacheFormatVersion else {
                return SpeculativePayloadLoad(outcome: .versionMismatch(found: payload.version),
                                              byteCount: payloadData.count,
                                              readElapsed: readElapsed,
                                              decodeElapsed: decodeElapsed,
                                              rebuildElapsed: .zero)
            }

            // Reconstruct all three dictionaries here, on this background thread, so the
            // work never lands on MainActor and MemoryStoreCacheResult can stay exactly
            // as it was for the caller.
            let rebuildStart = ContinuousClock.now

            var filmsByID = [UUID: FilmSnapshot](minimumCapacity: payload.films.count)
            for film in payload.films { filmsByID[film.id] = film }

            var listsByID = [UUID: MemoryList](minimumCapacity: payload.lists.count)
            var filmToLists: [UUID: Set<UUID>] = [:]
            for list in payload.lists {
                listsByID[list.listID] = list
                for filmID in list.filmIDs {
                    filmToLists[filmID, default: []].insert(list.listID)
                }
            }

            let store = DecodedStore(films: filmsByID, lists: listsByID,
                                     filmToLists: filmToLists)
            return SpeculativePayloadLoad(outcome: .decoded(store),
                                          byteCount: payloadData.count,
                                          readElapsed: readElapsed,
                                          decodeElapsed: decodeElapsed,
                                          rebuildElapsed: ContinuousClock.now - rebuildStart)
            }()
            result.startedAt = startedAt
            result.finishedAt = LaunchTimeline.now()
            return result
        }

        let liveFP = await liveFPLoad
        return .ready(stored: storedFP, readElapsed: storedFPResult.elapsed,
                      live: liveFP, payload: payloadTask,
                      startedAt: pipelineStart, fingerprintsAt: LaunchTimeline.now())
    }

    // MARK: - Fingerprint Helpers

    /// Builds the fingerprint from MemoryStore's dictionaries (used during save).
    /// List-layer counts are derived from the in-memory MemoryList data —
    /// no SwiftData access required.
    ///
    /// The film layer is accumulated by `FilmLayerDigest`, the same type
    /// `DataManager.computeStoreFingerprint` feeds from the store, so the stored and live
    /// sides cannot mix a film differently — a divergence would be a false mismatch, and a
    /// slow launch, every time.
    private func buildFingerprint(films: [UUID: FilmSnapshot],
                                  lists: [UUID: MemoryList]) -> StoreFingerprint {
        var filmLayer = FilmLayerDigest()
        for snapshot in films.values {
            filmLayer.add(id: snapshot.id, lastModified: snapshot.lastModified,
                          hofPosition: snapshot.hofPosition, userRating: snapshot.userRating)
        }

        // Membership count mirrors the total filmIDs across all lists,
        // matching what SwiftData reports via fetchCount(FetchDescriptor<ListMembership>()).
        let membershipCount = lists.values.reduce(0) { $0 + $1.filmIDs.count }

        return StoreFingerprint(
            filmCount: filmLayer.filmCount,
            xorFingerprint: filmLayer.xor,
            maxLastModified: filmLayer.maxLastModified,
            listCount: lists.count,
            membershipCount: membershipCount,
            hofRankFingerprint: filmLayer.hofRankXor,
            userRatingFingerprint: filmLayer.userRatingXor
        )
    }
}

// MARK: - UUID UInt64 Decomposition

extension UUID {
    /// Decomposes the UUID into two UInt64 values (the two halves of the 128-bit value).
    /// Used for XOR-based fingerprinting without needing to sort UUIDs.
    ///
    /// Used by `FilmLayerDigest`, which both sides of the fingerprint accumulate through.
    var fingerprintHalves: (UInt64, UInt64) {
        let bytes = uuid  // uuid is a (UInt8, UInt8, ...) 16-tuple
        let hi = UInt64(bytes.0)  << 56 | UInt64(bytes.1)  << 48
                | UInt64(bytes.2)  << 40 | UInt64(bytes.3)  << 32
                | UInt64(bytes.4)  << 24 | UInt64(bytes.5)  << 16
                | UInt64(bytes.6)  << 8  | UInt64(bytes.7)
        let lo = UInt64(bytes.8)  << 56 | UInt64(bytes.9)  << 48
                | UInt64(bytes.10) << 40 | UInt64(bytes.11) << 32
                | UInt64(bytes.12) << 24 | UInt64(bytes.13) << 16
                | UInt64(bytes.14) << 8  | UInt64(bytes.15)
        return (hi, lo)
    }
}
