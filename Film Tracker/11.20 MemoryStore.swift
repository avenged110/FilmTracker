// MARK: - MemoryStore.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// The in-memory source of truth for all film and list data, held as value types. Core Data
/// objects are read only during startup and converted to snapshots immediately.

import Foundation
import CoreData

struct MemoryList: Codable {
    let listID: UUID
    var listName: String
    var displayOrder: Int
    var sortFilterOptions: [String]
    var filmIDs: Set<UUID>
    
    init(listID: UUID, listName: String, displayOrder: Int,
         sortFilterOptions: [String], filmIDs: Set<UUID>) {
        self.listID = listID
        self.listName = listName
        self.displayOrder = displayOrder
        self.sortFilterOptions = sortFilterOptions
        self.filmIDs = filmIDs
    }

    /// The canonical display order for user lists: `displayOrder` ascending, tie-broken on `listID`.
    ///
    /// The tiebreak is required: Swift's sort is not stable, and duplicate `displayOrder` values
    /// are reachable (from a restored backup, or from two `createList` calls that read the same
    /// max order). Without it, a list's position could change between launches.
    ///
    /// Defined on the model so every surface that orders lists (the sidebar, the "Show in List"
    /// menus, the Right Sidebar's membership table) shares one rule.
    static func orderedBefore(_ lhs: MemoryList, _ rhs: MemoryList) -> Bool {
        lhs.displayOrder != rhs.displayOrder
            ? lhs.displayOrder < rhs.displayOrder
            : lhs.listID.uuidString < rhs.listID.uuidString
    }
}

@MainActor
final class MemoryStore: Loggable {
    nonisolated static let logTag = "[MemoryStore]"
    
    // MARK: - Storage (value types only — no model objects)
    private var films: [UUID: FilmSnapshot] = [:] {
        didSet {
            contentVersion = Self.nextContentVersion()
            filmsVersion = contentVersion
        }
    }
    private var lists: [UUID: MemoryList] = [:] { didSet { contentVersion = Self.nextContentVersion() } }
    private var filmToLists: [UUID: Set<UUID>] = [:]

    /// Film links by ID (64.10 FilmLinkObj.swift), and the reverse index from each film, at
    /// either end, to its links.
    ///
    /// A link is LIVE while both its films are in `films`; every reader sees only live links.
    /// Deleting a film leaves its links here, unseen, rather than removing them: if the delete
    /// fails to persist, the rollback puts the film back and its links are live again exactly
    /// as the store still holds them, with nothing to restore (even when the film at the other
    /// end was deleted by a later operation that also fails). DataCoordinator prunes the
    /// unseen ones once no operation is pending (`pruneDanglingFilmLinks`), when every delete
    /// has either persisted (the store cascaded the links) or rolled back.
    ///
    /// The live links obey FilmLinkRules as loaded (the slow path sieves them as the launch
    /// cleanup does). While writes are pending they can briefly hold a cycle of one kind (a
    /// failed delete's rollback reviving links beside an optimistic link the store will then
    /// refuse, and roll back too), so nothing that walks them may assume they cannot (see
    /// `linkedFilmIDs`).
    private var filmLinks: [UUID: FilmLinkSnapshot] = [:] { didSet { contentVersion = Self.nextContentVersion() } }
    private var filmToLinks: [UUID: Set<UUID>] = [:]
    /// Set when a link may have stopped being live (a linked film deleted, or a pair set to a
    /// link whose film is gone), so `pruneDanglingFilmLinks` scans only when there can be
    /// something to drop. It runs every time the operation queue drains.
    private var mayHoldDanglingFilmLinks = false
    /// The live links as one rule graph, with the `contentVersion` it was built at, for
    /// `filmLinkProblem`: built on the first check after any change, so a picker checking
    /// every film against the rules reads the links once, not once per film.
    private var liveFilmLinkGraph: (version: UInt64, graph: FilmLinkRules.Graph)?

    /// Called whenever the set of live links may have changed: a link written or removed, or a
    /// film that has links deleted or put back. DataCoordinator moves its observed
    /// `filmLinksRevision` from it, so a view reading links redraws.
    var filmLinksDidChange: (() -> Void)?
    private(set) var hallOfFameFilms: [UUID] = []
    private var cachedViews: [CacheKey: [FilmSnapshot]] = [:]
    
    /// Sorted array of all lists, invalidated on list mutations, so `getAllLists()` does not re-sort.
    private var sortedListsCache: [MemoryList]?
    
    private struct CacheKey: Hashable {
        let viewID: ViewIdentifier
        let sortOption: SortOption
        let direction: SortDirection
        let filterOptions: Set<FilterOption>
    }
    
    private(set) var isInitialized = false

    /// Set once Phase 1 has started, on either path. `isInitialized` is set only in Phase 2,
    /// so it cannot stop a second Phase 1 call that arrives before Phase 2 completes.
    private var hasLoadedFromDatabase = false

    /// Set when the slow-path store fetch threw. The dictionaries are then empty or partial and
    /// are not an authoritative picture of the library. Derived-cache writes are suspended, and
    /// DataCoordinator skips post-startup work that would act on the empty state.
    private(set) var loadFailed = false

    /// When true, every derived-cache write is suppressed, both the throttled path and the
    /// shutdown flush.
    ///
    /// The snapshot and metadata caches are derived data that let the next launch skip the store
    /// read. Writing them from a store that does not mirror the database would replace the correct
    /// caches with a wrong payload. Two situations set this, both from DataCoordinator:
    ///   • the persistent container failed to open and the app is running against the empty
    ///     in-memory fallback purely to present the "Library Unavailable" recovery alert;
    ///   • the Phase 1 store fetch threw (loadFailed above).
    private var cachePersistenceSuspended = false

    /// Identifies the current contents of `films`, `lists` and `filmLinks`, so MemoryStoreCache
    /// can skip a save of contents it already wrote. Advanced by the three properties' `didSet`,
    /// so no mutation path can miss it. `filmToLists` is not persisted and is excluded. The counter is
    /// shared by all instances, so two stores never share a version once mutated.
    private var contentVersion: UInt64 = 0
    /// Moves with every write to `films` (not `lists`), drawn from the same counter as
    /// `contentVersion`, so it is unique across stores. A reader that remembers it can tell
    /// whether the films changed without holding the dictionary, which would keep a stale
    /// copy alive and make the next edit copy all of it.
    private(set) var filmsVersion: UInt64 = 0
    private static var contentVersionCounter: UInt64 = 0
    private static func nextContentVersion() -> UInt64 {
        contentVersionCounter &+= 1
        return contentVersionCounter
    }

    /// Suspends derived-cache persistence for the rest of this session. It is one-way: neither
    /// triggering condition can recover in-session, so re-enabling would reintroduce the risk.
    func suspendCachePersistence(reason: String) {
        guard !cachePersistenceSuspended else { return }
        cachePersistenceSuspended = true
        /// Cancel any save already scheduled, so a throttled task cannot write after suspension.
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        Self.log("Derived-cache persistence suspended for this session: \(reason)")
    }

    /// Set when Phase 1 used the slow store path. validateCacheAndFinalize() reads this to decide
    /// whether to write a fresh snapshot cache.
    private var snapshotCacheNeedsRebuild = false

    /// True when Phase 1's store read found a release value in an old format (see
    /// LegacyReleaseValues). DataCoordinator then runs DataManager's one-time store rewrite.
    /// A cache hit never sets it: the cache is written from memory, which is always current.
    private(set) var hasLegacyReleaseValues = false
    
    #if DEBUG
    /// Which way Phase 1 loaded ("snapshot cache" or "store"), for the harness.
    private(set) var loadPathForTesting = ""
    #endif

    /// Direct film count without array allocation.
    var totalFilmCount: Int { films.count }
    
    /// Throttled save task, to limit disk I/O
    private var pendingSaveTask: Task<Void, Never>?
    private let saveThrottleInterval: Duration = .seconds(2)
    
    // MARK: - Initialization
    
    /// STARTUP: Two phases, so the store fetch (Phase 1) overlaps with MetadataCache disk I/O.
    ///
    ///   Phase 1 - loadFromDatabase(): store fetch (or snapshot cache), snapshot conversion, and
    ///             HoF rebuild. Has no MetadataCache dependency.
    ///
    ///   Phase 2 - validateCacheAndFinalize(): checks cache integrity, updates it if needed, and
    ///             sets isInitialized. Requires MetadataCache to be loaded.
    
