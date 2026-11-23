// MARK: - DataManager.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Background actor for Core Data persistence operations.

import Foundation
import CoreData
import os

actor DataManager: Loggable {
    nonisolated static let logTag = "[DataManager]"

    // MARK: - Context
    /// One long-lived private-queue context. The executor runs this actor's jobs on that context's
    /// queue (ContextExecutor), so every method uses `context` directly.
    nonisolated let persistentContainer: NSPersistentContainer
    private nonisolated let executor: ContextExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { unsafe executor.asUnownedSerialExecutor() }
    private var context: NSManagedObjectContext { executor.context }

    init(persistentContainer: NSPersistentContainer) {
        self.persistentContainer = persistentContainer
        self.executor = ContextExecutor(context: persistentContainer.makeBackgroundContext())
    }

    // MARK: - Error Types
    enum PersistenceError: Error, LocalizedError {
        case filmNotFound(UUID)
        case listNotFound(UUID)
        case savedSearchNotFound(UUID)

        var errorDescription: String? {
            switch self {
            case .filmNotFound(let id): return "Film not found: \(id)"
            case .listNotFound(let id): return "List not found: \(id)"
            case .savedSearchNotFound(let id): return "Saved search not found: \(id)" } } }

    // MARK: - Commit

    /// Saves the actor's context, discarding every staged change if the save fails.
    ///
    /// This context is long-lived and shared by every operation on the actor. A
    /// failed `save()` leaves its inserts, deletes, and property writes pending, so without
    /// the rollback they would ride along on the next unrelated operation's save — and if
    /// the save failed *because of* them, every later save in the session would fail too,
    /// silently breaking all persistence rather than just the one operation. Rolling back
    /// is safe at every call site: each method saves before it suspends, so the context
    /// never holds another operation's unrelated pending changes when this runs.
    ///
    /// Every write method commits once, so a failure leaves the store exactly as it was —
    /// which is what DataCoordinator's rollbacks restore memory to. (The film-insert and
    /// membership methods used to commit in chunks of 100; a failure partway left the earlier
    /// chunks committed behind a rollback that undid all of memory, and those films or
    /// memberships came back on the next launch.)
    private func commit() throws {
        try context.commit()
    }

    // MARK: - Startup Fingerprint

    /// Computes the lightweight fingerprint that `MemoryStoreCache` compares against its
    /// stored copy to decide whether the on-disk snapshot cache is still valid.
    /// Returns nil only if a fetch fails, which the caller treats as a cache miss.
    ///
    /// Three queries are issued:
    ///   1. Film.id, lastModified, hofPosition and userRating — a dictionary fetch of
    ///      those four columns, which builds no Film objects
    ///   2. ListObject count only (no properties, no relationships)
    ///   3. ListMembership count only (no properties, no relationships)
    ///
    /// Runs on this background context rather than `viewContext`, keeping the work off the main
    /// thread during launch. The film query uses a dictionary fetch, so it creates no managed
    /// objects. The fingerprint describes the committed store, which is what the snapshot cache
    /// was written from, so reading the committed state (not unsaved `viewContext` changes) is correct.
    ///
    /// Registered objects are not a concern: `allFilms` is released when this method returns, and
    /// an `NSManagedObjectContext` does not retain unmodified fetched objects.
    func computeStoreFingerprint() -> StoreFingerprint? {
        let start = ContinuousClock.now

        /// Runs off the main thread.
        guard let filmLayer = fetchFilmLayerDigest() else { return nil }
        let fetchElapsed = ContinuousClock.now - start

        /// List count: no properties or relationships fetched.
        guard let listCount = try? context.count(for: ListObject.request()) else { return nil }

        /// Membership count: no properties or relationships fetched.
        ///
        /// The predicate is not optional decoration — it is what makes this count
        /// comparable to the stored one. The stored side is built by
        /// MemoryStoreCache.buildFingerprint as the sum of `MemoryList.filmIDs.count`
        /// across every list, and `filmIDs` is a `Set<UUID>` populated by
        /// `compactMap { $0.film?.id }`. That construction silently discards two classes
        /// of row that an unfiltered `fetchCount` would happily include:
        ///
        ///   - Orphans: a ListMembership whose film or list relationship is nil
        ///     contributes no UUID to the set, but is still a row in the table.
        ///   - Duplicates: two rows for the same (film, list) pair collapse into one
        ///     element of the set, but remain two rows in the table.
        ///
        /// Either one makes the live count exceed the stored count forever, and because
        /// the fingerprint is an exact-equality check, that is a permanent cache miss —
        /// a slow launch on every start, which the log cannot tell from a real library change. Filtering here eliminates the orphan cause outright; duplicates are
        /// handled by cleanupOrphanedAndDuplicateMemberships() below, which corrects the
        /// store itself so the discrepancy costs at most one slow launch.
        ///
        /// This can only ever move the live count *toward* the stored one, never away:
        /// the filter is strictly subtractive, and every row it removes is a row the
        /// stored side had already excluded. It therefore cannot introduce a mismatch
        /// that does not exist today.
        ///
        /// The unfiltered count is retained as a fallback. If the predicate fails to
        /// translate at runtime, degrading to today's behavior — a possible mismatch,
        /// the slow path, and correct data — is the right failure mode; returning nil
        /// would convert a recoverable condition into a guaranteed cache miss.
        let validMembershipDescriptor = ListMembership.request(
            NSPredicate(format: "film != nil AND list != nil"))

        let membershipCount: Int
        if let filtered = try? context.count(for: validMembershipDescriptor) {
            membershipCount = filtered
        } else if let unfiltered = try? context.count(for: ListMembership.request()) {
            log("WARNING: Filtered membership count unavailable — falling back to unfiltered count")
            membershipCount = unfiltered
        } else {
            return nil
        }

        /// Link layer: every link with both films, as memory would hold it (orphans excluded,
        /// as the membership count excludes them). Failing to read it is a miss, as for films.
        guard let linkLayer = fetchFilmLinkLayerDigest() else { return nil }

        log("STARTUP BREAKDOWN (live fingerprint) — "
            + "filmFetch: \(fetchElapsed.formattedMilliseconds) | "
            + "total: \((ContinuousClock.now - start).formattedMilliseconds) | "
            + "films: \(filmLayer.filmCount), lists: \(listCount), memberships: \(membershipCount), "
            + "links: \(linkLayer.linkCount)")

        return StoreFingerprint(
            filmCount: filmLayer.filmCount,
            xorFingerprint: filmLayer.xor,
            maxLastModified: filmLayer.maxLastModified,
            listCount: listCount,
            membershipCount: membershipCount,
            hofRankFingerprint: filmLayer.hofRankXor,
            userRatingFingerprint: filmLayer.userRatingXor,
            linkCount: linkLayer.linkCount,
            linkFingerprint: linkLayer.xor
        )
    }

    /// The link layer of the live fingerprint: every link with both films, as a dictionary
    /// fetch of the five columns the digest reads (the films' IDs through a join), so it builds
    /// no FilmLink objects and faults no Film, as the film layer does. A row missing a value
    /// returns nil, which is a cache miss (fails safe).
    private func fetchFilmLinkLayerDigest() -> FilmLinkLayerDigest? {
        func filmID(_ name: String, through relationship: String) -> NSExpressionDescription {
            let description = NSExpressionDescription()
            description.name = name
            description.expression = NSExpression(forKeyPath: "\(relationship).id")
            description.expressionResultType = .UUIDAttributeType
            return description
        }
        let request = NSFetchRequest<NSDictionary>(entityName: FilmLink.entityName)
        request.resultType = .dictionaryResultType
        request.predicate = NSPredicate(format: "sourceFilm != nil AND targetFilm != nil")
        request.propertiesToFetch = ["id", "kind", "dateAdded", filmID("sourceID", through: "sourceFilm"),
                                     filmID("targetID", through: "targetFilm")]
        guard let rows = try? context.fetch(request) else { return nil }

        var digest = FilmLinkLayerDigest()
        for row in rows {
            guard let id = row["id"] as? UUID, let kind = row["kind"] as? String, let date = row["dateAdded"] as? Date,
                  let source = row["sourceID"] as? UUID, let target = row["targetID"] as? UUID else { return nil }
            digest.add(FilmLinkSnapshot(id: id, kind: kind, sourceID: source, targetID: target, dateAdded: date))
        }
        return digest
    }

    #if DEBUG
    /// The film layer, for the harness.
    func filmLayerDigestForTesting() -> FilmLayerDigest? { fetchFilmLayerDigest() }

    /// Spins for `milliseconds` without suspending and returns when it held the actor, so
    /// the harness can prove calls from different threads never overlap.
    func exclusionProbeForTesting(milliseconds: Double) -> (start: UInt64, end: UInt64, onMain: Bool) {
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let onMain = pthread_main_np() != 0
        while Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6 < milliseconds {}
        return (start, clock_gettime_nsec_np(CLOCK_UPTIME_RAW), onMain)
    }
    #endif

    /// The film layer: every film's ID, lastModified, hofPosition and userRating, folded into
    /// a digest. A dictionary-result fetch reads only those four columns and builds no Film
    /// objects.
    ///
    /// The cheap substitutes that do not enumerate film UUIDs do not work here:
    ///
    ///   - (count, max-lastModified) is permanently unsafe for FilmTracker. An empty
    ///     `lastModified` is the deliberate sentinel for "never modified since import", so an
    ///     insert can carry a value lower than every existing one and a balanced
    ///     add-and-delete leaves both count and maximum unchanged. Adding max-dateAdded does
    ///     not close it either: imports carry the file's own date, not Date().
    ///   - A generation counter or dirty flag would be cheap but fails UNSAFE: writes reach
    ///     the store from many save() sites, DBRestorer's own context, and viewContext.
    ///   - Store-file mtime/size fails safe but degenerates to a permanent miss, because
    ///     SQLite checkpoints on close and changes the file after the cache is written.
    ///
    /// The property that makes the check worth having is that it is derived from the data
    /// and therefore fails SAFE: anything unaccounted for produces a mismatch, the slow path
    /// runs, and the result is correct. A row with no ID returns nil, which is a cache miss.
    private func fetchFilmLayerDigest() -> FilmLayerDigest? {
        let filmDescriptor = NSFetchRequest<NSDictionary>(entityName: Film.entityName)
        filmDescriptor.resultType = .dictionaryResultType
        filmDescriptor.propertiesToFetch = ["id", "lastModified", "hofPosition", "userRating"]
        guard let rows = try? context.fetch(filmDescriptor) else { return nil }

        var digest = FilmLayerDigest()
        for row in rows {
            guard let id = row["id"] as? UUID else { return nil }
            digest.add(id: id, lastModified: row["lastModified"] as? String ?? "",
                       hofPosition: (row["hofPosition"] as? NSNumber)?.intValue ?? 0,
                       userRating: (row["userRating"] as? NSNumber)?.intValue ?? 0)
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

    /// Rewrites every Release still holding a value in an old format (see LegacyReleaseValues).
    ///
    /// Memory never sees the old values — ReleaseSnapshot converts them on the way in — so this
    /// only brings the store itself into line. DataCoordinator calls it once at startup, and
    /// only when MemoryStore's store read saw an old value, since the fetch materializes every
    /// Release. Film.lastModified is not touched, so the snapshot-cache fingerprint is unaffected.
    func migrateLegacyReleaseValues() async throws {
        let allReleases = try context.fetch(Release.request())
        var count = 0
        for release in allReleases where LegacyReleaseValues.migrate(release) {
            count += 1
        }
        guard count > 0 else { return }
        try commit()
        log("Migrated legacy values on \(count) release(s)")
    }

    /// Writes new release sort orders: the one-time carousel order conversion (see
    /// DataCoordinator.convertReleaseOrderIfNeeded). A release is changed only while it still
    /// holds the order the conversion read, so a film saved in the meantime keeps its own save.
    /// Film.lastModified is not touched, so the snapshot-cache fingerprint is unaffected; the
    /// caller brings memory, and through it the cache, into line. Returns the ids written.
    func applyReleaseSortOrders(_ changes: [UUID: ReleaseOrderChange]) async throws -> Set<UUID> {
        guard !changes.isEmpty else { return [] }
        let releases = try context.fetch(Release.request(.in("id", changes.keys)))
        var written: Set<UUID> = []
        for release in releases {
            guard let change = changes[release.id], release.sortOrder == change.old else { continue }
            release.sortOrder = change.new
            written.insert(release.id)
        }
        guard !written.isEmpty else { return [] }
        try commit()
        log("Release order conversion: wrote \(written.count) release(s)")
        return written
    }

    /// Removes ListMembership records that are structurally meaningless: those whose
    /// film or list relationship is nil (orphans), and redundant rows for a
    /// (film, list) pair that is already represented (duplicates).
    ///
    /// Called once at startup by DataCoordinator, deferred until after the UI is
    /// interactive. Runs entirely in the background context — no viewContext
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
    /// permanent snapshot-cache miss and a slow launch on every start until the
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
    /// their inverse, so Core Data removes the deleted row from each parent's set.
    func cleanupOrphanedAndDuplicateMemberships() async throws -> (orphans: Int, duplicates: Int) {
        #if DEBUG
        let threadProbe = DataManagerThreadProbe.begin("cleanupOrphanedAndDuplicateMemberships")
        defer { threadProbe?.end() }
        #endif

        let allMemberships = try context.fetch(ListMembership.request())

        var orphaned: [ListMembership] = []
        var valid: [ListMembership] = []
        for membership in allMemberships {
            /// Read each relationship once, partitioning in the same pass over the fetch
            /// that the duplicate scan below consumes.
            if membership.film == nil || membership.list == nil {
                orphaned.append(membership)
            } else {
                valid.append(membership)
            }
        }

        /// Duplicates are detected only among valid rows. An orphan has no resolvable
        /// (film, list) pair to key on, and every orphan is being deleted regardless —
        /// including them could only produce a nil-keyed bucket with no meaning.
        ///
        /// One pass keeps the survivor per pair: the row that orders first by
        /// (dateAdded, sortOrder, id). This picks exactly the row that sorting every valid
        /// membership and keeping the first per pair would, without sorting the whole
        /// table on every launch to find what is almost always zero duplicates.
        func ordersBefore(_ lhs: ListMembership, _ rhs: ListMembership) -> Bool {
            if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded < rhs.dateAdded }
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var survivorByPair: [MembershipPair: ListMembership] = [:]
        var duplicates: [ListMembership] = []
        for membership in valid {
            /// Re-derives the IDs rather than trusting the partition above, so the loop stays
            /// correct if that partition changes.
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

        /// Last cancellation check before anything destructive is staged. AppDelegate
        /// cancels the deferred-maintenance task at shutdown specifically so that
        /// maintenance deletions do not run mid-process-exit; honoring that here means
        /// the check covers this pass too, not just the poster pruner that precedes it.
        /// Checked after the analysis and before the first delete so a cancellation can
        /// never leave the context holding staged deletions.
        try Task.checkCancellation()

        var removedOrphans = 0
        var removedDuplicates = 0

        /// `context != nil` mirrors the guard already used at the membership-delete
        /// site in saveFilmChangeset. Nothing can invalidate these objects between the
        /// fetch above and here — this method contains no suspension point, so it runs as
        /// one atomic unit on the actor — but a restore running against its own separate
        /// context is outside that guarantee, and deleting an already-detached object is
        /// the one thing worth being defensive about. Counting actual deletions rather
        /// than candidate counts keeps the returned numbers truthful if the guard ever
        /// does skip one.
        for membership in orphaned where unsafe membership.managedObjectContext != nil {
            context.delete(membership)
            removedOrphans += 1
        }
        for membership in duplicates where unsafe membership.managedObjectContext != nil {
            context.delete(membership)
            removedDuplicates += 1
        }

        guard removedOrphans > 0 || removedDuplicates > 0 else { return (0, 0) }

        /// A single save for both classes. They are two symptoms of the same structural
        /// problem and there is no state in which committing one without the other is
        /// preferable, so an all-or-nothing transaction is the correct granularity.
        ///
        /// On failure the staged deletions must be discarded rather than left pending.
        /// This NSManagedObjectContext is long-lived and shared by every subsequent DataManager
        /// operation, so uncommitted deletions would otherwise ride along on the next
        /// unrelated `save()` — and, in the case that matters, if the save failed
        /// *because of* these deletions, every later save in the session would fail too,
        /// silently breaking all persistence rather than just this maintenance pass.
        /// Rolling back is safe here: every other method on this actor saves before it
        /// suspends, so the context holds no unrelated pending changes at this point.
        try commit()

        return (removedOrphans, removedDuplicates)
    }

    // MARK: - Film Operations

    /// Inserts an import's films in one transaction, so a failure leaves none of them behind
    /// the rollback that takes all of them out of memory (see commit()).
    func batchInsertFilms(_ snapshots: [FilmSnapshot]) async throws {
        #if DEBUG
        let threadProbe = DataManagerThreadProbe.begin("batchInsertFilms")
        defer { threadProbe?.end() }
        #endif

        guard !snapshots.isEmpty else { return }
        try Task.checkCancellation()

        for snapshot in snapshots { context.insert(snapshot.toFilm()) }
        try commit() }

    func updateFilm(_ snapshot: FilmSnapshot) async throws {
        #if DEBUG
        let threadProbe = DataManagerThreadProbe.begin("updateFilm")
        defer { threadProbe?.end() }
        #endif

        let filmID = snapshot.id
        let descriptor = Film.request(.equals("id", filmID))

        guard let film = try context.fetch(descriptor).first else {
            throw PersistenceError.filmNotFound(filmID) }

        snapshot.apply(to: film)
        try commit() }

    /// Atomically applies scalar property changes for multiple films in a single transaction.
    ///
    /// Used by the multi-film persistence paths (Hall of Fame add/remove/reorder) where
    /// several FilmSnapshots must be committed together. A single fetch + single
    /// context.save() guarantees all-or-nothing semantics: if the save fails, the
    /// background context is discarded and nothing is committed, so the store never ends
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

        try writeFetchedFilms(snapshots, operation: "updateFilms") { snapshot, film in
            snapshot.apply(to: film)
        }
    }

    /// Writes `fields` of each snapshot to its film, in one transaction.
    ///
    /// updateFilms' all-or-nothing batch, narrowed to the fields a bulk edit set, so a
    /// field it did not set keeps whatever an earlier operation committed (the FilmSheet's
    /// changedFields rule, applyFilmChangeset). A film deleted in the meantime is skipped.
    func applyFilmFields(_ snapshots: [FilmSnapshot], fields: Set<FilmField>) async throws {
        #if DEBUG
        let threadProbe = DataManagerThreadProbe.begin("applyFilmFields")
        defer { threadProbe?.end() }
        #endif

        guard !fields.isEmpty else { return }
        if let values = Self.batchValues(fields, snapshots) {
            try batchUpdateFilms(Set(snapshots.map(\.id)), values)
            return
        }
        try writeFetchedFilms(snapshots, operation: "applyFilmFields") { snapshot, film in
            for field in fields { field.apply(snapshot, to: film) }
        }
    }

    /// The common case of a bulk edit: every field set to one value on every film (a genre,
    /// a flag, Watched). That is one UPDATE statement in the store, through NSBatchUpdateRequest,
    /// instead of fetching each film, setting it and saving the object graph. Returns the
    /// values by attribute name, or nil when the batch can't express the edit: a field whose
    /// value differs between films (tags added to each film's own list), an array field
    /// (transformable, which a batch update can't write), or a field with no attribute of its name.
    private static func batchValues(_ fields: Set<FilmField>, _ snapshots: [FilmSnapshot]) -> [String: Any]? {
        guard let first = snapshots.first else { return nil }
        let attributes = LibraryModel.shared.entity(Film.entityName).attributesByName
        var values: [String: Any] = [:]
        for field in fields {
            guard let attribute = attributes[field.rawValue],
                  attribute.attributeType != .transformableAttributeType,
                  !snapshots.contains(where: { field.differs($0, first) }) else { return nil }
            let value = field.value(in: first)
            if let some = Mirror(reflecting: value).displayStyle == .optional
                ? Mirror(reflecting: value).children.first?.value : value {
                values[field.rawValue] = some
            } else {
                values[field.rawValue] = NSExpression(forConstantValue: nil)
            }
        }
        return values
    }

    /// Writes `values` to every film in `ids` in one statement. A film deleted in the meantime
    /// simply isn't matched. All-or-nothing, like the save it replaces.
    ///
    /// The statement goes around every context, so the films a context has registered are
    /// refreshed afterwards: this one's here, on its own queue, and the view context's on the
    /// main queue, without waiting for it. Only registered films are touched. The general
    /// `mergeChanges(fromRemoteContextSave:into:)` is costly on the main thread even when the
    /// view context has none of these films registered.
    private func batchUpdateFilms(_ ids: Set<UUID>, _ values: [String: Any]) throws {
        let request = NSBatchUpdateRequest(entityName: Film.entityName)
        request.predicate = .in("id", ids)
        request.propertiesToUpdate = values
        request.resultType = .updatedObjectIDsResultType
        let result = try context.execute(request) as? NSBatchUpdateResult
        let updated = result?.result as? [NSManagedObjectID] ?? []
        for id in updated {
            if let film = context.registeredObject(for: id) { context.refresh(film, mergeChanges: false) }
        }
        let container = persistentContainer
        Task { @MainActor in
            let view = container.viewContext
            for id in updated {
                if let film = view.registeredObject(for: id) { view.refresh(film, mergeChanges: true) }
            }
        }
        log("Batch-updated \(updated.count) of \(ids.count) film(s): \(values.keys.sorted().joined(separator: ", "))")
    }

    /// updateFilms' and applyFilmFields' shared body: one fetch for every snapshot's film,
    /// `write` on each one found, one commit. A film no longer in the database is skipped
    /// and logged under `operation`; nothing is committed when none was found.
    private func writeFetchedFilms(_ snapshots: [FilmSnapshot], operation: String,
                                   _ write: (FilmSnapshot, Film) -> Void) throws {
        guard !snapshots.isEmpty else { return }

        let ids = Set(snapshots.map { $0.id })
        let descriptor = Film.request(.in("id", ids))
        let films = try context.fetch(descriptor)

        /// Build a UUID → Film lookup. uniquingKeysWith guards against the (impossible
        /// under the unique-id constraint, but defensively handled) case of duplicate keys.
        let filmByID = Dictionary(films.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var appliedCount = 0
        for snapshot in snapshots {
            guard let film = filmByID[snapshot.id] else {
                log("WARNING: \(operation) — film \(snapshot.id) not found in database (likely deleted); skipping")
                continue
            }
            write(snapshot, film)
            appliedCount += 1
        }

        /// Nothing matched — no changes to commit.
        guard appliedCount > 0 else { return }

        try commit() }

    func deleteFilms(withIDs ids: Set<UUID>) async throws {
        #if DEBUG
        let threadProbe = DataManagerThreadProbe.begin("deleteFilms")
        defer { threadProbe?.end() }
        #endif

        guard !ids.isEmpty else { return }

        /// The delete rules remove each film's memberships (Film.memberships cascades); the
        /// membership-cascade harness scenario verifies this. Each film is refreshed first:
        /// this context is long-lived, and a memberships relationship it loaded earlier would
        /// not include a row another context saved since, which the cascade would then miss. Nothing is pending here
        /// (every method saves before it suspends), so the refresh discards nothing.
        let descriptor = Film.request(.in("id", ids))
        let films = try context.fetch(descriptor)

        for film in films {
            context.refresh(film, mergeChanges: false)
            context.delete(film)
        }
        try commit() }
    
    /// Resets rotation threshold overrides to nil for the specified film IDs.
    ///
    /// Accepts the exact ID set pre-identified by DataCoordinator, so the fetch is targeted.
    /// Operates on the background NSManagedObjectContext only.
    ///
    /// ONE TRANSACTION, deliberately. Chunked saves would leave earlier chunks committed if a
    /// later one failed, while the caller's rollback restores every film in MemoryStore. That
    /// divergence never self-corrects, because `rotationThresholdOverride` does not bump
    /// `lastModified` and is not in the snapshot-cache fingerprint. A single `commit()` either
    /// applies the whole reset or none of it.
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

        let descriptor = Film.request(.in("id", ids))
        let films = try context.fetch(descriptor)
        guard !films.isEmpty else { return }

        /// Nothing destructive is staged before this check, so a cancellation can never
        /// leave the context holding a half-applied reset.
        try Task.checkCancellation()

        for film in films { reset(film) }
        try commit()
    }

    // MARK: - Atomic Film Changeset Persistence

    /// Applies a complete FilmChangeset atomically in the background context.
    /// This is the single persistence entry point for all FilmSheet save operations.
    /// All model objects are fetched and created within this context - no cross-context access.
    ///
    /// Operations performed (in order):
    ///   1. Fetch or create the Film
    ///   2. Apply scalar Film properties from FilmSnapshot (every field, or the changeset's delta)
    ///   3. Delete removed releases
    ///   4. Update existing releases
    ///   5. Create new releases
    ///   6. Link release parent-child hierarchy
    ///   7. Remove list memberships
    ///   8. Add list memberships
    ///   9. Save context (single atomic transaction)
    ///
    /// Thread safety: This method runs entirely on DataManager's own context.
    /// All model objects are fetched locally - no objects cross actor boundaries.
    func applyFilmChangeset(_ changeset: FilmChangeset) async throws {
        #if DEBUG
        let threadProbe = DataManagerThreadProbe.begin("applyFilmChangeset")
        defer { threadProbe?.end() }
        #endif

        let filmID = changeset.filmID

        /// Step 1: Fetch or create the Film in this context.
        /// For new films, DataCoordinator.saveFilmChangeset adds the film to MemoryStore
        /// (optimistic update) and then dispatches this changeset via trackOperation.
        /// The new film is inserted into the store here, in this background context, never viewContext.
        ///
        /// For existing films the fetch will always find the record (it was created in a
        /// prior session). The else-if branch below handles the hypothetical case where an
        /// in-flight new-film operation is received before a previous session's records are
        /// fully flushed, which in practice should not occur.
        let film: Film
        let descriptor = Film.request(.equals("id", filmID))
        if let existingFilm = try context.fetch(descriptor).first {
            film = existingFilm
        } else if changeset.isNewFilm {
            /// New film: insert directly into this background context.
            /// This is the primary (not fallback) path for new film persistence.
            film = Film()
            film.id = filmID
            context.insert(film)
        } else {
            throw PersistenceError.filmNotFound(filmID)
        }

        /// Step 2: Apply scalar Film properties from snapshot — every field for a new film,
        /// otherwise only the fields the FilmSheet's three-way merge changed, so a field
        /// the save did not touch keeps whatever an earlier operation committed. The derived
        /// values (lastWatched, viewCount, lastModified, numberOfDiscs) are ordinary fields
        /// here: written by the whole-snapshot apply, and by the delta when it lists them.
        if let fields = changeset.changedFields, !changeset.isNewFilm {
            for field in fields { field.apply(changeset.filmSnapshot, to: film) }
        } else {
            changeset.filmSnapshot.apply(to: film)
        }

        /// Step 3: Delete removed releases.
        if !changeset.releasesToDelete.isEmpty {
            let existingReleases = film.releases
            for releaseID in changeset.releasesToDelete {
                if let release = existingReleases.first(where: { $0.id == releaseID }) {
                    context.delete(release)
                }
            }
        }

        /// Step 4: Update existing releases.
        for snapshot in changeset.releasesToUpdate {
            if let release = film.releases.first(where: { $0.id == snapshot.id }) {
                snapshot.apply(to: release)
            }
        }

        /// Step 5: Create new releases.
        for snapshot in changeset.releasesToCreate {
            let release = snapshot.toRelease(film: film)
            context.insert(release)
        }

        /// Step 6: Link release parent-child hierarchy.
        ///
        /// ReleaseSnapshot.apply(to:) and toRelease(film:) intentionally do not touch
        /// parentRelease / childReleases because those are object-graph
        /// relationships that require live Release references, not scalar values.
        /// All new and updated snapshots that carry a parentReleaseID must have their
        /// relationship established here, after every Release object
        /// for this film is guaranteed to exist in the context.
        ///
        /// The approach:
        ///   1. Build a UUID → Release lookup over the film's current releases.
        ///   2. For each created or updated snapshot that has a parentReleaseID, resolve
        ///      the parent Release and set childRelease.parentRelease = parentRelease.
        ///      Core Data's inverse maintenance populates parentRelease.childReleases.
        ///   3. For each snapshot whose parentReleaseID is nil (i.e., newly promoted to
        ///      top-level because the user changed independence away from Combo-pack and
        ///      already removed the link in-session), clear the relationship so
        ///      the DB stays in sync with the in-memory model.
        ///
        /// The one-level-depth constraint (no grandchildren) is already enforced at the
        /// UI layer in FSTabReleases; this step trusts the snapshots it receives.
        let hierarchySnapshots = changeset.releasesToCreate + changeset.releasesToUpdate
        if !hierarchySnapshots.isEmpty {
            /// Build the lookup map once — O(n) over film.releases which is tiny in practice.
            var releaseByID = [UUID: Release](minimumCapacity: film.releases.count)
            for release in film.releases { releaseByID[release.id] = release }

            for snapshot in hierarchySnapshots {
                guard let childRelease = releaseByID[snapshot.id] else { continue }

                if let parentID = snapshot.parentReleaseID {
                    /// Link to parent (no-op if the relationship is already correct, e.g. on a
                    /// subsequent save without hierarchy changes — Core Data does not dirty-track
                    /// a relationship assignment that doesn't change the value).
                    if let parentRelease = releaseByID[parentID] {
                        /// Core Data adds the child to `parentRelease.childReleases`, the
                        /// inverse the FilmSheet's combo-pack logic reads (see
                        /// FSTabReleases.comboChildren).
                        childRelease.parentRelease = parentRelease
                    } else {
                        /// Parent UUID not found in this film's releases — log and skip.
                        /// This would indicate a data integrity problem upstream; restoring as
                        /// top-level is the safe fallback (no data is lost, just the link).
                        Self.log("WARNING: parentReleaseID \(parentID) not found for release \(snapshot.id) — persisting as top-level")
                        childRelease.parentRelease = nil
                    }
                } else {
                    /// No parent — ensure any stale parentRelease link is cleared.
                    /// This handles the case where a user reverted a Combo-pack parent
                    /// and the child was removed in-session, but the existing DB record
                    /// still carries the old parentRelease pointer from a previous save.
                    /// Core Data removes it from the former parent's childReleases as well.
                    if childRelease.parentRelease != nil {
                        childRelease.parentRelease = nil
                    }
                }
            }
        }

        /// Step 7: Remove list memberships.
        if !changeset.listsToRemove.isEmpty {
            let allMemberships = Array(film.memberships)
            for membership in allMemberships {
                /// Guard against accessing deleted/detached objects
                guard unsafe membership.managedObjectContext != nil,
                      let listID = membership.list?.listID else { continue }
                if changeset.listsToRemove.contains(listID) {
                    context.delete(membership)
                }
            }
        }

        /// Step 8: Add list memberships.
        if !changeset.listsToAdd.isEmpty {
            let listsToAdd = changeset.listsToAdd
            let listDescriptor = ListObject.request(.in("listID", listsToAdd))
            let lists = try context.fetch(listDescriptor)
            let currentDate = Date()
            /// The lists the film already belongs to, extended as rows are inserted below, so
            /// two ListObject records sharing a listID (a corrupted or partial restore) can
            /// never yield a second row for the same (film, list) pair.
            var memberListIDs = Set(film.memberships.compactMap { $0.list?.listID })
            for list in lists {
                /// Skip lists the film is already a member of, to prevent duplicates.
                guard memberListIDs.insert(list.listID).inserted else { continue }

                let maxSortOrder = list.memberships.map { $0.sortOrder }.max() ?? -1
                let membership = ListMembership(
                    film: film, list: list, dateAdded: currentDate,
                    sortOrder: maxSortOrder + 1)
                context.insert(membership)
            }
        }

        /// Step 9: Single atomic save.
        try commit()
    }

    // MARK: - Release Operations (Wishlist Reorder)

    /// Atomically applies property changes for multiple releases in a single transaction.
    ///
    /// Writes only the releases: the film's own fields, numberOfDiscs included, are left as
    /// the last film save wrote them, which is what memory holds too.
    ///
    /// Used by the wishlist reorder persistence path, where every reordered release must be
    /// committed together. Releases are grouped by film so each Film is fetched exactly once,
    /// all snapshots are applied, and a single context.save() commits the batch — giving
    /// all-or-nothing semantics. If the save fails, nothing is committed, so the store never
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

        /// Group release snapshots by film so each Film is fetched and processed once.
        var snapshotsByFilm: [UUID: [ReleaseSnapshot]] = [:]
        for unit in units {
            snapshotsByFilm[unit.filmID, default: []].append(unit.snapshot)
        }

        let filmIDs = Set(snapshotsByFilm.keys)
        let descriptor = Film.request(.in("id", filmIDs))
        let films = try context.fetch(descriptor)
        let filmByID = Dictionary(films.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var appliedCount = 0
        for (filmID, releaseSnapshots) in snapshotsByFilm {
            guard let film = filmByID[filmID] else {
                log("WARNING: updateReleases — film \(filmID) not found in database (likely deleted); skipping \(releaseSnapshots.count) release(s)")
                continue
            }

            /// O(1) release lookup for this film.
            var releaseByID = [UUID: Release](minimumCapacity: film.releases.count)
            for release in film.releases { releaseByID[release.id] = release }

            for snapshot in releaseSnapshots {
                guard let release = releaseByID[snapshot.id] else {
                    log("WARNING: updateReleases — release \(snapshot.id) not found on film \(filmID); skipping")
                    continue
                }
                snapshot.apply(to: release)
                appliedCount += 1
            }
        }

        guard appliedCount > 0 else { return }

        try commit()
    }

    // MARK: - List Membership Operations
    /// Batch add films to lists with existence validation, in one transaction (see commit()).
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

        let listDescriptor = ListObject.request(.in("listID", listIDs))
        let lists = try context.fetch(listDescriptor)

        guard !lists.isEmpty else { return }

        /// uniquingKeysWith rather than uniqueKeysWithValues: the latter traps on a duplicate
        /// key, so two ListObject records sharing a listID — which a corrupted or partially
        /// completed restore can leave behind — would crash the app here instead of degrading.
        /// Keeping the first occurrence matches the defensive pattern already used by
        /// updateFilms and updateReleases. The type is spelled out because the Value here is
        /// itself a labeled tuple, which the uniquingKeysWith overload cannot always infer.
        let listDict: [UUID: (object: ListObject, maxSort: Int)] = Dictionary(
            lists.map { ($0.listID, (object: $0, maxSort: $0.memberships.map {
                $0.sortOrder }.max() ?? -1)) },
            uniquingKeysWith: { first, _ in first })

        /// Fetch films fresh from database to verify they exist.
        /// This is critical because the filmIDs passed in might reference films that
        /// have been deleted between when this operation was scheduled and when it
        /// actually runs. We must verify existence before creating relationships.
        let filmDescriptor = Film.request(.in("id", filmIDs))
        let films = try context.fetch(filmDescriptor)
        
        /// Log if any films were not found (indicates they were deleted)
        if films.count != filmIDs.count {
            let foundIDs = Set(films.map { $0.id })
            let missingIDs = filmIDs.subtracting(foundIDs)
            Self.log("WARNING: \(missingIDs.count) film(s) not found in database (likely deleted): \(missingIDs)")
        }

        guard !films.isEmpty else {
            Self.log("SAFETY: All films were deleted, skipping batchAddFilmsToLists")
            return }

        var currentMaxSorts = listDict.mapValues { $0.maxSort }
        var inserted = 0

        /// Existing memberships come from the ListObjects already fetched above, not from a
        /// full-table ListMembership.request(). `ListObject.memberships` is the
        /// declared inverse of `ListMembership.list`, so a list's membership array IS exactly
        /// the set of rows a whole-table scan would have kept for that listID — and the array
        /// is already faulted in, because `listDict` computes each list's `maxSort` from it
        /// one statement earlier. The old scan therefore read every membership row in the
        /// library (all lists, not just the targeted ones) to derive a subset already in hand.
        ///
        /// Iterating `lists` rather than `listDict.values` is deliberate: `listDict` collapses
        /// duplicate ListObject records sharing one listID down to the first occurrence, and
        /// the memberships hanging off the discarded twin must still count as "already exists"
        /// here or this method would insert a redundant row for that (film, list) pair. The
        /// whole-table scan unioned them via its listID key; unioning across `lists` preserves
        /// that exactly.
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
                /// Skip if membership already exists
                if existingFilmIDs.contains(film.id) { continue }
                
                /// Additional safety: Double-check film is still valid before creating membership.
                /// This guards against the film being deleted during this batch operation.
                guard unsafe film.managedObjectContext != nil else {
                    log("SAFETY: Film \(film.id) no longer has valid context, skipping")
                    continue
                }

                currentMaxSorts[listID] = (currentMaxSorts[listID] ?? -1) + 1
                let membership = ListMembership(film: film, list: listInfo.object,
                    dateAdded: currentDate, sortOrder: currentMaxSorts[listID]!)
                context.insert(membership)
                inserted += 1 } }

        if inserted > 0 { try commit() }
    }

    /// Batch remove films from lists, in one transaction (see commit()).
    func batchRemoveFilmsFromLists(filmIDs: Set<UUID>, listIDs: Set<UUID>) async throws {
        #if DEBUG
        let threadProbe = DataManagerThreadProbe.begin("batchRemoveFilmsFromLists")
        defer { threadProbe?.end() }
        #endif

        guard !filmIDs.isEmpty && !listIDs.isEmpty else { return }

        /// Targeted rather than a full-table ListMembership.request() scan: fetch
        /// only the named lists, then walk their `memberships` inverse arrays. The rows this
        /// reaches are exactly the rows the old whole-library scan kept — its filter required
        /// `membership.list?.listID` to be in `listIDs`, which is the same predicate as "hangs
        /// off one of these ListObjects", and a row with a nil `list` appeared in neither.
        /// Snapshotted into `toDelete` before any delete so the relationship arrays are never
        /// mutated mid-iteration.
        let listDescriptor = ListObject.request(.in("listID", listIDs))
        let lists = try context.fetch(listDescriptor)

        var toDelete: [ListMembership] = []
        for list in lists {
            for membership in list.memberships {
                guard let filmID = membership.film?.id, filmIDs.contains(filmID) else { continue }
                toDelete.append(membership)
            }
        }

        guard !toDelete.isEmpty else { return }
        for membership in toDelete { context.delete(membership) }
        try commit() }

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
    /// Each batch method is a transaction of its own, so the move needs one method that
    /// stages both halves before its single commit.
    ///
    /// Ordering is deliberate: the target list and every film are resolved BEFORE anything
    /// is staged, so a missing target or a fully-deleted film set returns having changed
    /// nothing rather than committing a removal whose matching insertion can never happen.
    func moveFilmsBetweenLists(filmIDs: Set<UUID>,
                               removalFilmIDs: Set<UUID>,
                               removalListIDs: Set<UUID>,
                               addingTo targetListID: UUID) async throws {

        guard !filmIDs.isEmpty else { return }

        /// Resolve the target and every source list in one fetch.
        let involvedListIDs = removalListIDs.union([targetListID])
        let listDescriptor = ListObject.request(.in("listID", involvedListIDs))
        let lists = try context.fetch(listDescriptor)

        guard let target = lists.first(where: { $0.listID == targetListID }) else {
            Self.log("SAFETY: target list \(targetListID) not found, skipping moveFilmsBetweenLists")
            return
        }

        /// Same existence validation batchAddFilmsToLists performs: a film deleted between
        /// this operation being scheduled and running must not gain a membership row.
        let filmDescriptor = Film.request(.in("id", filmIDs))
        let films = try context.fetch(filmDescriptor)
        if films.count != filmIDs.count {
            let missing = filmIDs.subtracting(Set(films.map { $0.id }))
            Self.log("WARNING: \(missing.count) film(s) not found in database (likely deleted): \(missing)")
        }
        guard !films.isEmpty else {
            Self.log("SAFETY: All films were deleted, skipping moveFilmsBetweenLists")
            return
        }

        /// --- Stage the removals. Reaches the same rows batchRemoveFilmsFromLists would:
        ///     those hanging off one of the source ListObjects whose film is also named.
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
                context.delete(membership)
                removed += 1
            }
        }

        /// --- Stage the insertions. The target's memberships are unaffected by the deletions
        ///     above: `removalListIDs` is built by subtracting the target from the three
        ///     internal sections, so the source lists are disjoint from it by construction.
        ///
        ///     Read across EVERY fetched ListObject carrying the target's listID, not just
        ///     the one `first(where:)` returned. A corrupted or partially completed restore
        ///     can leave two ListObject rows sharing a listID, and a membership hanging off
        ///     the twin this method did not pick still means the film is a member — missing
        ///     it would insert a redundant second row for that (film, list) pair. This
        ///     matches what batchAddFilmsToLists does for the same reason; the sortOrder
        ///     high-water mark is taken across both for the same reason again.
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
            guard unsafe film.managedObjectContext != nil else {
                log("SAFETY: Film \(film.id) no longer has valid context, skipping")
                continue
            }
            maxSort += 1
            context.insert(ListMembership(film: film, list: target,
                                               dateAdded: currentDate, sortOrder: maxSort))
            inserted += 1
        }

        guard removed > 0 || inserted > 0 else { return }

        /// The single commit both halves have been staged for.
        try commit()
        log("Moved film(s) between lists in one transaction: \(removed) membership(s) removed, \(inserted) inserted")
    }

    // MARK: - Import Session Operations

    /// Deletes a single ImportSession by its UUID.
    func deleteImportSession(id: UUID) async throws {
        let descriptor = ImportSession.request(.equals("id", id))
        guard let session = try context.fetch(descriptor).first else { return }
        context.delete(session)
        try commit()
    }

    /// Deletes all ImportSession records whose `importType` matches the given string
    /// (either "metadata" or "ratings"). Leaves sessions of the other type untouched.
    ///
    /// Kept: `activeID`, the session of an import still running, and any session dated at
    /// or after `cutoff` (the request), which an import begun since may own. ImportProgress
    /// writes such a session's final state through viewContext after the import finishes,
    /// and deleting it here would leave completeSession()/updateSessionAsCanceled() nothing
    /// to write. Every other unfinished session belongs to an import the app quit or
    /// crashed during, and nothing will ever finish it, so it goes with the rest.
    func deleteAllImportSessions(ofType importType: String, keeping activeID: UUID?,
                                 createdBefore cutoff: Date) async throws {
        let descriptor = ImportSession.request(.equals("importType", importType))
        let toDelete = try context.fetch(descriptor).filter { $0.id != activeID && $0.sessionDate < cutoff }
        guard !toDelete.isEmpty else { return }
        for session in toDelete { context.delete(session) }
        try commit()
    }

    func batchUpdateListOrders(_ updates: [(listID: UUID, displayOrder: Int)]) async throws {

        guard !updates.isEmpty else { return }

        let updateIDs = Set(updates.map { $0.listID })
        let descriptor = ListObject.request(.in("listID", updateIDs))
        let lists = try context.fetch(descriptor)

        /// Last value wins for a repeated listID, matching the order in which
        /// DataCoordinator applied the same updates to MemoryStore. uniqueKeysWithValues
        /// would trap on the repeat instead.
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

        context.insert(newList)
        try commit() }

    func updateList(listID: UUID, name: String?, displayOrder: Int?,
        sortFilterOptions: [String]?) async throws {

        let descriptor = ListObject.request(.equals("listID", listID))

        guard let list = try context.fetch(descriptor).first else {
            throw PersistenceError.listNotFound(listID) }

        if let name = name { list.listName = name }
        if let displayOrder = displayOrder { list.displayOrder = displayOrder }
        if let options = sortFilterOptions { list.sortFilterOptions = options }

        try commit() }

    func deleteList(listID: UUID) async throws {

        let descriptor = ListObject.request(.equals("listID", listID))

        guard let list = try context.fetch(descriptor).first else {
            throw PersistenceError.listNotFound(listID) }
        /// Refreshed so its memberships are read from the store, not from a relationship this
        /// long-lived context loaded earlier (see deleteFilms).
        context.refresh(list, mergeChanges: false)

        /// ListObject.memberships cascades, so its memberships go with it.
        context.delete(list)
        try commit() }

}

