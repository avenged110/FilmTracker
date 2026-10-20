// MARK: - DataCoordinator.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Central coordinator for film data operations. Bridges MemoryStore (UI source of truth) and
// DataManager (SwiftData persistence) using an optimistic-update + background-persist + rollback
// pattern; all UI reads return value types (FilmSnapshot / MemoryList), never @Model objects.
// NOTE: saveSettings/loadSettings use mainContext directly so that changes are immediately
// visible to DBExporter within the same session.

import SwiftUI
import SwiftData
import Observation

// MARK: - View Membership

/// The result of resolving a view's film membership — i.e. which films belong to it,
/// independent of sort order or user-selected filters. Centralizes what used to be
/// three separate, independently-resolved-and-stored properties on DataCoordinator
/// (one each for recents, smart lists, and Unwatched), each requiring its own
/// resolution branch in `loadFilms` and its own application branch in `performLoad`.
/// A future membership-filtered view needs only a new case in
/// `ViewIdentifier.resolveMembership` below — no new stored property, and no new
/// branch in either `loadFilms` or `performLoad`.
enum ViewMembership: Sendable {
    /// No membership restriction — every film in the library is a candidate. Used by
    /// allFilms, list (whose restriction is handled separately via its own base ID
    /// list), filmQueue (handled separately via its own grouped-by-section base ID
    /// list), reports, imports, and search.
    case unrestricted
    /// Exactly the films in this Set belong to the view.
    case set(Set<UUID>)
}

extension ViewIdentifier {
    /// Resolves this view's film membership. The single source of truth for how each
    /// membership-filtered view determines "which films belong to me" — used by
    /// DataCoordinator.loadFilms so that adding a new membership-filtered view means
    /// updating exactly this switch.
    @MainActor
    func resolveMembership(memoryStore: MemoryStore, smartLists: SmartLists) -> ViewMembership {
        switch self {
        case .recents(let category):
            // MetadataCache determines membership and per-category display order;
            // the ordered array is not needed here (DataCoordinator.loadFilms
            // resolves it directly for its fast-path use, to avoid computing it
            // twice), only the Set form for general membership filtering.
            return .set(Set(category.orderedFilmIDs()))

        case .smartList(let type):
            // Smart-list membership is always computed at runtime by the SmartLists manager.
            return .set(smartLists.filmIDs(for: type))

        case .unwatched(let category):
            // Membership is computed directly from each film's own watched/userRating
            // fields — both are simple, always-current snapshot properties, so no
            // SmartLists-style recalculation is needed.
            let allFilms = memoryStore.getAllFilms()
            switch category {
            case .unwatched:
                return .set(Set(allFilms.filter { !$0.watched }.map(\.id)))
            case .notRated:
                return .set(Set(allFilms.filter { $0.userRating == 0 }.map(\.id)))
            }

        case .allFilms, .list, .filmQueue, .reports, .imports, .search:
            return .unrestricted
        }
    }
}

// MARK: - Debug Persistence Fault Injection

#if DEBUG
/// Forces `trackOperation`'s background work to fail, so the harness can exercise every
/// rollback closure in this file against a real failure rather than by inspection.
///
/// Injected HERE rather than inside DataManager deliberately. The contract a rollback is
/// written against is "the persist did not commit", and that is a property of the
/// trackOperation boundary — every mutation path in this file funnels through it, so one
/// switch covers all of them with no per-method instrumentation to keep in sync.
///
/// `afterWork` exists to model the other, harder case: the work DID commit (or partially
/// committed) and the operation still reports failure. The rollback closures are all
/// written for `beforeWork`, so `afterWork` is how the harness demonstrates the divergence
/// a partially-committed write leaves behind rather than asserting it away.
///
/// MainActor-isolated because trackOperation's Task inherits MainActor, so no
/// synchronization is needed and no `nonisolated(unsafe)` is required.
@MainActor
enum DebugPersistenceFault {
    enum Mode { case none, beforeWork, afterWork }

    static var mode: Mode = .none
    static var injectedCount = 0

    struct Injected: Error, LocalizedError {
        var errorDescription: String? { "Injected persistence failure (debug harness)" }
    }

    static func reset() { mode = .none; injectedCount = 0 }
}
#endif

@MainActor
@Observable
final class DataCoordinator: Loggable {
    nonisolated static let logTag = "[DataCoordinator]"

    // MARK: - Published States
    private(set) var films: [FilmSnapshot] = []
    private(set) var filmCount: Int = 0
    // Single source of truth for the total number of films in the database.
    private(set) var totalFilmCount: Int = 0
    private(set) var isInitialized: Bool = false
    var hasDatabaseFilms: Bool { totalFilmCount > 0 }

    /// Pre-computed, sorted [ListInfo] array — the sidebar's reactive source of truth.
    /// Populated synchronously inside finalizeInitialization() alongside `films` so that
    /// user-generated lists appear in the first render frame, at the same time as gallery
    /// grid content. Updated synchronously on every MemoryStore list mutation so that
    /// LeftSidebar never needs an async refresh pass to stay current.
    private(set) var cachedLists: [ListInfo] = []

    /// Claimed synchronously by beginInitialization() and cleared when isInitialized is
    /// set. Allows FilmTrackerApp to guard against re-entrant calls during the async
    /// initialization window, before isInitialized is true.
    private(set) var isInitializing: Bool = false

    /// True when this coordinator was constructed against the in-memory fallback container
    /// (the persistent store failed to open), or when the Phase 1 SwiftData fetch threw.
    /// In either case the in-memory state does not mirror the user's library, so every
    /// post-startup path that would act on it — internal list bootstrapping, settings sync,
    /// duplicate-release cleanup, poster pruning, orphaned-membership cleanup — is skipped.
    var isLibraryStateUnreliable: Bool { usingFallbackStore || memoryStore.loadFailed }

    /// Set at init from FilmTrackerApp's persistentContainerFailed result. Stored rather
    /// than re-derived because ModelContainer exposes no supported way to ask whether a
    /// configuration ended up in-memory after the fact.
    private let usingFallbackStore: Bool

    // MARK: - Core Components
    let modelContainer: ModelContainer
    private let memoryStore: MemoryStore
    private let dataManager: DataManager
    // @Observable is incompatible with 'lazy var' because the macro synthesizes
    // init accessors that conflict with lazy's deferred-initialization mechanism.
    // The workaround is a private optional backing store plus a non-lazy computed
    // accessor that initializes on first call — identical runtime semantics to lazy.
    private var _smartLists: SmartLists?
    var smartLists: SmartLists {
        if let existing = _smartLists { return existing }
        let new = SmartLists(coordinator: self)
        _smartLists = new
        return new
    }

    /// Release-day notifications (71.20). Created by `startReleaseNotifications()` once the
    /// library has loaded, and never before: its first sync reads the library.
    @ObservationIgnored private var releaseNotifications: ReleaseNotifications?

    /// Starts release-day notifications. Called once by FilmTrackerApp after startup, beside
    /// the deferred smart-list calculation; a second call does nothing.
    func startReleaseNotifications() {
        guard releaseNotifications == nil else { return }
        let notifications = ReleaseNotifications(coordinator: self)
        releaseNotifications = notifications
        notifications.start()
    }

    /// Flushes any smart list state that is persisted on a debounce, for the quit path.
    ///
    /// Reads `_smartLists` directly rather than the computed accessor so that shutting down
    /// never instantiates a SmartLists that was not otherwise needed this session — which,
    /// besides being wasted work, would construct an object whose baseline is nil and has
    /// nothing to flush anyway.
    func flushSmartListState() {
        _smartLists?.flushRotationBaseline()
    }

    private var _settingsManager: SettingsManager?
    private var settingsManager: SettingsManager {
        if let existing = _settingsManager { return existing }
        let new = SettingsManager(dataCoordinator: self)
        _settingsManager = new
        return new
    }

    /// Builds the SettingsManager if it does not exist yet, purely for its side effect of
    /// installing the `preferencesChanged` observer.
    ///
    /// The lazy accessor above meant the manager — and therefore its subscription — came
    /// into existence only when something first read `settingsManager`. In practice the
    /// only startup read sits BELOW the `isLibraryStateUnreliable` guard in
    /// finalizeInitialization(), so an unreliable-library session installed no observer at
    /// all and NO preference change reached the database for the whole session. That guard
    /// is meant to skip the one-shot startup sync, not to disable settings persistence
    /// outright, so construction is now driven independently of it.
    func activateSettingsObserver() {
        _ = settingsManager
    }

    /// Forces SettingsManager's debounced write out immediately. Called from the quit path
    /// before prepareForShutdown(); see SettingsManager.flushPendingSync(). No-op when the
    /// manager was never built, which implies no observed change to flush.
    func flushPendingSettingsSync() async {
        guard let existing = _settingsManager else { return }
        await existing.flushPendingSync()
    }

    // MARK: - Hall of Fame Accessors
    var hallOfFameFilms: [UUID] { memoryStore.hallOfFameFilms }
    var hallOfFameIsFull: Bool { memoryStore.hallOfFameIsFull }
    
    func getHallOfFameFilms() -> [FilmSnapshot] {
        return memoryStore.getHallOfFameFilms()
    }

    /// The highest `wishlist` position currently held anywhere in the library, ignoring
    /// every release on `filmID`. Returns 0 when nothing outside that film is wishlisted.
    ///
    /// MARK: Why a maximum and not a count
    ///
    /// A count of wishlisted releases answers "how many are wishlisted", which is only the
    /// same number as "what is the last position in use" while the sequence is gap-free —
    /// and it is not.
    /// A removal on any film vacates a position and nothing renumbers the survivors across
    /// films, so counts and positions diverge the first time a release is un-wishlisted
    /// anywhere. Issuing `count + 1` after that lands on a slot another film already holds,
    /// which is a genuine collision: two releases share one position and the Wishlist
    /// report's sort has nothing left to separate them by. Deriving the next slot from the
    /// maximum cannot collide regardless of how gapped the sequence is.
    ///
    /// `filmID` is excluded because the caller (FSTabReleases.handleWishlistToggle) holds
    /// unsaved in-session values for that film which supersede whatever the store still
    /// records for it — it folds its own maximum in separately.
    ///
    /// Combo-pack children are excluded because a child's position is mirrored from its
    /// parent by `syncComboChildFields` and never occupies a slot of its own.
    ///
    /// Read on a user CLICK (the Wishlisted trait, and the purchased cascade when a
    /// wishlisted release is marked bought), never per frame. Iterates
    /// `getAllFilmsMap().values` rather than `getAllFilms()` because the latter
    /// materializes a copy of every FilmSnapshot in the library for a walk that only
    /// reads one Int per release; the `for … where` loop allocates nothing.
    func maxWishlistPosition(excludingFilm filmID: UUID) -> Int {
        var maximum = 0
        for film in memoryStore.getAllFilmsMap().values where film.id != filmID {
            for release in film.releases
            where release.wishlist > maximum && release.isTopLevel {
                maximum = release.wishlist
            }
        }
        return maximum
    }

    /// Returns all (film, release) pairs where the release has `wishlist > 0`,
    /// across every film in the library. The caller is responsible for applying the
    /// saved display order (using each release's `wishlist` position value directly).
    ///
    /// Combo-pack children are excluded (`isTopLevel` only): `syncComboChildFields`
    /// unconditionally mirrors the parent's `wishlist` value onto the child, so without
    /// this filter a single wishlisted combo pack would surface as two separate entries
    /// here, double-counting one purchase.
    func getWishlistReleases() -> [(film: FilmSnapshot, release: ReleaseSnapshot)] {
        Self.wishlistPairs(in: memoryStore.getAllFilms())
    }

    /// The wishlisted (film, release) pairs among `films`. Nonisolated so the Release
    /// Wishlist report can run the scan off the main actor.
    nonisolated static func wishlistPairs(
        in films: [FilmSnapshot]
    ) -> [(film: FilmSnapshot, release: ReleaseSnapshot)] {
        films.flatMap { film in
            film.releases
                .filter { $0.wishlist > 0 && $0.isTopLevel }
                .map { (film: film, release: $0) }
        }
    }
    
    // MARK: - Poster Cache Support
    /// Returns all poster UIDs for cache completion.
    /// Uses MemoryStore for fast access to cached film data.
    func getAllPosterUIDs() -> [String] {
        return memoryStore.getAllPosterUIDs()
    }

    // MARK: - Operation Tracking
    // pendingOperationCount and isShuttingDown are accessed exclusively on MainActor:
    //   - Incremented in trackOperation() (called from @MainActor methods)
    //   - Decremented in the Task's defer block (Task inherits MainActor from caller)
    //   - Read in hasPendingOperations (called from @MainActor AppDelegate)
    //   - Read/written in prepareForShutdown() (@MainActor method)
    // MainActor provides all necessary synchronization; no lock is needed.
    private var pendingOperationCount: Int = 0

    /// Set to true by prepareForShutdown(). Causes trackOperation() to silently
    /// discard any new work enqueued after shutdown has been initiated.
    private var isShuttingDown: Bool = false

    /// The most recently dispatched tracked operation. Each new operation awaits this
    /// before doing its own work, which is what makes dispatch order the execution order
    /// — see trackOperation. Reassigned on every dispatch; a finished task's closure (and
    /// with it the reference to ITS predecessor) is released on completion, so the chain
    /// never retains more than the tasks still running.
    private var lastTrackedOperation: Task<Void, Never>?

    // Returns 'true' if background persistence operations are in-progress.
    // Used by AppDelegate for graceful shutdown coordination.
    var hasPendingOperations: Bool {
        return pendingOperationCount > 0 }

    // Tracks a background operation for shutdown coordination.
    // Used for operations that go through DataManager (@ModelActor).
    // If a rollback closure is provided and the operation fails, MemoryStore
    // is restored to its pre-mutation state and the user is alerted.
    //
    // ORDERING: operations execute strictly in the order they were dispatched. Each
    // task first awaits the one dispatched before it, so the sequence of MemoryStore
    // mutations on the main actor and the sequence of commits in DataManager are the
    // same sequence. Without this, every operation was an independent unstructured Task
    // racing to the same @ModelActor: they virtually always arrived in creation order,
    // but nothing guaranteed it, and several paths in this file had to be written around
    // the gap — a FilmSheet save followed by a Hall of Fame toggle for the same film, a
    // queue removal following a queue add, a compaction following a deletion. A reversal
    // in any of them would have committed a stale snapshot over a fresh one, leaving the
    // database disagreeing with memory until the next slow-path launch. Serializing here
    // closes all of them at once. No parallelism is lost: every work closure ends in the
    // same actor, which already serialized them — just not in a defined order.
    //
    // A work closure must therefore never call trackOperation itself, directly or through
    // anything it awaits: the inner task would wait on the outer one forever. None does.
    //
    // THREADING: Task(priority:) inherits the caller's actor context (@MainActor), so the
    // ordering chain, the defer, the rollback and the alert all run on MainActor —
    // pendingOperationCount access is safe. The work itself does not: see runOffMainActor.
    // `work` is @Sendable so a closure literal passed here is nonisolated rather than
    // inheriting MainActor from the call site; anything it needs from MainActor it must
    // capture as a value or reach with `await`.
    private func trackOperation(
        rollback: (() -> Void)? = nil,
        _ work: @escaping @Sendable () async throws -> Void
    ) {
        // Drop new work silently once shutdown has been initiated. Any in-flight
        // operations tracked before prepareForShutdown() was called will still
        // complete normally and decrement pendingOperationCount as expected.
        guard !isShuttingDown else {
            Self.log("Ignoring new operation — shutdown in progress")
            return
        }

        pendingOperationCount += 1

        let predecessor = lastTrackedOperation
        lastTrackedOperation = Task(priority: .background) { [weak self] in
            defer {
                if let self { self.pendingOperationCount = max(0, self.pendingOperationCount - 1) }
            }
            // Wait for the previously dispatched operation to finish (success or rollback)
            // before starting this one. Returns immediately if it already has.
            await predecessor?.value
            do {
                #if DEBUG
                if DebugPersistenceFault.mode == .beforeWork {
                    DebugPersistenceFault.injectedCount += 1
                    throw DebugPersistenceFault.Injected()
                }
                try await Self.runOffMainActor(work)
                if DebugPersistenceFault.mode == .afterWork {
                    DebugPersistenceFault.injectedCount += 1
                    throw DebugPersistenceFault.Injected()
                }
                #else
                try await Self.runOffMainActor(work)
                #endif
            } catch {
                Self.log("ERROR: Background persistence failed: \(error)")
                // Task(priority:) inherits @MainActor from trackOperation; execution resumes
                // on MainActor after the 'await work()' suspension, so MainActor.run is
                // redundant here. rollback and sendAlert are both @MainActor-isolated.
                rollback?()
                AppEventBus.shared.sendAlert(.showPersistenceFailure(
                    error: AlertErrorDetail.full(error)))
            } } }