    /// Phase 1: Loads all data into memory as FilmSnapshots, from the snapshot cache if valid,
    /// otherwise from the store. Managed objects are converted and not retained. It has no
    /// MetadataCache dependency, so it can run alongside cache disk I/O.
    ///
    /// Reentrancy: `hasLoadedFromDatabase` is claimed synchronously at entry, before any
    /// suspension point, so MainActor isolation serializes callers.
    ///
    /// - Parameters:
    ///   - persistentContainer: Used only by the slow path, which fetches on a background context
    ///     (see `loadAllDataFromStore`).
    ///   - dataManager: Used only by the fast path, whose fingerprint query runs on DataManager's
    ///     background context (see `DataManager.computeStoreFingerprint()`).
    func loadFromDatabase(persistentContainer: NSPersistentContainer, dataManager: DataManager) async {
        guard !isInitialized, !hasLoadedFromDatabase else {
            Self.log("Phase 1 already completed — skipping")
            return
        }
        hasLoadedFromDatabase = true

        let startTime = Date()
        Self.log("Phase 1: Loading data...")

        /// Fast path: try to restore from the on-disk MemoryStore snapshot.
        /// MemoryStoreCache stores the full [UUID: FilmSnapshot] + list data serialized
        /// as JSON, validated by a fingerprint derived from the store.
        /// On a cache hit the entire store fetch + snapshot conversion is skipped —
        /// reducing Phase 1 from O(N × relationships) to a single JSON decode.
        let cacheResult = await MemoryStoreCache.shared.load(dataManager: dataManager)

        switch cacheResult {
        case .hit(let films, let lists, let filmToLists, let links):
            self.films = films
            self.lists = lists
            self.filmToLists = filmToLists
            self.filmLinks = links
            self.rebuildFilmLinkIndex()
            /// The loaded dictionaries match the file, so a save before any change has nothing to write.
            MemoryStoreCache.shared.recordOnDisk(contentVersion: contentVersion)
            #if DEBUG
            loadPathForTesting = "snapshot cache"
            #endif
            self.sortedListsCache = nil
            self.rebuildHallOfFame()
            /// No payload is pushed to MemoryStoreCache here: each flush reads the dictionaries when
            /// it runs (see flushCaches). Holding an extra reference would make the first film edit
            /// copy the whole dictionary.
            let duration = Date().timeIntervalSince(startTime)
            Self.log("Phase 1 fast-path: \(self.films.count) films, \(self.filmLinks.count) film link(s) from snapshot cache in \(Fmt.fixed(duration, 2))s")
            filmLinksDidChange?()

        case .miss:
            /// Slow path: full store fetch and snapshot conversion. Runs on first launch, or when the
            /// store fingerprint has changed. The cache is rebuilt by validateCacheAndFinalize().
            Self.log("Phase 1 slow-path: snapshot cache miss, reading the store...")
            LaunchReveal.shared.snapshotMissed()
            self.snapshotCacheNeedsRebuild = true
            #if DEBUG
            loadPathForTesting = "store"
            #endif
            do {
                let loadedData = try await loadAllDataFromStore(persistentContainer: persistentContainer)
                self.films = loadedData.films
                self.lists = loadedData.lists
                self.filmToLists = loadedData.filmToLists
                self.filmLinks = loadedData.links
                self.rebuildFilmLinkIndex()
                self.sortedListsCache = nil
                self.rebuildHallOfFame()
                if loadedData.rejectedLinkCount > 0 {
                    Self.log("Left out \(loadedData.rejectedLinkCount) film link(s) breaking FilmLinkRules — the launch cleanup removes them from the store")
                }
                filmLinksDidChange?()
            } catch {
                /// The dictionaries stay empty. Mark the store non-authoritative: suspend derived-cache
                /// writes immediately, so none can be scheduled, and DataCoordinator skips post-startup
                /// work that would act on an empty library (poster pruning, orphaned-membership cleanup,
                /// internal list bootstrapping, settings sync).
                loadFailed = true
                suspendCachePersistence(reason: "Phase 1 store fetch failed")
                Self.log("ERROR: Failed to load from database: \(error) — treating this session's in-memory state as non-authoritative")
            }
            let duration = Date().timeIntervalSince(startTime)
            Self.log("Phase 1 slow-path complete: \(films.count) films in \(Fmt.fixed(duration, 2))s")
        }
    }
    
    /// Phase 2: Validate MetadataCache integrity and finalize initialization.
    /// Must be called AFTER MetadataCache.load() has completed.
    func validateCacheAndFinalize() async {
        guard !isInitialized else { return }
        guard !films.isEmpty else {
            /// The cache file can still describe a library that is gone: one replaced by a new
            /// empty library, an empty restore, or a delete-all that crashed before the save.
            /// Left loaded, its entries would put films that do not exist into Recents for the
            /// whole session, and the shutdown save would write them back.
            if !MetadataCache.shared.metadata.isEmpty {
                Self.log("Library is empty — clearing \(MetadataCache.shared.metadata.count) stale MetadataCache entries")
                await MetadataCache.shared.rebuild(from: [:])
                scheduleThrottledSave()
            }
            isInitialized = true
            Self.log("Phase 2 complete (no films)")
            return
        }
        
        let startTime = Date()
        Self.log("Phase 2: Validating metadata cache...")
        
        let cacheCount = MetadataCache.shared.metadata.count

        /// If Phase 1 took the slow path (store fetch), film snapshots are guaranteed
        /// to be fresher than anything on disk. Force a full MetadataCache rebuild so
        /// derived sort keys, rotation dates, and search strings are always consistent
        /// with the newly-loaded snapshot data. This closes the narrow window where
        /// MetadataCache could be stale: both caches are normally written together in the
        /// same throttled save, but a crash between writes could leave MetadataCache out
        /// of sync with the store state that triggered the slow-path load.
        if snapshotCacheNeedsRebuild {
            Self.log("Slow-path load — forcing full MetadataCache rebuild...")
            let rebuildStart = Date()
            await MetadataCache.shared.rebuild(from: films)
            let rebuildDuration = Date().timeIntervalSince(rebuildStart)
            Self.log("Full rebuild in \(Fmt.fixed(rebuildDuration * 1000, 1))ms")
            /// Both caches are now current. Schedule a throttled save to write them together.
            snapshotCacheNeedsRebuild = false
            scheduleThrottledSave()
        } else if cacheCount == 0 {
            Self.log("No existing MetadataCache — performing full rebuild...")
            let rebuildStart = Date()
            await MetadataCache.shared.rebuild(from: films)
            let rebuildDuration = Date().timeIntervalSince(rebuildStart)
            Self.log("Full rebuild in \(Fmt.fixed(rebuildDuration * 1000, 1))ms")
            scheduleThrottledSave()
        } else if let mismatch = metadataMismatch(cacheCount: cacheCount) {
            /// The metadata file was not saved with this snapshot, so any entry may describe an
            /// older version of its film, not only the missing or extra ones. A full rebuild is the
            /// only repair that covers that (about 50 ms off the main actor at 1,400 films).
            Self.log("MetadataCache does not match the snapshot cache (\(mismatch)) — performing full rebuild...")
            let rebuildStart = Date()
            await MetadataCache.shared.rebuild(from: films)
            Self.log("Full rebuild in \(Fmt.fixed(Date().timeIntervalSince(rebuildStart) * 1000, 1))ms")
            scheduleThrottledSave()
        } else {
            Self.log("Cache validated — no rebuild needed")
        }

        isInitialized = true

        let totalDuration = Date().timeIntervalSince(startTime)
        Self.log("Phase 2 complete in \(Fmt.fixed(totalDuration, 2))s - memory store ready")
    }
    
    /// Why the loaded MetadataCache cannot be trusted beside the snapshot cache hit, or nil when
    /// it can. The deciding test is the pairing ID (StoredFingerprintFile): the snapshot cache
    /// records the ID of the metadata file saved with it. The count and a spot check of a few
    /// keys remain as cheap backstops.
    private func metadataMismatch(cacheCount: Int) -> String? {
        let loadedID = MetadataCache.shared.loadedFileID
        let pairedID = MemoryStoreCache.shared.loadedMetadataFileID
        if loadedID == nil || loadedID != pairedID {
            return "file \(loadedID?.uuidString ?? "unrecorded"), snapshot paired with \(pairedID?.uuidString ?? "none")"
        }
        if cacheCount != films.count {
            return "count \(cacheCount) ≠ \(films.count) films"
        }
        /// load() checked the file's threshold; this covers a default changed since, which
        /// DataCoordinator leaves to startup (handleDefaultRotationThresholdChangeIfNeeded).
        if !MetadataCache.shared.entriesFollowRotationThreshold(Preferences.defaultRotationThreshold) {
            return "entries follow another default rotation threshold"
        }
        if films.keys.prefix(5).contains(where: { MetadataCache.shared.metadata[$0] == nil }) {
            return "spot check found a film with no entry"
        }
        return nil
    }

    // MARK: - Data Loading
    
    /// Loads all Films and Lists from the store, converting each model object to a snapshot as
    /// it is read. Model objects are not retained after this method returns.
    ///
    /// Runs on a fresh private-queue context, off the main thread.
    private func loadAllDataFromStore(persistentContainer: NSPersistentContainer) async throws -> LoadedData {
        let context = persistentContainer.makeBackgroundContext()
        let loaded = try await context.perform {
            /// Releases are prefetched so that FilmSnapshot.init(from:) reading film.releases
            /// is pure property access, not one SQL round trip per film.
            let filmDescriptor = Film.request()
            filmDescriptor.relationshipKeyPathsForPrefetching = ["releases"]
            filmDescriptor.returnsObjectsAsFaults = false
            let allFilms = try context.fetch(filmDescriptor)

            var filmDict: [UUID: FilmSnapshot] = [:]
            filmDict.reserveCapacity(allFilms.count)
            var sawLegacyValues = false
            for film in allFilms {
                if !sawLegacyValues, film.releases.contains(where: LegacyReleaseValues.isLegacy) {
                    sawLegacyValues = true
                }
                filmDict[film.id] = FilmSnapshot(from: film)
            }

            /// Lists with their memberships and each membership's film prefetched, so that
            /// reading membership.film below does not fault per row.
            let listDescriptor = ListObject.request(
                sortedBy: [NSSortDescriptor(key: "displayOrder", ascending: true)])
            listDescriptor.relationshipKeyPathsForPrefetching = ["memberships", "memberships.film"]
            let allLists = try context.fetch(listDescriptor)

            var listDict: [UUID: MemoryList] = [:]
            var filmToListsDict: [UUID: Set<UUID>] = [:]

            for list in allLists {
                let filmIDs = Set(list.memberships.compactMap { $0.film?.id })

                let memoryList = MemoryList(
                    listID: list.listID,
                    listName: list.listName,
                    displayOrder: list.displayOrder,
                    sortFilterOptions: list.sortFilterOptions,
                    filmIDs: filmIDs
                )

                listDict[list.listID] = memoryList

                for filmID in filmIDs {
                    filmToListsDict[filmID, default: []].insert(list.listID)
                }
            }

            /// Links with both films prefetched. Sieved oldest first exactly as the launch cleanup
            /// sieves the store (DataManager.cleanupFilmLinks), so memory holds the links that
            /// cleanup keeps and never one it removes. Orphans are rejected by the sieve too.
            let linkDescriptor = FilmLink.request()
            linkDescriptor.relationshipKeyPathsForPrefetching = ["sourceFilm", "targetFilm"]
            let storedLinks = try context.fetch(linkDescriptor).sorted {
                FilmLinkRules.ordersBefore(($0.dateAdded, $0.id), ($1.dateAdded, $1.id))
            }
            let (keptLinks, rejectedLinks) = FilmLinkRules.sieve(storedLinks, ends: { link in
                guard let s = link.sourceFilm?.id, let t = link.targetFilm?.id,
                      filmDict[s] != nil, filmDict[t] != nil else { return nil }
                return (s, t)
            }, kind: \.kind)
            var linkDict: [UUID: FilmLinkSnapshot] = [:]
            for link in keptLinks { if let snapshot = link.snapshot { linkDict[snapshot.id] = snapshot } }

            return (LoadedData(films: filmDict, lists: listDict, filmToLists: filmToListsDict,
                               links: linkDict, rejectedLinkCount: rejectedLinks.count),
                    sawLegacyValues)
        }
        if loaded.1 { hasLegacyReleaseValues = true }
        return loaded.0
    }