// MARK: - Film Link Operations

/// Why a film link could not be set. The store is unchanged when one is thrown.
enum FilmLinkError: Error, LocalizedError, Equatable {
    case selfLink
    case emptyKind
    case filmNotFound(UUID)
    /// The link would close a cycle among links of its kind (FilmLinkRules rule 3).
    case cycle

    var errorDescription: String? {
        switch self {
        case .selfLink: return "A film can't be linked to itself."
        case .emptyKind: return "A film link needs a kind."
        case .filmNotFound(let id): return "Film not found: \(id)"
        case .cycle: return "That link would make the films a loop of the same kind."
        }
    }
}

/// Every film link write goes through here, on the actor's background context, one commit per
/// call. The rules are FilmLinkRules'; deleting a film needs nothing from this section, since
/// both of Film's link relationships cascade (deleteFilms already refreshes the film first, so
/// links another context saved are deleted too).
extension DataManager {

    /// Makes the store hold exactly `link` on its pair: the row with its ID (created if there
    /// is none, moved if it sits on another pair), with its kind, ends and date, and no other
    /// link on the pair. This is the write DataCoordinator sends, so the store ends with the
    /// very link memory shows, ID and date included. Validated against the store as it is
    /// (FilmLinkRules 1–3, both films present); throws FilmLinkError, leaving the store as it
    /// was. One commit.
    func saveFilmLink(_ link: FilmLinkSnapshot) throws {
        let kind = FilmLinkKind.normalized(link.kind)
        guard !kind.isEmpty else { throw FilmLinkError.emptyKind }
        guard link.sourceID != link.targetID else { throw FilmLinkError.selfLink }

        let films = try context.fetch(Film.request(.in("id", [link.sourceID, link.targetID])))
        guard let source = films.first(where: { $0.id == link.sourceID }) else { throw FilmLinkError.filmNotFound(link.sourceID) }
        guard let target = films.first(where: { $0.id == link.targetID }) else { throw FilmLinkError.filmNotFound(link.targetID) }

        /// Every link as stored. Those on this pair are being replaced, and so is the row with
        /// this ID wherever it sits, so all of them are left out of the cycle test. Normally the
        /// pair holds at most one link and it has this ID; a store the launch cleanup has not
        /// repaired yet can hold more, and every other one is deleted, so the pair ends with
        /// exactly this link either way.
        let links = try fetchAllFilmLinks()
        let replaced = links.filter { $0.id == link.id || $0.snapshot?.pair == link.pair }
        let edges = links.compactMap { stored -> FilmLinkRules.Edge? in
            guard !replaced.contains(where: { $0 === stored }) else { return nil }
            return stored.snapshot?.edge
        }
        guard !FilmLinkRules.closesCycle(source: link.sourceID, target: link.targetID, kind: kind, in: edges) else {
            throw FilmLinkError.cycle
        }

        let row: FilmLink
        if let existing = replaced.first(where: { $0.id == link.id }) {
            existing.kind = kind
            existing.sourceFilm = source
            existing.targetFilm = target
            existing.dateAdded = link.dateAdded
            row = existing
        } else {
            row = FilmLink(id: link.id, kind: kind, source: source, target: target, dateAdded: link.dateAdded)
        }
        for extra in replaced where extra !== row { context.delete(extra) }
        try commit()
        log("Linked \(link.sourceID) → \(link.targetID) as \(kind)\(replaced.isEmpty ? "" : " (replacing \(replaced.count) stored link(s))")")
    }

