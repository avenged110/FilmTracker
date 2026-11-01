// MARK: - MemStoreCache.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Persists MemoryStore's snapshot as JSON, so a later launch can skip the store fetch on a cache hit.
// The cache is validated by a lightweight store fingerprint. A mismatch triggers a full read and rewrite.

import Foundation
import CoreData

// MARK: - Cache Payload

/// Bumped whenever the on-disk payload layout changes. A file from another version is a cache miss,
/// so no migration is needed. The cost is one slow launch.
///
/// Version 3: `ReleaseSnapshot.releaseYear` became `releaseDate`.
/// Version 4: the payload is JSON rather than a binary plist (see `MemoryStoreCacheCoding`).
private let currentCacheFormatVersion = 4

/// The payload's JSON encoder and decoder. JSON was chosen over a binary plist for faster decode and
/// encode on a 1,400-film library, at a modest cost in file size. Non-finite Doubles, which JSON cannot
/// represent, are written as strings and read back to the same value.
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

/// The serialized form of MemoryStore's data, stored as JSON beside a binary-plist fingerprint.
///
/// Three redundancies were removed in version 2, because each cost decode time without adding information:
///
///   1. `filmToLists` is not stored. It is the reverse index of `lists[].filmIDs`, rebuilt on load.
///   2. `films` is an array, not a dictionary, because each `FilmSnapshot` already holds its `id`.
///   3. `lists` is an array, for the same reason (`listID`).
///
/// `UUID` is not usable as a `Codable` dictionary key, so Swift encodes such dictionaries as flat
/// key/value lists, which are awkward to read back. The arrays avoid that.
///
/// All three dictionaries are rebuilt right after decoding, on the same background thread.
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

/// A lightweight description of the store's state, used to check whether the on-disk snapshot cache
/// still matches the database. It is Equatable, so every field takes part in the comparison.
///
/// Film layer (detects film adds, deletes, and edits):
///   - filmCount, xorFingerprint (XOR of all film UUIDs), maxLastModified (the latest lastModified)
///
/// List layer (detects list creation, deletion, and membership changes):
///   - listCount, membershipCount
///
/// List renames and sortFilterOptions changes are intentionally not covered. They do not affect data
/// integrity, and the next save in the session records them.
///
/// Hall of Fame ranks and user ratings are covered by the two digests below.
struct StoreFingerprint: Codable, Sendable, Equatable {
    let filmCount: Int
    let xorFingerprint: UInt64
    let maxLastModified: String
    let listCount: Int
    let membershipCount: Int

    /// Digests of the Hall of Fame ranks and of every film's user rating.
    ///
    /// The fields above miss any change that does not bump `Film.lastModified`. Two such changes are covered:
    ///
    ///   - Hall of Fame rank changes (`hofPosition`), made by MemoryStore's Hall of Fame methods.
    ///     Covered by `hofRankFingerprint`.
    ///   - Imported ratings, written to `userRating` directly by `DataCoordinator.applyImportedRatingUpdates`.
    ///     Covered by `userRatingFingerprint`.
    ///
    /// Wishlist positions are deliberately not covered. A release-level digest would differ from the stored
    /// one on every launch whenever the store holds orphaned or duplicate Release rows, forcing the slow path
    /// each time. The user can restore wishlist order with a drag, so that trade is not worth making.
    ///
    /// Both digests cover every film, including unranked and unrated ones, so the two sides never disagree
    /// about a sentinel value.
    ///
    /// A plain sum of positions would miss a reorder, so each film's value is mixed with its identity
    /// (see `rankMix`). XOR keeps the digest order-independent, so neither side has to sort.
    ///
    /// Without these digests, a change lost in a crash inside the save throttle would validate against the
    /// cache and be served stale. The next save would then write the stale value back.
    let hofRankFingerprint: UInt64
    let userRatingFingerprint: UInt64

    /// Mixes a film's UUID hash with one integer field into a digest that is safe to XOR-accumulate.
    ///
    /// The SplitMix64 finalizer is applied to `idHash + value * φ⁻¹·2⁶⁴`. Its avalanche means that moving a
    /// value from one film to another changes the output. A linear combination would let such a move cancel
    /// out under XOR.
    ///
    /// Used by `FilmLayerDigest`, which both the stored and live sides accumulate through.
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
    /// Cache miss: caller must do the full store fetch.
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