    private struct LoadedData: Sendable {
        let films: [UUID: FilmSnapshot]
        let lists: [UUID: MemoryList]
        let filmToLists: [UUID: Set<UUID>]
        let links: [UUID: FilmLinkSnapshot]
        let rejectedLinkCount: Int
    }
    
    /// Throttled save of both derived caches: MetadataCache (sort and search data) and
    /// MemoryStoreCache (the snapshot, so the next launch can skip the store fetch). This is the
    /// only throttled-save owner, so there is one timer and no cross-file write races.
    ///
    /// The snapshot payload is read from this store's dictionaries when the throttle expires, not
    /// when the save is scheduled. Holding a reference earlier would force a full copy-on-write
    /// copy of the dictionary on the next film edit. See MemoryStoreCache.save(films:lists:).
    private func scheduleThrottledSave() {
        /// Checked here so no timer is armed when suspended, and again after the throttle window
        /// in case suspension was requested while it was pending.
        guard !cachePersistenceSuspended else { return }

        pendingSaveTask?.cancel()
        /// Not Task.detached: the task must return to MainActor to read the dictionaries, and
        /// Task.sleep suspends rather than blocking, so inheriting MainActor costs nothing.
        pendingSaveTask = Task { [weak self, saveThrottleInterval] in
            do {
                try await Task.sleep(for: saveThrottleInterval)
            } catch {
                return  /// Canceled during the throttle window — a newer save is scheduled.
            }
            guard !Task.isCancelled, let self, !self.cachePersistenceSuspended else { return }
            await self.flushCaches()
        }
    }

    /// Writes both derived caches from this store's current state. The files are independent, so
    /// the writes run concurrently. Callers must check `cachePersistenceSuspended` first.
    private func flushCaches() async {
        /// Read into locals on MainActor, in one synchronous step. The locals keep a reference during the write,
        /// so a mutation mid-encode pays one copy-on-write copy. `filmToLists` is not captured, since
        /// it is not persisted (the cache rebuilds it from `lists` on load).
        let filmsPayload = films
        let listsPayload = lists
        /// Live links only, so the payload never names a film it does not hold. A link left by a
        /// delete that is still pending is not written; if the delete rolls back, the version
        /// moves (the film comes back) and the next save writes it.
        let linksPayload = allFilmLinks()
        /// Read in the same synchronous step as the payload it names (see contentVersion).
        let payloadVersion = contentVersion

        /// The snapshot save records the ID of the metadata file this save leaves on disk
        /// (StoredFingerprintFile). It encodes and writes its payload while the metadata save runs,
        /// and waits for that ID only to write its small fingerprint file.
        let metadataSave = Task { await MetadataCache.shared.save() }
        await MemoryStoreCache.shared.save(
            films: filmsPayload, lists: listsPayload, links: linksPayload, contentVersion: payloadVersion,
            metadataFileID: metadataSave)
        _ = await metadataSave.value
    }

    /// Immediate save, for shutdown. Cancels the pending throttled task first, so it cannot wake
    /// after the shutdown write and overwrite the new files with a stale payload.
    func saveImmediately() async {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil

        /// A non-authoritative store must not overwrite the on-disk caches. This guard matters most
        /// on failure paths, because the shutdown flush bypasses the throttle.
        guard !cachePersistenceSuspended else {
            Self.log("Immediate save skipped — derived-cache persistence is suspended for this session")
            return
        }
        /// A quit before startup finishes would write a partial library over caches that are at
        /// least as good. Skipping the write loses nothing: the store is the record, and these
        /// files only save the next launch work.
        guard isInitialized else {
            Self.log("Immediate save skipped — startup had not finished loading the library")
            return
        }

        flushDeferredMetadata()
        await flushCaches()
    }
    
    // MARK: - Film Access

    /// Pre-warms the All Films view cache during startup, after Phase 2.
    ///
    /// DataCoordinator publishes the returned films in the same update that sets its `isInitialized`,
    /// so the gallery shows content on its first frame.
    ///
    /// The sort and filter options must match what ViewStateManager later requests, or the cache
    /// misses and the sort runs again on MainActor.
    ///
    /// Returns the sorted, filtered snapshots.
    func prewarmInitialView(sortOption: SortOption, direction: SortDirection, filterOptions: Set<FilterOption>) async -> [FilmSnapshot] {
        let allIDs = Array(films.keys)
        guard !allIDs.isEmpty else { return [] }

        let sortedIDs = await MetadataCache.shared.sortAsync(allIDs, by: sortOption, direction: direction)
        var sortedFilms = snapshots(for: sortedIDs)

        /// Apply saved filters, so the cache matches what loadFilms will request.
        if !filterOptions.isEmpty {
            sortedFilms = applyFilters(sortedFilms, filterOptions: filterOptions)
        }

        /// Populate the view cache so the next loadFilms() call is a hit.
        let key = CacheKey(viewID: .allFilms, sortOption: sortOption, direction: direction, filterOptions: filterOptions)
        cachedViews[key] = sortedFilms

        Self.log("Pre-warmed initial view: \(sortedFilms.count) films cached (sort: \(sortOption), dir: \(direction), filters: \(filterOptions.count))")
        return sortedFilms
    }

    /// Returns all poster UIDs for cache completion.
    /// Filters out empty UIDs to avoid unnecessary cache operations.
    func getAllPosterUIDs() -> [String] {
        return films.values.compactMap { $0.posterUID.isEmpty ? nil : $0.posterUID }
    }
    
    func getFilms(viewID: ViewIdentifier, sortOption: SortOption, direction: SortDirection,
                  filterOptions: Set<FilterOption>) -> [FilmSnapshot] {
        /// Before Phase 2, `films` is empty, so any view built here would be empty. Caching that
        /// result would persist it until a data mutation, which initialization is not. Return without
        /// caching, so the first request after initialization builds the view for real. Callers
        /// treat an empty result here as "not ready" (see DataCoordinator.performLoad).
        guard isInitialized else {
            Self.log("getFilms(\(viewID.description)) requested before Phase 2 completion — returning empty without caching")
            return []
        }

        /// Every whole-library view (a saved search, a smart list, Unwatched, Recents, Search) builds exactly All
        /// Films' array for the same sort, direction and filters: the whole library, sorted the same way. Its
        /// membership is applied afterward, by DataCoordinator. So each shares All Films' entry instead of
        /// sorting the library again on its first visit and holding a copy of its own. A smart list scoped to
        /// one release format sorts Date Last Purchased by that format's purchases only, so it keeps its own.
        let cacheViewID: ViewIdentifier
        switch viewID {
        case .savedSearch, .tag, .smartList, .unwatched, .recents, .insights, .search:
            cacheViewID = viewID.purchaseFormatScope == nil ? .allFilms : viewID
        case .allFilms, .list, .filmQueue, .imports, .recommendations:
            cacheViewID = viewID
        }
        let cacheKey = CacheKey(viewID: cacheViewID, sortOption: sortOption, direction: direction,
                               filterOptions: filterOptions)
        
        if let cached = cachedViews[cacheKey] {
            return cached
        }
        
        let start = Date()
        
        /// Get base film IDs for the view. Every membership-filtered view (smart lists,
        /// Unwatched, Recents) and Search start from the whole library: DataCoordinator
        /// applies their membership and search filters to the result.
        let baseFilmIDs: [UUID]
        switch viewID {
        case .list(let listID):
            guard let list = lists[listID] else { return [] }
            baseFilmIDs = Array(list.filmIDs)
        case .filmQueue, .imports, .recommendations:
            /// The Film Queue orders films by section (Up Next → Soon → Later) via the
            /// grouped path below, not by a flat union sort; Imports and Recommendations show no
            /// gallery films.
            baseFilmIDs = []
        case .allFilms, .smartList, .unwatched, .recents, .insights, .search, .savedSearch, .tag:
            baseFilmIDs = Array(films.keys)
        }
        
        /// Sort the IDs. The Film Queue is grouped by section first (Up Next → Soon → Later),
        /// with each section internally ordered by the requested sort — this section grouping is
        /// exactly what lets the gallery draw one labeled divider band per populated section.
        /// Every other view uses the standard flat MetadataCache sort.
        let sortedIDs: [UUID]
        if case .filmQueue = viewID {
            sortedIDs = filmQueueSectionGroupedIDs(sortOption: sortOption, direction: direction)
        } else {
            sortedIDs = MetadataCache.shared.sort(baseFilmIDs, by: sortOption, direction: direction,
                                                  purchaseFormat: viewID.purchaseFormatScope)
        }
        
        /// Convert IDs to FilmSnapshot objects
        var sortedFilms = snapshots(for: sortedIDs)
        
        /// Apply filters (search filtering is handled by DataCoordinator)
        if !filterOptions.isEmpty {
            sortedFilms = applyFilters(sortedFilms, filterOptions: filterOptions)
        }
        
        cachedViews[cacheKey] = sortedFilms
        
        let duration = Date().timeIntervalSince(start)
        if duration > 0.01 {
            Self.log("Built view \(viewID) with \(sortedFilms.count) films in \(Fmt.fixed(duration * 1000, 1))ms")
        }
        
        return sortedFilms
    }
    