    /// Deletes the link between two films, whichever way it points. Returns how many were
    /// deleted (more than one only in a store the launch cleanup has not repaired yet).
    @discardableResult
    func removeFilmLinks(between a: UUID, and b: UUID) throws -> Int {
        let pair = FilmLinkRules.Pair(a, b)
        let doomed = try fetchAllFilmLinks().filter { link in
            guard let s = link.sourceFilm?.id, let t = link.targetFilm?.id else { return false }
            return FilmLinkRules.Pair(s, t) == pair
        }
        for link in doomed { context.delete(link) }
        try commit()
        return doomed.count
    }

    /// What `cleanupFilmLinks` did: how many links it removed for each reason, their IDs, and,
    /// when it removed any, every link left in the store, so DataCoordinator can bring memory
    /// into line with exactly what the store now holds.
    struct FilmLinkCleanup: Sendable {
        var counts: [FilmLinkRules.Rejection: Int] = [:]
        var removedIDs: Set<UUID> = []
        var kept: [FilmLinkSnapshot] = []
    }

    /// Removes links that break FilmLinkRules: orphans, self-links, empty kinds, a second link
    /// on a pair and links closing a cycle of one kind. Oldest links win (FilmLinkRules.sieve),
    /// so the result is the same whenever it runs, and the same as MemoryStore's slow-path load,
    /// which sieves the same rows in the same order. Runs at launch after the membership cleanup;
    /// with nothing to remove it commits nothing. One commit for all of it.
    func cleanupFilmLinks() throws -> FilmLinkCleanup {
        #if DEBUG
        let threadProbe = DataManagerThreadProbe.begin("cleanupFilmLinks")
        defer { threadProbe?.end() }
        #endif

        let links = try fetchAllFilmLinks()
        guard !links.isEmpty else { return FilmLinkCleanup() }
        let (kept, rejected) = FilmLinkRules.sieve(links, ends: { link in
            guard let s = link.sourceFilm?.id, let t = link.targetFilm?.id else { return nil }
            return (s, t)
        }, kind: \.kind)
        guard !rejected.isEmpty else { return FilmLinkCleanup() }

        /// No cancellation check, unlike the membership cleanup: this runs as a tracked
        /// operation (DataCoordinator.cleanupFilmLinks), which shutdown lets finish rather than
        /// cancels, and memory is brought into line with what it commits.
        var result = FilmLinkCleanup(kept: kept.compactMap(\.snapshot))
        for (link, reason) in rejected where unsafe link.managedObjectContext != nil {
            result.removedIDs.insert(link.id)
            context.delete(link)
            result.counts[reason, default: 0] += 1
        }
        try commit()
        return result
    }

