// MARK: - MemoryStore.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// In-memory store and UI source of truth for all film and list data, held exclusively as value
// types (FilmSnapshot, MemoryList). @Model objects are accessed only during the startup load
// and immediately converted to snapshots; no SwiftData types are retained afterward.

import Foundation
import SwiftData

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

    /// The canonical display order for user-generated lists: `displayOrder` ascending,
    /// tie-broken on `listID`.
    ///
    /// The tiebreak is not cosmetic. Swift's sort is not guaranteed stable and the
    /// store's `lists.values` has no defined order, so `displayOrder` alone left
    /// duplicate orders resolving arbitrarily — and duplicates are reachable, both from
    /// a restored backup and from two `createList` calls that each read `maxOrder`
    /// before either awaited. That made a list's position able to change between
    /// launches with no user action.
    ///
    /// Defined here, on the model, because `getAllLists()` is not the only place lists
    /// get ordered: anything starting from an unordered `Set<UUID>` of memberships (the
    /// "Show in List" menus, the Right Sidebar's membership table) has to sort for
    /// itself, and each hand-written copy of the rule was one more chance for those
    /// surfaces to disagree with the sidebar about which of two equally-ordered lists
    /// comes first. One comparator makes that agreement structural.
    static func orderedBefore(_ lhs: MemoryList, _ rhs: MemoryList) -> Bool {
        lhs.displayOrder != rhs.displayOrder
            ? lhs.displayOrder < rhs.displayOrder
            : lhs.listID.uuidString < rhs.listID.uuidString
    }
}

@MainActor
final class MemoryStore: Loggable {
    nonisolated static let logTag = "[MemoryStore]"
    
    // MARK: - Storage (value types only — no SwiftData @Model objects)
    private var films: [UUID: FilmSnapshot] = [:] { didSet { contentVersion = Self.nextContentVersion() } }
    private var lists: [UUID: MemoryList] = [:] { didSet { contentVersion = Self.nextContentVersion() } }
    private var filmToLists: [UUID: Set<UUID>] = [:]
    private(set) var hallOfFameFilms: [UUID] = []
    private var cachedViews: [CacheKey: [FilmSnapshot]] = [:]
    
    /// Cached sorted array of all lists, invalidated on list mutations.
    /// Avoids re-sorting the lists dictionary on every getAllLists() call.
    private var sortedListsCache: [MemoryList]?
    
    private struct CacheKey: Hashable {
        let viewID: ViewIdentifier
        let sortOption: SortOption
        let direction: SortDirection
        let filterOptions: Set<FilterOption>
    }
    
    private(set) var isInitialized = false

    /// Set once Phase 1 has run to completion, regardless of which path it took.
    /// Makes loadFromDatabase() idempotent on its own terms: the isInitialized guard
    /// below cannot serve that purpose, because isInitialized is only set in Phase 2 —
    /// so a second Phase 1 call arriving before Phase 2 would otherwise redo the entire
    /// load and overwrite the dictionaries it had already built.
    private var hasLoadedFromDatabase = false

    /// Set to true when the slow-path SwiftData fetch threw. The films/lists dictionaries
    /// are then empty or partial and MUST NOT be treated as an authoritative picture of the
    /// library: derived-cache writes are suspended (see suspendCachePersistence) and
    /// DataCoordinator skips the post-startup work that would act on the empty state.
    private(set) var loadFailed = false

    /// When true, every derived-cache write from this store is suppressed — both the
    /// throttled path and the immediate shutdown flush.
    ///
    /// The snapshot cache and metadata cache are pure derived data whose sole purpose is to
    /// let the next launch skip the SwiftData read. Writing them from a MemoryStore that does
    /// not faithfully mirror the persistent store is strictly worse than not writing them at
    /// all: the caches would be replaced by a smaller, wrong payload, and the correct payload
    /// (which is still reconstructible from the database) would be gone. Two situations
    /// trigger this, both set by DataCoordinator:
    ///   • the persistent container failed to open and the app is running against the empty
    ///     in-memory fallback purely to present the "Library Unavailable" recovery alert;
    ///   • the Phase 1 SwiftData fetch threw (loadFailed above).
    private var cachePersistenceSuspended = false

    /// Identifies the current contents of `films` and `lists` — everything the snapshot
    /// cache persists — so MemoryStoreCache can skip a save of contents it already wrote.
    /// Moved by the two properties' `didSet`, so no mutation path can miss it (`filmToLists`
    /// is not persisted). Drawn from one counter for every instance, so two stores never
    /// share a version once mutated; a store still at 0 has never held anything.
    private var contentVersion: UInt64 = 0
    private static var contentVersionCounter: UInt64 = 0
    private static func nextContentVersion() -> UInt64 {
        contentVersionCounter &+= 1
        return contentVersionCounter
    }