    /// Runs a tracked operation's work away from the main thread and waits for it.
    ///
    /// SwiftData's model executor runs a DataManager call on the thread that awaits it, so
    /// work awaited from trackOperation's MainActor task held the main thread for its whole
    /// fetch-mutate-save — measured by `datamanager-thread` on a 1,384-film library: ~350 ms
    /// for a three-film delete, ~100 ms for a 60-film list add or remove, ~5 ms per FilmSheet
    /// save. A detached task puts the await on the global executor whatever default isolation
    /// nonisolated async closures get. The caller awaits the result, so trackOperation's
    /// ordering and shutdown accounting are unchanged. `.userInitiated`, not `.background`:
    /// these writes follow a user action and shutdown waits on them, and until they moved off
    /// the main thread they ran at its priority; background QoS can be throttled for seconds.
    private nonisolated static func runOffMainActor(
        _ work: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await Task.detached(priority: .userInitiated) { try await work() }.value
    }

    // MARK: - Current View State
    private var currentViewID: ViewIdentifier = .allFilms
    private var currentSortOption: SortOption = .title
    private var currentDirection: SortDirection = .ascending
    private var currentFilterOptions: Set<FilterOption> = []
    private var currentMembership: ViewMembership = .unrestricted
    private var currentFilmQueueSectionFilter: FilmQueueSection?

    /// The sort option the films currently held in `films` were actually ordered by, or
    /// nil before any load has completed.
    ///
    /// Distinct from `currentSortOption` for the same reason `loadedFilmQueueFilter` is
    /// distinct from `FilmQueueFilterState.shared.selectedFilter`: `currentSortOption` is
    /// the last *requested* sort, assigned at the top of `loadFilms` and therefore already
    /// updated during a load that goes on to return early at the readiness gate. This is
    /// written in `performLoad`, in the same statement group as `films` itself, so it can
    /// never describe an ordering the array does not actually have — which is what makes
    /// it the correct input for the sort-derived divider bands (see
    /// GallerySectioning.sectionBreaks).
    private(set) var loadedSortOption: SortOption?

    /// The Recents category the films currently held in `films` were actually ordered by,
    /// or nil when `films` is not a Recents result set at all.
    ///
    /// Exists for the same reason `loadedSortOption` does, and is written in the same
    /// statement group, so it can never describe an ordering the array does not have. It is
    /// deliberately NOT derived from `currentViewID`: that field is assigned at the top of
    /// `loadFilms`, before the readiness gate, so it can already name a view whose load
    /// returned early and whose films were never installed.
    ///
    /// Needed because a Recents tab's `SortOption` is a fixed placeholder that does not
    /// always describe the real ordering — `MetadataCache` orders Recently Come Up for
    /// Rotation by rotation eligibility date, which no SortOption expresses, and applies its
    /// own cap and tiebreaks to every tab. This is what lets the divider bands be derived
    /// from the order the films are genuinely in; see GallerySectionKey.
    private(set) var loadedRecentsCategory: RecentsCategory?

    /// The release format the films currently held in `films` were purchase-sorted within
    /// (`ViewIdentifier.purchaseFormatScope`), or nil for every-format. Written beside
    /// `loadedSortOption` for the same reason, so the Date Purchased bands are cut from the
    /// same format's purchases the sort ordered by.
    private(set) var loadedPurchaseFormat: ReleaseFormat?

    /// The Film Queue display filter that the films currently held in `films` were
    /// actually produced with, or nil when `films` is not a Film Queue result set at all.
    ///
    /// This is deliberately NOT the same thing as `FilmQueueFilterState.shared.selectedFilter`.
    /// That property is the live *intent* — it flips the instant the user taps the segmented
    /// control, while the narrower film set it implies is only installed later, when the
    /// deferred reload actually runs (see FilmQueueFilterState.selectFilter). Between those
    /// two moments the live filter and `films` disagree, and any renderer that mixes the two
    /// paints a frame that matches neither state: the previous tab's films with the new tab's
    /// divider treatment. Because `currentFilmQueueSectionFilter` and `films` are both written
    /// inside the same synchronous `loadFilms` → `performLoad` pass, this accessor can never
    /// disagree with the array it describes, which makes it the correct input for every
    /// presentation decision derived from the film set (see
    /// GallerySubview.Coordinator.updateSectionDividers).
    var loadedFilmQueueFilter: FilmQueueFilter? {
        guard case .filmQueue = currentViewID else { return nil }
        switch currentFilmQueueSectionFilter {
        case .none:         return .all
        case .some(.upNext): return .upNext
        case .some(.soon):   return .soon
        case .some(.later):  return .later
        }
    }

    // MARK: - Film Queue Explicit-Choice Guard
    /// Film IDs whose Film Queue membership was just explicitly set by the FilmSheet
    /// picker within the FilmChangeset currently being applied by `saveFilmChangeset`.
    /// Populated immediately before that method posts its `.film` events and cleared
    /// immediately after, so its lifetime spans only the synchronous delivery of those
    /// events to subscribers (SmartLists' `filmEvents` subscriber runs synchronously,
    /// with no `receive(on:)` hop). This closes a narrow but real ordering conflict:
    /// if the same save also causes the film to newly qualify for "Up for Rotation"
    /// (e.g. a backdated viewing event or a lowered rotation-threshold override) and
    /// the film has `autoAddToQueueOnRotation` set to a section different from the one
    /// the user just explicitly picked, `autoEnqueueFilmsNewlyUpForRotation` would
    /// otherwise fire mid-save and silently override the user's explicit choice before
    /// persistence is even dispatched. The user's explicit picker selection must always
    /// win, so `autoEnqueueFilmsNewlyUpForRotation` skips any film ID present here.
    /// Never affects the daily rotation scheduler, a full recalculation, or a targeted
    /// recalculation triggered by any other update path (updateViewingDates, etc.) —
    /// this set is empty outside the exact window described
    /// above, so auto-enqueue behaves exactly as before in every other circumstance.
    private var explicitQueueChangeFilmIDs: Set<UUID> = []

    // MARK: - Initialization
    /// - Parameter usingFallbackStore: true when `modelContainer` is the empty in-memory
    ///   fallback created because the persistent store could not be opened. Derived-cache
    ///   persistence is suspended immediately in that case, before any startup work runs,
    ///   so the user's real snapshot/metadata caches can never be overwritten by the
    ///   fallback's empty state (the internal Film Queue lists that finalizeInitialization
    ///   bootstraps would otherwise be enough on their own to schedule that write).
    init(modelContainer: ModelContainer, usingFallbackStore: Bool = false) {
        self.modelContainer = modelContainer
        self.memoryStore = MemoryStore()
        self.dataManager = DataManager(modelContainer: modelContainer)
        self.usingFallbackStore = usingFallbackStore
        if usingFallbackStore {
            memoryStore.suspendCachePersistence(reason: "running against the in-memory fallback container")
        }
        Self.log("DataCoordinator initialized\(usingFallbackStore ? " (in-memory fallback container)" : "")") }

    // STARTUP: Initialization is split into two phases so that the
    // SwiftData fetch can overlap with MetadataCache/PosterCache disk I/O on
    // background threads. FilmTrackerApp.initializeApp() orchestrates these phases.
    //
    //   Phase 1 - loadDatabasePhase(): SwiftData fetch + dict building + HoF rebuild.
    //             No MetadataCache dependency. Runs while cache I/O happens on BG threads.
    //
    //   Phase 2 - finalizeInitialization(): Validates cache integrity, does incremental
    //             update, sets isInitialized, defers SmartLists to background.
    //             Requires MetadataCache to be loaded first.

    /// Synchronously claims the initialization slot for the caller. Returns false when
    /// initialization has already completed or is already in flight.
    ///
    /// This exists because the previous arrangement — setting isInitializing inside
    /// loadDatabasePhase() — could not actually close the re-entrancy window it was meant
    /// to. loadDatabasePhase() runs in an `async let` child task, so it does not reach its
    /// assignment until after initializeApp() has already suspended; a second `.task`
    /// firing in that gap saw isInitializing still false, passed the guard, and went on to
    /// double-fire every deferred post-init step (smart-list calculation, the poster
    /// restore/completion task, and startDeferredMaintenance — the last of which overwrites
    /// its own stored task handle, orphaning the first and leaving it uncancellable at
    /// shutdown). Claiming the slot here, with no suspension point between the check and
    /// the assignment, makes MainActor isolation sufficient to serialize callers.
    func beginInitialization() -> Bool {
        guard !isInitialized, !isInitializing else {
            Self.log("Initialization already complete or in progress — skipping")
            return false
        }
        isInitializing = true
        return true
    }

    /// Starts the launch cache reads that need nothing from the UI, so they run while
    /// AppKit and SwiftUI bring up the first window instead of after it (see
    /// MemoryStoreCache.beginEarlyLoad and MetadataCache.beginEarlyLoad). Phase 1 and
    /// MetadataCache.load() consume them. Called from FilmTrackerApp.init; skipped for the
    /// in-memory fallback container, whose launch runs exactly as it did before.
    func beginEarlyCacheLoads() {
        guard !usingFallbackStore else { return }
        MemoryStoreCache.shared.beginEarlyLoad(dataManager: dataManager)
        MetadataCache.shared.beginEarlyLoad()
    }

    /// Phase 1: Load all SwiftData content into memory.
    /// Can run concurrently with MetadataCache.load() and PosterCache.loadMetadata()
    /// because it has no dependency on either cache.
    ///
    /// Reentrancy: the caller claims the slot via beginInitialization() before this is
    /// reached, and MemoryStore.loadFromDatabase() carries its own idempotence flag, so no
    /// guard is needed (nor possible) here — isInitializing is already true by design.
    func loadDatabasePhase() async {
        // dataManager is handed in so MemoryStoreCache can validate the snapshot cache
        // inside the background ModelActor instead of against mainContext — the fingerprint
        // query is an O(N) SwiftData fetch and was the last remaining piece of synchronous
        // main-thread work in this phase.
        await memoryStore.loadFromDatabase(modelContainer: modelContainer,
                                           dataManager: dataManager)

        Self.log("Phase 1 complete: \(memoryStore.totalFilmCount) films loaded from database")
    }

    /// Phase 2: Validate caches and make the coordinator ready for UI.
    /// Must be called after MetadataCache.load() and loadDatabasePhase() have both completed.
    ///
    /// NOTE: SmartLists calculation is not triggered here. It's intentionally separated
    /// into deferredSmartListsCalculation() so the caller (FilmTrackerApp) can yield
    /// to the run loop first, giving SwiftUI a chance to render the sidebar with user
    /// lists before SmartLists performs its lightweight MainActor setup.
    func finalizeInitialization() async {
        guard !isInitialized else { Self.log("Already initialized"); return }

        await memoryStore.validateCacheAndFinalize()

        // Ensure the three internal Film Queue lists exist before the UI is marked
        // ready, so the FilmSheet's Up Next picker always has valid lists to write to.
        // On first launch this creates them (in memory + persistent store); thereafter
        // it is a no-op because they are already loaded.
        //
        // Skipped entirely when the library state is unreliable. In that state MemoryStore
        // is empty, so this would always take the "create" branch and write three lists
        // into a store whose real contents are unknown — and the accompanying in-memory
        // insert is what would schedule a derived-cache write. Cache persistence is already
        // suspended, so that write is blocked either way; skipping here keeps the persistent
        // store itself untouched too. The lists are recreated on the next healthy launch.
        if isLibraryStateUnreliable {
            Self.log("Skipping internal Film Queue list bootstrap — library state is unreliable this session")
        } else {
            await ensureFilmQueueListsExist()
        }

        let allFilms = memoryStore.totalFilmCount
        totalFilmCount = allFilms

        // Pre-warm the initial view (sort + compactMap) on a background thread.
        // This runs the O(N log N) sort off-MainActor so the main thread stays free.
        // The result is also stored in MemoryStore's cachedViews, so the subsequent
        // loadFilms call triggered by GalleryView.handleReadyState returns instantly
        // from cache rather than re-sorting.
        //
        // IMPORTANT: We pre-warm with the user's actual saved sort preference, which is
        // what ViewStateManager.loadStateSync(for: .allFilms) will produce when
        // handleReadyState calls switchToViewSync. If these don't match, the cache is
        // missed and a second synchronous sort runs on MainActor — defeating the purpose.
        // Read the allFilms entry from the consolidated view-sort-states dictionary and
        // decode it through the SAME codec ViewStateManager.loadStateSync(for: .allFilms)
        // uses, keyed by the same ViewIdentifier.persistenceKey it derives its storage key
        // from. Both are load-bearing: if either the key or the decode diverged from that
        // method, the state resolved here would differ from the state
        // switchToViewSync(.allFilms) goes on to request, the pre-warmed cache would be
        // missed, and a second O(N log N) sort would run synchronously on MainActor at
        // launch — exactly the cost this pre-warm exists to avoid, and a failure with no
        // symptom other than a slower start. Sharing the codec and the key makes that
        // agreement structural rather than a comment.
        let prewarmKey = ViewIdentifier.allFilms.persistenceKey ?? "allFilms"
        let prewarmState = ViewState.decoded(from: Preferences.viewSortStates[prewarmKey] ?? [])
        // The EFFECTIVE sort, exactly as triggerReloadSync requests it — a saved choice that
        // the saved filters disable (Date Purchased under "Unpurchased") loads as Title.
        let prewarmSort = prewarmState.effectiveSortOption(in: .allFilms)
        let prewarmFilters = prewarmState.filterOptions
        let prewarmDir = prewarmState.sortDirection

        // Sync currentSortOption/currentDirection with the user's saved preference so that
        // if refreshFilms() is called before handleReadyState fires, it uses the right defaults
        // (loadFilms overwrites them from ViewStateManager's state either way).
        currentSortOption = prewarmSort
        currentDirection = prewarmDir
        currentFilterOptions = prewarmFilters

        // Timed separately because this is the main compute in Phase 2 — an O(N log N) sort
        // plus an O(N) snapshot gather — and it is the obvious second target if the snapshot
        // decode turns out not to dominate.
        let prewarmStart = ContinuousClock.now
        let prewarmedFilms = await memoryStore.prewarmInitialView(sortOption: prewarmSort, direction: prewarmDir, filterOptions: prewarmFilters)
        let prewarmElapsed = ContinuousClock.now - prewarmStart

        // Publish films + isInitialized + cachedLists atomically so SwiftUI coalesces them
        // into one render pass. cachedLists being populated here (not deferred to an async
        // refreshLists() call) is what ensures user-generated lists appear in the very same
        // frame as gallery grid content, eliminating the prior ~13-frame stagger.
        films = prewarmedFilms
        // Pre-warm installs its films directly rather than through performLoad, so it must
        // record the ordering itself; currentSortOption was set to prewarmSort just above.
        loadedSortOption = currentSortOption
        // The pre-warm is always All Films, so no Recents ordering or purchase format scope
        // is in effect.
        loadedRecentsCategory = nil
        loadedPurchaseFormat = nil
        filmCount = prewarmedFilms.count
        currentViewID = .allFilms
        syncListsCache()
        isInitialized = true
        isInitializing = false

        Self.log("Ready (\(allFilms) films, hasDatabaseFilms: \(hasDatabaseFilms))")

        Self.log("STARTUP BREAKDOWN (phase 2) — prewarmInitialView: \(prewarmElapsed.formattedMilliseconds) | sort: \(prewarmSort), dir: \(prewarmDir), filters: \(prewarmFilters.count) | films after filter: \(prewarmedFilms.count)")

        // The films published just above are the All Films pre-warm. If the user navigated
        // elsewhere — or began a search — while the progress indicator was on screen, that
        // is not the view they are looking at: ViewStateManager is already pointed at their
        // destination, but every load it requested in that window was deferred by
        // performLoad's readiness guard. Replay it now.
        //
        // This runs synchronously, in the same MainActor turn that set isInitialized, and
        // before this method's next suspension point. SwiftUI therefore coalesces the
        // pre-warm publish and this replacement into a single render pass: the first frame
        // the user sees already carries the correct content, so the spinner never gives way
        // to the wrong film set and there is no intermediate flash.
        //
        // Deliberately a no-op when All Films is the active view — that is precisely what
        // the pre-warm published, and GalleryView's own handleReadyState/initializeIfNeeded
        // resolves its saved sort/filter state from there exactly as it always has.
        ViewStateManager.shared.resyncAfterInitialization()

        // Install SettingsManager's preferencesChanged observer unconditionally, ABOVE the
        // unreliable-library guard below. The guard is about not WRITING to a store we
        // could not read; it must not also silence settings persistence for the rest of
        // the session (see activateSettingsObserver). The observer only ever writes the
        // singleton SettingsObject via saveSettings, which is not the destructive,
        // contents-dependent work the guard exists to defer.
        activateSettingsObserver()

        // Everything below writes to the persistent store. Skip it all when the library
        // state is unreliable: we could not read this store (or it is the empty in-memory
        // fallback), so mutating it is the one thing that could turn a recoverable,
        // read-side fault into real data loss. The duplicate-release cleanup is the sharp
        // edge — it issues deletes, and it would be issuing them against a store whose
        // actual contents are unknown to us. Both tasks are idempotent and re-run on the
        // next healthy launch, so nothing is permanently skipped by deferring them.
        guard !isLibraryStateUnreliable else {
            Self.log("Skipping settings sync and duplicate-release cleanup — library state is unreliable this session")
            return
        }

        // Sync settings to the database so the current UserDefaults state is captured
        // before the first user-initiated export or backup can run. Routed through
        // trackOperation so this write is visible to the shutdown drain — if the user
        // quits immediately after launch the settings are not silently lost.
        trackOperation { [weak self] in
            guard let self else { return }
            await self.settingsManager.syncToDatabase()
            Self.log("Settings synced to database (background)")
        }

        // Clean up any duplicate Release records left by the prior dual-write bug.
        // Runs once at startup; harmless no-op when no duplicates exist.
        // Not routed through trackOperation — it is idempotent and safe to interrupt.
        //
        // Detached, not a plain Task: SwiftData's model executor ran this DataManager call on
        // the thread that awaited it, so from a MainActor-inherited Task the whole release
        // pass ran on the main thread — ~590ms, landing between the first gallery data and
        // the first gallery frame (measured with `sample` against a copy of a 1,384-film
        // library).
        let dataManager = self.dataManager
        Task.detached(priority: .background) { [weak self] in
            guard let self, await !self.isShuttingDown else { return }
            do {
                try await dataManager.cleanupDuplicateReleases()
            } catch {
                Self.log("WARNING: Duplicate release cleanup failed: \(error)")
            }
        }
    }