    /// Every link row, orphans included, in FilmLinkRules.ordersBefore order (sorted here,
    /// where the ID tie-break can be applied), read fresh from the store. The table is small
    /// (one row per link the user made), so it is read whole.
    private func fetchAllFilmLinks() throws -> [FilmLink] {
        let request = FilmLink.request()
        request.shouldRefreshRefetchedObjects = true
        return try context.fetch(request).sorted {
            FilmLinkRules.ordersBefore(($0.dateAdded, $0.id), ($1.dateAdded, $1.id))
        }
    }
}

#if DEBUG
/// Reads and writes only the harness uses (99.63 DHFilmLinks), to drive and inspect the store
/// directly. The app writes through DataCoordinator, which sends `saveFilmLink`.
extension DataManager {

    /// Every link that has both films, oldest first, as stored.
    func fetchFilmLinks() throws -> [FilmLinkSnapshot] {
        try fetchAllFilmLinks().compactMap(\.snapshot)
    }

    /// The links `filmID` is part of, in either direction, oldest first.
    func fetchFilmLinks(for filmID: UUID) throws -> [FilmLinkSnapshot] {
        try fetchFilmLinks().filter { $0.sourceID == filmID || $0.targetID == filmID }
    }

    /// Records "source is a `kind` of target". A pair already linked (either direction, any
    /// kind) has that link rewritten in place: same ID and date, new kind and direction (the
    /// oldest, in a store not yet cleaned). Throws FilmLinkError as `saveFilmLink` does.
    @discardableResult
    func setFilmLink(source sourceID: UUID, target targetID: UUID, kind rawKind: String) throws -> FilmLinkSnapshot {
        let pair = FilmLinkRules.Pair(sourceID, targetID)
        let existing = try fetchAllFilmLinks().first { $0.snapshot?.pair == pair }
        let desired = FilmLinkSnapshot(id: existing?.id ?? UUID(), kind: FilmLinkKind.normalized(rawKind),
                                       sourceID: sourceID, targetID: targetID,
                                       dateAdded: existing?.dateAdded ?? Date())
        try saveFilmLink(desired)
        return desired
    }

