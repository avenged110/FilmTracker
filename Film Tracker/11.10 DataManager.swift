// MARK: - DataManager.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Background actor for SwiftData persistence operations.

import Foundation
import SwiftData
import SQLite3
import os

@ModelActor
actor DataManager: Loggable {
    nonisolated static let logTag = "[DataManager]"

    // MARK: - Error Types
    enum PersistenceError: Error, LocalizedError {
        case filmNotFound(UUID)
        case listNotFound(UUID)

        var errorDescription: String? {
            switch self {
            case .filmNotFound(let id): return "Film not found: \(id)"
            case .listNotFound(let id): return "List not found: \(id)" } } }

    // MARK: - State
    private let batchSize = 100

    // MARK: - Commit

    /// Saves the actor's context, discarding every staged change if the save fails.
    ///
    /// This `ModelContext` is long-lived and shared by every operation on the actor. A
    /// failed `save()` leaves its inserts, deletes, and property writes pending, so without
    /// the rollback they would ride along on the next unrelated operation's save — and if
    /// the save failed *because of* them, every later save in the session would fail too,
    /// silently breaking all persistence rather than just the one operation. Rolling back
    /// is safe at every call site: each method saves before it suspends, so the context
    /// never holds another operation's unrelated pending changes when this runs.
    ///
    /// The batched methods (`resetRotationThresholdOverrides`, `batchAddFilmsToLists`, …)
    /// are unaffected in their documented partial-commit behavior: a rollback here discards
    /// only the batch that failed, and the batches already committed stay committed.
    private func commit() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    // MARK: - Startup Fingerprint

    /// Computes the lightweight fingerprint that `MemoryStoreCache` compares against its
    /// stored copy to decide whether the on-disk snapshot cache is still valid.
    /// Returns nil only if a fetch fails, which the caller treats as a cache miss.
    ///
    /// Three queries are issued:
    ///   1. Film.id, lastModified, hofPosition and userRating — read directly from the
    ///      store file by `DirectStoreReader`, or through a SwiftData fetch when it declines
    ///   2. ListObject count only (no properties, no relationships)
    ///   3. ListMembership count only (no properties, no relationships)
    ///
    /// This lives here, in the background ModelActor, rather than in MemoryStoreCache where
    /// it used to run against `modelContainer.mainContext`. The two count queries really are
    /// negligible, but the film query is not: `propertiesToFetch` avoids faulting the
    /// `releases` relationship, yet SwiftData still instantiates one managed object per
    /// Film. On a large library that is tens of milliseconds of synchronous main-thread work
    /// — and it lands in the worst possible place, inside the first phase of startup, where
    /// it blocks the run loop while the launch progress indicator is the only thing on
    /// screen and stalls the MainActor continuations of the MetadataCache and PosterCache
    /// metadata loads that are supposed to be running in parallel with it. Nothing about the
    /// computation needs the main context, so the whole cost moves off the critical path.
    ///
    /// Correctness note: this reads through the ModelActor's own `ModelContext`, so it sees
    /// the committed store rather than any unsaved changes pending in `mainContext`. That is
    /// equivalent at the only point it is called — the first phase of launch, before any
    /// user action or background writer has had the opportunity to mutate anything — and the
    /// fingerprint's whole purpose is to describe what is on disk, which is precisely what
    /// the snapshot cache it validates was written from.
    ///
    /// Two consequences of the fetch landing in this context rather than `mainContext` were
    /// considered and are benign:
    ///
    ///   - Object registration. `allFilms` is released when this method returns and nothing
    ///     retains the objects, so they do not accumulate in this long-lived context; a
    ///     `ModelContext` does not retain unmodified fetched objects. No properties are
    ///     mutated either, so the context is left clean and a later `modelContext.save()`
    ///     from any write operation has nothing extra to flush. This is the same lifecycle
    ///     the fetch previously had inside `mainContext`.
    ///
    ///   - Slow-path warmth. When the fingerprint mismatches, MemoryStore follows up with
    ///     the full `mainContext` fetch, which no longer inherits registered objects from
    ///     the fingerprint pass. The shared row cache below the contexts still applies, the
    ///     slow path is already seconds long, and it gains this fetch's duration back on the
    ///     main thread — so the trade is favorable in the case that matters and immaterial
    ///     in the case that does not.
    func computeStoreFingerprint() -> StoreFingerprint? {
        let start = ContinuousClock.now

        // The film layer is read straight from the store file when possible (~5ms), and
        // through SwiftData only when that read declines (see DirectStoreReader). Both feed
        // the same FilmLayerDigest, so the two paths cannot mix a film differently.
        let filmLayer: FilmLayerDigest
        let filmSource: String
        if let direct = DirectStoreReader.filmLayerDigest(storeURL: persistentStoreURL) {
            filmLayer = direct
            filmSource = "direct read"
        } else {
            guard let fetched = fetchFilmLayerDigest() else { return nil }
            filmLayer = fetched
            filmSource = "SwiftData fetch"
        }
        let fetchElapsed = ContinuousClock.now - start

        // List count: no properties or relationships fetched.
        guard let listCount = try? modelContext.fetchCount(FetchDescriptor<ListObject>()) else { return nil }

        // Membership count: no properties or relationships fetched.
        //
        // The predicate is not optional decoration — it is what makes this count
        // comparable to the stored one. The stored side is built by
        // MemoryStoreCache.buildFingerprint as the sum of `MemoryList.filmIDs.count`
        // across every list, and `filmIDs` is a `Set<UUID>` populated by
        // `compactMap { $0.film?.id }`. That construction silently discards two classes
        // of row that an unfiltered `fetchCount` would happily include:
        //
        //   - Orphans: a ListMembership whose film or list relationship is nil
        //     contributes no UUID to the set, but is still a row in the table.
        //   - Duplicates: two rows for the same (film, list) pair collapse into one
        //     element of the set, but remain two rows in the table.
        //
        // Either one makes the live count exceed the stored count forever, and because
        // the fingerprint is an exact-equality check, that is a permanent cache miss —
        // a ~980ms penalty on every single launch, reported in the log as an ordinary
        // mismatch and therefore indistinguishable from "the library legitimately
        // changed." Filtering here eliminates the orphan cause outright; duplicates are
        // handled by cleanupOrphanedAndDuplicateMemberships() below, which corrects the
        // store itself so the discrepancy costs at most one slow launch.
        //
        // This can only ever move the live count *toward* the stored one, never away:
        // the filter is strictly subtractive, and every row it removes is a row the
        // stored side had already excluded. It therefore cannot introduce a mismatch
        // that does not exist today.
        //
        // The unfiltered count is retained as a fallback. If the predicate fails to
        // translate at runtime, degrading to today's behavior — a possible mismatch,
        // the slow path, and correct data — is the right failure mode; returning nil
        // would convert a recoverable condition into a guaranteed cache miss.
        let validMembershipDescriptor = FetchDescriptor<ListMembership>(
            predicate: #Predicate<ListMembership> { $0.film != nil && $0.list != nil })

        let membershipCount: Int
        if let filtered = try? modelContext.fetchCount(validMembershipDescriptor) {
            membershipCount = filtered
        } else if let unfiltered = try? modelContext.fetchCount(FetchDescriptor<ListMembership>()) {
            log("WARNING: Filtered membership count unavailable — falling back to unfiltered count")
            membershipCount = unfiltered
        } else {
            return nil
        }

        log("STARTUP BREAKDOWN (live fingerprint) — "
            + "filmFetch: \(fetchElapsed.formattedMilliseconds) (\(filmSource)) | "
            + "total: \((ContinuousClock.now - start).formattedMilliseconds) | "
            + "films: \(filmLayer.filmCount), lists: \(listCount), memberships: \(membershipCount)")

        return StoreFingerprint(
            filmCount: filmLayer.filmCount,
            xorFingerprint: filmLayer.xor,
            maxLastModified: filmLayer.maxLastModified,
            listCount: listCount,
            membershipCount: membershipCount,
            hofRankFingerprint: filmLayer.hofRankXor,
            userRatingFingerprint: filmLayer.userRatingXor
        )
    }

    /// The SQLite file behind this container, or nil for an in-memory one.
    private var persistentStoreURL: URL? {
        guard let configuration = modelContainer.configurations.first,
              !configuration.isStoredInMemoryOnly else { return nil }
        return configuration.url
    }

    #if DEBUG
    /// Both film-layer paths, for the harness's equivalence check.
    func filmLayerDigestsForTesting() -> (direct: FilmLayerDigest?, fetched: FilmLayerDigest?) {
        (DirectStoreReader.filmLayerDigest(storeURL: persistentStoreURL), fetchFilmLayerDigest())
    }

    /// The direct duplicate-release probe, for the harness.
    func duplicateReleaseProbeForTesting() -> Bool? {
        DirectStoreReader.hasDuplicateReleaseIDs(storeURL: persistentStoreURL)
    }

    /// Spins for `milliseconds` without suspending and returns when it held the actor, so
    /// the harness can prove calls from different threads never overlap.
    func exclusionProbeForTesting(milliseconds: Double) -> (start: UInt64, end: UInt64, onMain: Bool) {
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let onMain = pthread_main_np() != 0
        while Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6 < milliseconds {}
        return (start, clock_gettime_nsec_np(CLOCK_UPTIME_RAW), onMain)
    }
    #endif

    /// The film layer through SwiftData: the fallback when the direct read declines.
    private func fetchFilmLayerDigest() -> FilmLayerDigest? {
        // MEASURED: this fetch is ~980ms for 1,369 films and is roughly 77% of the launch
        // progress indicator's on-screen time. Attribution probing established why, and it is
        // worth recording because the result is counterintuitive:
        //
        //   - It is NOT store-open cost. A trivial count against another table issued first
        //     completes in 2.0ms, so SQLite is open and the schema validated almost instantly.
        //   - `fetchCount(FetchDescriptor<Film>())` over the same 1,369 rows takes 2.0ms, so
        //     the cost is entirely in materializing objects, not in reading the table.
        //   - `propertiesToFetch` below is NOT honored. The identical fetch with the line
        //     removed measured 716ms against 743ms with it — within noise, and marginally
        //     FASTER. SwiftData materializes all 67 stored properties regardless, including
        //     the 20 `[String]` arrays it persists as archived binary blobs. That is the
        //     ~0.54ms per row.
        //
        // The line is kept because it is harmless and documents intent, but it is buying
        // nothing. Any real fix has to avoid instantiating Film objects at all — which is
        // what DirectStoreReader does, reading the same four columns from the store file
        // without going through SwiftData. This fetch remains as its fallback. The cheap
        // substitutes that do not enumerate film UUIDs do not work here:
        //
        //   - (count, max-lastModified) is permanently unsafe for FilmTracker, not merely
        //     unsafe today. An empty `lastModified` is the deliberate sentinel for "never
        //     modified since import" (see 61_00_FilmObj.swift), so an insert can carry a
        //     value lower than every existing one and a balanced add-and-delete leaves both
        //     count and maximum unchanged. Adding max-dateAdded does not close it either:
        //     imports carry the file's own date, not Date().
        //   - A generation counter or dirty flag would be cheap but fails UNSAFE, and there
        //     is no interception point that would make it reliable: writes reach the store
        //     from 24 save() sites here, from DBRestorer's own context, and from mainContext
        //     with autosaveEnabled = true, which commits with no save() call to hook at all.
        //   - Store-file mtime/size fails safe but degenerates to a permanent miss, because
        //     SQLite checkpoints on close and changes the file after the cache is written.
        //
        // The property that makes the check worth having is that it is derived from the
        // data and therefore fails SAFE: anything unaccounted for produces a mismatch, the
        // slow path runs, and the result is correct. Both paths keep that property.
        //
        // `hofPosition` and `userRating` are read in the same loop below and cost nothing
        // extra for precisely the reason documented above: `propertiesToFetch` is not
        // honored, so SwiftData has already materialized all 67 stored properties on every
        // Film by the time this loop runs. Reading two more Ints off objects that are
        // already fully faulted in is free, which is what makes closing the
        // lastModified blind spot (see StoreFingerprint) affordable at all.
        var filmDescriptor = FetchDescriptor<Film>()
        filmDescriptor.propertiesToFetch = [\Film.id, \Film.lastModified,
                                            \Film.hofPosition, \Film.userRating]
        guard let allFilms = try? modelContext.fetch(filmDescriptor) else { return nil }

        var digest = FilmLayerDigest()
        for film in allFilms {
            digest.add(id: film.id, lastModified: film.lastModified,
                       hofPosition: film.hofPosition, userRating: film.userRating)
        }
        return digest
    }

    // MARK: - Startup Cleanup

    /// Identity of a membership as the in-memory model understands it: the
    /// (film, list) pair, with the membership row's own `id` deliberately excluded.
    /// Two rows sharing a pair are duplicates precisely because `MemoryList.filmIDs`
    /// is keyed on the film UUID alone and cannot distinguish them.
    ///
    /// A nested type on the actor rather than a file-scope one: it is an implementation
    /// detail of the cleanup below and has no other call site. It carries no isolation —
    /// nested types are not actor-isolated — so it remains usable as a plain value.
    private struct MembershipPair: Hashable {
        let filmID: UUID
        let listID: UUID
    }

    /// Removes duplicate Release records from the persistent store.
    /// Duplicates (same UUID) were caused by a prior dual-write bug where both
    /// mainContext and DataManager created releases for the same operation.
    /// Keeps the first occurrence of each UUID and deletes the rest.
    func cleanupDuplicateReleases() async throws {
        // Runs every launch, and the fetch below materializes every Release (~590ms for
        // 2,297 in a Debug build). Asking the store directly whether any UUID repeats costs
        // a few milliseconds; only a definite "no" skips the fetch, so a probe that cannot
        // answer falls through to the full pass exactly as before.
        if DirectStoreReader.hasDuplicateReleaseIDs(storeURL: persistentStoreURL) == false { return }

        let allReleases = try modelContext.fetch(FetchDescriptor<Release>())
        var seen = Set<UUID>()
        var duplicates: [Release] = []
        for release in allReleases {
            if seen.contains(release.id) {
                duplicates.append(release)
            } else {
                seen.insert(release.id)
            }
        }
        guard !duplicates.isEmpty else { return }

        log("Removing \(duplicates.count) duplicate Release record(s)")
        for release in duplicates { modelContext.delete(release) }
        try commit()
        log("Duplicate Release cleanup complete")
    }

    /// Rewrites every Release still holding a legacy single-element `marketAvailability` tag
    /// ("OOP (cheap)") in the two-component format. See ReleaseMarketAvailability.
    ///
    /// Memory never sees the legacy tags — ReleaseSnapshot migrates them on conversion, and
    /// MemoryStore declines a snapshot cache that still holds one — so this only brings the
    /// store itself into line. DataCoordinator calls it once at startup, and only when
    /// MemoryStore saw a legacy tag during load, since the fetch materializes every Release.
    /// Film.lastModified is not touched, so the snapshot-cache fingerprint is unaffected.
    func migrateLegacyMarketAvailability() async throws {
        let allReleases = try modelContext.fetch(FetchDescriptor<Release>())
        var count = 0
        for release in allReleases
        where ReleaseMarketAvailability.needsMigration(release.marketAvailability) {
            release.marketAvailability = ReleaseMarketAvailability.migrated(release.marketAvailability)
            count += 1
        }
        guard count > 0 else { return }
        try commit()
        log("Migrated market availability on \(count) release(s)")
    }

    /// Removes ListMembership records that are structurally meaningless: those whose
    /// film or list relationship is nil (orphans), and redundant rows for a
    /// (film, list) pair that is already represented (duplicates).
    ///
    /// Called once at startup by DataCoordinator, deferred until after the UI is
    /// interactive. Runs entirely in the background context — no mainContext
    /// involvement. Returns the number of each kind removed.
    ///
    /// Both classes are safe to delete by definition rather than by assumption. An
    /// orphan references nothing and can never be resolved back to a film or a list.
    /// A second row for the same (film, list) pair is not a distinguishable state:
    /// `MemoryList.filmIDs` is a `Set<UUID>`, so the in-memory model — which is what
    /// the entire UI reads from — already treats the pair as a single membership and
    /// has no way to represent it otherwise.
    ///
    /// Why this is worth doing at all: both classes inflate the live membership count
    /// in computeStoreFingerprint above without inflating the stored one, which is a
    /// permanent snapshot-cache miss and a ~980ms penalty on every launch until the
    /// store is corrected. The predicate there already neutralizes orphans at read
    /// time; this pass is what neutralizes duplicates, converting "slow forever" into
    /// "slow once, then healed":
    ///
    ///   - Launch N:   312 rows (311 valid + 1 duplicate) vs. 311 in memory →
    ///                 mismatch → slow path → correct data.
    ///   - After UI ready: this cleanup deletes the duplicate; the store is now 311.
    ///   - Launch N+1: 311 == 311 → fast path.
    ///
    /// The ordering is robust regardless of whether the snapshot cache saves before or
    /// after this cleanup runs, because the cache's count always derives from memory
    /// (311) and this cleanup only ever moves the store toward that number, never away
    /// from it.
    ///
    /// Duplicate resolution keeps the row ordered first by `(dateAdded, sortOrder, id)`
    /// and deletes the rest. Keeping the earliest addition preserves the membership's
    /// original position — `ListObject.filmIDs` orders by `sortOrder` — and the `id`
    /// tie-break makes the outcome fully deterministic even
    /// when two rows share a timestamp, so repeated runs cannot pick different
    /// survivors and shift ordering.
    ///
    /// Deleting a ListMembership directly is sufficient to keep the object graph
    /// consistent: both `Film.memberships` and `ListObject.memberships` declare it as
    /// their inverse, so SwiftData removes the deleted row from each parent's array.
    func cleanupOrphanedAndDuplicateMemberships() async throws -> (orphans: Int, duplicates: Int) {
        #if DEBUG
        let threadProbe = DataManagerThreadProbe.begin("cleanupOrphanedAndDuplicateMemberships")
        defer { threadProbe?.end() }
        #endif

        let allMemberships = try modelContext.fetch(FetchDescriptor<ListMembership>())

        var orphaned: [ListMembership] = []
        var valid: [ListMembership] = []
        for membership in allMemberships {
            // Read each relationship once, partitioning in the same pass over the fetch
            // that the duplicate scan below consumes.
            if membership.film == nil || membership.list == nil {
                orphaned.append(membership)
            } else {
                valid.append(membership)
            }
        }

        // Duplicates are detected only among valid rows. An orphan has no resolvable
        // (film, list) pair to key on, and every orphan is being deleted regardless —
        // including them could only produce a nil-keyed bucket with no meaning.
        //
        // One pass keeps the survivor per pair: the row that orders first by
        // (dateAdded, sortOrder, id). This picks exactly the row that sorting every valid
        // membership and keeping the first per pair would, without sorting the whole
        // table on every launch to find what is almost always zero duplicates.
        func ordersBefore(_ lhs: ListMembership, _ rhs: ListMembership) -> Bool {
            if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded < rhs.dateAdded }
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var survivorByPair: [MembershipPair: ListMembership] = [:]
        var duplicates: [ListMembership] = []
        for membership in valid {
            // Force-unwrap is avoided deliberately: `valid` was built from a nil check,
            // but re-deriving the IDs defensively costs nothing and keeps this loop
            // correct even if the partitioning above is ever changed.
            guard let filmID = membership.film?.id,
                  let listID = membership.list?.listID else { continue }

            let pair = MembershipPair(filmID: filmID, listID: listID)
            if let current = survivorByPair[pair] {
                if ordersBefore(membership, current) {
                    duplicates.append(current)
                    survivorByPair[pair] = membership
                } else {
                    duplicates.append(membership)
                }
            } else {
                survivorByPair[pair] = membership
            }
        }

        guard !orphaned.isEmpty || !duplicates.isEmpty else { return (0, 0) }

        // Last cancellation check before anything destructive is staged. AppDelegate
        // cancels the deferred-maintenance task at shutdown specifically so that
        // maintenance deletions do not run mid-process-exit; honoring that here means
        // the check covers this pass too, not just the poster pruner that precedes it.
        // Checked after the analysis and before the first delete so a cancellation can
        // never leave the context holding staged deletions.
        try Task.checkCancellation()

        var removedOrphans = 0
        var removedDuplicates = 0

        // `modelContext != nil` mirrors the guard already used at the membership-delete
        // site in saveFilmChangeset. Nothing can invalidate these objects between the
        // fetch above and here — this method contains no suspension point, so it runs as
        // one atomic unit on the actor — but a restore running against its own separate
        // context is outside that guarantee, and deleting an already-detached object is
        // the one thing worth being defensive about. Counting actual deletions rather
        // than candidate counts keeps the returned numbers truthful if the guard ever
        // does skip one.
        for membership in orphaned where membership.modelContext != nil {
            modelContext.delete(membership)
            removedOrphans += 1
        }
        for membership in duplicates where membership.modelContext != nil {
            modelContext.delete(membership)
            removedDuplicates += 1
        }

        guard removedOrphans > 0 || removedDuplicates > 0 else { return (0, 0) }

        // A single save for both classes. They are two symptoms of the same structural
        // problem and there is no state in which committing one without the other is
        // preferable, so an all-or-nothing transaction is the correct granularity.
        //
        // On failure the staged deletions must be discarded rather than left pending.
        // This ModelContext is long-lived and shared by every subsequent DataManager
        // operation, so uncommitted deletions would otherwise ride along on the next
        // unrelated `save()` — and, in the case that matters, if the save failed
        // *because of* these deletions, every later save in the session would fail too,
        // silently breaking all persistence rather than just this maintenance pass.
        // Rolling back is safe here: every other method on this actor saves before it
        // suspends, so the context holds no unrelated pending changes at this point.
        try commit()

        return (removedOrphans, removedDuplicates)
    }

    // MARK: - Film Operations
    func batchInsertFilms(_ snapshots: [FilmSnapshot]) async throws {
        #if DEBUG
        let threadProbe = DataManagerThreadProbe.begin("batchInsertFilms")
        defer { threadProbe?.end() }
        #endif

        guard !snapshots.isEmpty else { return }

        for batch in snapshots.chunked(into: batchSize) {
            try Task.checkCancellation()

            for snapshot in batch { modelContext.insert(snapshot.toFilm()) }
            try commit() } }

    func updateFilm(_ snapshot: FilmSnapshot) async throws {
        #if DEBUG
        let threadProbe = DataManagerThreadProbe.begin("updateFilm")
        defer { threadProbe?.end() }
        #endif

        let filmID = snapshot.id
        let descriptor = FetchDescriptor<Film>(predicate: #Predicate<Film> { $0.id == filmID })

        guard let film = try modelContext.fetch(descriptor).first else {
            throw PersistenceError.filmNotFound(filmID) }

        snapshot.apply(to: film)
        try commit() }

    /// Atomically applies scalar property changes for multiple films in a single transaction.
    ///
    /// Used by the multi-film persistence paths (Hall of Fame add/remove/reorder) where
    /// several FilmSnapshots must be committed together. A single fetch + single
    /// modelContext.save() guarantees all-or-nothing semantics: if the save fails, the
    /// background context is discarded and nothing is committed, so SwiftData never ends
    /// up in a partial state that the rollback closure (which restores MemoryStore in full)
    /// would silently diverge from.
    ///
    /// Films that no longer exist in the database (e.g. deleted between the in-memory
    /// reorder and this background persist) are skipped rather than throwing. There is no
    /// meaningful persistence target for a deleted film, and skipping it lets the valid
    /// position updates for the remaining films commit normally instead of forcing a full
    /// rollback of an otherwise-successful reorder.
    func updateFilms(_ snapshots: [FilmSnapshot]) async throws {
        #if DEBUG
        let threadProbe = DataManagerThreadProbe.begin("updateFilms")
        defer { threadProbe?.end() }
        #endif

        guard !snapshots.isEmpty else { return }

        let ids = Set(snapshots.map { $0.id })
        let descriptor = FetchDescriptor<Film>(
            predicate: #Predicate<Film> { ids.contains($0.id) })
        let films = try modelContext.fetch(descriptor)

        // Build a UUID → Film lookup. uniquingKeysWith guards against the (impossible
        // under the unique-id constraint, but defensively handled) case of duplicate keys.
        let filmByID = Dictionary(films.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var appliedCount = 0
        for snapshot in snapshots {
            guard let film = filmByID[snapshot.id] else {
                log("WARNING: updateFilms — film \(snapshot.id) not found in database (likely deleted); skipping")
                continue
            }
            snapshot.apply(to: film)
            appliedCount += 1
        }

        // Nothing matched — no changes to commit.
        guard appliedCount > 0 else { return }

        try commit() }

    func deleteFilms(withIDs ids: Set<UUID>) async throws {
        #if DEBUG
        let threadProbe = DataManagerThreadProbe.begin("deleteFilms")
        defer { threadProbe?.end() }
        #endif

        guard !ids.isEmpty else { return }

        // Explicitly delete ListMembership objects before deleting films.
        // SwiftData's cascade delete is unreliable for objects created within the same
        // session. Explicit pre-deletion ensures no orphaned memberships remain regardless
        // of when the films were originally created.
        let allMemberships = try modelContext.fetch(FetchDescriptor<ListMembership>())
        let membershipsToDelete = allMemberships.filter { membership in
            guard let filmID = membership.film?.id else {
                return true // also purge pre-existing orphans
            }
            return ids.contains(filmID)
        }
        for membership in membershipsToDelete {
            modelContext.delete(membership)
        }

        // Delete the films themselves.
        let descriptor = FetchDescriptor<Film>(
            predicate: #Predicate<Film> { ids.contains($0.id) })
        let films = try modelContext.fetch(descriptor)

        for film in films { modelContext.delete(film) }
        try commit() }
    
    /// Resets rotation threshold overrides to nil for the specified film IDs.
    ///
    /// Accepts the exact set of IDs pre-identified by DataCoordinator so the fetch
    /// is targeted rather than a full-table scan.  Operates exclusively on the
    /// background ModelContext - never touches mainContext.
    ///
    /// ONE TRANSACTION, deliberately. This used to commit in `batchSize` chunks, each a
    /// separate `save()`, on the theory that it kept memory pressure low — but the fetch
    /// below already materializes every target film in one call, so chunked saves bought
    /// nothing. What they cost was real: a failure partway through left the earlier chunks
    /// committed while the caller's rollback closure
    /// (`DataCoordinator.resetAllRotationThresholdOverrides`) restored every film in
    /// MemoryStore, and that divergence never self-corrected — `rotationThresholdOverride`
    /// does not bump `lastModified` and is not in the snapshot-cache fingerprint, so the next
    /// launch validated the cache, served memory's values, and never re-read the database.
    /// A single `commit()` either applies the whole reset or discards all of it, which is
    /// exactly the contract the rollback closure is written against.
    func resetRotationThresholdOverrides(for ids: Set<UUID>) async throws {
        try resetFilms(ids) { $0.rotationThresholdOverride = nil }
    }

    /// Resets the `infoComplete` flag to `false` for all films in the specified ID set.
    ///
    /// Mirrors `resetRotationThresholdOverrides(for:)` exactly, including its
    /// single-transaction contract and the reason for it: `infoComplete` likewise does not
    /// bump `lastModified` and is not in the fingerprint, so a partial commit would diverge
    /// from MemoryStore silently and permanently. See that method's note.
    func resetInfoCompleteFlags(for ids: Set<UUID>) async throws {
        try resetFilms(ids) { $0.infoComplete = false }
    }

    /// The single-transaction reset both methods above describe: fetch exactly the
    /// targeted films in one round trip, apply `reset` to each, commit once.
    private func resetFilms(_ ids: Set<UUID>, _ reset: (Film) -> Void) throws {
        guard !ids.isEmpty else { return }

        let descriptor = FetchDescriptor<Film>(
            predicate: #Predicate<Film> { ids.contains($0.id) }
        )
        let films = try modelContext.fetch(descriptor)
        guard !films.isEmpty else { return }

        // Nothing destructive is staged before this check, so a cancellation can never
        // leave the context holding a half-applied reset.
        try Task.checkCancellation()

        for film in films { reset(film) }
        try commit()
    }

    // MARK: - Atomic Film Changeset Persistence

    /// Applies a complete FilmChangeset atomically in the background context.
    /// This is the single persistence entry point for all FilmSheet save operations.
    /// All @Model objects are fetched and created within this context - no cross-context access.
    ///
    /// Operations performed (in order):
    ///   1. Fetch or create the Film
    ///   2. Apply scalar Film properties from FilmSnapshot (every field, or the changeset's delta)
    ///   3. Apply derived values (lastWatched, viewCount, lastModified, numberOfDiscs)
    ///   4. Delete removed releases
    ///   5. Update existing releases
    ///   6. Create new releases
    ///   7. Remove list memberships
    ///   8. Add list memberships
    ///   9. Save context (single atomic transaction)
    ///
    /// Thread safety: This method runs entirely within DataManager's @ModelActor context.
    /// All @Model objects are fetched locally - no objects cross actor boundaries.
    func applyFilmChangeset(_ changeset: FilmChangeset) async throws {
        #if DEBUG
        let threadProbe = DataManagerThreadProbe.begin("applyFilmChangeset")
        defer { threadProbe?.end() }
        #endif

        let filmID = changeset.filmID

        // Step 1: Fetch or create the Film in this context.
        // For new films, DataCoordinator.saveFilmChangeset adds the film to MemoryStore
        // (optimistic update) and then dispatches this changeset via trackOperation.
        // DataManager is therefore the first (and only) place the Film @Model object is
        // created in the persistent store — it is inserted here in the background context
        // and never touches mainContext.
        //
        // For existing films the fetch will always find the record (it was created in a
        // prior session). The else-if branch below handles the hypothetical case where an
        // in-flight new-film operation is received before a previous session's records are
        // fully flushed, which in practice should not occur.
        let film: Film
        let descriptor = FetchDescriptor<Film>(
            predicate: #Predicate<Film> { $0.id == filmID })
        if let existingFilm = try modelContext.fetch(descriptor).first {
            film = existingFilm
        } else if changeset.isNewFilm {
            // New film: insert directly into this background context.
            // This is the primary (not fallback) path for new film persistence.
            film = Film()
            film.id = filmID
            modelContext.insert(film)
        } else {
            throw PersistenceError.filmNotFound(filmID)
        }

        // Step 2: Apply scalar Film properties from snapshot — every field for a new film,
        // otherwise only the fields the FilmSheet's three-way merge changed, so a field
        // the save did not touch keeps whatever an earlier operation committed. The derived
        // values (lastWatched, viewCount, lastModified, numberOfDiscs) are ordinary fields
        // here: written by the whole-snapshot apply, and by the delta when it lists them.
        if let fields = changeset.changedFields, !changeset.isNewFilm {
            for field in fields { field.apply(changeset.filmSnapshot, to: film) }
        } else {
            changeset.filmSnapshot.apply(to: film)
        }

        // Step 4: Delete removed releases.
        if !changeset.releasesToDelete.isEmpty {
            let existingReleases = film.releases
            for releaseID in changeset.releasesToDelete {
                if let release = existingReleases.first(where: { $0.id == releaseID }) {
                    modelContext.delete(release)
                }
            }
        }

        // Step 5: Update existing releases.
        for snapshot in changeset.releasesToUpdate {
            if let release = film.releases.first(where: { $0.id == snapshot.id }) {
                snapshot.apply(to: release)
            }
        }

        // Step 6: Create new releases.
        for snapshot in changeset.releasesToCreate {
            let release = snapshot.toRelease(film: film)
            modelContext.insert(release)
        }

        // Step 6.5: Link release parent-child hierarchy.
        //
        // ReleaseSnapshot.apply(to:) and toRelease(film:) intentionally do not touch
        // parentRelease / childReleases because those are SwiftData object-graph
        // relationships that require live Release references, not scalar values.
        // All new and updated snapshots that carry a parentReleaseID must have their
        // SwiftData relationship established here, after every Release @Model object
        // for this film is guaranteed to exist in the context.
        //
        // The approach:
        //   1. Build a UUID → Release lookup over the film's current releases.
        //   2. For each created or updated snapshot that has a parentReleaseID, resolve
        //      the parent Release and set childRelease.parentRelease = parentRelease.
        //      SwiftData's inverse maintenance automatically populates parentRelease.childReleases.
        //   3. For each snapshot whose parentReleaseID is nil (i.e., newly promoted to
        //      top-level because the user changed independence away from Combo-pack and
        //      already removed the link in-session), clear the SwiftData relationship so
        //      the DB stays in sync with the in-memory model.
        //
        // The one-level-depth constraint (no grandchildren) is already enforced at the
        // UI layer in FSTabReleases; this step trusts the snapshots it receives.
        let hierarchySnapshots = changeset.releasesToCreate + changeset.releasesToUpdate
        if !hierarchySnapshots.isEmpty {
            // Build the lookup map once — O(n) over film.releases which is tiny in practice.
            var releaseByID = [UUID: Release](minimumCapacity: film.releases.count)
            for release in film.releases { releaseByID[release.id] = release }

            for snapshot in hierarchySnapshots {
                guard let childRelease = releaseByID[snapshot.id] else { continue }

                if let parentID = snapshot.parentReleaseID {
                    // Link to parent (no-op if the relationship is already correct, e.g. on a
                    // subsequent save without hierarchy changes — SwiftData does not dirty-track
                    // a relationship assignment that doesn't change the value).
                    if let parentRelease = releaseByID[parentID] {
                        childRelease.parentRelease = parentRelease
                        // Inverse maintenance, explicitly. Assigning the to-one side is
                        // supposed to populate `parentRelease.childReleases` on its own,
                        // and normally does — but the FilmSheet's combo-pack logic reads
                        // the parent side (see FSTabReleases.comboChildren) and a store
                        // in which the inverse did not follow presents as a combo-pack
                        // parent with no children: no deletion confirmation, no combined
                        // card, and children strandable as locked orphans. The check is
                        // idempotent (skipped whenever the array already agrees), so when
                        // SwiftData does its job this costs one array scan of two or three
                        // elements and writes nothing.
                        if !parentRelease.childReleases.contains(where: { $0.id == childRelease.id }) {
                            parentRelease.childReleases.append(childRelease)
                        }
                    } else {
                        // Parent UUID not found in this film's releases — log and skip.
                        // This would indicate a data integrity problem upstream; restoring as
                        // top-level is the safe fallback (no data is lost, just the link).
                        Self.log("WARNING: parentReleaseID \(parentID) not found for release \(snapshot.id) — persisting as top-level")
                        childRelease.parentRelease = nil
                    }
                } else {
                    // No parent — ensure any stale parentRelease link is cleared.
                    // This handles the case where a user reverted a Combo-pack parent
                    // and the child was removed in-session, but the existing DB record
                    // still carries the old parentRelease pointer from a previous save.
                    if let formerParent = childRelease.parentRelease {
                        childRelease.parentRelease = nil
                        // Same inverse maintenance as the link branch above, in the other
                        // direction: a stale entry left in the former parent's array would
                        // make it read as still owning a release that no longer names it,
                        // inflating its apparent child count.
                        formerParent.childReleases.removeAll { $0.id == childRelease.id }
                    }
                }
            }
        }

        // Step 7: Remove list memberships.
        if !changeset.listsToRemove.isEmpty {
            let allMemberships = Array(film.memberships)
            for membership in allMemberships {
                // Guard against accessing deleted/detached objects
                guard membership.modelContext != nil,
                      let listID = membership.list?.listID else { continue }
                if changeset.listsToRemove.contains(listID) {
                    modelContext.delete(membership)
                }
            }
        }

        // Step 8: Add list memberships.
        if !changeset.listsToAdd.isEmpty {
            let listsToAdd = changeset.listsToAdd
            let listDescriptor = FetchDescriptor<ListObject>(
                predicate: #Predicate<ListObject> { listsToAdd.contains($0.listID) })
            let lists = try modelContext.fetch(listDescriptor)
            let currentDate = Date()
            // The lists the film already belongs to, extended as rows are inserted below, so
            // two ListObject records sharing a listID (a corrupted or partial restore) can
            // never yield a second row for the same (film, list) pair.
            var memberListIDs = Set(film.memberships.compactMap { $0.list?.listID })
            for list in lists {
                // Skip lists the film is already a member of, to prevent duplicates.
                guard memberListIDs.insert(list.listID).inserted else { continue }

                let maxSortOrder = list.memberships.map { $0.sortOrder }.max() ?? -1
                let membership = ListMembership(
                    film: film, list: list, dateAdded: currentDate,
                    sortOrder: maxSortOrder + 1)
                modelContext.insert(membership)
            }
        }

        // Step 9: Single atomic save.
        try commit()
    }

    // MARK: - Individual Release Operations (Right Sidebar)

    /// Atomically applies property changes for multiple releases in a single transaction.
    ///
    /// Used by the wishlist reorder persistence path, where every reordered release must be
    /// committed together. Releases are grouped by film so each Film is fetched exactly once,
    /// all snapshots are applied, and a single modelContext.save() commits the batch — giving
    /// all-or-nothing semantics. If the save fails, nothing is committed, so SwiftData never
    /// diverges from the MemoryStore state that the rollback closure restores in full.
    ///
    /// Films or releases that no longer exist (deleted between the in-memory reorder and this
    /// background persist) are skipped rather than throwing, so a single stale entry cannot
    /// force a full rollback of an otherwise-successful reorder.
    func updateReleases(_ units: [(filmID: UUID, snapshot: ReleaseSnapshot)]) async throws {
        #if DEBUG
        let threadProbe = DataManagerThreadProbe.begin("updateReleases")
        defer { threadProbe?.end() }
        #endif

        guard !units.isEmpty else { return }

        // Group release snapshots by film so each Film is fetched and processed once.
        var snapshotsByFilm: [UUID: [ReleaseSnapshot]] = [:]
        for unit in units {
            snapshotsByFilm[unit.filmID, default: []].append(unit.snapshot)
        }

        let filmIDs = Set(snapshotsByFilm.keys)
        let descriptor = FetchDescriptor<Film>(
            predicate: #Predicate<Film> { filmIDs.contains($0.id) })
        let films = try modelContext.fetch(descriptor)
        let filmByID = Dictionary(films.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var appliedCount = 0
        for (filmID, releaseSnapshots) in snapshotsByFilm {
            guard let film = filmByID[filmID] else {
                log("WARNING: updateReleases — film \(filmID) not found in database (likely deleted); skipping \(releaseSnapshots.count) release(s)")
                continue
            }

            // O(1) release lookup for this film.
            var releaseByID = [UUID: Release](minimumCapacity: film.releases.count)
            for release in film.releases { releaseByID[release.id] = release }

            var filmTouched = false
            for snapshot in releaseSnapshots {
                guard let release = releaseByID[snapshot.id] else {
                    log("WARNING: updateReleases — release \(snapshot.id) not found on film \(filmID); skipping")
                    continue
                }
                snapshot.apply(to: release)
                filmTouched = true
                appliedCount += 1
            }

            // Recalculate numberOfDiscs only when a release on this film actually changed,
            // mirroring the per-film recompute the singular update path performed.
            if filmTouched {
                let totalDiscs = film.releases.filter { $0.purchased }.reduce(0) { $0 + $1.numberOfDiscs }
                film.numberOfDiscs = "\(totalDiscs)"
            }
        }

        guard appliedCount > 0 else { return }

        try commit()
    }

    // MARK: - List Membership Operations
    /// Batch add films to lists with existence validation.
    /// Before creating any ListMembership, we verify the Film still exists
    /// in the database. This prevents creating orphaned memberships if a
    /// film was deleted between when the operation was scheduled and when
    /// it actually executes.
    func batchAddFilmsToLists(filmIDs: Set<UUID>, listIDs: Set<UUID>) async throws {
        #if DEBUG
        let threadProbe = DataManagerThreadProbe.begin("batchAddFilmsToLists")
        defer { threadProbe?.end() }
        #endif

        guard !filmIDs.isEmpty && !listIDs.isEmpty else { return }

        let currentDate = Date()

        let listDescriptor = FetchDescriptor<ListObject>(
            predicate: #Predicate<ListObject> { listIDs.contains($0.listID) })
        let lists = try modelContext.fetch(listDescriptor)

        guard !lists.isEmpty else { return }

        // uniquingKeysWith rather than uniqueKeysWithValues: the latter traps on a duplicate
        // key, so two ListObject records sharing a listID — which a corrupted or partially
        // completed restore can leave behind — would crash the app here instead of degrading.
        // Keeping the first occurrence matches the defensive pattern already used by
        // updateFilms and updateReleases. The type is spelled out because the Value here is
        // itself a labeled tuple, which the uniquingKeysWith overload cannot always infer.
        let listDict: [UUID: (object: ListObject, maxSort: Int)] = Dictionary(
            lists.map { ($0.listID, (object: $0, maxSort: $0.memberships.map {
                $0.sortOrder }.max() ?? -1)) },
            uniquingKeysWith: { first, _ in first })

        // Fetch films fresh from database to verify they exist.
        // This is critical because the filmIDs passed in might reference films that
        // have been deleted between when this operation was scheduled and when it
        // actually runs. We must verify existence before creating relationships.
        let filmDescriptor = FetchDescriptor<Film>(
            predicate: #Predicate<Film> { filmIDs.contains($0.id) })
        let films = try modelContext.fetch(filmDescriptor)
        
        // Log if any films were not found (indicates they were deleted)
        if films.count != filmIDs.count {
            let foundIDs = Set(films.map { $0.id })
            let missingIDs = filmIDs.subtracting(foundIDs)
            Self.log("WARNING: \(missingIDs.count) film(s) not found in database (likely deleted): \(missingIDs)")
        }

        guard !films.isEmpty else {
            Self.log("SAFETY: All films were deleted, skipping batchAddFilmsToLists")
            return }

        var currentMaxSorts = listDict.mapValues { $0.maxSort }
        var operationCount = 0

        // Existing memberships come from the ListObjects already fetched above, not from a
        // full-table FetchDescriptor<ListMembership>(). `ListObject.memberships` is the
        // declared inverse of `ListMembership.list`, so a list's membership array IS exactly
        // the set of rows a whole-table scan would have kept for that listID — and the array
        // is already faulted in, because `listDict` computes each list's `maxSort` from it
        // one statement earlier. The old scan therefore read every membership row in the
        // library (all lists, not just the targeted ones) to derive a subset already in hand.
        //
        // Iterating `lists` rather than `listDict.values` is deliberate: `listDict` collapses
        // duplicate ListObject records sharing one listID down to the first occurrence, and
        // the memberships hanging off the discarded twin must still count as "already exists"
        // here or this method would insert a redundant row for that (film, list) pair. The
        // whole-table scan unioned them via its listID key; unioning across `lists` preserves
        // that exactly.
        var existingMembershipsByList: [UUID: Set<UUID>] = [:]
        for list in lists {
            for membership in list.memberships {
                guard let filmID = membership.film?.id else { continue }
                existingMembershipsByList[list.listID, default: []].insert(filmID)
            }
        }

        for listID in listIDs {
            guard let listInfo = listDict[listID] else { continue }

            let existingFilmIDs = existingMembershipsByList[listID] ?? []

            for film in films {
                // Skip if membership already exists
                if existingFilmIDs.contains(film.id) { continue }
                
                // Additional safety: Double-check film is still valid before creating membership.
                // This guards against the film being deleted during this batch operation.
                guard film.modelContext != nil else {
                    log("SAFETY: Film \(film.id) no longer has valid context, skipping")
                    continue
                }

                currentMaxSorts[listID] = (currentMaxSorts[listID] ?? -1) + 1
                let membership = ListMembership(film: film, list: listInfo.object,
                    dateAdded: currentDate, sortOrder: currentMaxSorts[listID]!)
                modelContext.insert(membership)

                operationCount += 1

                if operationCount >= batchSize {
                    try commit()
                    operationCount = 0
                    try? await Task.sleep(for: .milliseconds(10))
                    try Task.checkCancellation() } } }

        if operationCount > 0 { try commit() }
    }

    func batchRemoveFilmsFromLists(filmIDs: Set<UUID>, listIDs: Set<UUID>) async throws {
        #if DEBUG
        let threadProbe = DataManagerThreadProbe.begin("batchRemoveFilmsFromLists")
        defer { threadProbe?.end() }
        #endif

        guard !filmIDs.isEmpty && !listIDs.isEmpty else { return }

        var operationCount = 0

        // Targeted rather than a full-table FetchDescriptor<ListMembership>() scan: fetch
        // only the named lists, then walk their `memberships` inverse arrays. The rows this
        // reaches are exactly the rows the old whole-library scan kept — its filter required
        // `membership.list?.listID` to be in `listIDs`, which is the same predicate as "hangs
        // off one of these ListObjects", and a row with a nil `list` appeared in neither.
        // Snapshotted into `toDelete` before any delete so the relationship arrays are never
        // mutated mid-iteration.
        let listDescriptor = FetchDescriptor<ListObject>(
            predicate: #Predicate<ListObject> { listIDs.contains($0.listID) })
        let lists = try modelContext.fetch(listDescriptor)

        var toDelete: [ListMembership] = []
        for list in lists {
            for membership in list.memberships {
                guard let filmID = membership.film?.id, filmIDs.contains(filmID) else { continue }
                toDelete.append(membership)
            }
        }

        for membership in toDelete {
            modelContext.delete(membership)
            operationCount += 1

            if operationCount >= batchSize {
                try commit()
                operationCount = 0
                try? await Task.sleep(for: .milliseconds(10))
                try Task.checkCancellation() } }

        if operationCount > 0 { try commit() } }

    /// Applies a Film Queue section move as ONE transaction: every membership row named by
    /// (`removalFilmIDs` × `removalListIDs`) is deleted, every film in `filmIDs` that is not
    /// already a member of `targetListID` is inserted, and a single `save()` commits both
    /// halves together.
    ///
    /// WHY THIS EXISTS RATHER THAN TWO CALLS
    ///
    /// A queue move is one user gesture but two membership edits, and calling
    /// `batchRemoveFilmsFromLists` then `batchAddFilmsToLists` commits them as two separate
    /// transactions. If the second failed after the first had committed, the film had left
    /// its old section and never arrived in the new one — a state the caller's rollback
    /// restores in memory but cannot un-commit on disk, so it reappeared on the next cold
    /// launch. Staging both halves against the same context and saving once removes that
    /// window entirely: either the whole move is durable or none of it is.
    ///
    /// This does NOT replace the two batch methods. They carry bulk work (imports,
    /// multi-list adds) and commit incrementally in `batchSize` chunks to keep memory
    /// pressure bounded, which is incompatible with all-or-nothing by construction. A move
    /// is bounded by the films the user selected and touches at most three lists, so there
    /// is no batch here worth splitting and atomicity costs nothing.
    ///
    /// Ordering is deliberate: the target list and every film are resolved BEFORE anything
    /// is staged, so a missing target or a fully-deleted film set returns having changed
    /// nothing rather than committing a removal whose matching insertion can never happen.
    func moveFilmsBetweenLists(filmIDs: Set<UUID>,
                               removalFilmIDs: Set<UUID>,
                               removalListIDs: Set<UUID>,
                               addingTo targetListID: UUID) async throws {

        guard !filmIDs.isEmpty else { return }

        // Resolve the target and every source list in one fetch.
        let involvedListIDs = removalListIDs.union([targetListID])
        let listDescriptor = FetchDescriptor<ListObject>(
            predicate: #Predicate<ListObject> { involvedListIDs.contains($0.listID) })
        let lists = try modelContext.fetch(listDescriptor)

        guard let target = lists.first(where: { $0.listID == targetListID }) else {
            Self.log("SAFETY: target list \(targetListID) not found, skipping moveFilmsBetweenLists")
            return
        }

        // Same existence validation batchAddFilmsToLists performs: a film deleted between
        // this operation being scheduled and running must not gain a membership row.
        let filmDescriptor = FetchDescriptor<Film>(
            predicate: #Predicate<Film> { filmIDs.contains($0.id) })
        let films = try modelContext.fetch(filmDescriptor)
        if films.count != filmIDs.count {
            let missing = filmIDs.subtracting(Set(films.map { $0.id }))
            Self.log("WARNING: \(missing.count) film(s) not found in database (likely deleted): \(missing)")
        }
        guard !films.isEmpty else {
            Self.log("SAFETY: All films were deleted, skipping moveFilmsBetweenLists")
            return
        }

        // --- Stage the removals. Reaches the same rows batchRemoveFilmsFromLists would:
        //     those hanging off one of the source ListObjects whose film is also named.
        var removed = 0
        if !removalFilmIDs.isEmpty, !removalListIDs.isEmpty {
            var toDelete: [ListMembership] = []
            for list in lists where removalListIDs.contains(list.listID) {
                for membership in list.memberships {
                    guard let filmID = membership.film?.id,
                          removalFilmIDs.contains(filmID) else { continue }
                    toDelete.append(membership)
                }
            }
            for membership in toDelete {
                modelContext.delete(membership)
                removed += 1
            }
        }

        // --- Stage the insertions. The target's memberships are unaffected by the deletions
        //     above: `removalListIDs` is built by subtracting the target from the three
        //     internal sections, so the source lists are disjoint from it by construction.
        //
        //     Read across EVERY fetched ListObject carrying the target's listID, not just
        //     the one `first(where:)` returned. A corrupted or partially completed restore
        //     can leave two ListObject rows sharing a listID, and a membership hanging off
        //     the twin this method did not pick still means the film is a member — missing
        //     it would insert a redundant second row for that (film, list) pair. This
        //     matches what batchAddFilmsToLists does for the same reason; the sortOrder
        //     high-water mark is taken across both for the same reason again.
        var existingFilmIDs = Set<UUID>()
        var maxSort = -1
        for list in lists where list.listID == targetListID {
            for membership in list.memberships {
                if let filmID = membership.film?.id { existingFilmIDs.insert(filmID) }
                maxSort = max(maxSort, membership.sortOrder)
            }
        }

        let currentDate = Date()
        var inserted = 0
        for film in films {
            if existingFilmIDs.contains(film.id) { continue }
            guard film.modelContext != nil else {
                log("SAFETY: Film \(film.id) no longer has valid context, skipping")
                continue
            }
            maxSort += 1
            modelContext.insert(ListMembership(film: film, list: target,
                                               dateAdded: currentDate, sortOrder: maxSort))
            inserted += 1
        }

        guard removed > 0 || inserted > 0 else { return }

        // The single commit both halves have been staged for.
        try commit()
        log("Moved film(s) between lists in one transaction: \(removed) membership(s) removed, \(inserted) inserted")
    }

    // MARK: - Import Session Operations

    /// Deletes a single ImportSession by its UUID.
    func deleteImportSession(id: UUID) async throws {
        let descriptor = FetchDescriptor<ImportSession>(
            predicate: #Predicate { $0.id == id })
        guard let session = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(session)
        try commit()
    }

    /// Deletes all ImportSession records whose `importType` matches the given string
    /// (either "metadata" or "ratings"). Leaves sessions of the other type untouched.
    ///
    /// In-progress sessions (`isCompleted == false && isCanceled == false`) are
    /// intentionally skipped. ImportProgress writes the active session's final state
    /// through mainContext after the import finishes; deleting its record here would
    /// cause completeSession()/updateSessionAsCanceled() to silently find nothing and
    /// produce no persistent record for the completed run.
    func deleteAllImportSessions(ofType importType: String) async throws {
        let descriptor = FetchDescriptor<ImportSession>(
            predicate: #Predicate { $0.importType == importType })
        let sessions = try modelContext.fetch(descriptor)
        guard !sessions.isEmpty else { return }
        // Skip any session that is still in progress to protect the active import record.
        let toDelete = sessions.filter { $0.isCompleted || $0.isCanceled }
        guard !toDelete.isEmpty else { return }
        for session in toDelete { modelContext.delete(session) }
        try commit()
    }

    func batchUpdateListOrders(_ updates: [(listID: UUID, displayOrder: Int)]) async throws {

        guard !updates.isEmpty else { return }

        let updateIDs = Set(updates.map { $0.listID })
        let descriptor = FetchDescriptor<ListObject>(
            predicate: #Predicate<ListObject> { updateIDs.contains($0.listID) })
        let lists = try modelContext.fetch(descriptor)

        // Last value wins for a repeated listID, matching the order in which
        // DataCoordinator applied the same updates to MemoryStore. uniqueKeysWithValues
        // would trap on the repeat instead.
        let orderByID = Dictionary(updates.map { ($0.listID, $0.displayOrder) },
                                   uniquingKeysWith: { _, last in last })
        for list in lists {
            if let newOrder = orderByID[list.listID] {
                list.displayOrder = newOrder
            }
        }

        try commit()
    }

    // MARK: - List Operations
    func createList(listID: UUID, name: String, displayOrder: Int) async throws {

        let newList = ListObject(listID: listID, listName: name, viewStyle: "",
            sortFilterOptions: [], displayOrder: displayOrder)

        modelContext.insert(newList)
        try commit() }

    func updateList(listID: UUID, name: String?, displayOrder: Int?,
        sortFilterOptions: [String]?) async throws {

        let descriptor = FetchDescriptor<ListObject>(
            predicate: #Predicate<ListObject> { $0.listID == listID })

        guard let list = try modelContext.fetch(descriptor).first else {
            throw PersistenceError.listNotFound(listID) }

        if let name = name { list.listName = name }
        if let displayOrder = displayOrder { list.displayOrder = displayOrder }
        if let options = sortFilterOptions { list.sortFilterOptions = options }

        try commit() }

    func deleteList(listID: UUID) async throws {

        let descriptor = FetchDescriptor<ListObject>(
            predicate: #Predicate<ListObject> { $0.listID == listID })

        guard let list = try modelContext.fetch(descriptor).first else {
            throw PersistenceError.listNotFound(listID) }

        // Memberships are deleted explicitly rather than left to the cascade rule, for the
        // reason deleteFilms gives: the cascade is unreliable for rows created in the same
        // session, and a missed one survives as an orphan with a nil list.
        for membership in Array(list.memberships) {
            modelContext.delete(membership)
        }
        modelContext.delete(list)
        try commit() }

}

// MARK: - Film Layer Digest

/// The film half of `StoreFingerprint`, accumulated one film at a time. Both ways
/// `DataManager.computeStoreFingerprint` reads the film layer, and
/// `MemoryStoreCache.buildFingerprint` for the stored side, feed this one type, so no two
/// of them can mix a film differently.
struct FilmLayerDigest: Equatable, Sendable {
    private(set) var filmCount = 0
    private(set) var xor: UInt64 = 0
    private(set) var maxLastModified = ""
    private(set) var hofRankXor: UInt64 = 0
    private(set) var userRatingXor: UInt64 = 0

    mutating func add(id: UUID, lastModified: String, hofPosition: Int, userRating: Int) {
        let (hi, lo) = id.fingerprintHalves
        let idHash = hi ^ lo
        filmCount += 1
        xor ^= idHash
        if lastModified > maxLastModified { maxLastModified = lastModified }
        hofRankXor ^= StoreFingerprint.rankMix(idHash, hofPosition)
        userRatingXor ^= StoreFingerprint.rankMix(idHash, userRating)
    }
}

// MARK: - Direct Store Reader

/// Read-only SQL against the SwiftData store file, for the two launch-time questions
/// SwiftData can only answer by materializing every object: the fingerprint's film layer
/// (~820ms through a fetch for 1,384 films in a Debug build, ~5ms here) and whether any
/// Release UUID repeats (~590ms through a fetch of 2,297 releases).
///
/// Every method returns nil when it cannot answer exactly — no file, a table or column
/// that is not where Core Data's naming puts it, a value of an unexpected type, a busy
/// store — and the caller takes its SwiftData path instead. A schema change can therefore
/// cost speed, never correctness.
///
/// Safe beside the open ModelContainer:
///   - SQLITE_OPEN_READONLY: the connection never writes, never checkpoints the WAL, and
///     closing it never removes the WAL.
///   - It reads through the WAL like any reader, so it sees the committed state a fresh
///     ModelContext fetch would see — which is all the SwiftData fetch it replaces saw,
///     since that ran in DataManager's own context before anything had written.
///   - It uses the same system libsqlite3 as Core Data, whose unix VFS shares POSIX lock
///     state between connections to one file in a process, so closing this connection
///     cannot release the locks Core Data's connection holds.
///
/// Core Data's naming: entity `Film` is table `ZFILM`; attribute `id` is column `ZID`, a
/// UUID stored as its 16 bytes; `lastModified` is text (the empty "never modified"
/// sentinel is stored as ''); Int attributes are integer columns.
enum DirectStoreReader {

    /// The fingerprint's film layer, or nil if any row is not exactly the expected shape.
    static func filmLayerDigest(storeURL: URL?) -> FilmLayerDigest? {
        unsafe withReadOnlyConnection(storeURL) { db in
            var statement: OpaquePointer?
            guard unsafe sqlite3_prepare_v2(db, "SELECT ZID, ZLASTMODIFIED, ZHOFPOSITION, ZUSERRATING FROM ZFILM",
                                     -1, &statement, nil) == SQLITE_OK,
                  let statement = unsafe statement else { return nil }
            defer { unsafe sqlite3_finalize(statement) }

            var digest = FilmLayerDigest()
            while true {
                let step = unsafe sqlite3_step(statement)
                if step == SQLITE_DONE { return digest }
                guard step == SQLITE_ROW,
                      unsafe sqlite3_column_type(statement, 0) == SQLITE_BLOB,
                      let idBytes = unsafe sqlite3_column_blob(statement, 0),
                      unsafe sqlite3_column_bytes(statement, 0) == 16,
                      unsafe sqlite3_column_type(statement, 1) == SQLITE_TEXT,
                      unsafe sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
                      unsafe sqlite3_column_type(statement, 3) == SQLITE_INTEGER else { return nil }

                var uuidBytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                unsafe withUnsafeMutableBytes(of: &uuidBytes) {
                    unsafe $0.copyMemory(from: UnsafeRawBufferPointer(start: idBytes, count: 16))
                }

                let text = unsafe sqlite3_column_text(statement, 1)
                let textLength = unsafe Int(sqlite3_column_bytes(statement, 1))
                let lastModified = unsafe text.map {
                    unsafe String(decoding: UnsafeBufferPointer(start: $0, count: textLength), as: UTF8.self)
                } ?? ""

                unsafe digest.add(id: UUID(uuid: uuidBytes),
                           lastModified: lastModified,
                           hofPosition: Int(sqlite3_column_int64(statement, 2)),
                           userRating: Int(sqlite3_column_int64(statement, 3)))
            }
        }
    }

    /// Whether two Release rows share a UUID, or nil if the store could not be asked.
    static func hasDuplicateReleaseIDs(storeURL: URL?) -> Bool? {
        unsafe withReadOnlyConnection(storeURL) { db in
            var statement: OpaquePointer?
            guard unsafe sqlite3_prepare_v2(db, "SELECT EXISTS (SELECT 1 FROM ZRELEASE GROUP BY ZID HAVING COUNT(*) > 1)",
                                     -1, &statement, nil) == SQLITE_OK,
                  let statement = unsafe statement else { return nil }
            defer { unsafe sqlite3_finalize(statement) }
            guard unsafe sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return unsafe sqlite3_column_int(statement, 0) != 0
        }
    }

    private static func withReadOnlyConnection<T>(_ url: URL?, _ body: (OpaquePointer) -> T?) -> T? {
        guard let url else { return nil }
        var db: OpaquePointer?
        // sqlite3_close(nil) is a no-op, and a failed open still hands back a handle to close.
        defer { unsafe sqlite3_close(db) }
        guard unsafe sqlite3_open_v2(url.path(percentEncoded: false), &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db = unsafe db else { return nil }
        unsafe sqlite3_busy_timeout(db, 250)
        return unsafe body(db)
    }
}

// MARK: - Thread Probe

#if DEBUG
/// DEBUG-only record of which thread each probed DataManager method ran on, and what it
/// cost there. SwiftData's model executor runs a call on the thread that awaited it, so a
/// write awaited from MainActor occupies the main thread for its whole fetch-mutate-save.
/// Inert (nil tokens, no locking) unless a harness scenario sets `isEnabled`.
final class DataManagerThreadProbe: @unchecked Sendable {
    struct Record: Sendable {
        let method: String
        let onMainThread: Bool
        let wallMilliseconds: Double
        let threadCPUMilliseconds: Double
    }

    /// The switch and the records live inside their lock, so neither can be touched unlocked.
    private struct State: Sendable {
        var enabled = false
        var storage: [Record] = []
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static var isEnabled: Bool {
        get { state.withLock { $0.enabled } }
        set { state.withLock { $0.enabled = newValue; $0.storage.removeAll() } }
    }

    static var records: [Record] { state.withLock { $0.storage } }

    private let method: String
    private let onMainThread: Bool
    private let wallStart: UInt64
    private let cpuStart: UInt64

    private init(method: String) {
        self.method = method
        onMainThread = pthread_main_np() != 0
        wallStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    static func begin(_ method: String) -> DataManagerThreadProbe? {
        isEnabled ? DataManagerThreadProbe(method: method) : nil
    }

    func end() {
        let record = Record(
            method: method,
            onMainThread: onMainThread,
            wallMilliseconds: Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - wallStart) / 1e6,
            threadCPUMilliseconds: Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e6)
        Self.state.withLock { $0.storage.append(record) }
    }
}
#endif
