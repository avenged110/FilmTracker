// MARK: - MemoryStore.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The in-memory source of truth for all film and list data, held as value types. Core Data
// objects are read only during startup and converted to snapshots immediately.

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
    private var films: [UUID: FilmSnapshot] = [:] { didSet { contentVersion = Self.nextContentVersion() } }
    private var lists: [UUID: MemoryList] = [:] { didSet { contentVersion = Self.nextContentVersion() } }
    private var filmToLists: [UUID: Set<UUID>] = [:]
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

    /// Identifies the current contents of `films` and `lists`, so MemoryStoreCache can skip a
    /// save of contents it already wrote. Advanced by the two properties' `didSet`, so no
    /// mutation path can miss it. `filmToLists` is not persisted and is excluded. The counter is
    /// shared by all instances, so two stores never share a version once mutated.
    private var contentVersion: UInt64 = 0
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
        // Cancel any save already scheduled, so a throttled task cannot write after suspension.
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        Self.log("Derived-cache persistence suspended for this session: \(reason)")
    }

    /// Set when Phase 1 used the slow store path. validateCacheAndFinalize() reads this to decide
    /// whether to write a fresh snapshot cache.
    private var snapshotCacheNeedsRebuild = false

    /// True when Phase 1 found a legacy single-element market availability tag, in the snapshot
    /// cache or the store. DataCoordinator then runs DataManager's one-time store rewrite.
    private(set) var hasLegacyMarketAvailability = false
    
    /// Direct film count without array allocation.
    var totalFilmCount: Int { films.count }
    
    // Throttled save task, to limit disk I/O
    private var pendingSaveTask: Task<Void, Never>?
    private let saveThrottleInterval: Duration = .seconds(2)
    
    // MARK: - Initialization
    
    // STARTUP: Two phases, so the store fetch (Phase 1) overlaps with MetadataCache disk I/O.
    //
    //   Phase 1 - loadFromDatabase(): store fetch (or snapshot cache), snapshot conversion, and
    //             HoF rebuild. Has no MetadataCache dependency.
    //
    //   Phase 2 - validateCacheAndFinalize(): checks cache integrity, updates it if needed, and
    //             sets isInitialized. Requires MetadataCache to be loaded.
    
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

        // Fast path: try to restore from the on-disk MemoryStore snapshot.
        // MemoryStoreCache stores the full [UUID: FilmSnapshot] + list data serialized
        // as JSON, validated by a fingerprint derived from the store.
        // On a cache hit the entire store fetch + snapshot conversion is skipped —
        // reducing Phase 1 from O(N × relationships) to a single JSON decode.
        var cacheResult = await MemoryStoreCache.shared.load(dataManager: dataManager)

        // A cache written by a build that predates the two-component market availability
        // format still holds legacy tags. Read the store instead: ReleaseSnapshot migrates
        // them on conversion, and the rebuilt cache is written in the new format.
        if case .hit(let cachedFilms, _, _) = cacheResult,
           cachedFilms.values.contains(where: { $0.releases.contains {
               ReleaseMarketAvailability.needsMigration($0.marketAvailability) } }) {
            Self.log("Snapshot cache holds legacy market availability tags — reading the store")
            hasLegacyMarketAvailability = true
            cacheResult = .miss
        }

        switch cacheResult {
        case .hit(let films, let lists, let filmToLists):
            self.films = films
            self.lists = lists
            self.filmToLists = filmToLists
            // The loaded dictionaries match the file, so a save before any change has nothing to write.
            MemoryStoreCache.shared.recordOnDisk(contentVersion: contentVersion)
            self.sortedListsCache = nil
            self.rebuildHallOfFame()
            // No payload is pushed to MemoryStoreCache here: each flush reads the dictionaries when
            // it runs (see flushCaches). Holding an extra reference would make the first film edit
            // copy the whole dictionary.
            let duration = Date().timeIntervalSince(startTime)
            Self.log("Phase 1 fast-path: \(self.films.count) films from snapshot cache in \(Fmt.fixed(duration, 2))s")

        case .miss:
            // Slow path: full store fetch and snapshot conversion. Runs on first launch, or when the
            // store fingerprint has changed. The cache is rebuilt by validateCacheAndFinalize().
            Self.log("Phase 1 slow-path: snapshot cache miss, reading the store...")
            LaunchReveal.shared.snapshotMissed()
            self.snapshotCacheNeedsRebuild = true
            do {
                let loadedData = try await loadAllDataFromStore(persistentContainer: persistentContainer)
                self.films = loadedData.films
                self.lists = loadedData.lists
                self.filmToLists = loadedData.filmToLists
                self.sortedListsCache = nil
                self.rebuildHallOfFame()
            } catch {
                // The dictionaries stay empty. Mark the store non-authoritative: suspend derived-cache
                // writes immediately, so none can be scheduled, and DataCoordinator skips post-startup
                // work that would act on an empty library (poster pruning, orphaned-membership cleanup,
                // internal list bootstrapping, settings sync).
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
            isInitialized = true
            Self.log("Phase 2 complete (no films)")
            return
        }
        
        let startTime = Date()
        Self.log("Phase 2: Validating metadata cache...")
        
        let cacheCount = MetadataCache.shared.metadata.count

        // If Phase 1 took the slow path (store fetch), film snapshots are guaranteed
        // to be fresher than anything on disk. Force a full MetadataCache rebuild so
        // derived sort keys, rotation dates, and search strings are always consistent
        // with the newly-loaded snapshot data. This closes the narrow window where
        // MetadataCache could be stale: both caches are normally written together in the
        // same throttled save, but a crash between writes could leave MetadataCache out
        // of sync with the store state that triggered the slow-path load.
        if snapshotCacheNeedsRebuild {
            Self.log("Slow-path load — forcing full MetadataCache rebuild...")
            let rebuildStart = Date()
            await MetadataCache.shared.rebuild(from: films)
            let rebuildDuration = Date().timeIntervalSince(rebuildStart)
            Self.log("Full rebuild in \(Fmt.fixed(rebuildDuration * 1000, 1))ms")
            // Both caches are now current. Schedule a throttled save to write them together.
            snapshotCacheNeedsRebuild = false
            scheduleThrottledSave()
        } else if cacheCount == 0 {
            Self.log("No existing MetadataCache — performing full rebuild...")
            let rebuildStart = Date()
            await MetadataCache.shared.rebuild(from: films)
            let rebuildDuration = Date().timeIntervalSince(rebuildStart)
            Self.log("Full rebuild in \(Fmt.fixed(rebuildDuration * 1000, 1))ms")
            scheduleThrottledSave()
        } else if cacheCount != films.count {
            Self.log("Cache count mismatch (cache: \(cacheCount), films: \(films.count)) — incremental update...")
            await MetadataCache.shared.incrementalUpdate(from: films)
            scheduleThrottledSave()
        } else {
            // Cache hit with matching counts. Both caches are written in the same throttled save, so
            // they agree. A spot check catches a cache file with the right count but different keys.
            let filmIDs = Array(films.keys.prefix(5))
            var needsRebuild = false
            for id in filmIDs {
                if MetadataCache.shared.metadata[id] == nil {
                    needsRebuild = true
                    break
                }
            }

            if needsRebuild {
                Self.log("Cache spot check failed — incremental update...")
                await MetadataCache.shared.incrementalUpdate(from: films)
                scheduleThrottledSave()
            } else {
                Self.log("Cache validated — no rebuild needed")
            }
        }

        isInitialized = true

        let totalDuration = Date().timeIntervalSince(startTime)
        Self.log("Phase 2 complete in \(Fmt.fixed(totalDuration, 2))s - memory store ready")
    }
    
    // MARK: - Data Loading
    
    /// Loads all Films and Lists from the store, converting each model object to a snapshot as
    /// it is read. Model objects are not retained after this method returns.
    ///
    /// Runs on a fresh private-queue context, off the main thread.
    private func loadAllDataFromStore(persistentContainer: NSPersistentContainer) async throws -> LoadedData {
        let context = persistentContainer.makeBackgroundContext()
        let loaded = try await context.perform {
            // Releases are prefetched so that FilmSnapshot.init(from:) reading film.releases
            // is pure property access, not one SQL round trip per film.
            let filmDescriptor = Film.request()
            filmDescriptor.relationshipKeyPathsForPrefetching = ["releases"]
            filmDescriptor.returnsObjectsAsFaults = false
            let allFilms = try context.fetch(filmDescriptor)

            var filmDict: [UUID: FilmSnapshot] = [:]
            filmDict.reserveCapacity(allFilms.count)
            var sawLegacyMarketAvailability = false
            for film in allFilms {
                if !sawLegacyMarketAvailability,
                   film.releases.contains(where: {
                       ReleaseMarketAvailability.needsMigration($0.marketAvailability) }) {
                    sawLegacyMarketAvailability = true
                }
                filmDict[film.id] = FilmSnapshot(from: film)
            }

            // Lists with their memberships and each membership's film prefetched, so that
            // reading membership.film below does not fault per row.
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

            return (LoadedData(films: filmDict, lists: listDict, filmToLists: filmToListsDict),
                    sawLegacyMarketAvailability)
        }
        if loaded.1 { hasLegacyMarketAvailability = true }
        return loaded.0
    }

    private struct LoadedData: Sendable {
        let films: [UUID: FilmSnapshot]
        let lists: [UUID: MemoryList]
        let filmToLists: [UUID: Set<UUID>]
    }
    
    // Throttled save of both derived caches: MetadataCache (sort and search data) and
    // MemoryStoreCache (the snapshot, so the next launch can skip the store fetch). This is the
    // only throttled-save owner, so there is one timer and no cross-file write races.
    //
    // The snapshot payload is read from this store's dictionaries when the throttle expires, not
    // when the save is scheduled. Holding a reference earlier would force a full copy-on-write
    // copy of the dictionary on the next film edit. See MemoryStoreCache.save(films:lists:).
    private func scheduleThrottledSave() {
        // Checked here so no timer is armed when suspended, and again after the throttle window
        // in case suspension was requested while it was pending.
        guard !cachePersistenceSuspended else { return }

        pendingSaveTask?.cancel()
        // Not Task.detached: the task must return to MainActor to read the dictionaries, and
        // Task.sleep suspends rather than blocking, so inheriting MainActor costs nothing.
        pendingSaveTask = Task { [weak self, saveThrottleInterval] in
            do {
                try await Task.sleep(for: saveThrottleInterval)
            } catch {
                return  // Canceled during the throttle window — a newer save is scheduled.
            }
            guard !Task.isCancelled, let self, !self.cachePersistenceSuspended else { return }
            await self.flushCaches()
        }
    }

    /// Writes both derived caches from this store's current state. The files are independent, so
    /// the writes run concurrently. Callers must check `cachePersistenceSuspended` first.
    private func flushCaches() async {
        // Read into locals on MainActor, not inside the `async let` initializers: those run in a
        // child task without this actor's isolation. The locals keep a reference during the write,
        // so a mutation mid-encode pays one copy-on-write copy. `filmToLists` is not captured, since
        // it is not persisted (the cache rebuilds it from `lists` on load).
        let filmsPayload = films
        let listsPayload = lists
        // Read in the same synchronous step as the payload it names (see contentVersion).
        let payloadVersion = contentVersion

        async let metadataSave: Void = MetadataCache.shared.save()
        async let snapshotSave: Void = MemoryStoreCache.shared.save(
            films: filmsPayload, lists: listsPayload, contentVersion: payloadVersion)
        await metadataSave
        await snapshotSave
    }

    // Immediate save, for shutdown. Cancels the pending throttled task first, so it cannot wake
    // after the shutdown write and overwrite the new files with a stale payload.
    func saveImmediately() async {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil

        // A non-authoritative store must not overwrite the on-disk caches. This guard matters most
        // on failure paths, because the shutdown flush bypasses the throttle.
        guard !cachePersistenceSuspended else {
            Self.log("Immediate save skipped — derived-cache persistence is suspended for this session")
            return
        }
        // A quit before startup finishes would write a partial library over caches that are at
        // least as good. Skipping the write loses nothing: the store is the record, and these
        // files only save the next launch work.
        guard isInitialized else {
            Self.log("Immediate save skipped — startup had not finished loading the library")
            return
        }

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
        var sortedFilms = sortedIDs.compactMap { films[$0] }

        // Apply saved filters, so the cache matches what loadFilms will request.
        if !filterOptions.isEmpty {
            sortedFilms = applyFilters(sortedFilms, filterOptions: filterOptions)
        }

        // Populate the view cache so the next loadFilms() call is a hit.
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
        // Before Phase 2, `films` is empty, so any view built here would be empty. Caching that
        // result would persist it until a data mutation, which initialization is not. Return without
        // caching, so the first request after initialization builds the view for real. Callers
        // treat an empty result here as "not ready" (see DataCoordinator.performLoad).
        guard isInitialized else {
            Self.log("getFilms(\(viewID.description)) requested before Phase 2 completion — returning empty without caching")
            return []
        }

        // A saved search's base is the whole library in the requested order — exactly All
        // Films' array — so it shares that cache entry rather than holding one copy per search.
        let cacheViewID: ViewIdentifier
        if case .savedSearch = viewID { cacheViewID = .allFilms } else { cacheViewID = viewID }
        let cacheKey = CacheKey(viewID: cacheViewID, sortOption: sortOption, direction: direction,
                               filterOptions: filterOptions)
        
        if let cached = cachedViews[cacheKey] {
            return cached
        }
        
        let start = Date()
        
        // Get base film IDs for the view. Every membership-filtered view (smart lists,
        // Unwatched, Recents) and Search start from the whole library: DataCoordinator
        // applies their membership and search filters to the result.
        let baseFilmIDs: [UUID]
        switch viewID {
        case .list(let listID):
            guard let list = lists[listID] else { return [] }
            baseFilmIDs = Array(list.filmIDs)
        case .filmQueue, .imports:
            // The Film Queue orders films by section (Up Next → Soon → Later) via the
            // grouped path below, not by a flat union sort; Imports shows no films.
            baseFilmIDs = []
        case .allFilms, .smartList, .unwatched, .recents, .reports, .search, .savedSearch:
            baseFilmIDs = Array(films.keys)
        }
        
        // Sort the IDs. The Film Queue is grouped by section first (Up Next → Soon → Later),
        // with each section internally ordered by the requested sort — this section grouping is
        // exactly what lets the gallery draw one labeled divider band per populated section.
        // Every other view uses the standard flat MetadataCache sort.
        let sortedIDs: [UUID]
        if case .filmQueue = viewID {
            sortedIDs = filmQueueSectionGroupedIDs(sortOption: sortOption, direction: direction)
        } else {
            sortedIDs = MetadataCache.shared.sort(baseFilmIDs, by: sortOption, direction: direction,
                                                  purchaseFormat: viewID.purchaseFormatScope)
        }
        
        // Convert IDs to FilmSnapshot objects
        var sortedFilms = sortedIDs.compactMap { films[$0] }
        
        // Apply filters (search filtering is handled by DataCoordinator)
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
    
    // Returns all user-generated lists, sorted by display order. The three internal Film Queue
    // lists ("Up Next", "Soon", "Later") are excluded here, the single point every user-facing
    // list enumeration passes through. They stay in `lists` and are reached by UUID via getList(_:).
    func getAllLists() -> [MemoryList] {
        if let cached = sortedListsCache {
            return cached
        }
        // Ordered by MemoryList.orderedBefore, the shared rule.
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
            // Claim each film for the first (lowest-queueOrder) section it belongs to.
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
        films[snapshot.id] = snapshot
        MetadataCache.shared.addFilm(snapshot)
        invalidateCacheForAllFilms()
        // A snapshot carrying a ranked position must be reflected in the ordered Hall of
        // Fame list, which is derived state that only rebuildHallOfFame() maintains. Newly
        // created and newly imported films always have hofPosition == 0, so this is skipped
        // on those paths; the case that needs it is DataCoordinator.deleteFilms' rollback,
        // which re-adds previously ranked films. Without the rebuild those films would be
        // restored to the store but silently absent from the Hall of Fame for the rest of
        // the session.
        if snapshot.hofPosition > 0 {
            rebuildHallOfFame()
        }
        scheduleThrottledSave()
        Self.log("Added film: \(snapshot.name)")
    }
    
    /// Batch counterpart of addFilm(_:) for imports: one MetadataCache store, one view-cache
    /// invalidation and one throttled save for the whole batch, rather than one per film.
    func addFilms(_ snapshots: [FilmSnapshot]) {
        guard !snapshots.isEmpty else { return }
        var ranked = false
        for snapshot in snapshots {
            films[snapshot.id] = snapshot
            if snapshot.hofPosition > 0 { ranked = true }
        }
        MetadataCache.shared.updateFilms(snapshots)
        invalidateCacheForAllFilms()
        if ranked { rebuildHallOfFame() }
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
        let affected = films.values.filter { $0.rotationThresholdOverride == nil }
        guard !affected.isEmpty else { return }
        let built = await Task.detached(priority: .utility) {
            affected.map { ($0, FilmMetadata(from: $0)) }
        }.value
        guard !Task.isCancelled else { return }
        MetadataCache.shared.setEntries(built.compactMap { films[$0.0.id] == $0.0 ? $0.1 : nil })
        scheduleThrottledSave()
    }

    /// Replaces an existing FilmSnapshot in MemoryStore and updates MetadataCache.
    /// Called after any mutation that changes film properties — scalars, releases, or derived
    /// values — to keep the in-memory state authoritative for the UI.
    func updateFilm(_ snapshot: FilmSnapshot) {
        guard let existing = films[snapshot.id] else {
            Self.log("WARNING: Tried to update non-existent film: \(snapshot.id)")
            return
        }
        
        films[snapshot.id] = snapshot
        MetadataCache.shared.updateFilm(snapshot)
        
        invalidateCacheForAllFilms()
        
        if let listIDs = filmToLists[snapshot.id] {
            for listID in listIDs {
                invalidateCacheForList(listID)
            }
        }

        // hallOfFameFilms is derived state maintained only by rebuildHallOfFame(). Rank changes go
        // through the dedicated Hall of Fame methods, so this check is normally false. It keeps the
        // invariant at the entry point rather than relying on every caller.
        if snapshot.hofPosition != existing.hofPosition {
            rebuildHallOfFame()
        }
        
        scheduleThrottledSave()
        Self.log("Updated film: \(snapshot.name)")
    }
    
    /// Batch counterpart of updateFilm(_:), for many films changed at once (the MultiFilmSheet's
    /// save). Derived state is repaired once for the batch: one MetadataCache update, one round of
    /// view-cache invalidation, one Hall of Fame rebuild if a rank moved, and one scheduled save.
    func updateFilms(_ snapshots: [FilmSnapshot]) {
        var stored: [FilmSnapshot] = []
        stored.reserveCapacity(snapshots.count)
        var listsToInvalidate: Set<UUID> = []
        var ranksMoved = false
        for snapshot in snapshots {
            guard let existing = films[snapshot.id] else {
                Self.log("WARNING: Tried to update non-existent film: \(snapshot.id)")
                continue
            }
            films[snapshot.id] = snapshot
            stored.append(snapshot)
            if let listIDs = filmToLists[snapshot.id] { listsToInvalidate.formUnion(listIDs) }
            if snapshot.hofPosition != existing.hofPosition { ranksMoved = true }
        }
        guard !stored.isEmpty else { return }
        MetadataCache.shared.updateFilms(stored)
        invalidateCacheForAllFilms()
        for listID in listsToInvalidate { invalidateCacheForList(listID) }
        if ranksMoved { rebuildHallOfFame() }
        scheduleThrottledSave()
        Self.log("Updated \(stored.count) film(s)")
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

        // Determined BEFORE the eviction loop below, while the snapshots are still present.
        let deletedRankedMember = ids.contains { (films[$0]?.hofPosition ?? 0) > 0 }

        // Single pass: collect affected lists, evict from the snapshot store, and update the reverse index.
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

        // Deleting a ranked film would leave a phantom ID in hallOfFameFilms and a gapped position
        // sequence. That breaks hallOfFameIsFull (at 200 members, the Hall of Fame toggle would stay
        // disabled) and getNextHallOfFamePosition(), which can collide with an existing position.
        // Compaction prevents both.
        let compactedHofIDs: [UUID] = deletedRankedMember ? compactHallOfFamePositions() : []

        invalidateCacheForAllFilms()
        for listID in affectedLists {
            invalidateCacheForList(listID)
        }
        // MemoryList is a value type, so the sorted-lists cache holds stale copies. Drop it so
        // getAllLists() rebuilds from `lists`.
        if !affectedLists.isEmpty {
            sortedListsCache = nil
        }
        
        scheduleThrottledSave()
        Self.log("Deleted \(ids.count) film(s) from \(affectedLists.count) affected list(s)")
        return compactedHofIDs
    }
    
    // MARK: - List Mutations
    
    func addFilmsToList(filmIDs: Set<UUID>, listID: UUID) {
        guard var list = lists[listID] else { return }

        // Filter out IDs with no matching film. A deferred add (for example, the Film Queue "Add on
        // Drop" confirmation) can outlive a deleted film. Counts use raw filmIDs, so a phantom ID
        // would inflate them until the next reload. Legitimate adds are unaffected.
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
        // MemoryList is a value type, so the sorted-lists cache is now stale. Invalidate it so every
        // getAllLists() consumer (sidebar counts, alerts, menus) sees fresh data.
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
        // Drop the stale value-type cache, as in addFilmsToList.
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
    
    // MARK: - Cache Invalidation
    
    private func invalidateCacheForAllFilms() {
        // Collect the keys to remove, then remove each one in place, to avoid copying the dictionary.
        let keysToRemove = cachedViews.keys.filter { key in
            switch key.viewID {
            case .allFilms, .smartList, .unwatched, .recents, .reports, .imports, .search, .filmQueue,
                 .savedSearch:
                // (.savedSearch never keys a cache entry; getFilms maps it to .allFilms.)
                // .filmQueue and .unwatched are whole-library views: a film's sort keys, watched
                // flag, or rating can change without any list mutation.
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
        // Same collect-then-remove pattern as invalidateCacheForAllFilms(). The Film Queue view is the
        // union of the three internal lists, so an internal list change also invalidates it.
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
            // Non-genre filters: all must match
            for option in otherFilters {
                if !checkFilter(film, option: option) { return false }
            }
            // Genre filters: any may match
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
            // Matches either "Kids" or "Family" genre tags, which name the same category.
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
        // hallOfFameFilms is the ordered list maintained by rebuildHallOfFame(). Its count equals the
        // number of ranked films, so the next position is count + 1. max(hofPosition) + 1 would be
        // wrong, because stored positions can have gaps.
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

        // A film that already holds a position must be rejected. Re-ranking it would leave a gap at
        // its old slot and make the next add collide with its new one. Rejecting it keeps 1..N dense.
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
            // Non-members are skipped rather than written: clearing an already-zero position
            // would schedule a save and force a compaction pass for no state change.
            guard var snapshot = films[filmID], snapshot.hofPosition > 0 else { continue }
            snapshot.hofPosition = 0
            films[filmID] = snapshot
            removedCount += 1
        }

        guard removedCount > 0 else { return nil }

        // Rebuilds the ordered list, then renumbers it 1..N so no gaps remain.
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
        // The pre-restore rank is used below to decide whether the Hall of Fame must be rebuilt.
        // No current caller changes a rank through this path, but the check keeps the ordered list
        // consistent if one does.
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
            // Duplicates are collapsed. Unknown and unranked films are skipped, so a reorder never
            // promotes a film into the Hall of Fame.
            guard seen.insert(filmID).inserted,
                  var snapshot = films[filmID],
                  snapshot.hofPosition > 0 else { continue }
            position += 1
            guard snapshot.hofPosition != position else { continue }
            snapshot.hofPosition = position
            films[filmID] = snapshot
        }

        // A ranked film missing from filmIDs keeps its stored position instead of being dropped.
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
    static func isolatedForTesting(films: [FilmSnapshot], lists: [MemoryList]) -> MemoryStore {
        let store = MemoryStore()
        store.cachePersistenceSuspended = true
        for film in films { store.films[film.id] = film }
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

    /// The number of live entries in the view cache. Reported as a metric so unbounded
    /// growth is visible as a number rather than only as a slow leak.
    var cachedViewCountForTesting: Int { cachedViews.count }

    /// Empties the view cache, so the next getFilms for every key builds afresh.
    func clearViewCacheForTesting() { cachedViews.removeAll() }
    #endif

    private func rebuildHallOfFame() {
        // Every caller has just changed one or more films' `hofPosition`. The cached view
        // arrays hold FilmSnapshot copies, so they must go too: the Hall of Fame paths
        // (add, remove, reorder, restore, compaction) write `films` directly rather than
        // through updateFilm, and without this the gallery's next reload would serve
        // snapshots carrying the old ranks. Rank changes are rare, so a full clear is cheap.
        cachedViews.removeAll()
        // The `id` tiebreak makes the order total. Sorting on `hofPosition` alone is not
        // deterministic when positions collide, and Swift's sort is not stable.
        // compactHallOfFamePositions() then resolves collisions.
        let hofFilms = films.values
            .filter { $0.hofPosition > 0 }
            .sorted {
                $0.hofPosition == $1.hofPosition
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.hofPosition < $1.hofPosition
            }
        hallOfFameFilms = hofFilms.map { $0.id }
        Self.log("Rebuilt hall of fame: \(hallOfFameFilms.count) films")
    }
}