    /// Deletes one link. Returns whether it existed.
    @discardableResult
    func removeFilmLink(id: UUID) throws -> Bool {
        guard let link = try context.fetch(FilmLink.request(.equals("id", id))).first else { return false }
        context.delete(link)
        try commit()
        return true
    }
}
#endif

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

// MARK: - Film Link Layer Digest

/// The link half of `StoreFingerprint`, accumulated one link at a time, fed by both the live
/// side (`DataManager.computeStoreFingerprint`) and the stored side
/// (`MemoryStoreCache.buildFingerprint`), so the two cannot mix a link differently.
///
/// Each link's ID, source, target, kind and date are chained through `StoreFingerprint.rankMix`,
/// so swapping the ends, moving a kind to another link or rewriting a link in place (same ID)
/// all change the digest; XOR keeps it independent of order. The kind is hashed with FNV-1a
/// over its UTF-8 bytes, which is the same in every process (Swift's `hashValue` is seeded
/// per launch and would never match a stored value). The date is in it because the date
/// orders links (which one the rules keep, the order they are listed in) and a cache must
/// not show an order the store would not; it is the stored Double's exact bits, which the
/// store, memory and the snapshot cache's JSON all carry unchanged.
struct FilmLinkLayerDigest: Equatable, Sendable {
    private(set) var linkCount = 0
    private(set) var xor: UInt64 = 0