    func getFilm(_ id: UUID) -> FilmSnapshot? {
        return films[id]
    }

    /// The snapshots for `ids`, in order, in a buffer sized up front. The view cache keeps these
    /// arrays, and a `compactMap` grows by doubling: at 1,400 films it leaves about 150 unused
    /// snapshot slots (roughly 100 KB) in every cached view.
    private func snapshots(for ids: [UUID]) -> [FilmSnapshot] {
        var result: [FilmSnapshot] = []
        result.reserveCapacity(ids.count)
        for id in ids {
            if let film = films[id] { result.append(film) }
        }
        return result
    }
    
    func getAllFilms() -> [FilmSnapshot] {
        return Array(films.values)
    }
    
    /// Returns the raw films dictionary for O(1) keyed lookup.
    /// Used by DataCoordinator.loadFilms when mapping a pre-sorted [UUID] list directly to
    /// FilmSnapshot objects, avoiding a full sort pass for recents views where MetadataCache
    /// already provides the authoritative ordered ID array.
    func getAllFilmsMap() -> [UUID: FilmSnapshot] {
        return films
    }
    
    // MARK: - List Access
    
    /// Returns all user-generated lists, sorted by display order. The three internal Film Queue
    /// lists ("Up Next", "Soon", "Later") are excluded here, the single point every user-facing
    /// list enumeration passes through. They stay in `lists` and are reached by UUID via getList(_:).
    func getAllLists() -> [MemoryList] {
        if let cached = sortedListsCache {
            return cached
        }
        /// Ordered by MemoryList.orderedBefore, the shared rule.
        let sorted = lists.values
            .filter { !FilmQueue.isInternalList($0.listID) }
            .sorted(by: MemoryList.orderedBefore)
        sortedListsCache = sorted
        return sorted
    }
    
    func getList(_ id: UUID) -> MemoryList? {
        return lists[id]
    }

    /// Returns the union of every film ID that belongs to any of the three internal
    /// Film Queue lists. Builds the Film Queue view and its film count.
    func filmQueueFilmIDs() -> Set<UUID> {
        var union: Set<UUID> = []
        for section in FilmQueueSection.allCases {
            if let list = lists[section.listID] {
                union.formUnion(list.filmIDs)
            }
        }
        return union
    }

    /// Returns the Film Queue's film IDs grouped by section in queue order (Up Next → Soon →
    /// Later), each sorted by the given sort option and direction. A film in several internal lists
    /// is placed once, in the lowest-`queueOrder` section, so it appears exactly once.
    func filmQueueSectionGroupedIDs(sortOption: SortOption, direction: SortDirection) -> [UUID] {
        let orderedSections = FilmQueueSection.allCases.sorted { $0.queueOrder < $1.queueOrder }
        var claimed: Set<UUID> = []
        var result: [UUID] = []
        for section in orderedSections {
            guard let list = lists[section.listID] else { continue }
            /// Claim each film for the first (lowest-queueOrder) section it belongs to.
            var sectionIDs: [UUID] = []
            for id in list.filmIDs where !claimed.contains(id) {
                sectionIDs.append(id)
                claimed.insert(id)
            }
            guard !sectionIDs.isEmpty else { continue }
            result.append(contentsOf: MetadataCache.shared.sort(sectionIDs, by: sortOption, direction: direction))
        }
        return result
    }
    
    func getListIDs(forFilm filmID: UUID) -> Set<UUID> {
        return filmToLists[filmID] ?? []
    }
    
    func filmExists(filmID: UUID, inList listID: UUID) -> Bool {
        return lists[listID]?.filmIDs.contains(filmID) ?? false
    }
    
    // MARK: - Film Mutations
    
    /// Registers a FilmSnapshot in MemoryStore and updates MetadataCache.
    /// This is the canonical entry point for adding a film to the in-memory store.
    /// The corresponding managed object is managed separately by DataCoordinator (view context)
    /// and DataManager (background context).
    func addFilm(_ snapshot: FilmSnapshot) {
        TagUseStore.recordUses(from: nil, to: snapshot.tags)
        films[snapshot.id] = snapshot
        MetadataCache.shared.addFilm(snapshot)
        invalidateCacheForAllFilms()
        /// A snapshot carrying a ranked position must be reflected in the ordered Hall of
        /// Fame list, which is derived state that only rebuildHallOfFame() maintains. Newly
        /// created and newly imported films always have hofPosition == 0, so this is skipped
        /// on those paths; the case that needs it is DataCoordinator.deleteFilms' rollback,
        /// which re-adds previously ranked films. Without the rebuild those films would be
        /// restored to the store but silently absent from the Hall of Fame for the rest of
        /// the session.
        if snapshot.hofPosition > 0 {
            rebuildHallOfFame()
        }
        /// A film put back (a rollback) makes its links live again.
        if filmToLinks[snapshot.id] != nil { filmLinksDidChange?() }
        scheduleThrottledSave()
        Self.log("Added film: \(snapshot.name)")
    }
    
    /// Batch counterpart of addFilm(_:) for imports: one MetadataCache store, one view-cache
    /// invalidation and one throttled save for the whole batch, rather than one per film.
    /// `recordingTagUses` false for a rollback putting films back, which uses no tag.
    func addFilms(_ snapshots: [FilmSnapshot], recordingTagUses: Bool = true) {
        guard !snapshots.isEmpty else { return }
        if recordingTagUses { TagUseStore.recordUses(snapshots.map { (old: nil, new: $0.tags) }) }
        var ranked = false
        for snapshot in snapshots {
            films[snapshot.id] = snapshot
            if snapshot.hofPosition > 0 { ranked = true }
        }
        MetadataCache.shared.updateFilms(snapshots)
        invalidateCacheForAllFilms()
        if ranked { rebuildHallOfFame() }
        /// Films put back (a rollback) make their links live again.
        if snapshots.contains(where: { filmToLinks[$0.id] != nil }) { filmLinksDidChange?() }
        scheduleThrottledSave()
        Self.log("Added \(snapshots.count) film(s)")
    }

    /// Recomputes the MetadataCache entries whose rotation date follows the global
    /// default threshold (every film without an override) and persists the result.
    /// No snapshot changes, so no view cache is invalidated: nothing in a sorted view
    /// depends on rotation dates.
    ///
    /// The entries are built on a utility-priority task, keeping the main actor free. A film
    /// edited during the build keeps the entry its edit produced, and a canceled caller applies nothing.
    func refreshRotationDerivedMetadata() async {
        let threshold = Preferences.defaultRotationThreshold
        let affected = films.values.filter { $0.rotationThresholdOverride == nil }
        guard !affected.isEmpty else {
            /// No entry follows the default, so every one already agrees with it.
            MetadataCache.shared.markRotationThreshold(threshold)
            scheduleThrottledSave()
            return
        }
        let built = await Task.detached(priority: .utility) {
            affected.map { ($0, FilmMetadata(from: $0)) }
        }.value
        guard !Task.isCancelled else { return }
        MetadataCache.shared.setEntries(built.compactMap { films[$0.0.id] == $0.0 ? $0.1 : nil })
        /// A film edited during the build kept the entry its edit built, under the same default.
        MetadataCache.shared.markRotationThreshold(threshold)
        scheduleThrottledSave()
    }

    /// Replaces an existing FilmSnapshot in MemoryStore and updates MetadataCache.
    /// Called after any mutation that changes film properties — scalars, releases, or derived
    /// values — to keep the in-memory state authoritative for the UI.
    /// `recordingTagUses` false for a rollback putting a film's tags back (TagUseStore).
    func updateFilm(_ snapshot: FilmSnapshot, recordingTagUses: Bool = true) {
        guard let existing = films[snapshot.id] else {
            Self.log("WARNING: Tried to update non-existent film: \(snapshot.id)")
            return
        }
        if recordingTagUses, snapshot.tags != existing.tags {
            TagUseStore.recordUses(from: existing.tags, to: snapshot.tags)
        }

        films[snapshot.id] = snapshot
        MetadataCache.shared.updateFilm(snapshot)
        
        invalidateCacheForAllFilms()
        
        if let listIDs = filmToLists[snapshot.id] {
            for listID in listIDs {
                invalidateCacheForList(listID)
            }
        }

        /// hallOfFameFilms is derived state maintained only by rebuildHallOfFame(). Rank changes go
        /// through the dedicated Hall of Fame methods, so this check is normally false. It keeps the
        /// invariant at the entry point rather than relying on every caller.
        if snapshot.hofPosition != existing.hofPosition {
            rebuildHallOfFame()
        }
        
        scheduleThrottledSave()
        Self.log("Updated film: \(snapshot.name)")
    }
    