    /// Permanently suspends derived-cache persistence for this session. One-way by design:
    /// there is no in-session recovery from either triggering condition — both require a
    /// relaunch — so re-enabling would only reintroduce the risk it exists to remove.
    func suspendCachePersistence(reason: String) {
        guard !cachePersistenceSuspended else { return }
        cachePersistenceSuspended = true
        // Cancel any save already scheduled before the suspension was requested. Without
        // this, a throttled task armed moments earlier would still wake up and write.
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        Self.log("Derived-cache persistence suspended for this session: \(reason)")
    }

    /// Set to true when Phase 1 used the slow SwiftData path.
    /// validateCacheAndFinalize() reads this to decide whether to write
    /// a fresh MemoryStore snapshot cache after startup completes.
    private var snapshotCacheNeedsRebuild = false

    /// True when Phase 1 met a legacy single-element market availability tag, in the snapshot
    /// cache or the store. DataCoordinator then runs DataManager's one-time store rewrite.
    private(set) var hasLegacyMarketAvailability = false
    
    /// Direct film count without array allocation.
    var totalFilmCount: Int { films.count }
    
    // Throttled save task to prevent excessive disk I/O
    private var pendingSaveTask: Task<Void, Never>?
    private let saveThrottleInterval: Duration = .seconds(2)
    
    // MARK: - Initialization
    
    // STARTUP: Initialization is split into two phases so that the
    // SwiftData fetch (Phase 1) can overlap with MetadataCache disk I/O on
    // background threads. Phase 2 runs after MetadataCache finishes loading.
    //
    //   Phase 1 - loadFromDatabase(): SwiftData fetch + snapshot conversion + HoF rebuild.
    //             @Model objects are converted to snapshots and released immediately.
    //             No MetadataCache dependency. Runs while cache I/O is on BG threads.
    //
    //   Phase 2 - validateCacheAndFinalize(): Checks cache integrity, does incremental
    //             update if needed, sets isInitialized. Requires MetadataCache loaded.
    