    mutating func add(_ link: FilmLinkSnapshot) {
        func fold(_ id: UUID) -> UInt64 { let (hi, lo) = id.fingerprintHalves; return hi ^ lo }
        var mixed = StoreFingerprint.rankMix(fold(link.id), 1)
        mixed = StoreFingerprint.rankMix(mixed ^ fold(link.sourceID), 2)
        mixed = StoreFingerprint.rankMix(mixed ^ fold(link.targetID), 3)
        mixed = StoreFingerprint.rankMix(mixed ^ Self.stableHash(link.kind), 4)
        mixed = StoreFingerprint.rankMix(mixed ^ link.dateAdded.timeIntervalSinceReferenceDate.bitPattern, 5)
        linkCount += 1
        xor ^= mixed
    }

    /// FNV-1a, 64-bit.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}

// MARK: - Thread Probe

#if DEBUG
/// DEBUG-only record of which thread each probed DataManager method ran on, and what it
/// cost there. Under SwiftData a call ran on the thread that awaited it; under Core Data it
/// runs on the context's queue (ContextExecutor), which the probe can confirm.
/// Inert (nil tokens, no locking) unless a harness scenario sets `isEnabled`.
final class DataManagerThreadProbe: Sendable {
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

// MARK: - Saved Search Operations
/// An extension in this file, so it can call the actor's private commit().

extension DataManager {
    /// Every saved search, for SavedSearchStore.attach at startup, and the ones that need
    /// review: a stored rule this build cannot read (a backup or store a newer version wrote)
    /// is left out, and a query that cannot be read at all loads empty. Each is logged. Their
    /// rows are not rewritten here — only the user's save does that.
    func fetchSavedSearches() throws -> (searches: [SavedSearch], needingReview: Set<UUID>) {
        var searches: [SavedSearch] = []
        var needingReview: Set<UUID> = []
        for row in try SavedSearchObject.fetchAll(in: context) {
            let (search, dropped, isUnreadable) = row.decoded
            if isUnreadable {
                Self.log("WARNING: Saved search \"\(row.name)\" (\(row.searchID)) has an unreadable query — it needs review", level: .warning)
            }
            for token in dropped {
                Self.log("WARNING: Saved search \"\(row.name)\": left out \(token.syntax) — not a rule this version can read", level: .warning)
            }
            if isUnreadable || !dropped.isEmpty { needingReview.insert(search.id) }
            searches.append(search)
        }
        return (searches, needingReview)
    }