    /// Batch counterpart of updateFilm(_:), for many films changed at once (the MultiFilmSheet's
    /// save). Derived state is repaired once for the batch: one MetadataCache update, one round of
    /// view-cache invalidation, one Hall of Fame rebuild if a rank moved, and one scheduled save.
    /// `recordingTagUses` false for a rollback putting films' tags back (TagUseStore).
    func updateFilms(_ snapshots: [FilmSnapshot], recordingTagUses: Bool = true) {
        var stored: [FilmSnapshot] = []
        stored.reserveCapacity(snapshots.count)
        var listsToInvalidate: Set<UUID> = []
        var ranksMoved = false
        var tagChanges: [(old: [String]?, new: [String])] = []
        for snapshot in snapshots {
            guard let existing = films[snapshot.id] else {
                Self.log("WARNING: Tried to update non-existent film: \(snapshot.id)")
                continue
            }
            if recordingTagUses, snapshot.tags != existing.tags { tagChanges.append((existing.tags, snapshot.tags)) }
            films[snapshot.id] = snapshot
            stored.append(snapshot)
            if let listIDs = filmToLists[snapshot.id] { listsToInvalidate.formUnion(listIDs) }
            if snapshot.hofPosition != existing.hofPosition { ranksMoved = true }
        }
        guard !stored.isEmpty else { return }
        TagUseStore.recordUses(tagChanges)
        MetadataCache.shared.updateFilms(stored)
        invalidateCacheForAllFilms()
        for listID in listsToInvalidate { invalidateCacheForList(listID) }
        if ranksMoved { rebuildHallOfFame() }
        scheduleThrottledSave()
        Self.log("Updated \(stored.count) film(s)")
    }

    // MARK: - Deferred Metadata

    /// Why this exists (2026-11-16): a wishlist drag renumbers every film on the wishlist, and
    /// rebuilding their MetadataCache entries was most of the drop's remaining main-thread cost.
    /// No FilmMetadata field reads `wishlist`, so the rebuild changed nothing. Skipping it outright
    /// would be correct today but would silently go stale if a field ever did read it, so the
    /// rebuild runs here instead: deferred, off the main actor, and applied only where an entry
    /// actually differs. Today it applies nothing and leaves the metadata file unwritten.
    ///
    /// Films whose entries still need a deferred rebuild, and the task that will do it.
    private var deferredMetadataIDs: Set<UUID> = []
    private var deferredMetadataTask: Task<Void, Never>?