    /// Writes MemoryStore's current state to disk.
    ///
    /// The dictionaries are passed in at flush time, not pushed after each mutation. Holding a second
    /// reference between mutations would force a full copy-on-write copy of the dictionary on the next edit.
    /// Each save takes the reference only for its own duration.
    ///
    /// `contentVersion` is MemoryStore's counter for `films` and `lists`. A save of the version already on
    /// disk is skipped, so a quit with no edits writes nothing.
    ///
    /// Saves run one at a time, in call order, so overlapping writes cannot land out of order. A save still
    /// queued when `invalidateOnDisk()` runs is dropped, because it targets files being invalidated.
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
        // An invalidation that lands while the detached write below is running cannot stop
        // it, and the write would put the old library's files back after the invalidation
        // deleted them. Checked again once the write finishes.
        let startEpoch = invalidationEpoch

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

                // Payload first, fingerprint second, both atomic. A crash between the writes must never leave a
                // fingerprint that claims validity for an unwritten payload. load() reads them in the mirror order.

                let fingerprintEncoder = PropertyListEncoder()
                fingerprintEncoder.outputFormat = .binary
                let fpData = try fingerprintEncoder.encode(fingerprint)
                try fpData.write(to: fingerprintURL, options: .atomic)

                return (encodeElapsed, ContinuousClock.now - writeStart, payloadData.count)
            } catch {
                return nil
            }
        }.value

        if startEpoch != invalidationEpoch {
            Self.log("Snapshot cache invalidated during a save — deleting the files it wrote")
            removeFilesFromDisk()
        } else if let saved {
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

    /// Deletes the cache so the next launch reads the store in full. Used when the store is replaced wholesale
    /// (restore, fresh library). The fingerprint cannot be relied on there, because a backup can differ in
    /// fields the fingerprint does not cover.
    ///
    /// The fingerprint is deleted first, so a failed payload deletion still forces the slow path.
    func invalidateOnDisk() {
        onDiskContentVersion = nil
        invalidationEpoch += 1
        removeFilesFromDisk()
        Self.log("Snapshot cache invalidated on disk")
    }

    private func removeFilesFromDisk() {
        for url in [fingerprintURL, payloadURL].compactMap({ $0 }) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                Self.log("WARNING: Could not delete \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Load

    /// Loads MemoryStore data from the snapshot cache if its fingerprint matches the store.
    /// Returns .hit if valid, .miss otherwise.
    ///
    /// The live fingerprint runs on DataManager's background context, because it still creates one managed
    /// object per film. This is why the caller passes in a `DataManager`.
    ///
    /// ## Read ordering
    ///
    /// `save()` writes the payload first and the fingerprint second. The payload must therefore be read only
    /// after the fingerprint has been read. Otherwise a fresh fingerprint could pair with the previous payload,
    /// and stale data would be accepted.
    ///
    /// The payload read starts as soon as the fingerprint read resolves, before the verdict, so it overlaps
    /// the live fingerprint computation. Decoding also starts early, but its result is used only if the
    /// fingerprints match.
    ///
    /// This runs once per launch, from Phase 1, before any mutation can occur. The ordering rule is kept for
    /// future callers.
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
            // Causes: no fingerprint file (first launch), a corrupt file, or a file written by a build with a
            // different fingerprint shape. The last happens once after an upgrade that adds a field.
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
            Self.log("Cache miss: could not compute live fingerprint from the store")
            return .miss
        }

        guard storedFP == liveFP else {
            let detail = "stored \(storedFP.filmCount) films/\(storedFP.listCount) lists/\(storedFP.membershipCount) memberships, "
                + "live \(liveFP.filmCount) films/\(liveFP.listCount) lists/\(liveFP.membershipCount) memberships"

            // Checks whether the film identity and list counts agree, which confines the difference to one layer.
            let filmIdentityMatches =
                liveFP.filmCount == storedFP.filmCount
                && liveFP.xorFingerprint == storedFP.xorFingerprint
                && liveFP.maxLastModified == storedFP.maxLastModified
                && liveFP.listCount == storedFP.listCount

            // Computed once, so the two branches below are exact complements.
            let hofDiffers = liveFP.hofRankFingerprint != storedFP.hofRankFingerprint
            let ratingDiffers = liveFP.userRatingFingerprint != storedFP.userRatingFingerprint

            // Rank or rating mismatch, with every count matching. The usual cause is a change lost in the save
            // throttle after a force quit. The slow path corrects it in one launch. Repetition on normal quits
            // would point to a defect in the shutdown flush.
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
                    + "correct values from the store, so this resolves in one launch. "
                    + "Recurrence on consecutive normal quits is a real defect in the "
                    + "shutdown flush and should be investigated. (\(detail))")
                return .miss
            }

            // Membership-count mismatch, with every other layer matching. The causes are duplicate (film, list)
            // rows, which recur until cleaned, or a list change lost in the save throttle, which the next save
            // resolves. Orphaned rows cannot cause this, because the store predicate excludes them.
            if filmIdentityMatches,
               // The new digests must agree too, or this is not a membership-only
               // difference and labeling it as one would send the reader looking for
               // duplicate rows that do not exist.
               !hofDiffers, !ratingDiffers,
               // Strictly greater: a lower live count means memberships were removed, not duplicated.
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

        // Not retained here. A second reference would force a copy-on-write copy on the first film edit.
        Self.log("Cache hit: restored \(decoded.films.count) films, \(decoded.lists.count) lists from snapshot cache")

        // These segments run alongside AppKit's launch work, off the critical path.
        //
        // The counts and field total are diagnostics for decode cost, which scales with field count.
        // They are computed only when logging is on.
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

    /// Starts steps 1–3 of `load()` early, off the main thread, so they overlap AppKit's launch work
    /// between `FilmTrackerApp.init` and the `.task` that calls `initializeApp()`.
    ///
    /// This changes only when the work starts. Nothing writes the cache files before `load()` runs, so the
    /// bytes read are the same. Called once, from `FilmTrackerApp.init`. `load()` runs the steps itself if not.
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
    /// early, so the stored-fingerprint read and payload decode run in parallel with the
    /// rest of startup.
    private nonisolated static func runPipeline(payloadURL: URL, fingerprintURL: URL,
                                                dataManager: DataManager) async -> CachePipeline {
        guard FileManager.default.fileExists(atPath: payloadURL.path(percentEncoded: false)),
              FileManager.default.fileExists(atPath: fingerprintURL.path(percentEncoded: false)) else {
            return .noCacheFiles
        }
        let pipelineStart = LaunchTimeline.now()

        // Step 1: the stored fingerprint read and the live fingerprint computation run concurrently,
        // leaving MainActor free.
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

        // Step 2: wait for the stored fingerprint, since the payload read must follow it.
        let storedFPResult = await storedFPLoad
        guard let storedFP = storedFPResult.fingerprint else {
            return .storedFingerprintUnreadable(elapsed: storedFPResult.elapsed)
        }
        // Step 3: start the payload read, decode, and rebuild on one background task, before the verdict is known.
        // Decoding early keeps it off the critical path. A mismatch wastes that work, which is acceptable.
        //
        // Decoding early is not trusting early: the result is used only after the comparison passes.
        //
        // The task is unstructured and `.detached`, not an `async let`. A mismatch then does not block on it,
        // and it does not inherit MainActor isolation.
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

            // A payload from another format version is rejected, not reinterpreted.
            guard payload.version == currentCacheFormatVersion else {
                return SpeculativePayloadLoad(outcome: .versionMismatch(found: payload.version),
                                              byteCount: payloadData.count,
                                              readElapsed: readElapsed,
                                              decodeElapsed: decodeElapsed,
                                              rebuildElapsed: .zero)
            }

            // Rebuild the dictionaries here, off MainActor.

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
        LaunchReveal.recordSnapshotPrediction(hit: liveFP == storedFP)
        return .ready(stored: storedFP, readElapsed: storedFPResult.elapsed,
                      live: liveFP, payload: payloadTask,
                      startedAt: pipelineStart, fingerprintsAt: LaunchTimeline.now())
    }

    // MARK: - Fingerprint Helpers

    /// Builds the fingerprint from MemoryStore's dictionaries, for use during save. The film layer uses
    /// `FilmLayerDigest`, the same type the live side uses, so the two sides cannot disagree.
    private func buildFingerprint(films: [UUID: FilmSnapshot],
                                  lists: [UUID: MemoryList]) -> StoreFingerprint {
        var filmLayer = FilmLayerDigest()
        for snapshot in films.values {
            filmLayer.add(id: snapshot.id, lastModified: snapshot.lastModified,
                          hofPosition: snapshot.hofPosition, userRating: snapshot.userRating)
        }

        // Membership count mirrors the total filmIDs across all lists,
        // matching what Core Data reports via fetchCount(ListMembership.request()).
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