    func insertSavedSearch(_ search: SavedSearch) async throws {
        context.insert(SavedSearchObject(search))
        try commit()
    }

    func updateSavedSearch(_ search: SavedSearch) async throws {
        try savedSearchRow(search.id).apply(search)
        try commit()
    }

    func deleteSavedSearch(id: UUID) async throws {
        context.delete(try savedSearchRow(id))
        try commit()
    }

    /// Writes new sidebar positions: `orders` maps a search's ID to its displayOrder.
    func updateSavedSearchOrders(_ orders: [UUID: Int]) async throws {
        guard !orders.isEmpty else { return }
        let ids = Set(orders.keys)
        let rows = try context.fetch(SavedSearchObject.request(.in("searchID", ids)))
        for row in rows {
            if let order = orders[row.searchID] { row.displayOrder = order }
        }
        try commit()
    }

    // MARK: Settings

    /// Upserts the singleton settings row from `snapshot`, deleting any row under another
    /// snapshotID (a one-time recovery path from an earlier bug). One commit.
    func saveSettings(_ snapshot: SettingsSnapshot) async throws {
        var singleton: SettingsObject?
        var stale = 0
        for row in try context.fetch(SettingsObject.request()) {
            if row.snapshotID == SettingsObject.singletonID, singleton == nil {
                singleton = row
            } else {
                context.delete(row)
                stale += 1
            }
        }
        if stale > 0 { Self.log("Deleted \(stale) stale SettingsObject(s)") }

        let settings: SettingsObject
        if let singleton {
            settings = singleton
        } else {
            Self.log("Creating new SettingsObject singleton")
            settings = SettingsObject(snapshotID: SettingsObject.singletonID,
                                      version: SettingsObject.currentVersion, lastSyncDate: Date())
            context.insert(settings)
        }
        snapshot.apply(to: settings)
        /// After apply: a snapshot built with another snapshotID (a restored backup's) must
        /// still land on the singleton, or the next fetch would orphan it.
        settings.snapshotID = SettingsObject.singletonID
        try commit()
    }

    private func savedSearchRow(_ id: UUID) throws -> SavedSearchObject {
        let rows = try context.fetch(SavedSearchObject.request(.equals("searchID", id)))
        guard let row = rows.first else { throw PersistenceError.savedSearchNotFound(id) }
        return row
    }
}

/// One release's sort order before and after the carousel order conversion.
nonisolated struct ReleaseOrderChange: Sendable {
    let old: Int
    let new: Int
}