    /// Triggers SmartLists calculation as a deferred background task.
    /// Called by FilmTrackerApp after yielding to the run loop, ensuring the sidebar
    /// has rendered user-generated lists before any SmartLists work runs.
    ///
    /// calculateAllLists() performs only lightweight MainActor setup (fetches the full
    /// film list, advances the generation counter), then immediately dispatches the
    /// O(N × predicates) computation to Task.detached(priority: .utility). MainActor
    /// is never held for the full calculation. By deferring until after the first render
    /// pass, user lists appear in the sidebar immediately while smart list counts fill
    /// in on a background thread moments later.
    func deferredSmartListsCalculation() {
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            self.smartLists.recalculateIfNeeded()
            Self.log("Smart lists calculated (deferred)")
        }
    }

    // MARK: - Film Loading

    /// Full load for an explicit view + sort/filter state. This is the single
    /// navigation-driven entry point, called by ViewStateManager.triggerReloadSync for
    /// every view switch, sort/filter/direction change, and forced reload.
    ///
    /// Per-view membership is resolved HERE via ViewIdentifier.resolveMembership,
    /// which is the single source of truth for how each view's membership is derived
    /// (recents ordering from MetadataCache, smart-list membership from the
    /// SmartLists manager, Unwatched's watched/userRating check) — rather than each
    /// membership kind being independently resolved and stored by hand. The Film
    /// Queue's single-section display filter from FilmQueueFilterState remains a
    /// separate, narrower concept (it doesn't gate which films belong to the view,
    /// only which of the three already-grouped sections is currently shown) and is
    /// still resolved here directly. The resolved values are stored in the current*
    /// fields so that subsequent in-place refreshes (refreshFilms) preserve them
    /// unchanged, exactly as the former preserve-on-refresh semantics did.
    func loadFilms(viewID: ViewIdentifier, sortOption: SortOption,
                   filterOptions: Set<FilterOption>, direction: SortDirection) {
        currentViewID = viewID
        currentSortOption = sortOption
        currentFilterOptions = filterOptions
        currentDirection = direction

        // Readiness gate — deliberately placed HERE, above the membership resolution
        // below, and not only in performLoad.
        //
        // Everything between this point and performLoad resolves a view's membership, and
        // two of those resolutions populate their own long-lived caches from data that is
        // not yet present during initialization:
        //
        //   • RecentsCategory.orderedFilmIDs() reads MetadataCache's per-category recents
        //     cache, which memoizes whatever it computes. Called before MetadataCache.load()
        //     has assigned `metadata`, it caches an EMPTY ordering — and that entry is only
        //     ever cleared by a metadata mutation, so the affected Recents category would
        //     stay empty for the rest of the session. This is the identical failure mode to
        //     the MemoryStore view-cache poisoning this whole fix addresses, in a second
        //     cache; letting the resolution run and merely discarding its result downstream
        //     would leave that vector wide open.
        //
        //   • ViewIdentifier.resolveMembership's .smartList case instantiates the lazy
        //     SmartLists manager. That is harmless on its own (recalculateIfNeeded is
        //     gated on `hasCalculated`, which mere instantiation does not set, so the
        //     deferred startup calculation still runs and broadcasts normally), but there
        //     is no reason to force it early either.
        //
        // The scalar inputs above are assigned before returning because they are pure
        // stored state with no side effects, and leaving them current keeps the
        // coordinator's picture of "what was last requested" honest. currentMembership is
        // deliberately NOT touched: it would be resolved from unavailable data. The
        // deferred request is replayed in full through this same method by
        // ViewStateManager.resyncAfterInitialization(), which re-resolves every input
        // from scratch, so nothing is carried forward stale.
        guard memoryStore.isInitialized else {
            Self.log("Load deferred for \(viewID.description) — memory store not ready yet")
            return
        }

        // Recents needs its pre-ordered array (for performLoad's fast path) in
        // addition to the plain membership Set every other view resolves to, so it's
        // special-cased here rather than routed through resolveMembership — doing so
        // would require a second call to RecentsCategory.orderedFilmIDs() to
        // reconstruct the same array performLoad already needs. That call reads from
        // a per-category cache, so the duplicate call would be cheap, but computing
        // it once and reusing it for both purposes is simpler and avoids the
        // redundancy entirely.
        var recentsOrder: [UUID]? = nil
        if case .recents(let category) = viewID {
            let ordered = category.orderedFilmIDs()
            recentsOrder = ordered
            currentMembership = .set(Set(ordered))
        } else {
            currentMembership = viewID.resolveMembership(memoryStore: memoryStore, smartLists: smartLists)
        }

        // Film Queue: the currently selected single-section display filter.
        // A nil section means the "All" filter (no restriction).
        if case .filmQueue = viewID {
            currentFilmQueueSectionFilter = FilmQueueFilterState.shared.selectedFilter.section
        } else {
            currentFilmQueueSectionFilter = nil
        }

        performLoad(recentsOrder: recentsOrder)
    }

    /// In-place refresh that reloads the film array for the CURRENT view, preserving
    /// every current* input (view identity, sort, filters, and the membership
    /// resolved by the last full loadFilms call). Used by the internal mutation
    /// paths in this file (optimistic updates, rollbacks, list membership changes) to
    /// repaint the active view without re-resolving membership — matching the
    /// long-standing refresh semantics of the former no-argument loadFilms() call.
    ///
    /// Note: refreshes within a recents view intentionally take performLoad's general
    /// path (no recentsOrder): the retained Set-based membership filter preserves the
    /// existing sort order, which for recentlyAdded/recentlyUpdated matches the correct
    /// category order; categories that need a specialized sort (recentlyViewed,
    /// recentlyRotated, recentlyPurchased) are re-supplied a fresh ordering by the next
    /// full loadFilms via ViewStateManager.triggerReloadSync.
    func refreshFilms() {
        performLoad(recentsOrder: nil)
    }

    /// Shared load core for loadFilms/refreshFilms: builds the film array for the
    /// current view from MemoryStore, applies the active membership and search filters,
    /// and publishes the result to `films`/`filmCount`.
    private func performLoad(recentsOrder: [UUID]?) {
        // Second half of the readiness gate. loadFilms carries the primary one (see its
        // long comment); this one exists because refreshFilms() reaches performLoad
        // directly, bypassing loadFilms entirely.
        //
        // MemoryStore cannot answer any view query until its Phase 2 completes: the films
        // dictionary is empty, so every array built from it would be empty too. The app
        // window is already on screen (behind the indeterminate progress indicator) and
        // fully interactive throughout that window, so this is a genuinely reachable path.
        //
        // The request is DEFERRED rather than answered. ViewStateManager already points at
        // the correct destination view with its search query and sort/filter state intact,
        // so nothing is lost; finalizeInitialization() replays it (via
        // resyncAfterInitialization) in the same MainActor turn that publishes
        // isInitialized. An in-flight search therefore completes on its own the instant the
        // data is available, with no further user action.
        //
        // Publishing an empty `films` here instead of returning would be actively wrong:
        // it is indistinguishable from a legitimately empty result and would flash the
        // "No Results" placeholder before the real results arrive. Nothing is published at
        // all — films is already empty throughout this window, and the UI is showing the
        // progress indicator regardless, since every consumer gates on the separate
        // DataCoordinator.isInitialized flag.
        guard memoryStore.isInitialized else {
            Self.log("Refresh deferred for \(currentViewID.description) — memory store not ready yet")
            return
        }

        let startTime = Date()

        var loadedFilms: [FilmSnapshot]

        // When recentsOrder is provided, MetadataCache has already determined both which
        // films belong to this category and the correct display order for them. Build the
        // result directly from that ordered ID list (O(N) compactMap) so the general
        // O(N log N) sort in getFilms is never performed. Any user-applied FilterOptions
        // are still applied below so they work correctly in recents views. Because this
        // array is already exactly the correct membership, the general currentMembership
        // filter below is skipped for this path — re-applying it would be redundant work.
        let membershipAlreadyApplied: Bool
        if case .set(let membershipSet) = currentMembership, membershipSet.isEmpty {
            // An empty membership admits nothing, so the result is empty whatever the sort
            // and filters. Answered directly: the general path below would sort the whole
            // library by this view's key (and cache that full array under it) only for the
            // membership filter to discard every film — ~20 ms on a 1,400-film library for
            // each visit to an empty Recents category, smart list or Unwatched tab.
            loadedFilms = []
            membershipAlreadyApplied = true
        } else if let orderedIDs = recentsOrder, !orderedIDs.isEmpty {
            let snapshotMap = memoryStore.getAllFilmsMap()
            loadedFilms = orderedIDs.compactMap { snapshotMap[$0] }
            // Apply user-selected filter options if any are active.
            if !currentFilterOptions.isEmpty {
                loadedFilms = memoryStore.applyFilters(loadedFilms, filterOptions: currentFilterOptions)
            }
            membershipAlreadyApplied = true
        } else {
            loadedFilms = memoryStore.getFilms(viewID: currentViewID,
                sortOption: currentSortOption, direction: currentDirection,
                filterOptions: currentFilterOptions)
            membershipAlreadyApplied = false
        }

        // Apply the resolved membership filter — recents (when refreshing without a
        // fresh recentsOrder), smart list, or Unwatched — via the single
        // currentMembership property. See ViewMembership's doc comment.
        if !membershipAlreadyApplied, case .set(let membershipSet) = currentMembership {
            loadedFilms = loadedFilms.filter { membershipSet.contains($0.id) }
        }

        // Apply the Film Queue's single-section display filter, if one is active. The films
        // are already section-grouped (Up Next → Soon → Later) by memoryStore.getFilms above,
        // so filtering here simply narrows that ordered list down to the one selected section
        // without disturbing its relative order. When currentFilmQueueSectionFilter is nil
        // (the "All" filter, or any non-Film-Queue view), every film that reached this point
        // remains and no filtering occurs.
        if case .filmQueue = currentViewID, let sectionFilter = currentFilmQueueSectionFilter {
            loadedFilms = loadedFilms.filter { filmQueueSection(forFilm: $0.id) == sectionFilter }
        }

        // Apply search filtering whenever in the search view.
        // filterFilms() internally handles both the active state (uses currentTokens)
        // and the token-entry state (uses lastConfirmedTokens), so it always returns
        // the correct result set regardless of whether isActive is true or false.
        // Removing the isActive gate here fixes a race where isActive briefly becomes
        // false during token entry (e.g. from a stale debounce timer or from SwiftUI's
        // searchable binding modifying currentTokens), which previously caused
        // this load to skip filterFilms() entirely and show the full library.
        // The original isSearch guard is preserved: non-search views are unaffected.
        if currentViewID.isSearch && SearchController.shared.hasContent {
            loadedFilms = SearchController.shared.filterFilms(loadedFilms) { [weak self] filmID in
                guard let self else { return [] }
                return self.getListNames(forFilm: filmID)
            }
        }

        #if DEBUG
        ViewSwitchProbe.record("load \(currentViewID) films=\(loadedFilms.count) \(Fmt.fixed(Date().timeIntervalSince(startTime) * 1000, 2))ms")
        #endif
        self.films = loadedFilms
        self.filmCount = loadedFilms.count
        self.loadedSortOption = currentSortOption
        self.loadedRecentsCategory = currentViewID.recentsCategory
        self.loadedPurchaseFormat = currentViewID.purchaseFormatScope

        let duration = Date().timeIntervalSince(startTime)
        let searchInfo = currentViewID.isSearch && SearchController.shared.isActive ? " (search active)" : ""
        let membershipInfo: String
        switch currentMembership {
        case .unrestricted: membershipInfo = ""
        case .set: membershipInfo = " (membership filtered)"
        }
        Self.log("Loaded \(filmCount) films for \(currentViewID.description)\(searchInfo)\(membershipInfo) in \(Fmt.fixed(duration * 1000, 1))ms") }

    // MARK: - Film Access
    func getFilm(_ id: UUID) -> FilmSnapshot? {
        return memoryStore.getFilm(id)
    }

    func getAllFilms() -> [FilmSnapshot] { return memoryStore.getAllFilms() }

    /// The films dictionary itself. The Reports tabs' off-main reconciles capture it and
    /// compare it again before applying their rows: a dictionary compares equal in O(1)
    /// when its storage is shared, so "nothing changed meanwhile" costs nothing to confirm.
    func getAllFilmsMap() -> [UUID: FilmSnapshot] { return memoryStore.getAllFilmsMap() }

    /// Returns the names of all lists (user-generated and smart) the given film belongs to.
    /// Used by SearchController.filterFilms for list-field token filtering
    /// without any SwiftData object access.
    func getListNames(forFilm filmID: UUID) -> [String] {
        // User-generated list names. Internal Film Queue lists are excluded so their
        // names never surface in the #list search field (they are not user lists).
        let listIDs = memoryStore.getListIDs(forFilm: filmID)
            .subtracting(FilmQueue.allListIDs)
        var names = listIDs.compactMap { memoryStore.getList($0)?.listName }

        // Smart list names — every smart list whose computed set contains this film, in
        // allCases order. Resolved through getSmartListTypes below rather than by repeating
        // its loop and its Preferences.smartLists gate, which is what this did before: the
        // two asked the identical membership question and had to agree about the gate.
        names.append(contentsOf: getSmartListTypes(forFilm: filmID).map(\.rawValue))

        return names
    }

    /// Every smart list whose computed set currently contains `filmID`, in
    /// `SmartListType.allCases` declaration order (rotation family, then purchased,
    /// unpurchased, alternate-versions, and finally the filtered-library family).
    ///
    /// Returns an empty array when the smart lists feature is switched off — the sets are
    /// not maintained in that state and none of the lists is navigable, so reporting
    /// membership would be both stale and useless. Mirrors the identical gate in
    /// `getListNames(forFilm:)` above, which is the other consumer of this same
    /// membership question.
    ///
    /// Sub-variants are deliberately NOT collapsed into their parents: a film in
    /// "Purchased 4K" is by construction also in "Purchased", and the "Show in List ▸
    /// Smart Lists" submenu (MenuBar / GalleryContextMenu) is expected to offer both as
    /// separate destinations.
    func getSmartListTypes(forFilm filmID: UUID) -> [SmartListType] {
        guard Preferences.smartLists else { return [] }
        return SmartListType.allCases.filter {
            smartLists.filmIDs(for: $0).contains(filmID)
        }
    }

    // MARK: - Film Mutations

    /// Persists scalar property changes for a FilmSnapshot.
    /// Follows the memory-first pattern: MemoryStore is updated immediately for instant UI
    /// responsiveness, then persisted to the background context via DataManager with rollback
    /// on failure. Does not touch mainContext.
    func updateFilm(_ snapshot: FilmSnapshot) async {
        Self.log("Updating film: \(snapshot.name) (ID: \(snapshot.id))")

        let preSnapshot = memoryStore.getFilm(snapshot.id)

        memoryStore.updateFilm(snapshot)

        // Always reload the current view so sort order, filter results, and display
        // values stay consistent with the updated snapshot. When in a list view the
        // film may not be a member of that list, but a reload is still needed because
        // sort-key fields (title, rating, etc.) could have changed for other views.
        refreshFilms()

        // refreshFilms() repaints only DataCoordinator.films. Everything that holds its
        // own copy of a snapshot — the right sidebar's selected film, the Hall of Fame and
        // Wishlist reports — and SmartLists' membership sets are driven by this event, so
        // without it they keep showing the pre-update values. The rollback below posts
        // the same event for the same reason: restoring MemoryStore alone is invisible to
        // every one of those consumers (see applyImportedRatingUpdates).
        AppEventBus.shared.send(.film(.updated(filmID: snapshot.id)))

        trackOperation(
            rollback: { [weak self] in
                guard let self, let pre = preSnapshot else { return }
                self.memoryStore.updateFilm(pre)
                self.refreshFilms()
                AppEventBus.shared.send(.film(.updated(filmID: snapshot.id)))
                Self.log("Rolled back updateFilm for \(snapshot.id)")
            }
        ) { [dataManager] in
            try await dataManager.updateFilm(snapshot)
        }

        Self.log("Film update queued for background persistence: \(snapshot.name)")
    }

    // MARK: - Film Queue Auto-Removal
    /// Removes a film from the Film Queue in real time when a newly-added viewing
    /// event is dated the current calendar day or the day immediately prior. This is
    /// what "marking a film as watched" means for queue-removal purposes — a viewing
    /// entry added well after the fact (a backfilled historical record) does not count,
    /// since watching the film is the reason it was queued in the first place.
    ///
    /// Compares only the entries newly added to calendarTable against its previous
    /// state, so re-saving an unchanged historical entry never triggers removal.
    ///
    /// Called by both `updateViewingDates` (WatchDetails' "Add Viewing Event" quick-add)
    /// and `saveFilmChangeset` (FilmSheet's save path), so the behavior is identical
    /// regardless of which UI surface added the viewing event.
    private func removeFromFilmQueueIfRecentlyWatched(
        filmID: UUID, oldCalendarTable: [String], newCalendarTable: [String]
    ) {
        let addedEntries = Set(newCalendarTable).subtracting(Set(oldCalendarTable))
        guard !addedEntries.isEmpty else { return }

        let calendar = Calendar.current
        let triggersRemoval = addedEntries.contains { entry in
            guard let date = parseDate(from: entry) else { return false }
            return calendar.isDateInToday(date) || calendar.isDateInYesterday(date)
        }
        guard triggersRemoval else { return }

        let queueListIDs = memoryStore.getListIDs(forFilm: filmID).intersection(FilmQueue.allListIDs)
        guard !queueListIDs.isEmpty else { return }

        // Optimistic MemoryStore update — instant UI removal from the queue.
        for listID in queueListIDs {
            memoryStore.removeFilmsFromList(filmIDs: [filmID], listID: listID)
        }
        syncListsCache()
        refreshFilms()

        for listID in queueListIDs {
            AppEventBus.shared.listMembershipChanged(listID)
        }
        Self.log("Film \(filmID) automatically removed from Film Queue (\(queueListIDs.count) list(s)) after a viewing event dated today or yesterday")

        // Persist in background with rollback on failure, mirroring removeFilmsFromList's pattern.
        trackOperation(rollback: { [weak self] in
            guard let self else { return }
            for listID in queueListIDs {
                self.memoryStore.addFilmsToList(filmIDs: [filmID], listID: listID)
            }
            self.syncListsCache()
            self.refreshFilms()
            for listID in queueListIDs {
                AppEventBus.shared.listMembershipChanged(listID)
            }
            Self.log("Rolled back automatic Film Queue removal for film \(filmID)")
        }) { [dataManager] in
            try await dataManager.batchRemoveFilmsFromLists(filmIDs: [filmID], listIDs: queueListIDs)
        }
    }

    /// Updates viewing-related fields (calendarTable, lastWatched, watched) for a film.
    /// Follows the memory-first pattern: MemoryStore is updated immediately for instant UI
    /// responsiveness, then persisted to the background context via DataManager with rollback
    /// on failure. Does not touch mainContext.
    /// Used by WatchDetails for the "Add Viewing Event" action.
    func updateViewingDates(filmID: UUID, calendarTable: [String], lastWatched: String, watched: Bool) {
        guard var snapshot = memoryStore.getFilm(filmID) else {
            Self.log("WARNING: updateViewingDates called for unknown film \(filmID)")
            return
        }

        // Capture pre-mutation state for rollback
        let preSnapshot = snapshot

        // Apply new values to the snapshot copy (instant UI)
        snapshot.calendarTable = calendarTable
        // Derived exactly as FilmSheet.assembleFilm derives it. Every display reads
        // calendarTable.count, so a stale stored count hid here and surfaced only in
        // backups and exports, which write Film.viewCount verbatim.
        snapshot.viewCount = calendarTable.count
        snapshot.lastWatched = lastWatched
        snapshot.watched = watched
        snapshot.lastModified = StorageDateFormatters.timestamp.format(Date())

        // Sync MemoryStore
        memoryStore.updateFilm(snapshot)

        // Reload view
        refreshFilms()

        // Post UI event immediately
        AppEventBus.shared.send(.film(.updated(filmID: filmID)))

        // Persist in background with rollback on failure
        trackOperation(
            rollback: { [weak self] in
                guard let self else { return }
                self.memoryStore.restoreFilm(filmID: filmID, from: preSnapshot)
                self.refreshFilms()
                // Same event the forward path posted, so the sidebar's copied snapshot
                // and SmartLists' membership follow the restore rather than keeping the
                // rolled-back viewing entry.
                AppEventBus.shared.send(.film(.updated(filmID: filmID)))
                Self.log("Rolled back viewing date update for film \(filmID)")
            }
        ) { [dataManager, snapshot] in
            try await dataManager.updateFilm(snapshot)
        }

        // Real-time Film Queue removal: if this newly-added viewing event is dated
        // today or yesterday, treat the film as just-watched and remove it from the
        // queue if it's currently a member. No-op if the film isn't queued or if the
        // update didn't add a qualifying entry (e.g. a purely historical backfill).
        removeFromFilmQueueIfRecentlyWatched(
            filmID: filmID,
            oldCalendarTable: preSnapshot.calendarTable,
            newCalendarTable: calendarTable
        )
    }

    /// Deletes films from MemoryStore immediately (optimistic), then dispatches to DataManager
    /// for background persistence. On failure, films are restored to MemoryStore with rollback.
    ///
    /// - Parameter onPersisted: Run once the deletion has actually COMMITTED to SwiftData,
    ///   and never when the rollback path is taken. Exists for side effects that cannot be
    ///   undone — specifically FilmManager's poster-file cleanup, which previously ran on
    ///   the caller's straight-line path immediately after this (non-throwing) method
    ///   returned. Because the return only means "applied to MemoryStore", a failed persist
    ///   restored every FilmSnapshot while the poster JPEGs had already been erased from
    ///   disk and evicted from PosterCache, leaving the recovered films permanently
    ///   posterless behind an alert claiming the deletion was undone.
    func deleteFilms(withIDs ids: Set<UUID>,
                     onPersisted: (@MainActor () -> Void)? = nil) async {
        // Capture pre-deletion state for rollback
        let preSnapshots = ids.compactMap { memoryStore.getFilm($0) }
        let preListMemberships: [UUID: Set<UUID>] = ids.reduce(into: [:]) { result, id in
            result[id] = memoryStore.getListIDs(forFilm: id)
        }

        // Every current Hall of Fame member's position, captured before the deletion so a
        // failed persist can restore the exact pre-deletion ranking — both the removed
        // films' own positions and the compaction applied to the survivors below. Skipped
        // entirely (left empty) when no film being deleted is actually ranked, which is the
        // overwhelmingly common case.
        let deletingRankedMember = preSnapshots.contains { $0.hofPosition > 0 }
        let preHofPositions: [UUID: Int] = deletingRankedMember
            ? memoryStore.hallOfFameFilms.reduce(into: [:]) { result, id in
                result[id] = memoryStore.getFilm(id)?.hofPosition ?? 0
              }
            : [:]

        // Optimistic MemoryStore deletion. Returns the surviving Hall of Fame members whose
        // position shifted when the ranking was compacted, so those position updates can be
        // committed alongside the deletion below rather than silently diverging from
        // SwiftData until the next slow-path load.
        let compactedHofIDs = memoryStore.deleteFilms(ids: ids)
        let compactedHofSnapshots = compactedHofIDs.compactMap { memoryStore.getFilm($0) }
        if !compactedHofSnapshots.isEmpty {
            Self.log("Compacted Hall of Fame positions for \(compactedHofSnapshots.count) surviving member(s)")
        }
        totalFilmCount = memoryStore.totalFilmCount
        // Refresh cachedLists when any deleted film belonged to a user list. memoryStore
        // .deleteFilms() already pruned those films from each list's filmIDs set, but
        // cachedLists (the sidebar's [ListInfo] source of truth, which carries filmCount)
        // is rebuilt only by syncListsCache(). Without this, a list emptied or shrunk by a
        // film deletion keeps a stale filmCount — which, e.g., leaves the "Clear/Delete List
        // Contents" context-menu items incorrectly enabled. The rollback closure below already
        // syncs for the same reason; this mirrors it on the forward path.
        if preListMemberships.contains(where: { !$0.value.isEmpty }) {
            syncListsCache()
        }
        refreshFilms()
        Self.log("Deleted \(ids.count) film(s) from MemoryStore (optimistic)")

        trackOperation(
            rollback: { [weak self] in
                guard let self else { return }
                // Restore film snapshots
                for snapshot in preSnapshots {
                    self.memoryStore.addFilm(snapshot)
                }
                // Restore list memberships
                for (filmID, listIDs) in preListMemberships {
                    for listID in listIDs {
                        self.memoryStore.addFilmsToList(filmIDs: [filmID], listID: listID)
                    }
                }
                if preListMemberships.contains(where: { !$0.value.isEmpty }) {
                    self.syncListsCache()
                }
                // Undo the ranking compaction. Applied after the snapshots are restored
                // above, because a position can only be written to a film the store holds.
                // One batched call so the ordered list is rebuilt once rather than per film.
                self.memoryStore.restoreHofPositions(preHofPositions)
                self.totalFilmCount = self.memoryStore.totalFilmCount
                self.refreshFilms()
                // FilmManager broadcast `.deleted` when the deletion was applied, and
                // SmartLists dropped these films from every membership set on that
                // signal. Restoring the store alone would leave them absent from every
                // smart list until the next full recalculation, so announce them the
                // way any other newly present film is announced.
                for snapshot in preSnapshots {
                    AppEventBus.shared.filmAdded(snapshot.id)
                }
                Self.log("Rolled back deletion of \(preSnapshots.count) film(s)")
            }
        ) { [dataManager] in
            try await dataManager.deleteFilms(withIDs: ids)
            Self.log("Deleted \(ids.count) film(s) via DataManager")

            // Committed after the deletion, in the same tracked operation, so the
            // persisted ranking matches the compacted in-memory one and a failure of
            // either takes the one rollback. Ordering is required: updateFilms skips films
            // it cannot find, so running this first would write positions that the delete
            // then discards. Both calls end in a save() on the
            // same background context, so their failure modes are the same store-level
            // fault; in the narrow case where the delete commits and this does not, the
            // rollback re-adds films SwiftData no longer has, and the resulting snapshot
            // fingerprint mismatch forces a full re-read on the next launch, which
            // reconciles memory with the database.
            if !compactedHofSnapshots.isEmpty {
                try await dataManager.updateFilms(compactedHofSnapshots)
                Self.log("Persisted \(compactedHofSnapshots.count) compacted Hall of Fame position(s)")
            }

            // Deletion has committed. Only now is it safe to run irreversible cleanup.
            // Placed last inside the work closure so any throw above skips it and lets the
            // rollback restore intact films. The work runs off the main actor (see
            // trackOperation), so this hops to it; the work does not finish until it has run.
            await onPersisted?()
        }
    }

    /// The default rotation threshold the derived rotation state was last computed with.
    private var lastKnownDefaultRotationThreshold = Preferences.defaultRotationThreshold
    /// The refresh started by the latest threshold change; a newer change cancels it.
    @ObservationIgnored private var rotationThresholdRefresh: Task<Void, Never>?

    /// Brings every piece of state derived from `Preferences.defaultRotationThreshold`
    /// up to date after it changes: MetadataCache rotation dates (the "Recently Come Up
    /// for Rotation" list and its subtitles) and the "Up for Rotation" smart lists.
    /// Called for every `preferencesChanged` event; a no-op unless the value moved.
    /// The heavy work (metadata entries, smart-list sets) runs off the main actor; only
    /// applying the results and the reload come back to it.
    func handleDefaultRotationThresholdChangeIfNeeded() {
        let current = Preferences.defaultRotationThreshold
        guard current != lastKnownDefaultRotationThreshold else { return }
        lastKnownDefaultRotationThreshold = current
        // Before initialization the startup rebuild/validation reads the new value itself.
        guard memoryStore.isInitialized else { return }
        Self.log("Default rotation threshold changed to \(current) — refreshing rotation-derived state")
        rotationThresholdRefresh?.cancel()
        rotationThresholdRefresh = Task { [weak self] in
            guard let self else { return }
            await self.memoryStore.refreshRotationDerivedMetadata()
            guard !Task.isCancelled else { return }
            self.smartLists.forceFullRecalculation()
            // A full reload rather than refreshFilms(): Recents takes its ordering from
            // loadFilms' recentsOrder, which refreshFilms() does not re-supply.
            ViewStateManager.shared.forceReload()
        }
    }

    /// Resets all rotation threshold overrides to nil (use global default).
    ///
    /// Follows the same DTO / memory-first pattern used by other mutation operations:
    ///   1. Identify affected films from MemoryStore.
    ///   2. Capture each affected film's pre-mutation value of the reset field.
    ///   3. Apply optimistic mutation to MemoryStore so the UI updates immediately.
    ///   4. Dispatch background persistence to DataManager via trackOperation.
    ///      If persistence fails the rollback closure restores that one field on every
    ///      affected film in MemoryStore and the user is alerted.
    func resetAllRotationThresholdOverrides() {
        let filmsWithOverrides = memoryStore.getAllFilms()
            .filter { $0.rotationThresholdOverride != nil }

        guard !filmsWithOverrides.isEmpty else {
            Self.log("resetAllRotationThresholdOverrides: no overrides found - nothing to do")
            return
        }

        Self.log("Resetting rotation threshold overrides for \(filmsWithOverrides.count) film(s)...")

        // Capture IDs and pre-mutation values before touching anything.
        let targetIDs = Set(filmsWithOverrides.map(\.id))
        let preOverrides: [UUID: Int?] = Dictionary(
            filmsWithOverrides.map { ($0.id, $0.rotationThresholdOverride) },
            uniquingKeysWith: { first, _ in first }
        )

        // Optimistic MemoryStore update — makes the UI reflect the change instantly.
        for var snapshot in filmsWithOverrides {
            snapshot.rotationThresholdOverride = nil
            memoryStore.updateFilm(snapshot)
        }
        refreshFilms()

        // Rotation threshold overrides directly affect "Up for Rotation" membership.
        // Trigger a forced full recalculation so the smart list reflects the new effective
        // thresholds immediately — bypassing the daily sentinel that would otherwise
        // prevent recomputation if the reset happens on the same day as the last refresh.
        smartLists.forceFullRecalculation()

        // Rollback: restore the one field this reset changed on every mutated film. Only
        // that field, not the whole pre-reset snapshot: an operation dispatched after this
        // one may already have changed another field of the same film in memory, and its
        // write still commits after this rollback — restoring the whole snapshot would
        // erase that change from memory while the database keeps it.
        let rollback: () -> Void = { [weak self] in
            guard let self else { return }
            Self.log("Rolling back rotation threshold override reset for \(preOverrides.count) film(s)")
            for (id, value) in preOverrides {
                guard var current = self.memoryStore.getFilm(id) else { continue }
                current.rotationThresholdOverride = value
                self.memoryStore.updateFilm(current)
            }
            self.refreshFilms()
            self.smartLists.forceFullRecalculation()
        }

        trackOperation(rollback: rollback) { [dataManager] in
            try await dataManager.resetRotationThresholdOverrides(for: targetIDs)
            Self.log("Reset complete - updated \(targetIDs.count) film(s) in background context")
        }
    }

    /// Resets the `infoComplete` flag to `false` for every film in the library.
    ///
    /// Follows the identical DTO / memory-first pattern used by
    /// `resetAllRotationThresholdOverrides()`:
    ///   1. Identify affected films from MemoryStore.
    ///   2. Capture each affected film's pre-mutation value of the reset field.
    ///   3. Apply optimistic mutation to MemoryStore so the UI updates immediately.
    ///   4. Dispatch background persistence to DataManager via trackOperation.
    ///      If persistence fails the rollback closure restores that one field on every
    ///      affected film in MemoryStore and the user is alerted.
    func resetAllInfoCompleteFlags() {
        let filmsWithFlag = memoryStore.getAllFilms()
            .filter { $0.infoComplete }

        guard !filmsWithFlag.isEmpty else {
            Self.log("resetAllInfoCompleteFlags: no films with infoComplete == true — nothing to do")
            return
        }

        Self.log("Resetting infoComplete flag for \(filmsWithFlag.count) film(s)...")

        // Capture IDs before touching anything. Every targeted film's pre-reset value is
        // `true` by the filter above, so the IDs alone are the rollback baseline.
        let targetIDs = Set(filmsWithFlag.map(\.id))

        // Optimistic MemoryStore update — makes the UI reflect the change instantly.
        for var snapshot in filmsWithFlag {
            snapshot.infoComplete = false
            memoryStore.updateFilm(snapshot)
        }
        refreshFilms()

        // Rollback: set the flag back on every mutated film, and only the flag — see the
        // rollback in resetAllRotationThresholdOverrides() for why not the whole snapshot.
        let rollback: () -> Void = { [weak self] in
            guard let self else { return }
            Self.log("Rolling back infoComplete reset for \(targetIDs.count) film(s)")
            for id in targetIDs {
                guard var current = self.memoryStore.getFilm(id) else { continue }
                current.infoComplete = true
                self.memoryStore.updateFilm(current)
            }
            self.refreshFilms()
        }

        trackOperation(rollback: rollback) { [dataManager] in
            try await dataManager.resetInfoCompleteFlags(for: targetIDs)
            Self.log("resetAllInfoCompleteFlags: updated \(targetIDs.count) film(s) in background context")
        }
    }

    // MARK: - Atomic Film Changeset (FilmSheet)

    /// Persists all FilmSheet changes via the background-context-only path.
    ///
    /// Flow:
    ///   1. Capture pre-mutation state for rollback
    ///   2. Compute final releases array from current MemoryStore state + deltas
    ///   3. Apply scalar Film properties + releases to MemoryStore (instant UI)
    ///   4. Apply list membership changes to MemoryStore (instant UI)
    ///   5. Reload the current view and post UI events
    ///   6. Dispatch full FilmChangeset to DataManager via trackOperation (background)
    ///   7. On failure: rollback MemoryStore changes and alert user
    ///
    /// No mainContext operations are performed. DataManager handles all persistence
    /// (Film scalars, releases, and list memberships) atomically in its background context.
    func saveFilmChangeset(_ changeset: FilmChangeset) {
        let filmID = changeset.filmID

        // Capture pre-mutation state for rollback
        let preFilmSnapshot: FilmSnapshot? = changeset.isNewFilm ? nil : memoryStore.getFilm(filmID)

        // Step 1: Compute the final releases array for MemoryStore.
        // FilmSheet builds FilmSnapshot via the manual initializer (releases defaults to []).
        // The actual release state is derived from the current MemoryStore snapshot + deltas.
        let finalReleases: [ReleaseSnapshot]
        if changeset.isNewFilm {
            // New film: all releases come from the create delta.
            finalReleases = changeset.releasesToCreate
        } else {
            // Existing film: start from current MemoryStore releases, apply deltas.
            var releases = preFilmSnapshot?.releases ?? []
            releases = releases.filter { !changeset.releasesToDelete.contains($0.id) }
            releases = releases.map { existing in
                changeset.releasesToUpdate.first(where: { $0.id == existing.id }) ?? existing
            }
            releases.append(contentsOf: changeset.releasesToCreate)
            finalReleases = releases
        }

        // Step 2: Build the MemoryStore snapshot with the computed releases. The derived
        // values (lastWatched, viewCount, lastModified, numberOfDiscs) are already final
        // in filmSnapshot — FilmSheet recomputes them from the merged calendar table.
        var snapshot = changeset.filmSnapshot
        snapshot.releases = finalReleases

        // Step 3: Apply scalar Film changes to MemoryStore (instant UI)
        if changeset.isNewFilm {
            memoryStore.addFilm(snapshot)
            totalFilmCount = memoryStore.totalFilmCount
            Self.log("Added new film \(filmID) to MemoryStore")
        } else {
            memoryStore.updateFilm(snapshot)
            Self.log("Updated film \(filmID) in MemoryStore")
        }

        // Step 4: Apply list membership changes to MemoryStore (instant UI)
        if !changeset.listsToAdd.isEmpty {
            for listID in changeset.listsToAdd {
                memoryStore.addFilmsToList(filmIDs: [filmID], listID: listID)
            }
            Self.log("Added film \(filmID) to \(changeset.listsToAdd.count) list(s) in MemoryStore")
        }
        if !changeset.listsToRemove.isEmpty {
            for listID in changeset.listsToRemove {
                memoryStore.removeFilmsFromList(filmIDs: [filmID], listID: listID)
            }
            Self.log("Removed film \(filmID) from \(changeset.listsToRemove.count) list(s) in MemoryStore")
        }
        // Sync cachedLists once after all membership changes so LeftSidebar film counts
        // update in the same frame as the film save.
        if !changeset.listsToAdd.isEmpty || !changeset.listsToRemove.isEmpty {
            syncListsCache()
        }

        // Step 5: Reload and post UI events
        refreshFilms()

        // Guard the upcoming .film event posts so that if this same save also causes
        // the film to newly qualify for "Up for Rotation", autoEnqueueFilmsNewlyUpForRotation
        // (triggered synchronously via SmartLists' filmEvents subscriber) does not
        // override a Film Queue section the user just explicitly chose via the picker.
        // See explicitQueueChangeFilmIDs' declaration for the full rationale. Scoped
        // tightly to just the .film event sends below — the only events that reach
        // SmartLists' filmEvents subscriber — and cleared immediately after, so it has
        // no effect on anything else this method does (list-event posts, persistence
        // dispatch, or the recently-watched auto-removal check at the end of this method).
        let touchesQueueExplicitly = !changeset.listsToAdd.isDisjoint(with: FilmQueue.allListIDs)
            || !changeset.listsToRemove.isDisjoint(with: FilmQueue.allListIDs)
        if touchesQueueExplicitly {
            explicitQueueChangeFilmIDs.insert(filmID)
        }

        if changeset.isNewFilm {
            AppEventBus.shared.send(.film(.added(filmID: filmID)))
        } else {
            AppEventBus.shared.send(.film(.updated(filmID: filmID)))
        }

        let hasReleaseChanges = !changeset.releasesToCreate.isEmpty
            || !changeset.releasesToUpdate.isEmpty
            || !changeset.releasesToDelete.isEmpty
        if hasReleaseChanges {
            AppEventBus.shared.send(.film(.releaseChanged(filmID: filmID)))
        }

        if touchesQueueExplicitly {
            explicitQueueChangeFilmIDs.remove(filmID)
        }

        for listID in changeset.listsToAdd {
            AppEventBus.shared.listMembershipChanged(listID)
        }
        for listID in changeset.listsToRemove {
            AppEventBus.shared.listMembershipChanged(listID)
        }

        // Drives the LeftSidebar Queue row's completion glyph for an explicit Film
        // Queue assignment made via the FilmSheet's "Up Next" picker — additions only,
        // mirroring the identical drag-and-drop path in FilmManager.addFilmsToList.
        for listID in changeset.listsToAdd where FilmQueue.isInternalList(listID) {
            AppEventBus.shared.send(.list(.queueAdditionCompleted(listID: listID)))
        }

        // Step 6: Dispatch full changeset to DataManager with rollback.
        // DataManager handles Film scalars, all release mutations, and list memberships
        // atomically in a single background save. No mainContext is involved.
        trackOperation(
            rollback: { [weak self] in
                guard let self else { return }
                Self.log("Rolling back MemoryStore for film \(filmID)")

                if changeset.isNewFilm {
                    self.memoryStore.deleteFilms(ids: [filmID])
                    self.totalFilmCount = self.memoryStore.totalFilmCount
                } else if let preSnapshot = preFilmSnapshot {
                    self.memoryStore.restoreFilm(filmID: filmID, from: preSnapshot)
                }

                // Rollback list membership changes
                for listID in changeset.listsToAdd {
                    self.memoryStore.removeFilmsFromList(filmIDs: [filmID], listID: listID)
                }
                for listID in changeset.listsToRemove {
                    self.memoryStore.addFilmsToList(filmIDs: [filmID], listID: listID)
                }
                if !changeset.listsToAdd.isEmpty || !changeset.listsToRemove.isEmpty {
                    self.syncListsCache()
                }

                self.refreshFilms()

                // The forward path announced the film as added or updated; the rollback
                // must announce the reverse, or the sidebar's copied snapshot and
                // SmartLists' membership keep describing the save that never committed.
                if changeset.isNewFilm {
                    AppEventBus.shared.filmsDeleted([filmID])
                } else {
                    AppEventBus.shared.send(.film(.updated(filmID: filmID)))
                }
                if hasReleaseChanges {
                    AppEventBus.shared.send(.film(.releaseChanged(filmID: filmID)))
                }

                Self.log("Rollback complete for film \(filmID)")
            }
        ) { [dataManager] in
            try await dataManager.applyFilmChangeset(changeset)
        }

        // Real-time Film Queue removal: if the FilmSheet save added a viewing event
        // dated today or yesterday, treat the film as just-watched and remove it from
        // the queue if it's currently a member. Skipped when this same save's picker
        // action explicitly added queue membership (changeset.listsToAdd intersects
        // FilmQueue.allListIDs) — explicit intent from the picker wins over the
        // implicit auto-removal in that same-save combo. (trackOperation executes in
        // dispatch order, so the add inside applyFilmChangeset above always commits
        // before the removal below would; the guard is about intent, not ordering.)
        // No-op for new films, since they cannot already hold queue membership.
        let explicitlyAddedToQueue = !changeset.listsToAdd.isDisjoint(with: FilmQueue.allListIDs)
        if !explicitlyAddedToQueue {
            removeFromFilmQueueIfRecentlyWatched(
                filmID: filmID,
                oldCalendarTable: preFilmSnapshot?.calendarTable ?? [],
                newCalendarTable: changeset.filmSnapshot.calendarTable
            )
        }
    }

    // MARK: - List Operations
    // Note: List membership uses DataManager (@ModelActor) because:
    // 1. ListMembership is a separate entity (not a Film relationship handled by FSTabReleases)
    // 2. Batch operations benefit from background processing
    // 3. FilmSnapshot doesn't affect list membership operations

    func batchUpdateListOrders(_ updates: [(listID: UUID, displayOrder: Int)]) {
        guard !updates.isEmpty else { return }

        // Capture pre-state for rollback
        let preLists: [(listID: UUID, displayOrder: Int)] = updates.compactMap { update in
            guard let list = memoryStore.getList(update.listID) else { return nil }
            return (listID: update.listID, displayOrder: list.displayOrder)
        }

        // Optimistic MemoryStore update — all display orders applied in one pass
        for update in updates {
            memoryStore.updateList(listID: update.listID, name: nil,
                displayOrder: update.displayOrder, sortFilterOptions: nil)
        }
        syncListsCache()

        // Single tracked operation for the entire batch — one background save, one rollback surface
        trackOperation(rollback: { [weak self] in
            guard let self else { return }
            for pre in preLists {
                self.memoryStore.updateList(listID: pre.listID, name: nil,
                    displayOrder: pre.displayOrder, sortFilterOptions: nil)
            }
            self.syncListsCache()
        }) { [dataManager] in
            try await dataManager.batchUpdateListOrders(updates)
        }
    }

    /// Rebuilds cachedLists from MemoryStore — an O(N) in-memory map with no I/O.
    /// Called synchronously at every list mutation site so LeftSidebar's @Observable
    /// subscription delivers the updated array in the same SwiftUI update cycle.
    private func syncListsCache() {
        cachedLists = memoryStore.getAllLists().map {
            ListInfo(listID: $0.listID, listName: $0.listName,
                     filmCount: $0.filmIDs.count, displayOrder: $0.displayOrder)
        }
    }

    func getAllLists() -> [MemoryList] { return memoryStore.getAllLists() }

    func getList(_ id: UUID) -> MemoryList? { return memoryStore.getList(id) }

    func getListIDs(forFilm filmID: UUID) -> Set<UUID> {
        return memoryStore.getListIDs(forFilm: filmID) }

    /// The film's user-generated lists, resolved and ordered — the single accessor behind
    /// every surface that DISPLAYS a film's list membership: the "Show in List" menus (via
    /// SelectionMenuModel.listsContaining) and the Right Sidebar's List Membership table.
    ///
    /// Internal Film Queue lists are excluded; the FilmSheet intentionally uses the
    /// unfiltered getListIDs(forFilm:) so it can detect and manage the film's Up Next
    /// section separately.
    ///
    /// The membership is a Set, so its order is not merely unspecified but genuinely
    /// unstable between calls. Every consumer therefore had to sort — and each
    /// sorted by displayOrder alone, without the listID tiebreak `getAllLists()` applies,
    /// so two lists sharing a displayOrder could be presented in a different order by the
    /// menu, the membership table, and the sidebar, and in a different order again on the
    /// next render. Ordering here, once, by MemoryList.orderedBefore removes that.
    func userLists(forFilm filmID: UUID) -> [MemoryList] {
        memoryStore.getListIDs(forFilm: filmID)
            .subtracting(FilmQueue.allListIDs)
            .compactMap { memoryStore.getList($0) }
            .sorted(by: MemoryList.orderedBefore)
    }

    // MARK: - Film Queue

    /// Ensures the three internal Film Queue lists exist in both MemoryStore and the
    /// persistent store. Called once during startup (finalizeInitialization). Idempotent:
    /// on every launch after the first, the lists are already present (loaded from the
    /// snapshot cache or SwiftData) and this method does nothing.
    ///
    /// Crash-safety: the in-memory create and the SwiftData insert are consistent with the
    /// snapshot-cache fingerprint (which counts ListObjects and ListMemberships from both
    /// sides). If the app is interrupted between the two writes in any order, the next
    /// launch's fingerprint check falls back to the slow SwiftData path, and this method
    /// then re-creates whatever is missing — so the queue is always self-healing and never
    /// left in a divergent state. A failed persist is logged (not surfaced as an alert) and
    /// retried on the next launch for the same reason.
    private func ensureFilmQueueListsExist() async {
        for section in FilmQueueSection.allCases {
            guard memoryStore.getList(section.listID) == nil else { continue }

            let order = FilmQueue.displayOrder(for: section)
            memoryStore.createInternalList(listID: section.listID,
                name: section.displayName, displayOrder: order)

            do {
                try await dataManager.createList(listID: section.listID,
                    name: section.displayName, displayOrder: order)
                Self.log("Bootstrapped internal Up Next list '\(section.displayName)'")
            } catch {
                Self.log("WARNING: Failed to persist internal Up Next list '\(section.displayName)': \(error) — will retry next launch")
            }
        }
    }

    /// Called by SmartLists whenever the "Up for Rotation" smart list gains new members
    /// (either from the daily midnight refresh or a full recalculation). For every film
    /// that just became up for rotation and has `autoAddToQueueOnRotation` set (non-nil),
    /// this adds the film to the corresponding internal Film Queue section — "Up Next"
    /// (0), "Soon" (1), or "Later" (2), matching `FilmQueueSection.queueOrder`.
    ///
    /// Films are grouped by target section and added via `addFilmsToList`, which
    /// already enforces Film Queue mutual exclusivity and persists in the background with
    /// rollback — so a film manually moved into a different section after this call is
    /// never fought over. Films with a nil `autoAddToQueueOnRotation` (the default,
    /// meaning the feature is disabled for that film) are skipped entirely, and a film
    /// already present in its target section is a harmless no-op via the existing
    /// idempotent add path.
    ///
    /// Films present in `explicitQueueChangeFilmIDs` are skipped even if otherwise
    /// eligible: that set is populated only for the narrow duration of a FilmSheet save
    /// whose changeset explicitly set the same film's Film Queue membership, so this
    /// guarantees the user's explicit picker choice always wins over this same save's
    /// auto-enqueue trigger. See that property's declaration for the full rationale.
    func autoEnqueueFilmsNewlyUpForRotation(_ newlyUpForRotation: Set<UUID>) {
        var eligibleFilmIDs = newlyUpForRotation.subtracting(explicitQueueChangeFilmIDs)
        if eligibleFilmIDs.count != newlyUpForRotation.count {
            Self.log("Skipped auto-enqueue for \(newlyUpForRotation.count - eligibleFilmIDs.count) film(s) — Film Queue section was just explicitly set in the same save")
        }

        // Never touch a film that is already in the Film Queue. `addFilmsToList`
        // enforces queue mutual exclusivity, so adding an already-queued film does not merely
        // no-op — it MOVES that film out of whichever section it currently occupies and into
        // the one `autoAddToQueueOnRotation` names. For a film the user deliberately dragged
        // from "Up Next" to "Later", that silently reverses their decision.
        //
        // A film's presence in the queue means its placement has already been settled, either
        // by an earlier auto-enqueue or by the user directly. Either way there is nothing for
        // this method to decide, and the user's arrangement is preserved unconditionally.
        let alreadyQueued = eligibleFilmIDs.intersection(memoryStore.filmQueueFilmIDs())
        if !alreadyQueued.isEmpty {
            eligibleFilmIDs.subtract(alreadyQueued)
            Self.log("Skipped auto-enqueue for \(alreadyQueued.count) film(s) — already present in the Film Queue; existing placement preserved")
        }

        guard !eligibleFilmIDs.isEmpty else { return }

        var filmIDsBySection: [FilmQueueSection: Set<UUID>] = [:]
        for filmID in eligibleFilmIDs {
            guard let film = memoryStore.getFilm(filmID),
                  let order = film.autoAddToQueueOnRotation,
                  let section = FilmQueueSection.allCases.first(where: { $0.queueOrder == order }) else { continue }
            filmIDsBySection[section, default: []].insert(filmID)
        }
        guard !filmIDsBySection.isEmpty else { return }

        // "Up Next" holds at most FilmQueue.upNextCapacity films. With no user present to
        // be told, what doesn't fit goes to "Soon" rather than being dropped; the films
        // that do fit are chosen by title, so the split is the same every time.
        if let upNext = filmIDsBySection[.upNext] {
            let vacancies = max(0, FilmQueue.upNextCapacity
                - (memoryStore.getList(FilmQueueSection.upNext.listID)?.filmIDs.count ?? 0))
            if upNext.count > vacancies {
                let ordered = upNext.sorted {
                    let lhs = memoryStore.getFilm($0)?.name ?? "", rhs = memoryStore.getFilm($1)?.name ?? ""
                    return lhs == rhs ? $0.uuidString < $1.uuidString
                        : lhs.localizedStandardCompare(rhs) == .orderedAscending
                }
                let fitting = Set(ordered.prefix(vacancies))
                filmIDsBySection[.upNext] = fitting.isEmpty ? nil : fitting
                filmIDsBySection[.soon, default: []].formUnion(upNext.subtracting(fitting))
                Self.log("Auto-enqueue: 'Up Next' had room for \(vacancies) of \(upNext.count) film(s); the rest go to 'Soon'")
            }
        }

        for (section, filmIDs) in filmIDsBySection {
            addFilmsToList(filmIDs: filmIDs, listID: section.listID)
            Self.log("Auto-enqueued \(filmIDs.count) film(s) newly up for rotation into '\(section.displayName)'")
        }
    }

    /// Returns the union of film IDs across all three internal Film Queue lists.
    /// Exposed for the Film Queue gallery UI.
    func getFilmQueueFilmIDs() -> Set<UUID> {
        return memoryStore.filmQueueFilmIDs() }

    /// Returns the canonical Up Next section for a film — the section with the lowest queueOrder
    /// among the film's internal-list memberships — or nil if the film is not in the queue at
    /// all. This canonical rule matches MemoryStore.filmQueueSectionGroupedIDs(sortOption:direction:)
    /// exactly, so the Film Queue gallery's section-divider break points always agree with the
    /// section grouping the film list itself was built with. Used by GallerySubview.Coordinator
    /// to detect section transitions when computing divider breaks.
    func filmQueueSection(forFilm filmID: UUID) -> FilmQueueSection? {
        let internalIDs = memoryStore.getListIDs(forFilm: filmID).intersection(FilmQueue.allListIDs)
        return internalIDs
            .compactMap { FilmQueueSection(listID: $0) }
            .min { $0.queueOrder < $1.queueOrder }
    }

    /// Returns every internal Film Queue list ID a film currently belongs to — as
    /// opposed to `filmQueueSection(forFilm:)`, which resolves only the single canonical
    /// section. Under normal operation these will never differ, since every add path
    /// self-heals to guarantee mutual exclusivity; this exists so removal call sites
    /// can be corruption-proof against a film left in more than one section by a
    /// corrupted or pre-exclusivity backup restore.
    func filmQueueListIDs(forFilm filmID: UUID) -> Set<UUID> {
        memoryStore.getListIDs(forFilm: filmID).intersection(FilmQueue.allListIDs)
    }

    func filmExists(filmID: UUID, inList listID: UUID) -> Bool {
        return memoryStore.filmExists(filmID: filmID, inList: listID) }

    /// Enforces the Film Queue's mutual-exclusivity invariant: a film may belong to
    /// at most one of the three internal sections ("Up Next", "Soon", "Later") at a
    /// time. Called before any film is added to an internal Film Queue list, so that
    /// the add always leaves each affected film in exactly one section.
    ///
    /// The FilmSheet Details tab (FSTabDetails) already self-heals this invariant via its
    /// own delta computation, since `selectedFilmQueueSection` is a single-select control —
    /// it can only ever request membership in one section, and its save path removes the
    /// film from any other internal list first. This helper closes the same gap for every
    /// OTHER add path, most notably the LeftSidebar's "Film Queue" drop target, which
    /// previously performed a plain add with no awareness of a film's existing section
    /// membership — allowing a dropped film to end up in two sections simultaneously.
    ///
    /// No-op (and cheap to call unconditionally) whenever `targetListID` is not one of
    /// the three internal lists, so ordinary user-generated list adds are unaffected.
    ///
    /// PERSISTENCE IS NOT DISPATCHED HERE. This method applies only the optimistic
    /// MemoryStore side and RETURNS what it removed; the caller folds that into the same
    /// `trackOperation` as the add that follows. It used to own a `trackOperation` of its
    /// own, which made a queue move two independent background writes with two independent
    /// rollbacks — and left a real gap between them:
    ///
    ///   • The removal committed and the add then failed. The add's rollback undid only the
    ///     add, so the film was left in NO section at all: SwiftData had already lost its
    ///     old membership, and nothing was tracking that loss as reversible.
    ///   • A failure in either half raised its own persistence alert, so one user gesture
    ///     could produce two.
    ///
    /// Returning the removal map instead makes the whole move one unit of work with one
    /// rollback surface (see `listAddRollback`) and — because the caller routes it through
    /// `DataManager.moveFilmsBetweenLists` — one database transaction, so the intermediate
    /// state where the film has left its old section but not yet joined its new one is
    /// never committed at all.
    ///
    /// - Returns: The films removed from each OTHER internal section, keyed by that
    ///   section's list ID. Empty when nothing needed reconciling, or when `targetListID`
    ///   is an ordinary user list.
    private func enforceFilmQueueExclusivity(filmIDs: Set<UUID>,
                                             addingTo targetListID: UUID) -> [UUID: Set<UUID>] {
        guard FilmQueue.isInternalList(targetListID) else { return [:] }
        let otherSections = FilmQueue.allListIDs.subtracting([targetListID])
        guard !otherSections.isEmpty else { return [:] }

        // Map each OTHER internal list to the subset of the incoming filmIDs that must
        // be removed from it before (or alongside) the add to targetListID proceeds.
        var removalsByList: [UUID: Set<UUID>] = [:]
        for filmID in filmIDs {
            let currentInternalMemberships = memoryStore.getListIDs(forFilm: filmID).intersection(otherSections)
            for listID in currentInternalMemberships {
                removalsByList[listID, default: []].insert(filmID)
            }
        }
        guard !removalsByList.isEmpty else { return [:] }

        // Optimistic MemoryStore removal — instant UI update, mirroring every other
        // Film Queue membership mutation in this file.
        for (listID, ids) in removalsByList {
            memoryStore.removeFilmsFromList(filmIDs: ids, listID: listID)
        }
        syncListsCache()
        refreshFilms()
        for listID in removalsByList.keys {
            AppEventBus.shared.listMembershipChanged(listID)
        }
        Self.log("Enforced Film Queue exclusivity: removed film(s) from \(removalsByList.count) other section(s) before adding to \(targetListID)")

        return removalsByList
    }

    /// The memory-side reversal of one add-to-list operation, including any Film Queue
    /// exclusivity removals folded into the same tracked operation.
    ///
    /// Undoes the add first and then restores the source
    /// sections, which is the reverse of the order they were applied in; because the lists
    /// are disjoint by construction the order does not affect the result, but keeping it
    /// reversed makes the closure readable as a straight unwind.
    ///
    /// Both halves are optional: an add of films that were all already members has nothing
    /// to remove, and an ordinary user-list add has nothing to restore. When both are empty
    /// the closure does nothing at all rather than posting a spurious refresh.
    private func listAddRollback(newlyAdded: Set<UUID>, listID: UUID,
                                 restoring removals: [UUID: Set<UUID>]) -> () -> Void {
        return { [weak self] in
            guard let self else { return }
            guard !newlyAdded.isEmpty || !removals.isEmpty else { return }

            if !newlyAdded.isEmpty {
                self.memoryStore.removeFilmsFromList(filmIDs: newlyAdded, listID: listID)
            }
            for (sourceListID, ids) in removals {
                self.memoryStore.addFilmsToList(filmIDs: ids, listID: sourceListID)
            }

            self.syncListsCache()
            self.refreshFilms()
            if !newlyAdded.isEmpty {
                AppEventBus.shared.send(.list(.membershipChanged(listID: listID)))
            }
            for sourceListID in removals.keys {
                AppEventBus.shared.send(.list(.membershipChanged(listID: sourceListID)))
            }
            if !removals.isEmpty {
                Self.log("Rolled back Film Queue exclusivity enforcement alongside the add it belonged to")
            }
        }
    }

    /// The background write for one add-to-list operation, including any Film Queue
    /// exclusivity removals that must land with it.
    ///
    /// With nothing to reconcile this is the ordinary `batchAddFilmsToLists` call, which
    /// keeps its incremental per-batch saves — that path also carries bulk user-list adds,
    /// where committing in batches is what keeps memory pressure bounded. A queue move
    /// instead routes through `moveFilmsBetweenLists`, which commits the removals and the
    /// insertions in ONE transaction. That is the stronger guarantee, and it is affordable
    /// precisely here: a move is bounded by the films the user selected and touches at most
    /// three lists, so there is no batch worth splitting.
    ///
    /// Unioning the per-list removal sets is safe for the same reason it always was: the
    /// deletion only matches rows whose film AND list both appear in the sets it is given,
    /// so combining every (listID, films) pair can never reach a row this enforcement pass
    /// had not already slated for removal.
    private func listAddWork(filmIDs: Set<UUID>, listID: UUID,
                             removals: [UUID: Set<UUID>]) -> @Sendable () async throws -> Void {
        let dataManager = self.dataManager
        guard !removals.isEmpty else {
            return { try await dataManager.batchAddFilmsToLists(filmIDs: filmIDs, listIDs: [listID]) }
        }
        let removalFilmIDs = removals.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
        let removalListIDs = Set(removals.keys)
        return {
            try await dataManager.moveFilmsBetweenLists(
                filmIDs: filmIDs,
                removalFilmIDs: removalFilmIDs,
                removalListIDs: removalListIDs,
                addingTo: listID)
        }
    }

    /// Adds films to a list. Synchronous — like every list mutation here it applies the
    /// in-memory change on the caller's stack and hands the database write to
    /// `trackOperation`, whose rollback and alert are the only failure path. That matters
    /// for AppKit drag-and-drop completion handlers invoked from within
    /// `NSDraggingDestination.performDragOperation`: that call arrives synchronously from
    /// inside `NSDraggingSession`'s internal event-tracking run loop, which runs in a run
    /// loop mode that defers Swift Concurrency's main-actor continuations until the
    /// tracking session unwinds — so wrapping this work in `Task { ... }` would silently
    /// delay it until after the drag's own completion animation finishes.
    /// - Returns: `true` if the list was found and the mutation was applied.
    @discardableResult
    func addFilmsToList(filmIDs: Set<UUID>, listID: UUID) -> Bool {
        guard let targetList = memoryStore.getList(listID) else { return false }

        // Last line of defense for the "Up Next" cap: every user-facing path refuses an
        // overflowing add with an alert before reaching here (see FilmQueue's Up Next
        // Capacity section), so this only fires if one of them is bypassed.
        // An add with no newcomers takes no slot (see FilmQueue.upNextOverflow).
        if listID == FilmQueueSection.upNext.listID,
           !filmIDs.isSubset(of: targetList.filmIDs),
           targetList.filmIDs.count + filmIDs.subtracting(targetList.filmIDs).count > FilmQueue.upNextCapacity {
            Self.log("ERROR: Refused add of \(filmIDs.count) film(s) to 'Up Next' — it would exceed \(FilmQueue.upNextCapacity) films")
            return false
        }

        let preExisting = memoryStore.getList(listID)?.filmIDs ?? []
        let newlyAdded = filmIDs.subtracting(preExisting)

        // Self-healing invariant: a film can never end up in more than one Up Next
        // Queue section as a result of this add. No-op for ordinary user lists.
        // Safe to call from this synchronous drag-and-drop path — like the rest of
        // this method, it never suspends. Its removals are returned, not persisted
        // separately, so they ride in the same tracked operation as the add below.
        let removals = enforceFilmQueueExclusivity(filmIDs: filmIDs, addingTo: listID)

        memoryStore.addFilmsToList(filmIDs: filmIDs, listID: listID)
        syncListsCache()

        if case .list(let currentList) = currentViewID, currentList == listID {
            refreshFilms()
        } else if case .filmQueue = currentViewID, FilmQueue.isInternalList(listID) {
            // Keeps the Film Queue view current when this add follows an
            // enforceFilmQueueExclusivity removal while the queue itself is on
            // screen — without this, the film could briefly appear to vanish rather
            // than move to its new section.
            refreshFilms()
        }

        // One tracked operation for the whole move: one background write, one rollback
        // surface, and at most one persistence alert per user gesture.
        trackOperation(
            rollback: listAddRollback(newlyAdded: newlyAdded, listID: listID, restoring: removals),
            listAddWork(filmIDs: filmIDs, listID: listID, removals: removals))

        return true }

    func removeFilmsFromList(filmIDs: Set<UUID>, listID: UUID) {
        // Capture pre-state for rollback: only IDs that are actually in the list
        let actuallyRemoved = memoryStore.getList(listID)?.filmIDs.intersection(filmIDs) ?? []
        
        memoryStore.removeFilmsFromList(filmIDs: filmIDs, listID: listID)
        syncListsCache()

        if case .list(let currentList) = currentViewID, currentList == listID {
            refreshFilms()
        } else if case .filmQueue = currentViewID, FilmQueue.isInternalList(listID) {
            // Without this, removing a film from the queue via Opt+Delete, the trash
            // menu, or the MenuBar "Remove from List" item left the film visible in
            // the grid until the user switched views and back, because those paths
            // route through this method rather than saveFilmChangeset (which already
            // reloads unconditionally). Matches the identical branch in
            // addFilmsToList for the same view.
            refreshFilms()
        }

        // Use DataManager for batch list operations (background processing)
        trackOperation(rollback: { [weak self] in
            guard let self, !actuallyRemoved.isEmpty else { return }
            self.memoryStore.addFilmsToList(filmIDs: actuallyRemoved, listID: listID)
            self.syncListsCache()
            self.refreshFilms()
            AppEventBus.shared.send(.list(.membershipChanged(listID: listID)))
        }) { [dataManager] in
            try await dataManager.batchRemoveFilmsFromLists(
                filmIDs: filmIDs, listIDs: [listID]) } }

    func createList(name: String, displayOrder: Int) -> UUID {
        let listID = memoryStore.createList(name: name, displayOrder: displayOrder)
        syncListsCache()

        trackOperation(rollback: { [weak self] in
            guard let self else { return }
            self.memoryStore.deleteList(listID: listID)
            self.syncListsCache()
            self.refreshFilms()
            AppEventBus.shared.send(.list(.deleted(listID: listID)))
        }) { [dataManager] in
            try await dataManager.createList(listID: listID, name: name,
                displayOrder: displayOrder) }

        return listID }

    func updateList(listID: UUID, name: String?, displayOrder: Int?,
        sortFilterOptions: [String]?) {
        // Capture pre-state for rollback (MemoryList is a struct, so this copies)
        let preList = memoryStore.getList(listID)
        
        memoryStore.updateList(listID: listID, name: name, displayOrder: displayOrder,
            sortFilterOptions: sortFilterOptions)
        syncListsCache()

        trackOperation(rollback: { [weak self] in
            guard let self, let preList else { return }
            self.memoryStore.updateList(
                listID: listID,
                name: preList.listName,
                displayOrder: preList.displayOrder,
                sortFilterOptions: preList.sortFilterOptions)
            self.syncListsCache()
            AppEventBus.shared.send(.list(.updated(listID: listID)))
        }) { [dataManager] in
            try await dataManager.updateList(listID: listID, name: name,
                displayOrder: displayOrder, sortFilterOptions: sortFilterOptions) } }

    func deleteList(listID: UUID) {
        // Defense-in-depth: the three internal Film Queue lists must never be
        // deletable, per the feature's core invariant. In practice this is already
        // unreachable — every UI entry point sources its listID from getAllLists(),
        // which filters out the internal IDs — but this guard makes the guarantee
        // hold at the data layer itself, independent of any future UI path, scripted
        // interaction, or keyboard-shortcut regression that might otherwise bypass
        // that filtering. Silently returns rather than throwing: this mirrors the
        // "list not found" guard directly below, treating an attempted delete of a
        // protected list the same as a no-op on a nonexistent one.
        guard !FilmQueue.isInternalList(listID) else {
            Self.log("WARNING: Ignored attempt to delete internal Film Queue list \(listID)")
            return
        }

        // Capture pre-state for rollback (MemoryList is a struct, so this copies)
        guard let preList = memoryStore.getList(listID) else { return }
        
        memoryStore.deleteList(listID: listID)
        syncListsCache()

        if case .list(let currentList) = currentViewID, currentList == listID {
            currentViewID = .allFilms
            refreshFilms() }

        trackOperation(rollback: { [weak self] in
            guard let self else { return }
            self.memoryStore.restoreList(preList)
            self.syncListsCache()
            self.refreshFilms()
            AppEventBus.shared.send(.list(.updated(listID: listID)))
        }) { [dataManager] in try await dataManager.deleteList(listID: listID) } }

    // MARK: - Import Operations

    /// Batch-inserts new films from a metadata import session.
    /// Accepts Sendable FilmSnapshot DTOs — no Film @Model objects are created on the caller side.
    /// MemoryStore is updated immediately for UI display; background persistence is handled
    /// via DataManager without any mainContext involvement.
    func importFilms(_ snapshots: [FilmSnapshot]) {
        let importedIDs = Set(snapshots.map { $0.id })

        // Register snapshots directly with MemoryStore — no mainContext insertion needed.
        for snapshot in snapshots {
            memoryStore.addFilm(snapshot)
        }

        totalFilmCount = memoryStore.totalFilmCount
        refreshFilms()

        // Notify SmartLists and the rest of the UI about each newly imported film.
        for snapshot in snapshots {
            AppEventBus.shared.filmAdded(snapshot.id)
        }

        trackOperation(rollback: { [weak self] in
            guard let self else { return }
            self.memoryStore.deleteFilms(ids: importedIDs)
            self.totalFilmCount = self.memoryStore.totalFilmCount
            self.refreshFilms()
            // The forward path posted `.added` per film, which is what put them into
            // SmartLists' membership sets; the matching `.deleted` takes them back out.
            AppEventBus.shared.filmsDeleted(importedIDs)
            Self.log("Rolled back import of \(importedIDs.count) film(s)")
        }) { [dataManager] in
            try await dataManager.batchInsertFilms(snapshots) } }

    /// Applies a batch of rating updates from an import session to the MemoryStore
    /// snapshots, then persists the whole batch in a single background transaction.
    /// No mainContext.save() is called. Used by RatingsImporter.flushPendingUpdates().
    ///
    /// Deliberately batched rather than per-film. A single flush routinely carries a hundred
    /// or more ratings, and dispatching each one separately meant one trackOperation, one
    /// SwiftData fetch, and one modelContext.save() per film — a hundred round trips to the
    /// @ModelActor for what is one logical unit of work, and a hundred independent rollback
    /// surfaces that could each fail in isolation. One updateFilms call commits them
    /// together or not at all.
    ///
    /// The per-film `.film(.updated)` events are still posted individually: every subscriber
    /// (Right Sidebar, Hall of Fame report, open FilmSheet) resolves them by film ID, and a
    /// rating change alters "Not Rated" membership, which only a full reload re-resolves.
    /// - Parameter updates: (filmID, rating) pairs, in the order the importer matched them.
    func applyImportedRatingUpdates(_ updates: [(filmID: UUID, rating: Int)]) {
        guard !updates.isEmpty else { return }

        // Pre-mutation ratings for rollback, and the final snapshot per film for
        // persistence. Both are keyed by film ID because one flush can legitimately contain
        // more than one entry for the same film (a ratings file listing a title twice).
        // For the rollback baseline only the FIRST value seen is correct — a later
        // iteration would capture this method's own intermediate write. For persistence
        // only the LAST snapshot is correct, which is what plain assignment yields.
        var preRatings: [UUID: Int] = [:]
        var finalSnapshots: [UUID: FilmSnapshot] = [:]

        for update in updates {
            guard var snapshot = memoryStore.getFilm(update.filmID) else {
                Self.log("WARNING: applyImportedRatingUpdates — film \(update.filmID) not found in MemoryStore")
                continue
            }
            if preRatings[update.filmID] == nil {
                preRatings[update.filmID] = snapshot.userRating
            }
            guard snapshot.userRating != update.rating else { continue }
            snapshot.userRating = update.rating
            memoryStore.updateFilm(snapshot)
            finalSnapshots[update.filmID] = snapshot
        }

        guard !finalSnapshots.isEmpty else { return }

        let snapshotsToPersist = Array(finalSnapshots.values)
        let rollbackRatings = preRatings.filter { finalSnapshots[$0.key] != nil }

        // Deliberately no refreshFilms() here. A ratings import runs with the Imports view
        // active, and refreshFilms() takes performLoad's general path for whatever view is
        // current — which for .imports resolves to an empty base ID list and would publish
        // films = [] / filmCount = 0 while the import is still running. The reload that
        // actually matters is driven by the per-film events posted below, which reach
        // ViewStateManager.triggerReloadSync; that path skips .imports and .reports by
        // design, and it re-resolves view membership rather than reusing the stale set a
        // refresh would keep. This matches the behavior of the per-film method this replaced.
        trackOperation(rollback: { [weak self] in
            guard let self else { return }
            for (filmID, rating) in rollbackRatings {
                guard var current = self.memoryStore.getFilm(filmID) else { continue }
                current.userRating = rating
                self.memoryStore.updateFilm(current)
            }
            // The same per-film events the forward path posts, for the same reason.
            //
            // Without them the rollback is invisible to everything downstream: the forward
            // path's events drive a reload that publishes the imported ratings into
            // DataCoordinator.films, and restoring the store alone does not repaint that
            // array — so a failed ratings import left the gallery, the sidebar and any open
            // FilmSheet showing ratings that had already been rolled back underneath them,
            // until some unrelated mutation happened to trigger the next reload. Posting
            // here makes the undo as visible as the change was.
            for filmID in rollbackRatings.keys {
                AppEventBus.shared.send(.film(.updated(filmID: filmID)))
            }
            Self.log("Rolled back \(rollbackRatings.count) imported rating update(s)")
        }) { [dataManager] in
            try await dataManager.updateFilms(snapshotsToPersist)
        }

        for filmID in finalSnapshots.keys {
            AppEventBus.shared.send(.film(.updated(filmID: filmID)))
        }
        Self.log("Applied \(snapshotsToPersist.count) imported rating update(s)")
    }

    // MARK: - Hall of Fame Operations

    // The debounce task holds the IDs of the most recent reorder so that rapid successive
    // drags (which each call reorderHallOfFame) only trigger one DataManager write once the
    // user's hand is off the mouse. The task itself does NOT hold a pendingOperationCount
    // slot — it simply waits and then dispatches through trackOperation, which owns the
    // counter. This keeps all counter management inside trackOperation and eliminates the
    // asymmetry with every other mutation path in this class.
    private var hofDebounceTask: Task<Void, Never>?
    private var pendingHofFilmIDs: [UUID] = []
    /// Captures the hofPosition each film held *before* the current debounce sequence
    /// began. Set on the first reorderHallOfFame() call of a sequence (when
    /// pendingHofFilmIDs is empty) and consumed by persistPendingHofReorder() for
    /// its rollback closure. This ensures a true rollback to the DB-consistent state
    /// rather than restoring the post-mutation positions.
    private var preReorderPositions: [UUID: Int] = [:]
    
    func addToHallOfFame(_ filmID: UUID) {
        Self.log("Adding film \(filmID) to hall of fame")

        // A pending reorder is deliberately NOT flushed here. persistPendingHofReorder()
        // re-reads each snapshot at the moment it runs, so whenever it fires it writes
        // current truth and can never contradict this operation. Forcing it to commit first
        // would instead capture pre-mutation positions and dispatch them as a SEPARATE
        // operation whose rollback closure, on failure, would restore ranks that this
        // operation has since changed. See persistPendingHofReorder().

        // MemoryStore owns the eligibility rules (unknown film, list full, already ranked)
        // and reports whether anything was actually written. A nil return means no rank
        // changed, so there is nothing to broadcast, persist, or roll back — the previous
        // code queued a database write and fired an update event unconditionally.
        guard memoryStore.addToHallOfFame(filmID) != nil,
              let snapshot = memoryStore.getFilm(filmID) else {
            Self.log("addToHallOfFame — no change applied for film \(filmID); skipping persistence")
            return
        }

        AppEventBus.shared.send(.film(.updated(filmID: filmID)))

        trackOperation(rollback: { [weak self] in
            guard let self else { return }
            self.memoryStore.removeFromHallOfFame(filmID)
            AppEventBus.shared.send(.film(.updated(filmID: filmID)))
        }) { [dataManager] in
            try await dataManager.updateFilm(snapshot)
        }
    }
    
    /// Removes a single film from the Hall of Fame. Delegates to the batch path so both
    /// have identical semantics.
    func removeFromHallOfFame(_ filmID: UUID) {
        removeFromHallOfFame(Set([filmID]))
    }

    /// Removes one or more films from the Hall of Fame, compacting the surviving ranking and
    /// committing the whole change as a single atomic transaction.
    ///
    /// Callers used to loop the single-film method over a multi-selection. That issued one
    /// database transaction per film, each rewriting *every* surviving member (up to 200) even
    /// when their positions had not moved, and each capturing a rollback baseline taken after
    /// the previous iteration had already compacted — so a mid-loop failure could not restore a
    /// coherent ranking. This path captures one baseline, mutates once, and writes only the
    /// films whose stored position actually changed.
    func removeFromHallOfFame(_ filmIDs: Set<UUID>) {
        guard !filmIDs.isEmpty else { return }
        Self.log("Removing \(filmIDs.count) film(s) from hall of fame")

        // See addToHallOfFame for why a pending reorder is not flushed here.

        // Every current member's position, captured before the mutation so a failed persist
        // can restore the exact pre-removal ranking — the removed films' own positions and
        // the compaction applied to the survivors alike. Bounded at 200 entries.
        //
        // Seeded from the derived ordered list, then topped up by testing each requested film
        // against `hofPosition > 0` directly. That second pass is what MemoryStore itself uses
        // to decide what to clear, so the two predicates cannot disagree: a film that is
        // ranked but somehow missing from the derived list still gets a captured baseline and
        // still lands in the write set below, instead of being mutated in memory and silently
        // left at its old position in SwiftData.
        var prePositions: [UUID: Int] = [:]
        for id in memoryStore.hallOfFameFilms {
            if let position = memoryStore.getFilm(id)?.hofPosition, position > 0 {
                prePositions[id] = position
            }
        }
        for id in filmIDs where prePositions[id] == nil {
            if let position = memoryStore.getFilm(id)?.hofPosition, position > 0 {
                prePositions[id] = position
            }
        }

        // Mutate MemoryStore: clears the removed films' positions and compacts the rest once.
        // nil means none of the given films were ranked members, so nothing was written.
        guard let compactedIDs = memoryStore.removeFromHallOfFame(filmIDs) else {
            Self.log("removeFromHallOfFame — no ranked members among the given films; nothing to do")
            return
        }

        // The films that were actually ranked before the mutation — the ones whose snapshots
        // now carry hofPosition == 0 and must be written back. Every entry in prePositions is
        // a positive position by construction, so presence is sufficient.
        let removedIDs = filmIDs.filter { prePositions[$0] != nil }

        // Persist only genuinely changed films: the removed ones plus any survivor whose
        // stored position actually shifted. Removing the lowest-ranked member shifts no
        // survivor at all, which previously still rewrote all 199 of them.
        let changedIDs = Array(removedIDs) + compactedIDs.filter { !removedIDs.contains($0) }
        let snapshotsToPersist = changedIDs.compactMap { memoryStore.getFilm($0) }

        // Broadcast only the removed films, deliberately not the shifted survivors.
        // .film(.updated) is a heavyweight signal — GalleryView reloads its data set and
        // SmartLists recomputes membership per event — so emitting one per survivor would
        // turn a single removal into up to 200 full reloads. Nothing displays a survivor's
        // rank from a cached value: HallOfFameView recomputes every row's position from the
        // reloaded order it gets from this same removal, and the Metadata module reads the position
        // off a snapshot fetched at render time.
        for id in removedIDs {
            AppEventBus.shared.send(.film(.updated(filmID: id)))
        }

        guard !snapshotsToPersist.isEmpty else {
            Self.log("WARNING: removeFromHallOfFame — no snapshots available after mutation; skipping persistence")
            return
        }

        trackOperation(rollback: { [weak self] in
            guard let self else { return }
            // Restore all films to their pre-removal positions in one pass. This un-compacts
            // the survivors and re-inserts the removed films back into the ranking.
            //
            // Every captured value is a positive position, so this is a straight restoration
            // of the pre-removal ranking — no sentinel handling is needed.
            self.memoryStore.restoreHofPositions(prePositions)
            for id in prePositions.keys {
                AppEventBus.shared.send(.film(.updated(filmID: id)))
            }
        }) { [dataManager] in
            // Single atomic transaction: the removed films (hofPosition = 0) and every
            // shifted survivor are committed together, so a mid-write failure leaves
            // SwiftData untouched rather than partially shifted.
            try await dataManager.updateFilms(snapshotsToPersist)
        }
    }
    
    func reorderHallOfFame(_ filmIDs: [UUID]) {
        guard !filmIDs.isEmpty else { return }
        Self.log("Reordering hall of fame: \(filmIDs.count) films")

        // On the first reorder of a new debounce sequence, capture each film's
        // current hofPosition so the rollback can restore DB-consistent state.
        // Subsequent rapid drags within the same sequence skip this — the first
        // capture is the correct pre-mutation baseline until a persist succeeds.
        // The baseline covers every current member rather than just the IDs passed in:
        // MemoryStore reconciles the ranking against its stored positions, so a film absent
        // from filmIDs can still be renumbered, and a baseline restricted to filmIDs would
        // have no value to roll that film back to.
        if pendingHofFilmIDs.isEmpty {
            preReorderPositions = memoryStore.hallOfFameFilms.reduce(into: [:]) { dict, id in
                dict[id] = memoryStore.getFilm(id)?.hofPosition ?? 0
            }
        }

        // Snapshot positions before the mutation so we can compute the changed set.
        // Using the pre-mutation MemoryStore values (1-based, matching filmIDs order)
        // gives us the minimal diff without an extra dictionary allocation on the hot path.
        let prePositions: [UUID: Int] = filmIDs.reduce(into: [:]) { dict, id in
            dict[id] = memoryStore.getFilm(id)?.hofPosition ?? 0
        }

        // Apply to MemoryStore immediately so the UI reflects the new order at once.
        // MemoryStore returns the ordering it actually applied, which is authoritative:
        // it collapses duplicates and drops unknown or unranked IDs, so using the caller's
        // array below would mis-address events and persist positions for films that never
        // received one.
        let appliedOrder = memoryStore.reorderHallOfFame(filmIDs)

        // Fire .film(.updated) only for films whose position actually changed.
        // A single drag shifts the dragged item and every film in the displaced range;
        // films outside that range retain their positions and need no event. This reduces
        // O(N) events per drag to O(range-size), which can be as small as O(2) for a
        // single-step move.
        for (index, filmID) in appliedOrder.enumerated() {
            let newPosition = index + 1   // 1-based, matching MemoryStore.reorderHallOfFame
            if prePositions[filmID] != newPosition {
                AppEventBus.shared.send(.film(.updated(filmID: filmID)))
            }
        }

        // Record the latest ordering. Any prior pending value is overwritten —
        // only the final resting state matters, not every intermediate drag position.
        pendingHofFilmIDs = appliedOrder

        // Cancel the previous debounce window and open a fresh one. The task itself
        // holds no pendingOperationCount slot; it simply waits for the quiet window
        // to expire and then calls persistPendingHofReorder(), which dispatches through
        // trackOperation. All counter management stays inside trackOperation.
        hofDebounceTask?.cancel()
        hofDebounceTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(1)) // 1-second quiet window
            guard !Task.isCancelled, let self else { return }
            self.persistPendingHofReorder()
        }
    }

    /// Flushes any accumulated Hall of Fame reorder through trackOperation.
    ///
    /// Called in two situations:
    ///   1. By the debounce task once the 1-second quiet window has elapsed (normal path).
    ///   2. Directly by prepareForShutdown() before isShuttingDown is set, ensuring a
    ///      pending reorder is committed via trackOperation while the gate is still open.
    ///
    /// Snapshots are gathered here rather than at reorder time, and that is load bearing:
    /// it is what allows an add or remove to run inside the debounce window without racing
    /// this write. Both operations then carry post-mutation truth and agree. Do not hoist the
    /// snapshot capture to reorderHallOfFame(), and do not force this to commit early from a
    /// membership-changing path.
    private func persistPendingHofReorder() {
        let filmIDs = pendingHofFilmIDs
        guard !filmIDs.isEmpty else { return }
        pendingHofFilmIDs = []

        // Capture and consume the pre-reorder positions for rollback.
        let prePositions = preReorderPositions
        preReorderPositions = [:]

        // Collect snapshots on MainActor before crossing the actor boundary.
        //
        // Two filters, both load bearing:
        //
        // • hofPosition > 0 — a film that has since left the Hall of Fame was removed by a
        //   later, independent operation which already persisted its own zeroed position and
        //   owns its own rollback. reorderHallOfFame() never assigns 0, so a zero here always
        //   means "someone else took this film out". Including it would make the rollback
        //   below restore its pre-reorder rank and resurrect a removed film in memory.
        //
        // • baseline mismatch — narrows the write to films whose position actually differs
        //   from the last state committed to SwiftData (which is precisely what prePositions
        //   holds). A one-step drag near the bottom of a full ranking changes two positions;
        //   the whole 200-member list was previously rewritten regardless. A film with no
        //   baseline entry is written, since its stored value cannot be assumed to match.
        let snapshots = filmIDs.compactMap { memoryStore.getFilm($0) }
            .filter { $0.hofPosition > 0 && prePositions[$0.id] != $0.hofPosition }

        // Nothing to do when a drag sequence nets out to the order already on disk. Both
        // pieces of pending state have been consumed above, so returning here leaves no
        // residue for the next sequence.
        guard !snapshots.isEmpty else {
            Self.log("Hall of fame reorder resolved to the persisted order; no write needed")
            return
        }

        Self.log("Persisting \(snapshots.count) hall of fame position update(s)")

        trackOperation(rollback: { [weak self] in
            guard let self else { return }
            // The DB write failed; the database still holds the pre-reorder positions.
            // Restore each film's hofPosition to the value it held before the debounce
            // sequence began — that is the last state successfully committed to the DB.
            //
            // One batched call: the previous per-film loop re-sorted the entire film
            // collection and rescheduled the derived-cache save once per film, up to 200
            // times for a single failed reorder. No smart list is keyed on hofPosition, so
            // the forced full smart-list recalculation that used to follow was pure work.
            var restore: [UUID: Int] = [:]
            for snapshot in snapshots {
                restore[snapshot.id] = prePositions[snapshot.id] ?? snapshot.hofPosition
            }
            self.memoryStore.restoreHofPositions(restore)
            Self.log("Rolled back hall of fame reorder (\(snapshots.count) film(s))")
        }) { [dataManager] in
            // Single atomic transaction for the whole reorder, so every shifted member
            // commits together or not at all.
            try await dataManager.updateFilms(snapshots)
            Self.log("Hall of fame reorder persisted successfully")
        }
    }

    // MARK: - Wishlist Operations

    // Debounce state for wishlist reorders — same pattern as Hall of Fame.
    private var wishlistDebounceTask: Task<Void, Never>?
    /// Ordered (filmID, releaseID, newPosition) tuples from the most recent reorder call.
    private var pendingWishlistPositions: [(filmID: UUID, releaseID: UUID, position: Int)] = []
    /// Pre-mutation `wishlist` values captured at the start of each debounce sequence.
    private var preWishlistPositions: [UUID: Int] = [:]   // keyed by releaseID

    /// Updates `wishlist` positions for all reordered releases immediately in MemoryStore,
    /// then debounces the SwiftData persist (1-second quiet window, identical to HoF).
    ///
    /// - Parameter orderedPairs: The full wishlist in its new display order, as
    ///   `(filmID, releaseID)` tuples. Each release receives a 1-based `wishlist` position
    ///   equal to its index in this array.
    func reorderWishlist(_ orderedPairs: [(filmID: UUID, releaseID: UUID)]) {
        Self.log("Reordering wishlist: \(orderedPairs.count) release(s)")

        // On the first reorder of a new debounce sequence, snapshot the current
        // wishlist positions of all involved releases as the rollback baseline.
        if pendingWishlistPositions.isEmpty {
            preWishlistPositions = [:]
            for pair in orderedPairs {
                if let snapshot = memoryStore.getFilm(pair.filmID),
                   let release = snapshot.releases.first(where: { $0.id == pair.releaseID }) {
                    preWishlistPositions[pair.releaseID] = release.wishlist
                }
            }
        }

        // Snapshot positions before mutation to compute the minimal changed set.
        let preMutation: [UUID: Int] = orderedPairs.reduce(into: [:]) { dict, pair in
            dict[pair.releaseID] = memoryStore.getFilm(pair.filmID)?
                .releases.first(where: { $0.id == pair.releaseID })?.wishlist ?? 0
        }

        // Apply new positions to MemoryStore immediately so the UI reflects the new
        // order at once. Releases are grouped by film to minimize snapshot re-fetches.
        //
        // Each position is written to the release AND its combo-pack children: a child's
        // `wishlist` is locked to its parent's (FSTabReleases.syncComboChild), and the rows
        // arriving here are top-level only (getWishlistReleases). Renumbering the parent
        // alone left every child holding its old position in memory and in the store, which
        // the FilmSheet then flagged and converged on each open without ever persisting.
        let grouped = Dictionary(grouping: orderedPairs.enumerated()) { $0.element.filmID }
        for (filmID, indexedPairs) in grouped {
            guard var filmSnapshot = memoryStore.getFilm(filmID) else { continue }
            for (index, pair) in indexedPairs {
                let newPosition = index + 1
                for releaseIndex in filmSnapshot.releases.indices {
                    let release = filmSnapshot.releases[releaseIndex]
                    guard release.id == pair.releaseID
                        || release.parentReleaseID == pair.releaseID else { continue }
                    filmSnapshot.releases[releaseIndex] = release.withWishlist(newPosition)
                }
            }
            memoryStore.updateFilm(filmSnapshot)
        }

        // Fire .releaseChanged events only for releases whose position actually changed.
        var changedFilmIDs = Set<UUID>()
        for (index, pair) in orderedPairs.enumerated() {
            let newPosition = index + 1
            if preMutation[pair.releaseID] != newPosition {
                changedFilmIDs.insert(pair.filmID)
            }
        }
        for filmID in changedFilmIDs {
            AppEventBus.shared.send(.film(.releaseChanged(filmID: filmID)))
        }

        // Record the latest ordering for the debounced persist.
        pendingWishlistPositions = orderedPairs.enumerated().map { index, pair in
            (filmID: pair.filmID, releaseID: pair.releaseID, position: index + 1)
        }

        wishlistDebounceTask?.cancel()
        wishlistDebounceTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.persistPendingWishlistReorder()
        }
    }

    /// Flushes the accumulated wishlist reorder through `trackOperation`.
    /// Called by the debounce task and by `prepareForShutdown`.
    private func persistPendingWishlistReorder() {
        let positions = pendingWishlistPositions
        guard !positions.isEmpty else { return }
        pendingWishlistPositions = []

        let prePositions = preWishlistPositions
        preWishlistPositions = [:]

        // Gather the updated ReleaseSnapshot for each affected (filmID, releaseID) pair.
        // These snapshots already carry the new wishlist positions set above.
        //
        // `wishlist > 0` mirrors the hofPosition filter in persistPendingHofReorder, for the
        // same reason: reorderWishlist never assigns 0, so a zero here means a later,
        // independent save took the release off the wishlist and already persisted that.
        // Including it would let the rollback below restore its pre-reorder position and
        // put it back on the wishlist in memory while the database says otherwise.
        //
        // Each entry's combo-pack children ride along, carrying the position reorderWishlist
        // mirrored onto them.
        typealias ReleasePersistUnit = (filmID: UUID, snapshot: ReleaseSnapshot)
        let units: [ReleasePersistUnit] = positions.flatMap { entry -> [ReleasePersistUnit] in
            guard let film = memoryStore.getFilm(entry.filmID),
                  let release = film.releases.first(where: { $0.id == entry.releaseID }),
                  release.wishlist > 0
            else { return [] }
            let family = [release] + film.releases.filter { $0.parentReleaseID == release.id }
            return family.map { (filmID: entry.filmID, snapshot: $0) }
        }
        guard !units.isEmpty else { return }

        Self.log("Persisting \(units.count) wishlist position update(s)")

        trackOperation(rollback: { [weak self] in
            guard let self else { return }
            // The DB write failed; restore each release to its pre-reorder position.
            let grouped = Dictionary(grouping: units) { $0.filmID }
            for (filmID, filmUnits) in grouped {
                guard var filmSnapshot = self.memoryStore.getFilm(filmID) else { continue }
                for unit in filmUnits {
                    // A child has no baseline of its own; it mirrored its parent's.
                    let originalPosition = prePositions[unit.snapshot.id]
                        ?? unit.snapshot.parentReleaseID.flatMap { prePositions[$0] }
                        ?? unit.snapshot.wishlist
                    if let idx = filmSnapshot.releases.firstIndex(where: { $0.id == unit.snapshot.id }) {
                        filmSnapshot.releases[idx] = filmSnapshot.releases[idx].withWishlist(originalPosition)
                    }
                }
                self.memoryStore.updateFilm(filmSnapshot)
                AppEventBus.shared.send(.film(.releaseChanged(filmID: filmID)))
            }
            Self.log("Rolled back wishlist reorder (\(units.count) release(s))")
        }) { [dataManager] in
            // Single atomic transaction for the whole wishlist reorder.
            try await dataManager.updateReleases(units)
            Self.log("Wishlist reorder persisted successfully")
        }
    }

    /// Removes orphaned and duplicate ListMembership records at startup.
    /// Delegates entirely to DataManager's background context — no mainContext usage.
    ///
    /// Both classes of row inflate the live membership count in the snapshot cache's
    /// fingerprint without inflating the stored count, which costs a full slow-path
    /// load on every launch until the store is corrected. Removing them here is what
    /// makes that condition self-healing rather than permanent.
    func cleanupOrphanedAndDuplicateMemberships() async {
        do {
            // Awaited from a detached task, not from here: SwiftData's model executor runs a
            // DataManager call on the thread that awaits it, and this method is MainActor —
            // the pass held the main thread ~340ms just after every launch (1,384-film
            // library, `datamanager-thread`). Shutdown cancels deferred maintenance, so the
            // cancellation is forwarded to the detached task, whose checkCancellation throws.
            let dataManager = self.dataManager
            let pass = Task.detached(priority: .background) {
                try await dataManager.cleanupOrphanedAndDuplicateMemberships()
            }
            let (orphans, duplicates) = try await withTaskCancellationHandler {
                try await pass.value
            } onCancel: {
                pass.cancel()
            }
            if orphans > 0 {
                Self.log("Cleaned up \(orphans) orphaned membership(s) (background)")
            }
            if duplicates > 0 {
                Self.log("Cleaned up \(duplicates) duplicate membership(s) (background) — "
                    + "startup snapshot cache should validate on the next launch")
            }
        } catch is CancellationError {
            // Expected whenever AppDelegate cancels deferred maintenance at shutdown.
            // The pass is idempotent and re-runs on the next launch, so this is a
            // normal outcome and must not be reported as a failure.
            Self.log("Membership cleanup canceled (shutdown) — will re-run next launch")
        } catch {
            Self.log("ERROR: Membership cleanup failed: \(error)")
        }
    }

    // MARK: - Import Session Management

    /// Removes a single import session from the persistent store.
    /// ImportSession objects have no MemoryStore mirror, so no in-memory rollback
    /// is needed; if persistence fails ImportHistory (and so ImportsView) will simply
    /// continue showing the record, which is the safe failure behavior.
    func deleteImportSession(id sessionID: UUID) {
        trackOperation { [dataManager] in
            try await dataManager.deleteImportSession(id: sessionID)
            Self.log("Deleted import session: \(sessionID)")
        }
    }

    /// Removes all import sessions of the given type ("metadata" or "ratings").
    /// Sessions of the other type are left untouched.
    func deleteAllImportSessions(ofType importType: String) {
        trackOperation { [dataManager] in
            try await dataManager.deleteAllImportSessions(ofType: importType)
            Self.log("Deleted all import sessions of type: \(importType)")
        }
    }

    // MARK: - Settings
    // Load settings from database and apply every stored preference to UserDefaults.
    func loadSettingsFromDatabase() async throws {
        try await settingsManager.loadFromDatabase() }

    // Internal method used by SettingsManager - save settings to database
    // - Parameter snapshot: The SettingsSnapshot to save (Sendable, can cross actor boundary)
    // NOTE: Saves directly to mainContext instead of going through DataManager to ensure
    // settings are immediately visible to exports. DataManager uses an isolated actor context
    // that doesn't automatically sync changes to mainContext.
    func saveSettings(_ snapshot: SettingsSnapshot) async throws {
        let context = modelContainer.mainContext
        
        // Fetch all SettingsObjects without predicate filter to catch any stale objects
        // with wrong UUIDs — a one-time recovery path from an earlier bug.
        let allSettingsDescriptor = FetchDescriptor<SettingsObject>()
        let allSettings = try context.fetch(allSettingsDescriptor)
        
        // Partition into the singleton we want to keep and any stale objects to purge.
        var singletonObject: SettingsObject?
        var objectsToDelete: [SettingsObject] = []
        
        for obj in allSettings {
            if obj.snapshotID == SettingsObject.singletonID {
                singletonObject = obj
            } else {
                objectsToDelete.append(obj)
            }
        }
        
        // Delete all non-singleton objects (stale UUIDs from prior sessions).
        for obj in objectsToDelete {
            context.delete(obj)
        }
        if !objectsToDelete.isEmpty {
            Self.log("Deleted \(objectsToDelete.count) stale SettingsObject(s) with wrong UUID(s)")
        }
        
        // Upsert the singleton.
        let settings: SettingsObject
        if let existing = singletonObject {
            settings = existing
        } else {
            Self.log("Creating new SettingsObject singleton")
            settings = SettingsObject(
                snapshotID: SettingsObject.singletonID,
                version: SettingsObject.currentVersion,
                lastSyncDate: Date()
            )
            context.insert(settings)
        }
        
        // Belt-and-suspenders: explicitly ensure snapshotID is the canonical singleton
        // value, even though snapshot.apply(to:) already sets it. This guards against
        // any future SettingsSnapshot path that constructs a snapshot with a different
        // snapshotID (e.g., from a restored backup) being silently persisted under the
        // wrong UUID and orphaned in subsequent fetches.
        settings.snapshotID = SettingsObject.singletonID
        
        // Apply snapshot data and save atomically.
        snapshot.apply(to: settings)
        try context.save()
        Self.log("Settings saved")
    }

    // Internal method used by SettingsManager - load settings from database
    // - Returns: A SettingsSnapshot from the database, or a new empty one if none exists
    // NOTE: Loads directly from mainContext to match saveSettings() behavior
    func loadSettings() async throws -> SettingsSnapshot {
        let context = modelContainer.mainContext
        
        let singletonID = SettingsObject.singletonID
        let descriptor = FetchDescriptor<SettingsObject>(
            predicate: #Predicate { $0.snapshotID == singletonID }
        )
        
        guard let settings = try context.fetch(descriptor).first else {
            // No settings in database - return empty snapshot
            return SettingsSnapshot()
        }
        
        // Convert to snapshot
        return SettingsSnapshot(from: settings)
    }

    // MARK: - Debug Harness Support

    #if DEBUG
    /// The coordinator's MemoryStore, for harness scenarios that assert on store-level
    /// invariants (the reverse membership index, the view cache, Hall of Fame density) which
    /// have no public accessor and should not acquire one for production code's sake.
    /// DEBUG-only, and reachable only from a process the sandbox already contains.
    var memoryStoreForTesting: MemoryStore { memoryStore }

    /// Waits for the refresh the latest default-rotation-threshold change started, which
    /// runs off the main actor (see handleDefaultRotationThresholdChangeIfNeeded).
    func awaitRotationThresholdRefreshForTesting() async {
        await rotationThresholdRefresh?.value
    }
    #endif

    // MARK: - Shutdown

    /// Signals the coordinator that shutdown is imminent.
    /// Sets isShuttingDown so that trackOperation() silently discards any new work
    /// enqueued after this point. Must be called before the drain-wait loop so that
    /// the window where new operations could slip in while polling is closed.
    func prepareForShutdown() {
        // Flush any pending Hall of Fame / wishlist reorder BEFORE setting isShuttingDown,
        // so both can still reach trackOperation — it silently drops work once
        // isShuttingDown is set.
        flushPendingReorders()

        isShuttingDown = true
        Self.log("Preparing for shutdown (pending: \(pendingOperationCount))")
    }

    /// Cancels any in-flight throttled save and immediately flushes both
    /// MetadataCache and MemoryStoreCache to disk.
    ///
    /// Called by AppDelegate.performGracefulShutdown() instead of reaching into
    /// the cache singletons directly. Routing through DataCoordinator ensures that
    /// MemoryStore's pendingSaveTask is always canceled before the shutdown write,
    /// closing the race window where the throttled task could wake up after the
    /// shutdown save completes and overwrite the cache files with a stale payload.
    func saveImmediately() async {
        await memoryStore.saveImmediately()
    }

    /// Commits everything this session has already applied in memory, for a reader that
    /// goes to the store directly (DBExporter's fresh ModelContext).
    ///
    /// Without it an export captured whatever the debounces had not yet written: a
    /// preference changed on another Settings tab moments before Export (5 s window), or a
    /// Hall of Fame / wishlist drag inside its 1 s window. The reorders are dispatched now
    /// rather than waited out; operations run in dispatch order, so awaiting the last one
    /// awaits them all.
    func commitPendingWritesForExport() async {
        // A full sync, not flushPendingSettingsSync: many Settings controls write through
        // @AppStorage without posting preferencesChanged, so nothing is marked pending for
        // them and a flush would skip exactly those. Skipped when the fingerprint shows no
        // change, so it is free otherwise.
        await settingsManager.syncNow()

        flushPendingReorders()

        await lastTrackedOperation?.value
    }

    /// Dispatches any Hall of Fame or wishlist reorder still waiting out its debounce
    /// window, now, instead of when the window closes.
    private func flushPendingReorders() {
        hofDebounceTask?.cancel()
        hofDebounceTask = nil
        persistPendingHofReorder()

        wishlistDebounceTask?.cancel()
        wishlistDebounceTask = nil
        persistPendingWishlistReorder()
    }

    /// Stops this session's derived-cache writes for good. Called when the persistent store
    /// is replaced underneath it (DBRestorer): memory now describes the previous library,
    /// and a throttled save landing before the relaunch would write that back to disk.
    func suspendCachePersistence(reason: String) {
        memoryStore.suspendCachePersistence(reason: reason)
    }
}