    /// Phase 1: Load all data from SwiftData into memory as FilmSnapshots.
    /// @Model objects are converted to value types during this call and not retained.
    /// Has no dependency on MetadataCache, so it can run concurrently with cache disk I/O.
    ///
    /// Reentrancy: guarded by hasLoadedFromDatabase, claimed synchronously at entry with
    /// no suspension point before the assignment, so MainActor isolation is sufficient to
    /// serialize callers. isInitialized cannot serve this role on its own — it is not set
    /// until Phase 2, so a second Phase 1 call arriving in between would sail past it.
    ///
    /// - Parameters:
    ///   - modelContainer: Used only by the slow path, whose SwiftData fetch must run
    ///     against `mainContext`.
    ///   - dataManager: Used only by the fast path's cache validation, whose fingerprint
    ///     query runs inside this actor's background `ModelContext` so that the O(N) film
    ///     fetch it performs never occupies MainActor during launch. See
    ///     `DataManager.computeStoreFingerprint()`.
    func loadFromDatabase(modelContainer: ModelContainer, dataManager: DataManager) async {
        guard !isInitialized, !hasLoadedFromDatabase else {
            Self.log("Phase 1 already completed — skipping")
            return
        }
        hasLoadedFromDatabase = true

        let startTime = Date()
        Self.log("Phase 1: Loading data...")

        // Fast path: try to restore from the on-disk MemoryStore snapshot.
        // MemoryStoreCache stores the full [UUID: FilmSnapshot] + list data serialized
        // as JSON, validated by a fingerprint derived from the SwiftData DB.
        // On a cache hit the entire SwiftData fetch + snapshot conversion is skipped —
        // reducing Phase 1 from O(N × relationships) to a single JSON decode.
        var cacheResult = await MemoryStoreCache.shared.load(dataManager: dataManager)

        // A cache written by a build that predates the two-component market availability
        // format still holds legacy tags. Read the store instead: ReleaseSnapshot migrates
        // them on conversion, and the rebuilt cache is written in the new format.
        if case .hit(let cachedFilms, _, _) = cacheResult,
           cachedFilms.values.contains(where: { $0.releases.contains {
               ReleaseMarketAvailability.needsMigration($0.marketAvailability) } }) {
            Self.log("Snapshot cache holds legacy market availability tags — reading SwiftData")
            hasLegacyMarketAvailability = true
            cacheResult = .miss
        }

        switch cacheResult {
        case .hit(let films, let lists, let filmToLists):
            self.films = films
            self.lists = lists
            self.filmToLists = filmToLists
            // These dictionaries are the file's contents, so a save before anything changes
            // them has nothing to write.
            MemoryStoreCache.shared.recordOnDisk(contentVersion: contentVersion)
            self.sortedListsCache = nil
            self.rebuildHallOfFame()
            // No payload is pushed to MemoryStoreCache here. Every flush reads this store's
            // dictionaries at the moment it runs (see flushCaches), so there is nothing to
            // prime — and priming would leave the films dictionary non-uniquely-referenced
            // from launch onward, making the session's first film edit pay for a full
            // copy-on-write copy of the whole library.
            let duration = Date().timeIntervalSince(startTime)
            Self.log("Phase 1 fast-path: \(self.films.count) films from snapshot cache in \(Fmt.fixed(duration, 2))s")

        case .miss:
            // Slow path: full SwiftData fetch + snapshot conversion.
            // Runs on first launch (no cache) or when DB fingerprint has changed
            // (films added/deleted/modified since last save). The cache is rebuilt
            // at the end of finalizeInitialization() via scheduleThrottledSave().
            Self.log("Phase 1 slow-path: snapshot cache miss, reading SwiftData...")
            self.snapshotCacheNeedsRebuild = true
            do {
                let loadedData = try await loadAllDataFromMainContext(modelContainer: modelContainer)
                self.films = loadedData.films
                self.lists = loadedData.lists
                self.filmToLists = loadedData.filmToLists
                self.sortedListsCache = nil
                self.rebuildHallOfFame()
            } catch {
                // The dictionaries are left untouched (empty). Record the failure so the
                // rest of startup treats this store as non-authoritative: derived-cache
                // writes are suspended immediately — before any other code can schedule
                // one — and DataCoordinator skips the post-startup work that would
                // otherwise act on an empty library (poster pruning, orphaned-membership
                // cleanup, internal list bootstrapping, settings sync).
                loadFailed = true
                suspendCachePersistence(reason: "Phase 1 SwiftData fetch failed")
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

        // If Phase 1 took the slow path (SwiftData fetch), film snapshots are guaranteed
        // to be fresher than anything on disk. Force a full MetadataCache rebuild so
        // derived sort keys, rotation dates, and search strings are always consistent
        // with the newly-loaded snapshot data. This closes the narrow window where
        // MetadataCache could be stale: both caches are normally written together in the
        // same throttled save, but a crash between writes could leave MetadataCache out
        // of sync with the SwiftData state that triggered the slow-path load.
        if snapshotCacheNeedsRebuild {
            Self.log("Slow-path load — forcing full MetadataCache rebuild...")
            let rebuildStart = Date()
            await MetadataCache.shared.rebuild(from: films)
            let rebuildDuration = Date().timeIntervalSince(rebuildStart)
            Self.log("Full rebuild in \(Fmt.fixed(rebuildDuration * 1000, 1))ms")
            // Both caches are now fully current. Schedule the throttled save to flush
            // them to disk together. The throttle interval (2 seconds) is short enough that
            // the data is persisted well before any user action can trigger a mutation.
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
            // Fast-path cache hit with matching counts. Both MemoryStoreCache and
            // MetadataCache are written together in the same throttled save, so the
            // MetadataCache is consistent with these snapshots. A spot check guards
            // against the unlikely case of a partially-decoded cache file that produced
            // the right count but with different keys (e.g. mid-write file corruption).
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
    
    /// Loads all Films and Lists from mainContext, immediately converting @Model objects
    /// to value-type snapshots. The @Model objects are not retained after this method returns.
    ///
    /// This is the only point in the application where Film @Model objects are accessed
    /// from inside MemoryStore. After this call, MemoryStore holds exclusively FilmSnapshots.
    ///
    /// IMPORTANT: The conversion loop yields to the run loop every `yieldInterval` films.
    /// Without these yields, the entire fetch + conversion runs as a single synchronous
    /// block on MainActor — no events can be processed, causing the beach ball cursor.
    /// SwiftData's mainContext is MainActor-bound and cannot be moved to a background
    /// thread, so cooperative yielding is the only mechanism available.
    private func loadAllDataFromMainContext(modelContainer: ModelContainer) async throws -> LoadedData {
        let context = modelContainer.mainContext
        
        // Fetch all films with relationship prefetching so SwiftData loads every Film's
        // releases array in a single batched query rather than faulting each one lazily
        // when FilmSnapshot.init(from:) accesses film.releases. Without prefetching,
        // a 1,300-film library triggers ~1,300 additional SQL round-trips on MainActor —
        // the dominant source of startup latency after the architectural migration.
        var filmDescriptor = FetchDescriptor<Film>()
        filmDescriptor.relationshipKeyPathsForPrefetching = [\Film.releases]
        let allFilms = try context.fetch(filmDescriptor)
        
        var filmDict: [UUID: FilmSnapshot] = [:]
        filmDict.reserveCapacity(allFilms.count)
        
        // With releases prefetched, each FilmSnapshot.init(from:) is pure property access —
        // no I/O — so the per-film cost is far lower. Yield every 200 films rather than 50
        // to reduce Task.yield() overhead while still keeping the run loop responsive
        // for very large libraries (2,600+ films would still yield ~13 times).
        let yieldInterval = 200
        for (index, film) in allFilms.enumerated() {
            if !hasLegacyMarketAvailability,
               film.releases.contains(where: {
                   ReleaseMarketAvailability.needsMigration($0.marketAvailability) }) {
                hasLegacyMarketAvailability = true
            }
            filmDict[film.id] = FilmSnapshot(from: film)
            if index % yieldInterval == yieldInterval - 1 {
                await Task.yield()
            }
        }
        // allFilms array goes out of scope here — @Model objects are released.
        
        // Fetch all lists with membership and film relationships prefetched so that
        // accessing list.memberships and membership.film below does not trigger
        // per-membership SQL faults. A typical library has many list membership records,
        // and faulting each one individually on MainActor adds measurable latency.
        var listDescriptor = FetchDescriptor<ListObject>(
            sortBy: [SortDescriptor(\.displayOrder)]
        )
        listDescriptor.relationshipKeyPathsForPrefetching = [\ListObject.memberships]
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
        
        return LoadedData(films: filmDict, lists: listDict, filmToLists: filmToListsDict)
    }
    
    /// Container for data loaded during startup.
    private struct LoadedData {
        let films: [UUID: FilmSnapshot]
        let lists: [UUID: MemoryList]
        let filmToLists: [UUID: Set<UUID>]
    }
    
    // Throttled save to prevent multiple rapid disk I/O operations.
    // Saves both MetadataCache (derived sort/search data) and MemoryStoreCache
    // (the full snapshot, so the next launch can skip the SwiftData fetch). This is the
    // sole throttled-save owner in the app — MetadataCache deliberately does not maintain
    // its own throttle, so there is exactly one timer and no cross-file write races.
    //
    // The snapshot payload is read from this store's dictionaries when the throttle
    // expires, NOT when the save is scheduled. Handing them to MemoryStoreCache up front
    // (as this method previously did) left them permanently non-uniquely-referenced, so
    // every subsequent `films[id] = snapshot` paid for a full copy-on-write copy of the
    // entire dictionary — thousands of FilmSnapshot structs, each with dozens of String and
    // Array fields to retain — on MainActor, for every single film edit. See
    // MemoryStoreCache.save(films:lists:).
    private func scheduleThrottledSave() {
        // Suppressed when this store is not an authoritative mirror of the persistent
        // store. Checked here so no timer is ever armed, and re-checked after the throttle
        // window below in case suspension was requested while it was pending.
        guard !cachePersistenceSuspended else { return }

        pendingSaveTask?.cancel()
        // Deliberately NOT Task.detached: this task must return to MainActor to read the
        // store's dictionaries once the throttle expires, and Task.sleep suspends rather
        // than blocking, so inheriting MainActor isolation costs nothing while waiting.
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

    /// Writes both derived caches to disk from this store's current state.
    ///
    /// The two caches live in independent files, so the writes run concurrently. Both
    /// callers (the throttled task above and saveImmediately() below) are responsible for
    /// checking cachePersistenceSuspended first; this method performs the write
    /// unconditionally once reached.
    private func flushCaches() async {
        // Read into locals here, on MainActor, rather than inside the `async let`
        // initializers below. An `async let` initializer is evaluated in a child task that
        // does not inherit this method's actor isolation, so referencing the isolated
        // dictionaries directly in that expression would be a cross-isolation access. These
        // are Sendable value types, so they cross into the child task cleanly.
        //
        // The locals do hold a second reference for the duration of the write, which means a
        // mutation landing mid-encode pays for one copy-on-write copy. That is the same,
        // deliberately narrow window MetadataCache.save() has always had, and it is the
        // entire point of not holding the reference between saves.
        // filmToLists is deliberately not captured: it is no longer persisted (the cache
        // rebuilds it as the reverse index of lists[].filmIDs on load), so taking a reference
        // to it here would leave its storage non-uniquely-referenced during the write for no
        // reason at all.
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

    // Force immediate save (for shutdown scenarios).
    // Cancels MemoryStore's pending throttled task before flushing, ensuring the
    // timer cannot wake after the shutdown writes complete and overwrite the
    // just-saved cache files with a stale payload.
    func saveImmediately() async {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil

        // Same rationale as scheduleThrottledSave(): a non-authoritative store must not
        // overwrite the on-disk derived caches. This is the guard that actually matters
        // for the failure paths, because the shutdown flush bypasses the throttle entirely.
        guard !cachePersistenceSuspended else {
            Self.log("Immediate save skipped — derived-cache persistence is suspended for this session")
            return
        }
        // A quit during launch, before this store and MetadataCache hold the library: what
        // they hold then is nothing, or a part, and writing it would replace caches on disk
        // that are at least as good (an empty snapshot meant a full SwiftData read on the
        // next launch, an empty MetadataCache a rebuild). Nothing is lost by not writing —
        // the store is the record; these files only spare the next launch work.
        guard isInitialized else {
            Self.log("Immediate save skipped — startup had not finished loading the library")
            return
        }

        await flushCaches()
    }
    
    // MARK: - Film Access

    /// Pre-warms the default view cache on a background thread immediately after startup,
    /// before isInitialized is set to true.
    ///
    /// This ensures DataCoordinator can populate `films` in the same SwiftUI update cycle that
    /// sets `isInitialized = true`, so the gallery renders content on its very first frame
    /// rather than showing content only after a subsequent handleReadyState → loadFilms → sort pass.
    ///
    /// The sortOption, direction, and filterOptions must match exactly what ViewStateManager
    /// will request via triggerReloadSync, or the cache will be missed and a second synchronous
    /// sort will run on MainActor — defeating the purpose.
    ///
    /// Returns the pre-sorted, pre-filtered snapshot array so DataCoordinator can publish it directly.
    func prewarmInitialView(sortOption: SortOption, direction: SortDirection, filterOptions: Set<FilterOption>) async -> [FilmSnapshot] {
        let allIDs = Array(films.keys)
        guard !allIDs.isEmpty else { return [] }

        let sortedIDs = await MetadataCache.shared.sortAsync(allIDs, by: sortOption, direction: direction)
        var sortedFilms = sortedIDs.compactMap { films[$0] }

        // Apply any saved filters so the cache matches exactly what loadFilms will request.
        if !filterOptions.isEmpty {
            sortedFilms = applyFilters(sortedFilms, filterOptions: filterOptions)
        }

        // Populate the view cache so the subsequent loadFilms() call from handleReadyState
        // is a cache hit and returns immediately without re-sorting.
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
        // Refuse to answer — and, critically, to CACHE an answer — before Phase 2 has
        // completed. Until then the `films` dictionary is empty (fast path: not yet
        // decoded; slow path: not yet fetched), so every view built here is empty by
        // construction.
        //
        // Caching that empty result was a permanent, session-long corruption: the app
        // window is on screen and fully interactive during the ~1–3s initialization
        // window, so a user who navigates or types a search query in it drives a real
        // loadFilms() call for the destination view. The empty array it produced was
        // written into cachedViews under that view's (viewID, sort, direction, filters)
        // key, and nothing subsequently invalidated it — invalidateCacheForAllFilms /
        // invalidateCacheForList only fire on data MUTATIONS, and initialization is not a
        // mutation. Every later request with the same key returned the poisoned empty
        // array straight from the cache, so search (and any other view touched in that
        // window) stayed permanently empty until the app was relaunched.
        //
        // Returning without writing the cache leaves the key absent, so the very next
        // request after initialization builds the view for real. Callers are expected to
        // treat an empty result here as "not ready yet" rather than "no films" — see
        // DataCoordinator.performLoad, which short-circuits ahead of this for the same
        // reason and re-issues the deferred load once initialization completes.
        guard isInitialized else {
            Self.log("getFilms(\(viewID.description)) requested before Phase 2 completion — returning empty without caching")
            return []
        }

        let cacheKey = CacheKey(viewID: viewID, sortOption: sortOption, direction: direction,
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
        case .allFilms, .smartList, .unwatched, .recents, .reports, .search:
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
    
    // Returns all USER-generated lists, sorted by display order. The three internal
    // Film Queue lists ("Up Next", "Soon", "Later") are deliberately excluded here:
    // this is the single choke point through which every user-facing list enumeration
    // flows (sidebar, "Add to List" menus, List Membership picker, reordering, name
    // generation), so filtering here keeps the internal lists hidden everywhere at once.
    // The internal lists remain fully present in the `lists` dictionary and are reached
    // directly by UUID via getList(_:), which is all their membership operations require.
    func getAllLists() -> [MemoryList] {
        if let cached = sortedListsCache {
            return cached
        }
        // Ordered by MemoryList.orderedBefore — the canonical rule, shared with every
        // other surface that has to order lists for itself. See its doc comment for why
        // the listID tiebreak is load-bearing rather than cosmetic.
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
    /// Film Queue lists. Used to build the Film Queue view and its film count.
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
    /// Later), with each section internally sorted by the given sort option / direction. Each
    /// film is assigned to exactly ONE canonical section — the one with the lowest queueOrder
    /// among its internal-list memberships — so a film that (through corruption) ended up in more
    /// than one internal list still appears exactly once, under a single deterministic section.
    /// This canonical rule is identical to DataCoordinator.filmQueueSection(forFilm:), so the
    /// gallery's per-film section resolution always agrees with this grouping when it computes
    /// the divider break points.
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
    /// The corresponding @Model object is managed separately by DataCoordinator (mainContext)
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
    
    /// Recomputes the MetadataCache entries whose rotation date follows the global
    /// default threshold (every film without an override) and persists the result.
    /// No snapshot changes, so no view cache is invalidated: nothing in a sorted view
    /// depends on rotation dates.
    ///
    /// The entries are built on a utility-priority thread so the main actor stays free
    /// (the change usually lands while a Settings picker is still animating closed). A film
    /// edited while they were being built keeps the entry its edit already produced, and a
    /// canceled caller (superseded by a newer change) applies nothing.
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

        // hallOfFameFilms is derived state that only rebuildHallOfFame() maintains, and this
        // method replaces the whole snapshot — including hofPosition. No current caller
        // changes a rank through here (every Hall of Fame path routes through the dedicated
        // add/remove/reorder/restore methods, and FilmSheet explicitly carries the existing
        // position forward untouched), so in practice this comparison is always false and
        // costs one Int check on the hottest mutation path. It is here so the invariant holds
        // at the entry point rather than by convention at every call site — the same class of
        // gap that let a deleted film linger in the ordered list indefinitely.
        if snapshot.hofPosition != existing.hofPosition {
            rebuildHallOfFame()
        }
        
        scheduleThrottledSave()
        Self.log("Updated film: \(snapshot.name)")
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

        // Single pass: collect affected lists, evict from snapshot store, and tear
        // down the reverse-index simultaneously. Previously two separate for-loops
        // iterated `ids` twice; one pass halves the work for large batch deletions.
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

        // Deleting a ranked film leaves hallOfFameFilms holding a phantom ID and the
        // survivors holding a gapped 1..N sequence. Both matter well beyond display:
        // hallOfFameIsFull gates the FilmSheet's Hall of Fame toggle (so at 200 members a
        // single deletion would disable it permanently), and getNextHallOfFamePosition()
        // derives the next slot from the inflated count, which can collide with a position
        // an existing member already holds — the exact indeterminate-ordering corruption
        // removeFromHallOfFame() compacts to avoid.
        let compactedHofIDs: [UUID] = deletedRankedMember ? compactHallOfFamePositions() : []

        invalidateCacheForAllFilms()
        for listID in affectedLists {
            invalidateCacheForList(listID)
        }
        // The deleted films were removed from each affected list's filmIDs set above.
        // MemoryList is a value type, so the sorted-lists cache still holds pre-mutation
        // copies with stale filmIDs; drop it so getAllLists() rebuilds from `lists`.
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

        // Guard against stale filmIDs that no longer correspond to an actual film —
        // e.g. a film deleted while a deferred add flow (the Film Queue "Add on Drop"
        // confirmation alert, or any other add that can be pending across a run-loop
        // gap) was still awaiting user confirmation. Without this, a phantom filmID
        // could be inserted into list.filmIDs / filmToLists: getFilms(viewID:) already
        // silently drops any ID with no matching snapshot via compactMap, but counts are
        // taken from raw filmIDs (the sidebar's ListInfo.filmCount, filmQueueFilmIDs()),
        // so a phantom entry would inflate the count without a corresponding visible
        // film — a display/count mismatch that would persist until the next full reload
        // from disk. Real list adds never intend to
        // reference a nonexistent film, so this is a pure safety filter with no effect
        // on any legitimate add.
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
        // MemoryList is a value type — the sorted-lists cache holds pre-mutation copies
        // whose filmIDs no longer reflect this membership change. Invalidate so every
        // getAllLists() consumer (sidebar counts, alert handlers, menus) sees fresh data.
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
        // Same rationale as addFilmsToList: drop the stale value-type cache so
        // getAllLists() rebuilds with the updated filmIDs membership.
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

    /// Creates an internal (application-owned) list with a caller-supplied fixed UUID.
    /// Used only to bootstrap the three Film Queue lists at startup. Idempotent:
    /// does nothing if a list with this UUID already exists. The list is registered in
    /// the `lists` dictionary exactly like a user list — so all membership operations,
    /// the snapshot cache, and export/restore treat it identically — but it is excluded
    /// from getAllLists(), keeping it out of every user-facing enumeration.
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
        // Dictionary has no removeAll(where:) in the Swift standard library.
        // The correct in-place approach is to collect the keys to remove first,
        // then removeValue(forKey:) for each — one dictionary lookup per key,
        // no full-dictionary copy, and no new dictionary allocation.
        let keysToRemove = cachedViews.keys.filter { key in
            switch key.viewID {
            case .allFilms, .smartList, .unwatched, .recents, .reports, .imports, .search, .filmQueue:
                // .filmQueue is a cross-cutting membership view whose ordering can shift
                // when any film's sort-key fields change, so it is invalidated alongside
                // the other whole-library views. .unwatched is included for the same
                // reason: a film's watched flag or userRating can change independently
                // of any list/smart-list mutation, so its cached view must be treated
                // as whole-library-affecting too.
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
        // Same collect-then-remove pattern as invalidateCacheForAllFilms().
        // When the mutated list is one of the internal Up Next lists, the Film Queue
        // view (whose membership is the union of the three internal lists) must also be
        // invalidated, since its cached result no longer reflects the changed membership.
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
    
    /// Applies standard filter options to the film list. Used by getFilms and by
    /// DataCoordinator when it builds a Recents result from a pre-ordered ID list
    /// (bypassing the getFilms sort path), so both apply the same logic.
    /// Note: Search filtering is handled by DataCoordinator using SearchController,
    /// not here. This keeps the caching layer clean.
    func applyFilters(_ films: [FilmSnapshot], filterOptions: Set<FilterOption>) -> [FilmSnapshot] {
        guard !filterOptions.isEmpty && !filterOptions.contains(.none) else {
            return films
        }
        let genreFilters = filterOptions.filter { $0.isGenre }
        let otherFilters = filterOptions.filter { !$0.isGenre }
        
        return films.filter { film in
            // Non-genre filters use AND logic (all must match)
            for option in otherFilters {
                if !checkFilter(film, option: option) { return false }
            }
            // Genre filters use OR logic (any must match)
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
            // Matches films tagged as either "Kids" or "Family" — both genre strings
            // refer to the same category in the data model, so both are checked here.
            return film.genre.contains("Kids") || film.genre.contains("Family")
        case .sciFiAndFantasy:
            return film.genre.contains("Sci-Fi") || film.genre.contains("Fantasy")
        case .thriller:
            return film.genre.contains("Thriller")
        }
    }
    
    // MARK: - Hall of Fame Management
    
    var hallOfFameIsFull: Bool { return hallOfFameFilms.count >= 200 }
    
    /// The next free 1-based slot. Private because the only correct way to occupy a slot is
    /// `addToHallOfFame(_:)`; exposing the value invited callers to write positions directly
    /// and bypass the density invariant that every other method in this section maintains.
    private func getNextHallOfFamePosition() -> Int {
        // hallOfFameFilms is the authoritative ordered list maintained by rebuildHallOfFame().
        // Its count is always equal to the number of currently-ranked films, so the next
        // available position is simply count + 1. Using max(hofPosition) + 1 is unsafe
        // because stored position integers may not be perfectly dense (gaps can arise from
        // removals that were never compacted), which would produce a position higher than
        // the film's actual rank in the list.
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

        // Re-adding a film that already holds a position is not a no-op if allowed through:
        // it would be assigned hallOfFameFilms.count + 1 while still occupying its old slot,
        // leaving the sequence gapped AND making the next add collide with the position this
        // film just took. Rejecting it here keeps 1..N dense by construction.
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
    
    /// Removes a film from the Hall of Fame by clearing its position, then compacts
    /// the remaining entries so positions form an unbroken 1..N sequence.
    ///
    /// Compaction is essential: `getNextHallOfFamePosition()` derives the next slot
    /// from `hallOfFameFilms.count + 1`. If gaps remain (e.g. films hold positions
    /// 1,2,…,193,195,196,…) a re-added film receives the count-based position, which
    /// may collide with an existing film's stored integer, producing indeterminate sort
    /// order when `rebuildHallOfFame()` re-sorts by `hofPosition`.
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
    /// Batching matters for correctness as much as for cost. Removing N films by calling the
    /// single-film path N times compacts N times, and each compaction shifts a different set
    /// of survivors — so the caller cannot capture one coherent pre-mutation ranking to roll
    /// back to, and it emits N separate database transactions each rewriting up to 200 films.
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
    /// Used by the deletion rollback, which must undo both the removed films' own positions
    /// and the compaction applied to every survivor. Restoring one film at a time would
    /// rebuild — and schedule a save — once per film, which for a full 200-member Hall of Fame
    /// is 200 redundant sorts of the entire film collection. This is the only restore entry
    /// point for that reason; there is deliberately no single-film variant.
    /// Positions of 0 are applied as-is: that is the correct representation of "not ranked",
    /// and rebuildHallOfFame() filters those entries out.
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
        // Bound rather than nil-checked so the pre-restore rank is available below without a
        // second lookup. No current caller rolls a position back through this path (FilmSheet
        // routes Hall of Fame changes through the dedicated add/remove methods), but
        // hofPosition is a stored property of the snapshot being replaced wholesale, so
        // leaving the derived ordered list unreconciled would be a latent inconsistency for
        // any future path that does.
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
    /// `filmIDs` is treated as a *request*, not as the new truth. The previous implementation
    /// assigned `hallOfFameFilms = filmIDs` verbatim, which made the derived ordered list only
    /// as trustworthy as its caller: a duplicate, an ID the store no longer holds, an unranked
    /// film, or a ranked film omitted from the array each left the list disagreeing with the
    /// stored `hofPosition` values — corrupting `hallOfFameIsFull` and the next-slot
    /// calculation for the rest of the session. Positions are now written from the requested
    /// order and the list is then rebuilt and renumbered from those stored positions, so the
    /// invariant holds regardless of what the caller passed in.
    ///
    /// - Returns: The ordering actually applied, which callers should use in place of their
    ///   own array when emitting events or gathering snapshots to persist.
    @discardableResult
    func reorderHallOfFame(_ filmIDs: [UUID]) -> [UUID] {
        guard !filmIDs.isEmpty else { return hallOfFameFilms }

        var position = 0
        var seen = Set<UUID>()
        for filmID in filmIDs {
            // Duplicates are collapsed; unknown and unranked films are skipped so a reorder
            // can never silently promote a film into the Hall of Fame.
            guard seen.insert(filmID).inserted,
                  var snapshot = films[filmID],
                  snapshot.hofPosition > 0 else { continue }
            position += 1
            guard snapshot.hofPosition != position else { continue }
            snapshot.hofPosition = position
            films[filmID] = snapshot
        }

        // Reconciles the ordered list with the stored positions and renumbers it 1..N. A
        // ranked film missing from filmIDs is placed by its retained position rather than
        // dropped, which self-heals a stale caller instead of losing a member.
        compactHallOfFamePositions()

        scheduleThrottledSave()
        Self.log("Reordered hall of fame: \(hallOfFameFilms.count) film(s)")
        return hallOfFameFilms
    }
    
    // MARK: - Debug Harness Support

    #if DEBUG
    /// Builds a store directly from value types, with no SwiftData involvement.
    ///
    /// The same rationale as `MetadataCache(isolatedForTesting:)`: a scenario that loaded its
    /// corpus into the live store would mutate state the running app is reading, so its result
    /// could depend on what the app happened to be doing and two scenarios in one run could
    /// contaminate each other. This instance is a pure function of the snapshots handed to it.
    ///
    /// It is the identical object the app uses — every mutation, cache-invalidation and Hall of
    /// Fame path below is the production one — differing only in how the dictionaries were
    /// first populated. Cache persistence is suspended so it can never write over the real
    /// derived-cache files, and both load flags are set so `getFilms` answers queries rather
    /// than short-circuiting at its readiness gate.
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

    /// Every list, including the three internal Film Queue lists that `getAllLists()`
    /// deliberately hides. Needed to reconstruct a store faithfully in a differential check;
    /// rebuilding from the filtered list would drop the queue and make the two sides differ
    /// for a reason that has nothing to do with the property under test.
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
        // The `id` tiebreak makes the ordering total. Sorting on `hofPosition` alone is a
        // strict weak ordering only while every position is unique, and Swift's sort is not
        // guaranteed stable — so any transient collision (a restore file with duplicate
        // positions, a partially-applied reorder) produced an order that could differ between
        // two rebuilds of identical data, i.e. rows that reshuffle for no visible reason.
        // compactHallOfFamePositions() then resolves the collision deterministically.
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
