// MARK: - GalleryView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Root content view that displays the film grid or list for the active view (all films,
// user list, smart list, recents, etc.). ViewStateManager, SearchController, and PosterCache
// are @Observable singletons accessed directly; per-property tracking replaces the
// narrow ObservableObject proxy classes that were previously needed.

import SwiftUI
import SwiftData
import Combine

struct GalleryView: View, Loggable {
    nonisolated static let logTag = "[GalleryView]"

    @Environment(AppState.self) private var appState
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SelectionState.self) private var selectionState

    /// The sidebar item this instance was mounted for. MainContentSwitcher remounts
    /// GalleryView on every sidebar change, and SwiftUI gives the OUTGOING instance one
    /// more update pass, with the destination's state already in place, before removing
    /// it. See isOutgoing.
    let sidebarItem: SidebarItem

    /// The list currently being viewed, or nil in any non-list view. Still needed by the
    /// loading/placeholder logic below; the companion cachedListName it used to carry is
    /// gone, because the only consumer of a list *name* here — GalleryTitleBar's removal
    /// commands — now resolves the active list from appState.selectedSidebarItem via
    /// FilmRemoval instead of receiving a one-render-stale copy of it.
    @State private var cachedListID: UUID?
    @State private var viewID = UUID()
    @State private var hasInitialized = false
    @State private var hasLoadedInitialView = false  // Prevents duplicate loads
    @State private var forceReloadID = UUID()
    @State private var scrollRequest: FilmScrollRequest?
    
    /// Holds Combine subscriptions for gallery event handlers. Plain reference type — not an
    /// ObservableObject — because it has no @Published properties. Using @StateObject for a
    /// class with zero published state causes SwiftUI to register observation bookkeeping
    /// that can never fire, wasting memory and CPU on every body evaluation.
    @State private var eventHandler = SubscriptionHolder()

    private var viewStateManager: ViewStateManager { ViewStateManager.shared }

    var body: some View {
        VStack(spacing: 0) {
            GalleryTitleBar(
                viewIdentifier: viewStateManager.activeView
            )
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            
            ZStack {
                // The state of the films on screen, which lags activeState only across a Film
                // Queue tab switch — see ViewStateManager.displayedGalleryState.
                let shown = viewStateManager.displayedGalleryState(
                    loadedQueueFilter: dataCoordinator.loadedFilmQueueFilter)
                if !isOutgoing && !dataCoordinator.films.isEmpty && PosterCache.shared.isReady && !shouldShowLoading {
                    // showSectionDividers is read HERE, in a real SwiftUI body, rather
                    // than inside either style. Both consumers are NSViewRepresentables,
                    // whose updateNSView is not an observation-tracked scope — reading the
                    // @Observable ViewState from inside one would give SwiftUI no reason to
                    // run another update pass when the value changed. Reading it in this
                    // body (which already observes activeState for isListView directly
                    // above) makes it a stored property of the representable, so a change
                    // re-renders here and propagates down as an ordinary value change.
                    if shown.isListView {
                        GalleryListView(activeViewID: viewStateManager.activeView,
                                        scrollRequest: scrollRequest,
                                        subtitleProvider: subtitleProvider,
                                        showSectionDividers: shown.showSectionDividers)
                            .environment(dataCoordinator)
                            .environment(selectionState)
                    } else {
                        GallerySubview(forceReloadID: forceReloadID, scrollRequest: scrollRequest, activeViewID: viewStateManager.activeView, subtitleProvider: subtitleProvider, showSectionDividers: shown.showSectionDividers)
                            .environment(dataCoordinator)
                            .environment(selectionState)
                    }
                }
                
                if shouldShowPlaceholder {
                    placeholderView
                }
                
                if shouldShowLoading {
                    Color(NSColor.controlBackgroundColor).opacity(0.5)
                        .overlay(ProgressView())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        // NOTE: No .focusedSceneValue(\.selectedFilmIDs / \.selectedFilmID) here — deliberately.
        //
        // FilmTrackerApp already publishes both values scene-wide at the root (see
        // 10_00_FilmTrackerApp.swift, WindowGroup content), unconditionally and with the
        // identical values, which is what keeps MenuBar's @FocusedValue enablement working
        // in every view — including Reports and Imports, where no GalleryView is mounted.
        // Publishing them here as well was purely redundant, and it carried a real cost:
        // reading selectionState.selectedFilmIDs in this body subscribed the ENTIRE
        // GalleryView body to every selection change, so each gallery click re-evaluated
        // the title bar and re-ran GallerySubview.updateNSView (including its O(N)
        // film-order scan and selection re-sync) for no benefit — the Coordinator's own
        // withObservationTracking loop already syncs NSCollectionView selection directly.
        // With the duplicate publishers removed, this body no longer observes selection at
        // all, and selection changes flow only through the paths that need them
        // (Coordinator observation loop, RightSidebar, StatusBar, MenuBar via the root).
        .onAppear {
            initializeIfNeeded()
            setupEventHandlersIfNeeded()
        }
        .onDisappear { eventHandler.cancel() }
        .onChange(of: dataCoordinator.isInitialized) { _, initialized in
            if initialized && PosterCache.shared.isReady { handleReadyState() }
        }
        .onChange(of: PosterCache.shared.isReady) { _, ready in
            if ready && dataCoordinator.isInitialized { handleReadyState() }
        }
        .onChange(of: appState.selectedSidebarItem) { oldItem, newItem in
            handleSidebarChange(from: oldItem, to: newItem)
        }
    }
    
    // MARK: - Computed Properties

    /// True for the one update pass this instance receives after the sidebar has moved to
    /// another item, just before SwiftUI removes it. The destination's films, active view
    /// and grid/list style are already in place by then (AppState.navigate switches before
    /// it flips), so rendering the gallery on that pass is pure waste: it reloaded the
    /// outgoing grid with the destination's films, and when the two views differ in
    /// style it built the destination's style in this dying instance, alongside the one
    /// the fresh instance builds. Dropping the gallery instead dismantles it, which its
    /// removal was about to do anyway. Its dismantleNSView still banks the outgoing scroll
    /// origin under the outgoing view, because no update pass has moved its currentViewID.
    private var isOutgoing: Bool {
        appState.selectedSidebarItem != sidebarItem
    }

    /// The subtitle provider for the view currently being rendered.
    ///
    /// Derived, not stored. It was previously an `@State` cache rebuilt from
    /// `.onChange(of: viewStateManager.activeView)` and `.onChange(of:
    /// appState.selectedSidebarItem)`, and that is what produced stale date
    /// subtitles in Recents: `onChange` runs AFTER the body evaluation that
    /// observed the new value, so the first render of a newly-active view
    /// necessarily carried the PREVIOUS view's provider. `GallerySubview` sees a
    /// changed `activeViewID` on that same pass, judges it a view switch, and
    /// reloads — configuring cells with the outgoing category's dates. The
    /// corrected provider arrived one pass later, by which point the reload had
    /// already happened and, if the incoming film set matched on the count and
    /// endpoint heuristics, no second reload followed to replace the text. The
    /// result was a subtitle that neither matched the grid's ordering nor the
    /// value in `MetadataCache` — and that a tab round-trip fixed, because the
    /// return trip's first pass finally had the right provider in hand.
    ///
    /// Computing it in the body removes the lag entirely: the provider is always
    /// built from the very `ViewIdentifier` being handed to `GallerySubview` in
    /// the same expression, so the two cannot disagree by construction. There is
    /// no longer any state to keep in sync, and no key to guard it with.
    ///
    /// Allocating a small struct with a captured `DateType` per body evaluation
    /// is not a cost worth caching against — `GallerySubview` is an
    /// `NSViewRepresentable` whose `updateNSView` already runs on every parent
    /// render regardless, and the closure is invoked only during actual cell
    /// configuration.
    private var subtitleProvider: GallerySubtitleProvider? {
        guard case .libraryItem(.recents) = appState.selectedSidebarItem,
              let category = viewStateManager.activeView.recentsCategory else { return nil }

        let dateType = category.dateType
        return GallerySubtitleProvider(kind: dateType.rawValue) { filmID in
            MetadataCache.shared.getFormattedDate(for: filmID, type: dateType)
        }
    }
    
    private var shouldShowPlaceholder: Bool {
        guard dataCoordinator.isInitialized, PosterCache.shared.isReady, dataCoordinator.films.isEmpty else { return false }

        // The spinner and a placeholder are mutually exclusive: while the view is
        // genuinely awaiting films, it says so with the spinner alone. Without this guard a
        // user list whose films hadn't loaded yet drew "List is Empty" under the spinner,
        // because cachedListID alone qualifies for a placeholder below.
        guard !shouldShowLoading else { return false }

        // Recents, smart lists, the Film Queue, and Unwatched always show a
        // placeholder when empty — see ViewIdentifier.treatsEmptyAsValidState.
        if viewStateManager.activeView.treatsEmptyAsValidState {
            // The Film Queue is empty until films are assigned to a section, which is a
            // perfectly valid state that should show its own placeholder rather than blank space.
            return true
        }

        return !dataCoordinator.hasDatabaseFilms || isNarrowed || cachedListID != nil
    }

    /// True while a search query, search tokens, or a filter could account for an empty
    /// result. The spinner and the placeholder both read this one property, so every
    /// empty, ready state falls to exactly one of them. When they tested narrowing
    /// separately, the placeholder missed search tokens: in the window after a token was
    /// confirmed but before `activeState.searchQuery` carried it, the spinner stood down
    /// for the tokens while the placeholder waited for the query, and the gallery drew a
    /// blank frame between "Enter Search Token" and "No Results".
    ///
    /// Search tokens are read from SearchController.currentTokens, the authoritative source
    /// for whether a token search is active, whether or not the query has reached
    /// activeState yet.
    private var hasSearchContent: Bool {
        !viewStateManager.activeState.searchQuery.isEmpty || !SearchController.shared.currentTokens.isEmpty
    }

    private var isNarrowed: Bool {
        hasSearchContent || !viewStateManager.activeState.filterOptions.isEmpty
    }

    /// True only while the gallery is genuinely waiting for films it knows exist: the
    /// infrastructure is still initializing, or the view's unnarrowed source (the
    /// database, or the user list) has films but none have arrived yet.
    ///
    /// Anything that can legitimately narrow the result to nothing — a filter, a search
    /// query, or search tokens — rules the spinner out, because an empty result is then
    /// an answer rather than a wait. That rule applies to user lists exactly as it does to
    /// All Films: previously the list branch checked only that the list had films, so
    /// filtering a list and then removing every matching film from it left the list
    /// non-empty, the result empty, and the spinner drawn over the "No Results" placeholder
    /// indefinitely.
    private var shouldShowLoading: Bool {
        guard dataCoordinator.isInitialized, PosterCache.shared.isReady else { return true }

        // Recents, smart lists, the Film Queue, and Unwatched treat empty as a valid
        // state — see ViewIdentifier.treatsEmptyAsValidState.
        guard !viewStateManager.activeView.treatsEmptyAsValidState,
              dataCoordinator.films.isEmpty else { return false }

        // Token-only searches (e.g. OR operations) count as narrowing. Without that there
        // was a one-run-loop window after OR-token confirmation where searchQuery was
        // still "" but films was [] (filter pending), causing the spinner to appear and
        // never clear.
        guard !isNarrowed else { return false }

        if let listID = cachedListID {
            return dataCoordinator.getList(listID)?.filmIDs.isEmpty == false
        }
        return dataCoordinator.hasDatabaseFilms
    }

    // MARK: - Placeholder Views
    
    @ViewBuilder
    private var placeholderView: some View {
        let hasFilters = !viewStateManager.activeState.filterOptions.isEmpty
        let hasSearchQuery = hasSearchContent
        let isListView = cachedListID != nil
        
        // Check if we're on a recents view
        if case .recents(let category) = viewStateManager.activeView {
            recentsCategoryPlaceholder(for: category)
        } else if case .unwatched(let category) = viewStateManager.activeView {
            unwatchedCategoryPlaceholder(for: category)
        } else if case .smartList(let type) = viewStateManager.activeView {
            smartListPlaceholder(for: type)
        } else if case .filmQueue = viewStateManager.activeView {
            filmQueuePlaceholder()
        } else if hasSearchQuery {
            StandardPlaceholder(
                glyph: ViewGlyphs.search.outline,
                title: "No Results",
                message: "Try adjusting your search query.",
                actionTitle: "Clear Query",
                action: clearFiltersAndSearch
            )
        } else if hasFilters {
            StandardPlaceholder(
                glyph: ViewGlyphs.activeFilters.filled,
                title: "No Results",
                message: "Try adjusting your filters.",
                actionTitle: "Clear Filters",
                action: clearFiltersOnly
            )
        } else if isListView && dataCoordinator.hasDatabaseFilms {
            StandardPlaceholder(
                glyph: ViewGlyphs.userList.outline,
                title: "List is Empty",
                message: "Add films to this list to get started."
            )
        } else {
            StandardPlaceholder(
                glyph: ViewGlyphs.allFilms.filled,
                title: "Add Films to Get Started",
                message: "Import films, or add them manually."
            )
        }
    }
    
    @ViewBuilder
    private func filmQueuePlaceholder() -> some View {
        let selectedFilter = FilmQueueFilterState.shared.selectedFilter
        // dataCoordinator.films is already filtered to the selected section (see
        // DataCoordinator.loadFilms), so it being empty only tells us the CURRENT section
        // is empty — it says nothing about the queue as a whole. getFilmQueueFilmIDs()
        // (unfiltered, all three sections) is the only reliable way to distinguish "the
        // queue itself has nothing in it yet" from "this section happens to be empty."
        if selectedFilter == .all || dataCoordinator.getFilmQueueFilmIDs().isEmpty {
            // Either viewing "All" and it's empty, or every section is empty — the queue
            // as a whole has nothing assigned to it yet.
            StandardPlaceholder(
                glyph: ViewGlyphs.filmQueue.outline,
                title: "Your Queue Is Empty",
                message: "Assign films to the Up Next, Soon, or Later section from a film's Details tab to build your queue."
            )
        } else {
            // The queue has films overall, but none currently assigned to this section.
            StandardPlaceholder(
                glyph: ViewGlyphs.filmQueue.outline,
                title: "\(selectedFilter.displayName) Is Empty",
                message: "No films are currently assigned to the \(selectedFilter.displayName) section. Select \u{201C}All\u{201D} to see the rest of your queue.",
                actionTitle: "Show All",
                action: { FilmQueueFilterState.shared.selectFilter(.all) }
            )
        }
    }
    
    @ViewBuilder
    private func recentsCategoryPlaceholder(for category: RecentsCategory) -> some View {
        switch category {
        case .recentlyViewed:
            StandardPlaceholder(
                glyph: ViewGlyphs.recentlyViewed.outline,
                title: "Nothing Viewed Recently",
                message: "Add a viewing event or a past viewing date to get started."
            )
        case .recentlyRotated:
            StandardPlaceholder(
                glyph: ViewGlyphs.recentlyRotated.outline,
                title: "Nothing Came Up for Rotation Recently",
                message: "Wait a while or change the rotation threshold preference."
            )
        case .recentlyAdded:
            StandardPlaceholder(
                glyph: ViewGlyphs.recentlyAdded.outline,
                title: "Nothing Added Recently",
                message: "Import more films or add them manually."
            )
        case .recentlyUpdated:
            StandardPlaceholder(
                glyph: ViewGlyphs.recentlyUpdated.outline,
                title: "Nothing Updated Recently",
                message: "Edit a film to see it here."
            )
        case .recentlyPurchased:
            StandardPlaceholder(
                glyph: ViewGlyphs.recentlyPurchased.filled,
                title: "Nothing Purchased Recently",
                message: "Add releases with purchase dates to films."
            )
        }
    }
    
    @ViewBuilder
    private func unwatchedCategoryPlaceholder(for category: UnwatchedCategory) -> some View {
        switch category {
        case .unwatched:
            StandardPlaceholder(
                glyph: ViewGlyphs.unwatched.filled,
                title: "No Unwatched Films",
                message: "Every film in your library is marked as watched."
            )
        case .notRated:
            StandardPlaceholder(
                glyph: ViewGlyphs.unwatched.filled,
                title: "No Unrated Films",
                message: "Every film in your library has a rating."
            )
        }
    }
    
    /// Empty-state placeholder for any smart list. The per-list copy is data on
    /// `SmartListType.emptyState` (SmartLists.swift), beside the case it describes, so
    /// this is one placeholder for all eighteen rather than an eighteen-arm switch that
    /// repeated the same glyph and the same call over and over.
    private func smartListPlaceholder(for type: SmartListType) -> some View {
        let copy = type.emptyState
        return StandardPlaceholder(
            glyph: ViewGlyphs.smartList.filled,
            title: copy.title,
            message: copy.message
        )
    }
    
    // MARK: - Initialization
    
    private func initializeIfNeeded() {
        guard !hasInitialized else { return }
        hasInitialized = true
        #if DEBUG
        ViewSwitchProbe.record("gallery.appear sidebar=\(appState.selectedSidebarItem) active=\(ViewStateManager.shared.activeView)")
        #endif
        Self.log("GalleryView appeared (instance: \(viewID))")

        // NOTE: No singleton registration here — deliberately. The sub-category state
        // singletons (RecentsState, the format/variant/sorting states) route their
        // shared switch sequence through SubcategoryNavigation, which reaches the
        // process-wide SelectionState.shared and AppDelegate.appState directly (both
        // are set at process init, before any UI interaction), so the former
        // setAppState/setSelectionState registration dance is no longer needed.

        updateListInfo()
        
        // Only load if both caches ready and we haven't loaded yet
        if PosterCache.shared.isReady && dataCoordinator.isInitialized && !hasLoadedInitialView {
            Self.log("Cache ready on appear - loading view immediately")
            hasLoadedInitialView = true
            ViewStateManager.shared.switchToViewSync(viewIDFromSidebar())
        }
    }
    
    /// Re-subscribes event handlers on every appear.
    /// Called from onAppear so that subscriptions are restored after onDisappear
    /// canceled them. initializeIfNeeded() only runs once (guarded by hasInitialized),
    /// so event-handler setup cannot live there — it must be idempotent and repeatable.
    private func setupEventHandlersIfNeeded() {
        // If cancellables are already populated the handlers are still active.
        guard eventHandler.cancellables.isEmpty else { return }
        setupEventHandlers()
    }
    
    // Guard against duplicate initial loads
    private func handleReadyState() {
        guard !hasLoadedInitialView else {
            Self.log("Skipping handleReadyState - already loaded initial view")
            return
        }
        
        Self.log("DataCoordinator and cache ready - loading initial view")
        hasLoadedInitialView = true
        updateListInfo()
        ViewStateManager.shared.switchToViewSync(viewIDFromSidebar())
    }
    
    private func setupEventHandlers() {
        let handler = eventHandler
        
        // Note: search query changes are applied synchronously by SearchController.triggerSearch()
        // via a direct ViewStateManager.updateSearchQuery() call. No AppEventBus subscriber is
        // needed here — the synchronous path is both faster and race-condition-free.
        
        // NOTE: there is deliberately no .membershipChanged subscription here. The gallery's
        // own contents are already kept current by DataCoordinator.addFilmsToList /
        // removeFilmsFromList, which call refreshFilms() themselves whenever the affected
        // list is the one on screen; the subscription that used to live here existed solely
        // to maintain a cached list film count that no view ever read, and every event it
        // handled cost a RunLoop hop plus a redundant @State write that invalidated this
        // whole view's body.
        
        // Film changes (consolidated handler for updated/added/deleted).
        // All three event types share the same core logic: force-reload the current view
        // state and bump forceReloadID to signal GallerySubview. The only difference is
        // scroll behavior — film updates request a scroll-to-film evaluation, while
        // adds/deletes do not.
        AppEventBus.shared.filmEvents
            .receive(on: RunLoop.main)
            .sink { [weak dataCoordinator, weak appState] event in
                // Liveness check only — neither object is read in this closure any more,
                // so they are tested rather than bound (a binding would be unused).
                guard dataCoordinator != nil, appState != nil else { return }

                // Extract the scroll target (if any).
                let scrollTarget: UUID?
                switch event {
                case .updated(let filmID):
                    scrollTarget = filmID
                case .added, .deleted:
                    scrollTarget = nil
                default:
                    return
                }
                
                Self.log("Film change detected - preserving current view state")
                
                // Refresh data without reloading view state, keeping search query intact.
                ViewStateManager.shared.forceReload()
                
                // Signal the gallery to evaluate the post-edit scroll position. The request
                // is one-shot on the gallery's side (each carries a fresh token and is acted
                // on once), so it is simply left in place rather than cleared on a later
                // turn — clearing it cost every edit a second full gallery update pass.
                if let scrollTarget { scrollRequest = FilmScrollRequest(filmID: scrollTarget) }
                forceReloadID = UUID()
            }
            .store(in: &handler.cancellables)
        
        // Smart list membership changed underneath an open gallery. Two independent sources
        // post this: the daily midnight rotation recalculation and the rotation-family display
        // filters (both of which affect only "Up for Rotation" / "Viewed Over One Year Ago"),
        // and any full recalculation, which replaces the membership of ALL smart lists —
        // startup's deferred calculation, re-enabling the feature, a database restore/import,
        // or a bulk rotation-threshold reset.
        //
        // Because a full recalculation can change any list, this must refresh whenever the
        // active view is a smart list of any kind. Scoping it to only the two rotation lists
        // left every other smart list showing pre-recalculation membership until the user
        // navigated away and back. Non-smart-list views are still skipped entirely, and
        // forceReload is an in-memory filtered pass, so the occasional redundant refresh from
        // a rotation-only broadcast is negligible.
        AppEventBus.shared.viewEvents
            .filter { if case .smartListsRecalculated = $0 { return true } else { return false } }
            .receive(on: RunLoop.main)
            .sink { _ in
                guard case .smartList = ViewStateManager.shared.activeView else { return }
                Self.log("Smart lists recalculated - refreshing active smart list view")
                ViewStateManager.shared.forceReload()
                forceReloadID = UUID()
            }
            .store(in: &handler.cancellables)

        Self.log("Event handlers setup complete (instance: \(viewID))")
    }

    // MARK: - Sidebar Handling

    private func handleSidebarChange(from oldItem: SidebarItem, to newItem: SidebarItem) {
        guard dataCoordinator.isInitialized else {
            Self.log("Ignoring sidebar change - coordinator not initialized")
            return
        }
        
        Self.log("Sidebar selection changed: \(String(describing: newItem))")

        // For a gallery-backed destination AppState.navigate(to:) has already run this
        // same preparation, and the switch, before the flip that fired this handler (see
        // prepareSidebarTransition), so here every step below re-applies an outcome that
        // is already in place and is a no-op. It remains the path for every other
        // destination, exactly as before.
        let isSubcategoryView = Self.prepareSidebarTransition(from: oldItem, to: newItem)

        // Selection clearing is now handled by MainView.handleViewChange()
        // to ensure it happens reliably for all view switches, including
        // when switching between different GalleryView instances with stable .id()
        
        updateListInfo()
        
        // Only call switchToViewSync if NOT switching to a subcategory-tab view (each
        // such state's own ensureInitialViewLoad, called above, already handles the
        // switch).
        if !isSubcategoryView {
            ViewStateManager.shared.switchToViewSync(viewIDFromSidebar())
        }
    }

    /// Every subcategory-tab state (Recents, Unwatched, and any future addition) whose
    /// initial-load/reset lifecycle must be synchronized with sidebar navigation. See
    /// SubcategoryViewState's doc comment (ViewState.swift) — adding a new
    /// subcategory-tab view means adding its state here; the sidebar transition itself
    /// never needs to change.
    private static var subcategoryStates: [any SubcategoryViewState] {
        [RecentsState.shared, UnwatchedState.shared]
    }

    /// The model-side half of a sidebar transition: intent invalidation, the
    /// subcategory-tab lifecycle, and the smart-list picker resync. Returns whether
    /// `newItem` is scoped to a subcategory-tab state (whose ensureInitialViewLoad has
    /// then already performed the view switch, unless it had nothing left to do).
    ///
    /// Shared by handleSidebarChange and preSwitchBeforeSidebarFlip. Every step is
    /// idempotent, which is what lets both run for the same navigation.
    static func prepareSidebarTransition(from oldItem: SidebarItem, to newItem: SidebarItem) -> Bool {
        // A genuine navigation invalidates any unconsumed scroll intent addressed to a
        // view OTHER than the destination — e.g. a grid⟷list toggle handoff whose
        // destination style never mounted before the user navigated elsewhere. Without
        // this, a stale target addressed to the view being left could linger and
        // trigger a surprise scroll on some later, unrelated visit. An intent addressed
        // to the destination itself — the search-exit handoff, which MainView sets
        // immediately before the sidebar flip that fires this very handler — must
        // survive here so the destination gallery's makeNSView can consume it.
        GalleryScrollIntent.shared.clear(unlessTargeting: ViewIdentifier.from(newItem))
        GalleryFocusIntent.shared.clear(unlessTargeting: ViewIdentifier.from(newItem))

        // Synchronize every subcategory-tab state's initial-load/reset lifecycle with
        // this navigation, and determine whether newItem is scoped to any of them
        // (in which case ensureInitialViewLoad, called below, already performs the
        // view switch, so the final switchToViewSync call must be skipped for it).
        // See SubcategoryViewState's doc comment (ViewState.swift).
        var isSubcategoryView = false
        for state in subcategoryStates {
            let wasActive = oldItem == state.scopedSidebarItem
            let isActive = newItem == state.scopedSidebarItem
            if isActive {
                isSubcategoryView = true
            }
            if isActive && !wasActive {
                // Switching TO this state's view - ensure initial load
                state.ensureInitialViewLoad()
            } else if wasActive && !isActive {
                // Switching AWAY from this state's view - reset for next visit
                state.resetInitialization()
            }
        }
        
        // Sync the smart list family's sub-variant picker when switching to a smart list
        if case .smartList(let parent) = newItem {
            // Sync the sub-variant pickers to the smart list that is ACTUALLY being
            // displayed, not merely to the sidebar row being switched to.
            //
            // For an ordinary sidebar click the two are the same thing: activeView still
            // holds the outgoing view (or a smart list from a different family), the
            // fallback below selects `parent`, and each picker resets to its parent
            // default exactly as before.
            //
            // They diverge for the two navigations that promote ViewStateManager to the
            // destination BEFORE flipping the sidebar — ShowInListNavigation and the
            // search-exit pre-load. Those can land on a sub-variant that has no sidebar row
            // of its own ("Purchased 4K", "Viewed Over One Year Ago", "Blacklisted", …),
            // where syncing to `parent` would reset the picker to "All" while the films on
            // screen are the sub-variant's — leaving the control disagreeing with the
            // content. Honoring the loaded view keeps the two in agreement in every case.
            //
            // The sidebarParent test is what makes this safe: a loaded smart list from an
            // unrelated family can never be mistaken for a sub-variant of `parent`.
            var resolved = parent
            if let displayed = ViewStateManager.shared.activeView.smartListType,
               displayed.sidebarParent == parent {
                resolved = displayed
            }
            SmartListVariantState.syncAll(to: resolved)
        }
        
        return isSubcategoryView
    }

    /// Promotes ViewStateManager (and so dataCoordinator.films) to a gallery-backed
    /// destination BEFORE AppState flips selectedSidebarItem. Called only from
    /// AppState.navigate(to:).
    ///
    /// MainContentSwitcher keys GalleryView on the sidebar item, so the flip mounts a
    /// fresh GalleryView, and that view's first body builds its gallery from whatever
    /// activeView, activeState.isListView and films hold at that instant. When the switch
    /// ran afterwards (from onAppear / handleSidebarChange), that was still the OUTGOING
    /// view: every sidebar switch built and fully reloaded a gallery of the previous
    /// view's films, then reloaded it again with the destination's — and when the two
    /// views differ in grid/list style, built the wrong style outright, reloaded it, tore
    /// it down and built the right one. Switching first makes the fresh mount's first pass
    /// the only reload, in the correct style.
    ///
    /// This is the ordering ShowInListNavigation, the search-exit pre-load and the
    /// MenuBar's smart-list commands already use. It also lets prepareScrollHandoff bank
    /// the outgoing origin from the outgoing gallery while it is genuinely still mounted,
    /// which is the moment its own doc comment asks for.
    ///
    /// Unconditional switch, even for a subcategory-tab view: its ensureInitialViewLoad
    /// switches only on the first entry after a reset, and when it does, this call is a
    /// no-op re-entry to the same view.
    static func preSwitchBeforeSidebarFlip(from oldItem: SidebarItem, to newItem: SidebarItem) {
        _ = prepareSidebarTransition(from: oldItem, to: newItem)
        ViewStateManager.shared.switchToViewSync(ViewIdentifier.from(newItem))
    }

    private func viewIDFromSidebar() -> ViewIdentifier {
        ViewIdentifier.from(appState.selectedSidebarItem)
    }

    private func updateListInfo() {
        if case .list(let listID) = appState.selectedSidebarItem,
           let list = dataCoordinator.getList(listID) {
            cachedListID = list.listID
        } else {
            cachedListID = nil
        }
    }

    private func clearFiltersAndSearch() {
        Self.log("Clearing filters and search")
        // One committed state change rather than two, so this costs a single film reload
        // instead of two before the search-exit navigation below triggers its own.
        ViewStateManager.shared.clearFiltersAndSearch()
        SearchController.shared.clearSearch()
    }
    
    private func clearFiltersOnly() {
        Self.log("Clearing filters only")
        ViewStateManager.shared.clearFilters()
    }
    
}

// MARK: - SubscriptionHolder

/// Manages Combine subscriptions for gallery event handlers with proper lifecycle cleanup.
/// Plain reference type — not ObservableObject — because it holds no @Observable
/// properties that SwiftUI needs to observe. No deinit: each AnyCancellable cancels itself
/// when the set releases it, which is exactly what an explicit removeAll() there did.
private final class SubscriptionHolder {
    var cancellables = Set<AnyCancellable>()

    func cancel() {
        cancellables.removeAll()
    }
}

/// A post-edit request to keep a film in view, handed from GalleryView to both gallery
/// styles. The token makes two requests for the same film distinct, so a gallery can act on
/// each exactly once by remembering the last one it saw.
struct FilmScrollRequest: Equatable {
    let filmID: UUID
    let token = UUID()
}