    /// updateFilms(_:) for edits that cannot change a film's FilmMetadata (wishlist renumbering):
    /// the snapshots, view caches and save are handled now; the metadata entries one quiet second
    /// later, in the background (refreshDeferredMetadata). A rank change must not come through
    /// here, since this skips the Hall of Fame rebuild.
    func updateFilmsDeferringMetadata(_ snapshots: [FilmSnapshot]) {
        var listsToInvalidate: Set<UUID> = []
        var count = 0
        for snapshot in snapshots {
            guard let existing = films[snapshot.id] else {
                Self.log("WARNING: Tried to update non-existent film: \(snapshot.id)")
                continue
            }
            assert(snapshot.hofPosition == existing.hofPosition, "Rank changes need updateFilms(_:)")
            films[snapshot.id] = snapshot
            deferredMetadataIDs.insert(snapshot.id)
            if let listIDs = filmToLists[snapshot.id] { listsToInvalidate.formUnion(listIDs) }
            count += 1
        }
        guard count > 0 else { return }
        invalidateCacheForAllFilms()
        for listID in listsToInvalidate { invalidateCacheForList(listID) }
        scheduleThrottledSave()

        /// Restarted on every call, so a run of drags rebuilds once, after the last.
        deferredMetadataTask?.cancel()
        deferredMetadataTask = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await self?.refreshDeferredMetadata()
        }
        Self.log("Updated \(count) film(s), metadata deferred")
    }

    /// Builds the deferred entries on a utility task and stores only those that differ from the
    /// cached ones. An ID leaves the pending set only once its result is known to describe the
    /// film's current snapshot; a film edited during the build stays pending (a later deferred
    /// write reschedules it, and the shutdown flush catches the rest).
    private func refreshDeferredMetadata() async {
        let work: [(snapshot: FilmSnapshot, cached: FilmMetadata?)] = deferredMetadataIDs.compactMap { id in
            films[id].map { ($0, MetadataCache.shared.metadata[id]) }
        }
        guard !work.isEmpty else { deferredMetadataIDs = []; return }
        let results = await Task.detached(priority: .utility) {
            work.map { item -> (snapshot: FilmSnapshot, entry: FilmMetadata?) in
                let entry = FilmMetadata(from: item.snapshot)
                return (item.snapshot, entry == item.cached ? nil : entry)
            }
        }.value
        var changed: [FilmMetadata] = []
        for result in results where films[result.snapshot.id] == result.snapshot {
            deferredMetadataIDs.remove(result.snapshot.id)
            if let entry = result.entry { changed.append(entry) }
        }
        guard !changed.isEmpty else { return }
        MetadataCache.shared.setEntries(changed)
        scheduleThrottledSave()
        Self.log("Deferred metadata refresh stored \(changed.count) changed entr\(changed.count == 1 ? "y" : "ies")")
    }

    /// Runs any pending deferred rebuild synchronously, for the shutdown save.
    private func flushDeferredMetadata() {
        deferredMetadataTask?.cancel()
        deferredMetadataTask = nil
        guard !deferredMetadataIDs.isEmpty else { return }
        let changed = deferredMetadataIDs.compactMap { films[$0].map(FilmMetadata.init(from:)) }
            .filter { $0 != MetadataCache.shared.metadata[$0.id] }
        deferredMetadataIDs = []
        if !changed.isEmpty { MetadataCache.shared.setEntries(changed) }
    }

    /// Deletes films from the store, pruning their list memberships and — when any of them
    /// held a Hall of Fame position — rebuilding and compacting the Hall of Fame.
    ///
    /// - Returns: The IDs of the SURVIVING Hall of Fame members whose `hofPosition` changed
    ///   as a result of compaction, so the caller can persist those position updates. Empty
    ///   whenever no deleted film was a ranked member.
    @discardableResult
    func deleteFilms(ids: Set<UUID>) -> [UUID] {
        var affectedLists = Set<UUID>()

        /// Determined BEFORE the eviction loop below, while the snapshots are still present.
        let deletedRankedMember = ids.contains { (films[$0]?.hofPosition ?? 0) > 0 }

        /// Single pass: collect affected lists, evict from the snapshot store, and update the reverse index.
        for id in ids {
            if let listIDs = filmToLists[id] {
                affectedLists.formUnion(listIDs)
                for listID in listIDs {
                    lists[listID]?.filmIDs.remove(id)
                }
                filmToLists.removeValue(forKey: id)
            }
            films.removeValue(forKey: id)
        }

        MetadataCache.shared.removeFilms(ids)

        /// Deleting a ranked film would leave a phantom ID in hallOfFameFilms and a gapped position
        /// sequence. That breaks hallOfFameIsFull (at 200 members, the Hall of Fame toggle would stay
        /// disabled) and getNextHallOfFamePosition(), which can collide with an existing position.
        /// Compaction prevents both.
        let compactedHofIDs: [UUID] = deletedRankedMember ? compactHallOfFamePositions() : []

        invalidateCacheForAllFilms()
        for listID in affectedLists {
            invalidateCacheForList(listID)
        }
        /// MemoryList is a value type, so the sorted-lists cache holds stale copies. Drop it so
        /// getAllLists() rebuilds from `lists`.
        if !affectedLists.isEmpty {
            sortedListsCache = nil
        }
        /// The deleted films' links stay in `filmLinks`, unseen (see there), so a rollback that
        /// puts the films back finds them as the store still holds them.
        if ids.contains(where: { filmToLinks[$0] != nil }) {
            mayHoldDanglingFilmLinks = true
            filmLinksDidChange?()
        }
        
        scheduleThrottledSave()
        Self.log("Deleted \(ids.count) film(s) from \(affectedLists.count) affected list(s)")
        return compactedHofIDs
    }
    
    // MARK: - List Mutations
    
    func addFilmsToList(filmIDs: Set<UUID>, listID: UUID) {
        guard var list = lists[listID] else { return }

        /// Filter out IDs with no matching film. A deferred add (for example, the Film Queue "Add on
        /// Drop" confirmation) can outlive a deleted film. Counts use raw filmIDs, so a phantom ID
        /// would inflate them until the next reload. Legitimate adds are unaffected.
        let validFilmIDs = filmIDs.filter { films[$0] != nil }
        guard !validFilmIDs.isEmpty else {
            if validFilmIDs.count != filmIDs.count {
                Self.log("WARNING: Skipped adding \(filmIDs.count) film(s) to list '\(list.listName)' — none correspond to an existing film")
            }
            return
        }
        if validFilmIDs.count != filmIDs.count {
            Self.log("WARNING: Skipped \(filmIDs.count - validFilmIDs.count) stale film ID(s) when adding to list '\(list.listName)' — film(s) no longer exist")
        }

        for filmID in validFilmIDs {
            list.filmIDs.insert(filmID)
            filmToLists[filmID, default: []].insert(listID)
        }
        
        lists[listID] = list
        /// MemoryList is a value type, so the sorted-lists cache is now stale. Invalidate it so every
        /// getAllLists() consumer (sidebar counts, alerts, menus) sees fresh data.
        sortedListsCache = nil
        invalidateCacheForList(listID)
        scheduleThrottledSave()
        Self.log("Added \(validFilmIDs.count) film(s) to list: \(list.listName)")
    }
    
    func removeFilmsFromList(filmIDs: Set<UUID>, listID: UUID) {
        guard var list = lists[listID] else { return }
        
        for filmID in filmIDs {
            list.filmIDs.remove(filmID)
            filmToLists[filmID]?.remove(listID)
            if filmToLists[filmID]?.isEmpty == true {
                filmToLists.removeValue(forKey: filmID)
            }
        }
        
        lists[listID] = list
        /// Drop the stale value-type cache, as in addFilmsToList.
        sortedListsCache = nil
        invalidateCacheForList(listID)
        scheduleThrottledSave()
        Self.log("Removed \(filmIDs.count) film(s) from list: \(list.listName)")
    }
    
    func createList(name: String, displayOrder: Int) -> UUID {
        let listID = UUID()
        let newList = MemoryList(
            listID: listID,
            listName: name,
            displayOrder: displayOrder,
            sortFilterOptions: [],
            filmIDs: []
        )
        
        lists[listID] = newList
        sortedListsCache = nil
        scheduleThrottledSave()
        Self.log("Created list: \(name)")
        
        return listID
    }

    /// Creates an internal list with a fixed UUID, used only to bootstrap the three Film Queue
    /// lists at startup. It is idempotent. The list is stored like a user list, so membership,
    /// the snapshot cache, and export/restore treat it the same, but getAllLists() excludes it.
    func createInternalList(listID: UUID, name: String, displayOrder: Int) {
        guard lists[listID] == nil else { return }
        let newList = MemoryList(
            listID: listID,
            listName: name,
            displayOrder: displayOrder,
            sortFilterOptions: [],
            filmIDs: []
        )
        lists[listID] = newList
        sortedListsCache = nil
        scheduleThrottledSave()
        Self.log("Created internal list: \(name)")
    }
    
    func updateList(listID: UUID, name: String?, displayOrder: Int?,
                   sortFilterOptions: [String]?) {
        guard var list = lists[listID] else { return }
        
        if let name = name { list.listName = name }
        if let displayOrder = displayOrder { list.displayOrder = displayOrder }
        if let sortFilterOptions = sortFilterOptions { list.sortFilterOptions = sortFilterOptions }
        
        lists[listID] = list
        sortedListsCache = nil
        scheduleThrottledSave()
        Self.log("Updated list: \(list.listName)")
    }
    
    func deleteList(listID: UUID) {
        guard let list = lists[listID] else { return }
        
        for filmID in list.filmIDs {
            filmToLists[filmID]?.remove(listID)
            if filmToLists[filmID]?.isEmpty == true {
                filmToLists.removeValue(forKey: filmID)
            }
        }
        
        lists.removeValue(forKey: listID)
        sortedListsCache = nil
        invalidateCacheForList(listID)
        scheduleThrottledSave()
        Self.log("Deleted list: \(list.listName)")
    }
    
    /// Restores a previously deleted list from a captured snapshot.
    /// Used by persistence rollback to undo a failed deleteList operation.
    ///
    /// The captured membership is filtered against the films the store currently holds,
    /// for the same reason addFilmsToList filters its input — and here the stale ID is not
    /// hypothetical. The snapshot is taken at the moment deleteList runs and replayed only
    /// if the background persist later fails, so any film deleted inside that window is
    /// still named by it. Restoring such an ID would insert a membership for a film that no
    /// longer exists: getFilms(viewID:) drops it silently via compactMap, but the list's
    /// count is taken from its raw filmIDs, so the list would report more films than it
    /// can draw — and the reverse index would hold an entry keyed by a deleted film, which
    /// nothing subsequently removes because every removal path is driven from the film side.
    /// Both persist for the rest of the session.
    func restoreList(_ list: MemoryList) {
        var restored = list
        restored.filmIDs = list.filmIDs.filter { films[$0] != nil }
        if restored.filmIDs.count != list.filmIDs.count {
            Self.log("WARNING: Dropped \(list.filmIDs.count - restored.filmIDs.count) membership(s) while restoring list '\(list.listName)' — film(s) deleted after the list was removed")
        }

        lists[list.listID] = restored
        for filmID in restored.filmIDs {
            filmToLists[filmID, default: []].insert(list.listID)
        }
        sortedListsCache = nil
        invalidateCacheForList(list.listID)
        scheduleThrottledSave()
        Self.log("Restored list: \(list.listName)")
    }
    
    // MARK: - Film Links

    /// Whether both of the link's films are in the library (see `filmLinks`).
    private func isLive(_ link: FilmLinkSnapshot) -> Bool {
        films[link.sourceID] != nil && films[link.targetID] != nil
    }

    /// Every live link, oldest first (FilmLinkRules.ordersBefore), so the order never changes
    /// between calls.
    func allFilmLinks() -> [FilmLinkSnapshot] {
        filmLinks.values.filter(isLive).sorted {
            FilmLinkRules.ordersBefore(($0.dateAdded, $0.id), ($1.dateAdded, $1.id))
        }
    }

    /// Every link held, live or not (see `filmLinks`), in no particular order: for bringing
    /// memory into line with the store, which still holds a deleted film's links until its
    /// delete persists.
    func heldFilmLinks() -> [FilmLinkSnapshot] { Array(filmLinks.values) }

    /// How many live links the library holds.
    var filmLinkCount: Int { filmLinks.values.reduce(0) { isLive($1) ? $0 + 1 : $0 } }

    /// The live links `filmID` is part of, read from its side, in FilmLinkRelation order.
    /// Empty for a film not in the library.
    func filmLinkRelations(forFilm filmID: UUID) -> [FilmLinkRelation] {
        guard films[filmID] != nil, let ids = filmToLinks[filmID] else { return [] }
        return ids.compactMap { filmLinks[$0] }
            .filter(isLive)
            .map { FilmLinkRelation(link: $0, filmID: filmID) }
            .sorted(by: FilmLinkRelation.orderedBefore)
    }

    /// The live link with this ID, or nil.
    func filmLink(id: UUID) -> FilmLinkSnapshot? {
        filmLinks[id].flatMap { isLive($0) ? $0 : nil }
    }

    /// The live link between two films, whichever way it points, or nil.
    func filmLink(between a: UUID, and b: UUID) -> FilmLinkSnapshot? {
        guard a != b else { return nil }
        let pair = FilmLinkRules.Pair(a, b)
        return linksOnPair(pair).first(where: isLive)
    }

    /// Every film reachable from `filmID` through live links of any kind, in either direction,
    /// `filmID` itself excluded: the films a "related films" view groups together. Walks with
    /// a visited set, so a cycle (only ever transient; see `filmLinks`) cannot loop it.
    func linkedFilmIDs(connectedTo filmID: UUID) -> Set<UUID> {
        guard films[filmID] != nil else { return [] }
        var seen: Set<UUID> = [filmID]
        var stack = [filmID]
        while let film = stack.popLast() {
            for linkID in filmToLinks[film] ?? [] {
                guard let link = filmLinks[linkID], isLive(link) else { continue }
                let other = link.sourceID == film ? link.targetID : link.sourceID
                if seen.insert(other).inserted { stack.append(other) }
            }
        }
        seen.remove(filmID)
        return seen
    }

    /// Why "source is a `kind` of target" cannot be recorded, or nil when it can: FilmLinkRules
    /// 1–3 and both films present, judged against the live links with any link already on the
    /// pair left out (setting a linked pair replaces its link). The same test DataManager runs
    /// against the store, so a UI can refuse a choice before anything is written. Cheap enough
    /// to ask for every film in a picker: the graph is built once per change (see
    /// `liveFilmLinkGraph`), and each check walks only the chain the target starts.
    func filmLinkProblem(source sourceID: UUID, target targetID: UUID, kind rawKind: String) -> FilmLinkError? {
        let kind = FilmLinkKind.normalized(rawKind)
        if kind.isEmpty { return .emptyKind }
        if sourceID == targetID { return .selfLink }
        if films[sourceID] == nil { return .filmNotFound(sourceID) }
        if films[targetID] == nil { return .filmNotFound(targetID) }
        let graph: FilmLinkRules.Graph
        if let cached = liveFilmLinkGraph, cached.version == contentVersion {
            graph = cached.graph
        } else {
            graph = FilmLinkRules.Graph(filmLinks.values.filter(isLive).map(\.edge))
            liveFilmLinkGraph = (contentVersion, graph)
        }
        /// The graph holds the pair's own link too; closesCycle leaves it out.
        return graph.closesCycle(source: sourceID, target: targetID, kind: kind) ? .cycle : nil
    }

    /// Every link on `pair` (normally at most one), live or not.
    func linksOnPair(_ pair: FilmLinkRules.Pair) -> [FilmLinkSnapshot] {
        (filmToLinks[pair.low] ?? []).compactMap { id in
            filmLinks[id].flatMap { $0.pair == pair ? $0 : nil }
        }
    }

    /// Makes `pair` hold exactly `links` (normally one link, or none to clear it): every link on
    /// the pair is removed, and so is any link with one of the new links' IDs wherever it sits,
    /// then `links` are stored. The one write path for links in memory, mirroring
    /// DataManager.saveFilmLink and removeFilmLinks(between:). Returns what it removed. The
    /// caller checks the rules first (`filmLinkProblem`); this does not, so a rollback can put
    /// back exactly what was there.
    @discardableResult
    func setFilmLinks(onPair pair: FilmLinkRules.Pair, to links: [FilmLinkSnapshot]) -> [FilmLinkSnapshot] {
        assert(links.allSatisfy { $0.pair == pair }, "every link must be on the pair")
        let newIDs = Set(links.map(\.id))
        let doomed = Set(linksOnPair(pair).map(\.id)).union(newIDs.filter { filmLinks[$0] != nil })
        let removed = doomed.compactMap { filmLinks[$0] }
        if removed.isEmpty, links.isEmpty { return [] }
        for id in doomed { removeFromLinkIndex(id) }
        for id in doomed { filmLinks.removeValue(forKey: id) }
        for link in links {
            filmLinks[link.id] = link
            filmToLinks[link.sourceID, default: []].insert(link.id)
            filmToLinks[link.targetID, default: []].insert(link.id)
            if !isLive(link) { mayHoldDanglingFilmLinks = true }
        }
        filmLinksDidChange?()
        scheduleThrottledSave()
        Self.log("Film links on a pair: removed \(removed.count), stored \(links.count)")
        return removed
    }

    /// Removes the links with these IDs (the launch cleanup's removals). Returns what it removed.
    @discardableResult
    func removeFilmLinks(ids: Set<UUID>) -> [FilmLinkSnapshot] {
        let removed = ids.compactMap { filmLinks[$0] }
        guard !removed.isEmpty else { return [] }
        for link in removed {
            removeFromLinkIndex(link.id)
            filmLinks.removeValue(forKey: link.id)
        }
        filmLinksDidChange?()
        scheduleThrottledSave()
        Self.log("Removed \(removed.count) film link(s)")
        return removed
    }

    /// Drops the links that are no longer live (a film at either end deleted). For
    /// DataCoordinator to call once no operation is pending (see `filmLinks`). Returns how many.
    /// No reader saw them, so nothing is announced, and nothing is saved: the payload never
    /// included them.
    @discardableResult
    func pruneDanglingFilmLinks() -> Int {
        guard mayHoldDanglingFilmLinks else { return 0 }
        mayHoldDanglingFilmLinks = false
        let dangling = filmLinks.values.filter { !isLive($0) }
        guard !dangling.isEmpty else { return 0 }
        for link in dangling {
            removeFromLinkIndex(link.id)
            filmLinks.removeValue(forKey: link.id)
        }
        Self.log("Pruned \(dangling.count) film link(s) of deleted films")
        return dangling.count
    }

    /// Removes one link from `filmToLinks` (both ends), leaving `filmLinks` to the caller.
    private func removeFromLinkIndex(_ id: UUID) {
        guard let link = filmLinks[id] else { return }
        for end in [link.sourceID, link.targetID] {
            filmToLinks[end]?.remove(id)
            if filmToLinks[end]?.isEmpty == true { filmToLinks.removeValue(forKey: end) }
        }
    }

    /// Rebuilds `filmToLinks` from `filmLinks`, after a load.
    private func rebuildFilmLinkIndex() {
        var index: [UUID: Set<UUID>] = [:]
        for link in filmLinks.values {
            index[link.sourceID, default: []].insert(link.id)
            index[link.targetID, default: []].insert(link.id)
        }
        filmToLinks = index
    }

    // MARK: - Cache Invalidation
    
    private func invalidateCacheForAllFilms() {
        /// Collect the keys to remove, then remove each one in place, to avoid copying the dictionary.
        let keysToRemove = cachedViews.keys.filter { key in
            switch key.viewID {
            case .allFilms, .smartList, .unwatched, .recents, .insights, .imports, .recommendations, .search, .filmQueue,
                 .savedSearch, .tag:
                /// (.savedSearch and .tag never key a cache entry; getFilms maps them to .allFilms.)
                /// .filmQueue and .unwatched are whole-library views: a film's sort keys, watched
                /// flag, or rating can change without any list mutation.
                return true
            case .list:
                return false
            }
        }
        for key in keysToRemove {
            cachedViews.removeValue(forKey: key)
        }
    }
    
    private func invalidateCacheForList(_ listID: UUID) {
        /// Same collect-then-remove pattern as invalidateCacheForAllFilms(). The Film Queue view is the
        /// union of the three internal lists, so an internal list change also invalidates it.
        let alsoInvalidateFilmQueue = FilmQueue.isInternalList(listID)
        let keysToRemove = cachedViews.keys.filter { key in
            if case .list(let id) = key.viewID, id == listID { return true }
            if alsoInvalidateFilmQueue, case .filmQueue = key.viewID { return true }
            return false
        }
        for key in keysToRemove {
            cachedViews.removeValue(forKey: key)
        }
    }
    
    // MARK: - Filtering
    
    /// Applies the standard filter options. Used by getFilms and by DataCoordinator's Recents path,
    /// so both apply the same logic. Search filtering is handled by DataCoordinator, not here.
    func applyFilters(_ films: [FilmSnapshot], filterOptions: Set<FilterOption>) -> [FilmSnapshot] {
        guard !filterOptions.isEmpty && !filterOptions.contains(.none) else {
            return films
        }
        let genreFilters = filterOptions.filter { $0.isGenre }
        let otherFilters = filterOptions.filter { !$0.isGenre }
        
        return films.filter { film in
            /// Non-genre filters: all must match
            for option in otherFilters {
                if !checkFilter(film, option: option) { return false }
            }
            /// Genre filters: any may match
            if !genreFilters.isEmpty {
                var matchesGenre = false
                for option in genreFilters {
                    if checkFilter(film, option: option) { matchesGenre = true; break }
                }
                if !matchesGenre { return false }
            }
            return true
        }
    }
    
    private func checkFilter(_ film: FilmSnapshot, option: FilterOption) -> Bool {
        switch option {
        case .none:
            return true
        case .watched:
            return film.watched
        case .unwatched:
            return !film.watched
        case .color:
            return film.color
        case .blackAndWhite:
            return !film.color
        case .purchased:
            return film.releases.contains { $0.purchased }
        case .unpurchased:
            return film.releases.isEmpty || film.releases.allSatisfy { !$0.purchased }
        case .completeData:
            return film.infoComplete
        case .incompleteData:
            return !film.infoComplete
        case .actionAndAdventure:
            return film.genre.contains("Action")
        case .comedy:
            return film.genre.contains("Comedy")
        case .drama:
            return film.genre.contains("Drama")
        case .horror:
            return film.genre.contains("Horror")
        case .kidsAndFamily:
            /// Matches either "Kids" or "Family" genre tags, which name the same category.
            return film.genre.contains("Kids") || film.genre.contains("Family")
        case .sciFiAndFantasy:
            return film.genre.contains("Sci-Fi") || film.genre.contains("Fantasy")
        case .thriller:
            return film.genre.contains("Thriller")
        }
    }
    
    // MARK: - Hall of Fame Management
    
    /// The most films the Hall of Fame holds.
    nonisolated static let hallOfFameCapacity = 200

    var hallOfFameIsFull: Bool { return hallOfFameFilms.count >= Self.hallOfFameCapacity }
    
    /// The next free 1-based slot. Private so that positions are assigned only through
    /// `addToHallOfFame(_:)`, which keeps the ranks dense.
    private func getNextHallOfFamePosition() -> Int {
        /// hallOfFameFilms is the ordered list maintained by rebuildHallOfFame(). Its count equals the
        /// number of ranked films, so the next position is count + 1. max(hofPosition) + 1 would be
        /// wrong, because stored positions can have gaps.
        return hallOfFameFilms.count + 1
    }
    
    func getHallOfFameFilms() -> [FilmSnapshot] {
        return hallOfFameFilms.compactMap { films[$0] }
    }
    
    /// Adds a film to the Hall of Fame at the next available position.
    /// Mutates the stored snapshot in place via value-copy-and-replace.
    ///
    /// - Returns: The assigned 1-based position, or `nil` when nothing was written (the film
    ///   is unknown, the Hall of Fame is full, or the film is already a ranked member).
    ///   Callers must not persist a snapshot when this returns `nil` — no rank changed.
    @discardableResult
    func addToHallOfFame(_ filmID: UUID) -> Int? {
        guard var snapshot = films[filmID] else {
            Self.log("WARNING: addToHallOfFame — unknown film \(filmID)")
            return nil
        }

        /// A film that already holds a position must be rejected. Re-ranking it would leave a gap at
        /// its old slot and make the next add collide with its new one. Rejecting it keeps 1..N dense.
        guard snapshot.hofPosition == 0 else {
            Self.log("addToHallOfFame — film \(filmID) is already ranked at position \(snapshot.hofPosition); ignoring")
            return nil
        }

        guard !hallOfFameIsFull else {
            Self.log("addToHallOfFame — hall of fame is full; ignoring \(filmID)")
            return nil
        }

        let position = getNextHallOfFamePosition()
        snapshot.hofPosition = position
        films[filmID] = snapshot
        rebuildHallOfFame()
        scheduleThrottledSave()
        Self.log("Added film \(filmID) to hall of fame at position \(position)")
        return position
    }

    /// Adds films to the Hall of Fame at the next positions, in the order given, rebuilding
    /// the ranking once. Skips each film the single-film add would refuse — unknown, already
    /// ranked — and stops when the Hall of Fame is full.
    ///
    /// - Returns: The films ranked, in rank order; empty when nothing was written.
    @discardableResult
    func addToHallOfFame(_ filmIDs: [UUID]) -> [UUID] {
        var added: [UUID] = []
        var nextPosition = getNextHallOfFamePosition()
        for filmID in filmIDs {
            guard nextPosition <= Self.hallOfFameCapacity else {
                Self.log("addToHallOfFame — hall of fame is full; \(filmIDs.count - added.count) film(s) not added")
                break
            }
            guard var snapshot = films[filmID], snapshot.hofPosition == 0,
                  !added.contains(filmID) else { continue }
            snapshot.hofPosition = nextPosition
            films[filmID] = snapshot
            added.append(filmID)
            nextPosition += 1
        }
        guard !added.isEmpty else { return [] }
        rebuildHallOfFame()
        scheduleThrottledSave()
        Self.log("Added \(added.count) film(s) to hall of fame at positions \(nextPosition - added.count)…\(nextPosition - 1)")
        return added
    }
    
    /// Removes a film from the Hall of Fame by clearing its position, then compacts
    /// the remaining entries so positions form an unbroken 1..N sequence.
    ///
    /// Compaction is required: `getNextHallOfFamePosition()` assigns `count + 1`, which collides
    /// with an existing stored position if gaps remain.
    ///
    /// - Returns: The IDs of the SURVIVING members whose `hofPosition` changed as a result of
    ///   compaction, or `nil` when the film was not a ranked member and nothing was written.
    ///   An empty array therefore means "removed, and no survivor shifted".
    @discardableResult
    func removeFromHallOfFame(_ filmID: UUID) -> [UUID]? {
        return removeFromHallOfFame(Set([filmID]))
    }

    /// Removes several films from the Hall of Fame in a single pass, compacting the surviving
    /// positions exactly once at the end.
    ///
    /// Batching compacts once, so the caller can capture one coherent pre-mutation ranking for
    /// rollback. Calling the single-film path N times would compact N times.
    ///
    /// - Returns: The IDs of the SURVIVING members whose `hofPosition` changed as a result of
    ///   compaction, or `nil` when none of the given films were ranked members (nothing was
    ///   written, so callers must not persist or roll anything back).
    @discardableResult
    func removeFromHallOfFame(_ filmIDs: Set<UUID>) -> [UUID]? {
        var removedCount = 0
        for filmID in filmIDs {
            /// Non-members are skipped rather than written: clearing an already-zero position
            /// would schedule a save and force a compaction pass for no state change.
            guard var snapshot = films[filmID], snapshot.hofPosition > 0 else { continue }
            snapshot.hofPosition = 0
            films[filmID] = snapshot
            removedCount += 1
        }

        guard removedCount > 0 else { return nil }

        /// Rebuilds the ordered list, then renumbers it 1..N so no gaps remain.
        let compacted = compactHallOfFamePositions()

        scheduleThrottledSave()
        Self.log("Removed \(removedCount) film(s) from hall of fame; \(compacted.count) survivor(s) shifted")
        return compacted
    }
    
    /// Restores several films' hall of fame positions in one pass, rebuilding the ordered
    /// list exactly once at the end.
    ///
    /// Used by the deletion rollback, which must undo both the removed films' own positions and
    /// the compaction applied to every survivor. The list is rebuilt once for the whole set.
    /// Positions of 0 are applied as-is: that is the representation of "not ranked".
    func restoreHofPositions(_ positions: [UUID: Int]) {
        guard !positions.isEmpty else { return }
        var restoredCount = 0
        for (filmID, position) in positions {
            guard var snapshot = films[filmID] else { continue }
            snapshot.hofPosition = position
            films[filmID] = snapshot
            restoredCount += 1
        }
        guard restoredCount > 0 else { return }
        rebuildHallOfFame()
        scheduleThrottledSave()
        Self.log("Restored hall of fame positions for \(restoredCount) film(s)")
    }

    /// Rebuilds the ordered Hall of Fame list from the surviving snapshots, then renumbers
    /// it into an unbroken 1..N sequence.
    ///
    /// - Returns: The IDs whose stored `hofPosition` actually changed, so callers that need
    ///   to persist the renumbering can write only those films rather than all of them.
    @discardableResult
    private func compactHallOfFamePositions() -> [UUID] {
        rebuildHallOfFame()

        var changed: [UUID] = []
        for (index, id) in hallOfFameFilms.enumerated() {
            guard var snapshot = films[id] else { continue }
            let newPosition = index + 1
            guard snapshot.hofPosition != newPosition else { continue }
            snapshot.hofPosition = newPosition
            films[id] = snapshot
            changed.append(id)
        }
        return changed
    }

    /// Restores an existing film's properties from a pre-mutation snapshot.
    /// Used by persistence rollback to undo a failed update operation.
    ///
    /// Replaces the stored snapshot atomically, then updates MetadataCache and
    /// invalidates all relevant view caches — ensuring the rollback is always complete.
    func restoreFilm(filmID: UUID, from snapshot: FilmSnapshot) {
        /// The pre-restore rank is used below to decide whether the Hall of Fame must be rebuilt.
        /// No current caller changes a rank through this path, but the check keeps the ordered list
        /// consistent if one does.
        guard let existing = films[filmID] else {
            Self.log("WARNING: restoreFilm called for non-existent film: \(filmID)")
            return
        }

        films[filmID] = snapshot
        MetadataCache.shared.updateFilm(snapshot)
        invalidateCacheForAllFilms()
        if let listIDs = filmToLists[filmID] {
            for listID in listIDs { invalidateCacheForList(listID) }
        }
        if snapshot.hofPosition != existing.hofPosition {
            rebuildHallOfFame()
        }
        scheduleThrottledSave()
        Self.log("Restored film to pre-mutation state: \(snapshot.name)")
    }
    
    /// Reorders Hall of Fame entries by updating each film snapshot's position.
    ///
    /// `filmIDs` is treated as a request, not as the new ordering. Positions are written from the
    /// requested order, then the list is rebuilt and renumbered from the stored positions. Duplicates,
    /// unknown films, and omitted members therefore cannot break the invariant.
    ///
    /// - Returns: The ordering actually applied, which callers should use in place of their
    ///   own array when emitting events or gathering snapshots to persist.
    @discardableResult
    func reorderHallOfFame(_ filmIDs: [UUID]) -> [UUID] {
        guard !filmIDs.isEmpty else { return hallOfFameFilms }

        var position = 0
        var seen = Set<UUID>()
        for filmID in filmIDs {
            /// Duplicates are collapsed. Unknown and unranked films are skipped, so a reorder never
            /// promotes a film into the Hall of Fame.
            guard seen.insert(filmID).inserted,
                  var snapshot = films[filmID],
                  snapshot.hofPosition > 0 else { continue }
            position += 1
            guard snapshot.hofPosition != position else { continue }
            snapshot.hofPosition = position
            films[filmID] = snapshot
        }

        /// A ranked film missing from filmIDs keeps its stored position instead of being dropped.
        compactHallOfFamePositions()

        scheduleThrottledSave()
        Self.log("Reordered hall of fame: \(hallOfFameFilms.count) film(s)")
        return hallOfFameFilms
    }
    
    // MARK: - Debug Harness Support

    #if DEBUG
    /// Builds a store directly from value types, with no store involvement.
    ///
    /// Like `MetadataCache(isolatedForTesting:)`, this keeps scenarios off the live store. The
    /// result depends only on the snapshots passed in. Every code path is the production one.
    /// Cache persistence is suspended so the real cache files are never written, and the load
    /// flags are set so `getFilms` answers queries.
    static func isolatedForTesting(films: [FilmSnapshot], lists: [MemoryList],
                                   links: [FilmLinkSnapshot] = []) -> MemoryStore {
        let store = MemoryStore()
        store.cachePersistenceSuspended = true
        for film in films { store.films[film.id] = film }
        for link in links { store.filmLinks[link.id] = link }
        store.rebuildFilmLinkIndex()
        store.mayHoldDanglingFilmLinks = true
        for list in lists {
            store.lists[list.listID] = list
            for filmID in list.filmIDs {
                store.filmToLists[filmID, default: []].insert(list.listID)
            }
        }
        store.rebuildHallOfFame()
        store.hasLoadedFromDatabase = true
        store.isInitialized = true
        return store
    }

    /// Every list, including the internal Film Queue lists that `getAllLists()` hides. A faithful
    /// reconstruction needs them; without them, the two sides of a comparison would differ for
    /// unrelated reasons.
    var allListsForTesting: [MemoryList] { Array(lists.values) }

    /// The reverse index, exposed so a scenario can assert it against `lists[].filmIDs`
    /// rather than inferring its health from behavior that happens to look right.
    var filmToListsForTesting: [UUID: Set<UUID>] { filmToLists }

    /// Every link held, unseen ones included (see `filmLinks`), and the reverse index, so a
    /// scenario can assert both against each other and against the store.
    var filmLinksForTesting: [UUID: FilmLinkSnapshot] { filmLinks }
    var filmToLinksForTesting: [UUID: Set<UUID>] { filmToLinks }

    /// The number of live entries in the view cache. Reported as a metric so unbounded
    /// growth is visible as a number rather than only as a slow leak.
    var cachedViewCountForTesting: Int { cachedViews.count }

    /// Empties the view cache, so the next getFilms for every key builds afresh.
    func clearViewCacheForTesting() { cachedViews.removeAll() }
    #endif

    private func rebuildHallOfFame() {
        /// Every caller has just changed one or more films' `hofPosition`. The cached view
        /// arrays hold FilmSnapshot copies, so they must go too: the Hall of Fame paths
        /// (add, remove, reorder, restore, compaction) write `films` directly rather than
        /// through updateFilm, and without this the gallery's next reload would serve
        /// snapshots carrying the old ranks. Rank changes are rare, so a full clear is cheap.
        cachedViews.removeAll()
        /// The `id` tiebreak makes the order total. Sorting on `hofPosition` alone is not
        /// deterministic when positions collide, and Swift's sort is not stable.
        /// compactHallOfFamePositions() then resolves collisions.
        ///
        /// Sorts (position, id) pairs, not snapshots: every comparison copied two whole FilmSnapshots, which made this sort most of a
        /// Hall of Fame drag's cost (about 20 ms of a 23 ms drop for 198 members, Debug build).
        let ranked: [(position: Int, id: UUID)] = films.values.compactMap { film in
            film.hofPosition > 0 ? (film.hofPosition, film.id) : nil
        }
        hallOfFameFilms = ranked
            .sorted {
                $0.position == $1.position
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.position < $1.position
            }
            .map(\.id)
        Self.log("Rebuilt hall of fame: \(hallOfFameFilms.count) films")
    }
}
