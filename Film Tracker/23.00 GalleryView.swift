// MARK: - GalleryView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Root content view that displays the film grid or list for the active view (all films,
// user list, smart list, recents, etc.). ViewStateManager, SearchController, and PosterCache
// are @Observable singletons, so views track only the properties they read.

import SwiftUI
import Combine
import os

struct GalleryView: View, Loggable {
    nonisolated static let logTag = "[GalleryView]"

    @Environment(AppState.self) private var appState
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SelectionState.self) private var selectionState

    /// The sidebar item this instance was mounted for. SwiftUI gives the outgoing instance one more
    /// update pass after a sidebar change, so isOutgoing skips rendering on that pass.
    let sidebarItem: SidebarItem

    /// The list being viewed, or nil in a non-list view. Used by the loading and placeholder logic.
    /// Removal commands resolve the active list through FilmRemoval instead.
    @State private var cachedListID: UUID?
    @State private var viewID = UUID()
    @State private var hasInitialized = false
    @State private var hasLoadedInitialView = false  // Prevents duplicate loads
    @State private var scrollRequest: FilmScrollRequest?
    
    /// Holds the Combine subscriptions for gallery event handlers. It is a plain reference type with
    /// no published state, so it is not an ObservableObject.
    @State private var eventHandler = SubscriptionHolder()

    private var viewStateManager: ViewStateManager { ViewStateManager.shared }

    var body: some View {
        VStack(spacing: 0) {
            GalleryTitleBar(
                viewIdentifier: viewStateManager.activeView
            )
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            
            ZStack {
                // The films on screen. This lags activeState only during a Film Queue tab switch (see
                // ViewStateManager.displayedGalleryState).
                let shown = viewStateManager.displayedGalleryState(
                    loadedQueueFilter: dataCoordinator.loadedFilmQueueFilter)
                if !isOutgoing && !dataCoordinator.films.isEmpty && PosterCache.shared.isReady && !shouldShowLoading {
                    // showSectionDividers is read here, from `shown`, so the style and the dividers always come from
                    // the same tab. Passing it down makes a change an ordinary value change on the representable.
                    if shown.isListView {
                        GalleryListView(activeViewID: viewStateManager.activeView,
                                        scrollRequest: scrollRequest,
                                        subtitleProvider: subtitleProvider,
                                        showSectionDividers: shown.showSectionDividers)
                            .environment(dataCoordinator)
                            .environment(selectionState)
                    } else {
                        GallerySubview(scrollRequest: scrollRequest, activeViewID: viewStateManager.activeView, subtitleProvider: subtitleProvider, showSectionDividers: shown.showSectionDividers)
                            .environment(dataCoordinator)
                            .environment(selectionState)
                    }
                }
                
                if shouldShowPlaceholder {
                    placeholderView
                        .onAppear { LaunchReveal.shared.placeholderAppeared() }
                }
                
                // At launch LaunchReveal owns the spinner. Afterward the ordinary spinner below takes over.
                if LaunchReveal.shared.isActive {
                    if LaunchReveal.shared.showsSpinner {
                        LaunchSpinnerOverlay(dismissing: !shouldShowLoading)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .onAppear { LaunchTimeline.markLoadingIndicatorShown() }
                    }
                } else if shouldShowLoading {
                    Color(NSColor.controlBackgroundColor).opacity(0.5)
                        .overlay(ProgressView())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        // No .focusedSceneValue for selectedFilmIDs or selectedFilmID here. FilmTrackerApp publishes both
        // at the scene root, which keeps MenuBar's @FocusedValue working in every view. Reading selection in
        // this body would also re-evaluate the whole gallery on every click.
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

    /// True for the one update pass after the sidebar has moved to another item, just before SwiftUI
    /// removes this instance. The destination's state is already in place, so this pass renders nothing.
    /// dismantleNSView still saves the outgoing scroll origin.
    private var isOutgoing: Bool {
        appState.selectedSidebarItem != sidebarItem
    }

    /// The subtitle provider for the view being rendered. It is derived rather than stored. A cached
    /// @State rebuilt in onChange ran after the body that read it, so the first render of a new view
    /// used the previous view's provider and showed stale date subtitles.
    ///
    /// Building it in the body keeps it in step with the ViewIdentifier passed to GallerySubview. The
    /// allocation is cheap, and the closure runs only during cell configuration.
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

        // The spinner and the placeholder are mutually exclusive. While films are still loading, only the
        // spinner shows. Otherwise an empty user list would show "List is Empty" under it.
        guard !shouldShowLoading else { return false }

        // Recents, smart lists, the Film Queue, and Unwatched show a placeholder when empty. See
        // ViewIdentifier.treatsEmptyAsValidState.
        if viewStateManager.activeView.treatsEmptyAsValidState {
            // An empty Film Queue is a valid state and shows its own placeholder.
            return true
        }

        return !dataCoordinator.hasDatabaseFilms || isNarrowed || cachedListID != nil
    }

    /// True while a search query, search tokens, or a filter could explain an empty result. The spinner
    /// and the placeholder both read this, so each empty state falls to exactly one of them. Tokens come
    /// from SearchController.currentTokens, which is current before activeState.searchQuery catches up.
    private var hasSearchContent: Bool {
        !viewStateManager.activeState.searchQuery.isEmpty || !SearchController.shared.currentTokens.isEmpty
    }

    private var isNarrowed: Bool {
        hasSearchContent || !viewStateManager.activeState.filterOptions.isEmpty
    }

    /// True only while the gallery is waiting for films it knows exist. A filter, query, or token can
    /// narrow the result to nothing. In that case the empty result is an answer, so the spinner stays off.
    /// This applies to user lists as well as All Films.
    private var shouldShowLoading: Bool {
        guard dataCoordinator.isInitialized, PosterCache.shared.isReady else { return true }

        // Empty is a valid state for these views (see ViewIdentifier.treatsEmptyAsValidState).
        guard !viewStateManager.activeView.treatsEmptyAsValidState,
              dataCoordinator.films.isEmpty else { return false }

        // Token-only searches, such as OR, count as narrowing. Without this, the spinner could stay up
        // after an OR token is confirmed.
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
        
        // A saved search stored with rules this version cannot read shows no films until
        // it is saved again (SavedSearchStore.needsReview) — this, not a "No Results", is
        // what says so, whatever filters are on.
        if case .savedSearch(let id) = viewStateManager.activeView, SavedSearchStore.shared.needsReview(id) {
            StandardPlaceholder(
                glyph: "exclamationmark.triangle.fill",
                title: "Search Configuration Changed",
                message: "There was an issue restoring this saved search\u{2019}s configuration and it needs to be updated.",
                actionTitle: "Edit Saved Search\u{2026}",
                action: { SavedSearchActions.edit(id) }
            )
        } else if case .savedSearch(let id) = viewStateManager.activeView {
            savedSearchPlaceholder(for: id, hasFilters: hasFilters)
        } else if case .recents(let category) = viewStateManager.activeView {
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
            filtersPlaceholder
        } else if isListView && dataCoordinator.hasDatabaseFilms {
            StandardPlaceholder(
                glyph: ViewGlyphs.userList.outline,
                title: "List is Empty",
                message: "Add films to this list to get started."
            )
        } else {
            emptyLibraryPlaceholder
        }
    }

    private var filtersPlaceholder: some View {
        StandardPlaceholder(
            glyph: ViewGlyphs.activeFilters.filled,
            title: "No Results",
            message: "Try adjusting your filters.",
            actionTitle: "Clear Filters",
            action: clearFiltersOnly
        )
    }

    private var emptyLibraryPlaceholder: some View {
        StandardPlaceholder(
            glyph: ViewGlyphs.allFilms.filled,
            title: "Add Films to Get Started",
            message: "Import films, or add them manually."
        )
    }

    /// An empty saved search, by cause: an empty library, rules that match no film, or
    /// filters that leave none of the films the rules match. Rules that match nothing win
    /// over filters — clearing the filters would not help.
    @ViewBuilder
    private func savedSearchPlaceholder(for id: UUID, hasFilters: Bool) -> some View {
        if !dataCoordinator.hasDatabaseFilms {
            emptyLibraryPlaceholder
        } else if hasFilters && !dataCoordinator.savedSearchMatchedNothing(id) {
            filtersPlaceholder
        } else {
            StandardPlaceholder(
                glyph: ViewGlyphs.savedSearch.outline,
                title: "No Results",
                message: "No films in your library match this saved search\u{2019}s rules.",
                actionTitle: "Edit Saved Search\u{2026}",
                action: { SavedSearchActions.edit(id) }
            )
        }
    }
    
    @ViewBuilder
    private func filmQueuePlaceholder() -> some View {
        let selectedFilter = FilmQueueFilterState.shared.selectedFilter
        // dataCoordinator.films is filtered to the selected section, so an empty result says only that the
        // current section is empty. getFilmQueueFilmIDs() covers all three sections and is the reliable check.
        if selectedFilter == .all || dataCoordinator.getFilmQueueFilmIDs().isEmpty {
            // The queue as a whole has nothing assigned yet.
            StandardPlaceholder(
                glyph: ViewGlyphs.filmQueue.outline,
                title: "Your Queue Is Empty",
                message: "Assign films to the Up Next, Soon, or Later section from a film's Details tab to build your queue."
            )
        } else {
            // The queue has films overall, but none in this section.
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
    
    /// Empty-state placeholder for any smart list. The per-list copy is on `SmartListType.emptyState`, so
    /// one placeholder covers all twenty cases.
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
        LaunchReveal.shared.galleryViewAppeared()
        Self.log("GalleryView appeared (instance: \(viewID))")

        // No singleton registration is needed here. The sub-category state singletons reach the shared
        // SelectionState and AppState directly, through SubcategoryNavigation.

        updateListInfo()
        
        // Only load if both caches ready and we haven't loaded yet
        if PosterCache.shared.isReady && dataCoordinator.isInitialized && !hasLoadedInitialView {
            Self.log("Cache ready on appear - loading view immediately")
            hasLoadedInitialView = true
            ViewStateManager.shared.switchToViewSync(viewIDFromSidebar())
        }
    }
    
    /// Re-subscribes event handlers on every appear, since onDisappear cancels them. initializeIfNeeded()
    /// runs only once, so the setup must be idempotent and repeatable here.
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
        
        // Search query changes are applied synchronously by SearchController.triggerSearch(), so no event
        // subscriber is needed.
        
        // There is deliberately no .membershipChanged subscription. DataCoordinator.addFilmsToList and
        // removeFilmsFromList call refreshFilms() themselves when the affected list is on screen.
        
        // Film changes and smart-list recalculations underneath an open smart list. Each change that can
        // alter this view is noted on the holder. The holder flushes once per turn and reloads only if no full
        // load has happened since the latest change. A single edit loads itself in DataCoordinator.reloadCurrentView,
        // so it is not reloaded again. A burst of per-film events costs one load.
        //
        // The subscription runs synchronously, so the load generation is read at the moment of the event, before
        // the sender's own reload moves it on. Only the flush waits one turn.
        AppEventBus.shared.filmEvents
            .sink { [weak dataCoordinator] event in
                guard let dataCoordinator else { return }
                switch event {
                case .updated(let filmID):
                    // Edits also ask the gallery to keep the edited film in view.
                    handler.pendingScrollTarget = filmID
                case .added:
                    break
                case .deleted:
                    // Already loaded by every sender, which reloads after removing the films from MemoryStore. The films are gone, so no membership change can alter that load. See DataCoordinator.deleteFilms.
                    return
                case .releaseChanged:
                    return
                }
                handler.noteChange(coordinator: dataCoordinator, flush: flushChanges)
            }
            .store(in: &handler.cancellables)

        // Smart list membership changed underneath an open gallery. Two sources post this: the midnight
        // rotation recalculation, and any full recalculation (startup, re-enabling the feature, a restore or import,
        // or a rotation-threshold reset). A full recalculation can change any list, so this refreshes whenever the
        // active view is any smart list. Non-smart-list views are skipped. The refresh is an in-memory filter pass,
        // so an occasional redundant refresh costs little.
        AppEventBus.shared.viewEvents
            .filter { if case .smartListsRecalculated = $0 { return true } else { return false } }
            .sink { [weak dataCoordinator] _ in
                guard let dataCoordinator else { return }
                switch ViewStateManager.shared.activeView {
                case .smartList, .savedSearch: break
                default: return
                }
                Self.log("Smart lists recalculated - refreshing active membership view")
                handler.noteChange(coordinator: dataCoordinator, flush: flushChanges)
            }
            .store(in: &handler.cancellables)

        Self.log("Event handlers setup complete (instance: \(viewID))")
    }

    /// The deferred half of the change handlers, run once per turn by the holder. `reload` is false when
    /// DataCoordinator has fully loaded the view since the latest change, as it does for every edit it announces.
    ///
    /// No other signal is sent. A reload that changes films reaches the gallery through `dataCoordinator.films`,
    /// and a post-edit scroll through `scrollRequest`.
    private func flushChanges(reload: Bool, scrollTarget: UUID?) {
        if reload {
            Self.log("Film or smart-list change not yet loaded - reloading current view state")
            // Refresh data without reloading view state, keeping search query intact.
            ViewStateManager.shared.forceReload()
        }
        // Signals the gallery to evaluate the post-edit scroll. The request is one-shot on the gallery's side, so
        // it is left in place rather than cleared later.
        if let scrollTarget { scrollRequest = FilmScrollRequest(filmID: scrollTarget) }
    }

    // MARK: - Sidebar Handling

    private func handleSidebarChange(from oldItem: SidebarItem, to newItem: SidebarItem) {
        guard dataCoordinator.isInitialized else {
            Self.log("Ignoring sidebar change - coordinator not initialized")
            return
        }
        
        Self.log("Sidebar selection changed: \(String(describing: newItem))")

        // For a gallery-backed destination, AppState.navigate(to:) has already run this preparation before the
        // flip. Here every step re-applies a result already in place, so it is a no-op. It is the path for every
        // other destination.
        let isSubcategoryView = Self.prepareSidebarTransition(from: oldItem, to: newItem)

        // Selection clearing is handled by MainView.handleViewChange(), which covers every view switch.
        
        updateListInfo()
        
        // switchToViewSync runs only for views that are not subcategory tabs. Those handle their own switch.
        if !isSubcategoryView {
            ViewStateManager.shared.switchToViewSync(viewIDFromSidebar())
        }
    }

    /// Every subcategory-tab state (Recents, Unwatched, and any future addition) whose initial-load and reset
    /// lifecycle must sync with sidebar navigation. See SubcategoryViewState (ViewState.swift). A new subcategory
    /// tab adds its state here. The sidebar transition itself does not change.
    private static var subcategoryStates: [any SubcategoryViewState] {
        [RecentsState.shared, UnwatchedState.shared]
    }

    /// The model-side half of a sidebar transition: intent invalidation, the subcategory-tab lifecycle, and the
    /// smart-list picker resync. Returns whether `newItem` is a subcategory-tab view, whose ensureInitialViewLoad has
    /// already switched the view. Shared by handleSidebarChange and preSwitchBeforeSidebarFlip. Every step is idempotent.
    static func prepareSidebarTransition(from oldItem: SidebarItem, to newItem: SidebarItem) -> Bool {
        // A real navigation invalidates any unconsumed scroll intent aimed at a view other than the destination. Without
        // this, a stale target could cause a surprise scroll on a later visit. An intent aimed at the destination, such as
        // the search-exit handoff, must survive so the destination's makeNSView can consume it.
        GalleryScrollIntent.shared.clear(unlessTargeting: ViewIdentifier.from(newItem))
        GalleryFocusIntent.shared.clear(unlessTargeting: ViewIdentifier.from(newItem))

        // Syncs each subcategory-tab state with this navigation and checks whether newItem belongs to one. If it does,
        // ensureInitialViewLoad has already switched the view, so the final switchToViewSync is skipped.
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
            // Syncs the sub-variant pickers to the smart list actually displayed, not just the sidebar row clicked. For an
            // ordinary sidebar click the two are the same, so each picker resets to its parent. They differ for
            // ShowInListNavigation and the search-exit pre-load, which promote the view before the flip. Those can land on a
            // sub-variant with no sidebar row of its own, such as "Purchased 4K". Syncing to the parent would then disagree
            // with the films on screen. The sidebarParent test keeps an unrelated family from being mistaken for a sub-variant.
            var resolved = parent
            if let displayed = ViewStateManager.shared.activeView.smartListType,
               displayed.sidebarParent == parent {
                resolved = displayed
            }
            SmartListVariantState.syncAll(to: resolved)
        }
        
        return isSubcategoryView
    }

    /// Promotes ViewStateManager, and so dataCoordinator.films, to a gallery view BEFORE AppState flips
    /// selectedSidebarItem. Called only from AppState.navigate(to:).
    ///
    /// MainContentSwitcher keys GalleryView on the sidebar item, so the flip mounts a fresh GalleryView. Its first
    /// body reads whatever view is active at that moment. Switching first makes that first pass the only reload, in
    /// the correct style. The switch is unconditional. For a subcategory tab it is a no-op re-entry after the first switch.
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
        // One committed state change, so only one film reload runs.
        ViewStateManager.shared.clearFiltersAndSearch()
        SearchController.shared.clearSearch()
    }
    
    private func clearFiltersOnly() {
        Self.log("Clearing filters only")
        ViewStateManager.shared.clearFilters()
    }
    
}

// MARK: - SubscriptionHolder

/// Manages Combine subscriptions for gallery event handlers, cancels them on teardown, and coalesces their
/// changes into one flush per turn. It is a plain reference type. No deinit is needed, since each AnyCancellable
/// cancels when the set releases it.
@MainActor
private final class SubscriptionHolder {
    var cancellables = Set<AnyCancellable>()

    /// The film the latest edit in this turn asked to keep in view.
    var pendingScrollTarget: UUID?
    /// DataCoordinator.fullLoadGeneration when the latest change of this turn arrived.
    private var generationAtLatestChange: Int?
    private weak var coordinator: DataCoordinator?
    private var flush: ((_ reload: Bool, _ scrollTarget: UUID?) -> Void)?
    private var isFlushScheduled = false
    /// Carries the turn's flush request to the main run loop. A run-loop delivery lands before SwiftUI's update for
    /// the turn, so the scroll request joins the sender's reload in one gallery update pass. DispatchQueue.main.async
    /// would arrive too late and cost a second pass.
    private let flushRequests = PassthroughSubject<Void, Never>()
    private var flushSubscription: AnyCancellable?

    /// Records a change the view may not have loaded yet, and schedules the turn's flush. The flush reloads only if
    /// no full load has happened since the latest change. A load after the last change covers every earlier change.
    func noteChange(coordinator: DataCoordinator,
                    flush: @escaping (_ reload: Bool, _ scrollTarget: UUID?) -> Void) {
        generationAtLatestChange = coordinator.fullLoadGeneration
        self.coordinator = coordinator
        self.flush = flush
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        if flushSubscription == nil {
            flushSubscription = flushRequests
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.performFlush() }
        }
        flushRequests.send()
    }

    private func performFlush() {
        isFlushScheduled = false
        let reload = generationAtLatestChange != nil
            && generationAtLatestChange == coordinator?.fullLoadGeneration
        let target = pendingScrollTarget
        generationAtLatestChange = nil
        pendingScrollTarget = nil
        flush?(reload, target)
    }

    /// Also drops a flush already scheduled, since canceling the subscription cancels its delivery.
    func cancel() {
        cancellables.removeAll()
        flushSubscription = nil
        isFlushScheduled = false
        generationAtLatestChange = nil
        pendingScrollTarget = nil
        flush = nil
    }
}

/// A post-edit request to keep a film in view, handed from GalleryView to both gallery styles. The token makes two
/// requests for the same film distinct, so each gallery acts on each one once.
struct FilmScrollRequest: Equatable {
    let filmID: UUID
    let token = UUID()
}

// MARK: - Launch Reveal

/// How the gallery first appears at launch. The snapshot cache's verdict is known early, so the launch picks its
/// look up front. A warm launch (cache hit) holds the main window transparent and shows it with the gallery's first
/// content, so the first visible frame is the loaded gallery. A cold launch shows the spinner and crossfades it
/// with the gallery. Both fades are Core Animation opacity animations, so main-thread work cannot stall them.
@MainActor @Observable
final class LaunchReveal {
    static let shared = LaunchReveal()

    static let fadeDuration: CFTimeInterval = 0.2

    /// The early pipeline's verdict, written from its background task. nil means unknown, which is treated as cold.
    private nonisolated static let prediction = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    nonisolated static func recordSnapshotPrediction(hit: Bool) {
        prediction.withLock { $0 = hit }
    }

    /// True until the launch reveal finishes. GalleryView then draws its ordinary spinner.
    private(set) var isActive = true {
        didSet { if !isActive { allowMenuRefresh() } }
    }

    /// False until the launch's gallery (or its placeholder) is on screen. MenuBar holds its library-derived refresh
    /// until then, so the rebuild runs after the first frame. Nobody can open a menu before the window is visible.
    private(set) var menuRefreshAllowed = LaunchExperiment.noMenuGate

    /// Flips `menuRefreshAllowed` on a later main-queue turn than the one that shows the window, so the window's commit
    /// is not held behind menu work. It runs from every path that ends the reveal, and from showHeldWindow. The backstop
    /// in initializationFinished covers a reveal that never ends.
    private func allowMenuRefresh() {
        guard !menuRefreshScheduled else { return }
        menuRefreshScheduled = true
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    LaunchTimeline.mark("menuRefreshAllowed")
                    self.allowMenuContent()
                    self.menuRefreshAllowed = true
                }
            }
        }
    }

    @ObservationIgnored private var menuRefreshScheduled = false

    /// False while a warm launch holds its window hidden. It becomes true when the window can first be seen. MenuBar
    /// builds its costliest submenus (View > Left Sidebar and Sort By) only after this, so a warm launch builds them
    /// after its first frame. Neither has a shortcut the menu delivers, because KeyboardManager's key monitor handles
    /// those keys first.
    private(set) var menuContentAllowed = LaunchExperiment.noMenuGate

    private func allowMenuContent() {
        guard !menuContentAllowed else { return }
        LaunchTimeline.mark("menuContentAllowed")
        menuContentAllowed = true
    }

    /// Decided on first read and then fixed, so the spinner never vanishes mid-launch. Only a predicted hit that turns
    /// out a miss changes it, toward showing the spinner.
    var showsSpinner: Bool {
        if snapshotDidMiss { return true }
        if let decided = spinnerDecision { return decided }
        let decided = Self.prediction.withLock { $0 } != true
        spinnerDecision = decided
        return decided
    }

    @ObservationIgnored private var spinnerDecision: Bool?
    private var snapshotDidMiss = false
    @ObservationIgnored private var hasRevealed = false

    /// The main window while a warm launch holds it transparent. nil once it is shown.
    @ObservationIgnored private weak var heldWindow: NSWindow?
    @ObservationIgnored private(set) var didHoldWindow = false
    @ObservationIgnored private var galleryMounted = false

    /// From LaunchWindowHold, as the main window's root view joins its window, before the first frame. Holds it only on a
    /// predicted warm launch.
    func windowWillAppear(_ window: NSWindow) {
        guard isActive, !didHoldWindow, !showsSpinner else {
            // Not held: the window is about to be seen as it is.
            if !didHoldWindow { allowMenuContent() }
            return
        }
        didHoldWindow = true
        heldWindow = window
        window.alphaValue = 0
        LaunchTimeline.mark("windowHeld")
    }

    /// Shows the held window on the main queue's next turn, after this turn's Core Animation commit, so it appears with
    /// whatever this update pass put in it. A CATransaction completion block would wait for every animation to finish,
    /// which delays the window.
    private func showHeldWindowOnCommit() {
        guard heldWindow != nil else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.showHeldWindow() }
        }
    }

    private func showHeldWindow() {
        guard let window = heldWindow else { return }
        heldWindow = nil
        window.alphaValue = 1
        LaunchTimeline.mark("windowShown")
        allowMenuRefresh()
        LaunchTimeline.finalizeIfComplete()
    }

    /// A predicted hit that turned out a miss: show the window now, spinner and all.
    func snapshotMissed() {
        snapshotDidMiss = true
        showHeldWindow()
    }

    func galleryViewAppeared() {
        galleryMounted = true
    }

    /// GalleryView's launch view is empty and draws a placeholder instead of the gallery.
    func placeholderAppeared() {
        guard isActive, !showsSpinner else { return }
        showHeldWindowOnCommit()
        isActive = false
    }

    /// Initialization is done. A launch into a view without a gallery shows its window with this update. The backstop
    /// shows the window if a mounted gallery never reports, so a launch cannot stay invisible.
    func initializationFinished() {
        // A reveal that never ends must not leave the menu bar showing pre-load state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { self.allowMenuRefresh() }
        }
        guard heldWindow != nil else { return }
        if !galleryMounted {
            showHeldWindowOnCommit()
            isActive = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                guard self.heldWindow != nil else { return }
                GalleryView.log("LaunchReveal backstop: gallery never reported its first frame; showing the window", level: .warning)
                self.showHeldWindow()
                self.isActive = false
            }
        }
    }

    /// Called by the gallery style that draws first, in the update pass that loads its first films, before reloadData.
    /// Warm: the held window shows when this pass's transaction commits. Cold: the fade-in starts with that first content.
    func galleryWillAppear(_ scrollView: NSScrollView) {
        guard isActive, !hasRevealed else { return }
        hasRevealed = true
        guard showsSpinner else {
            showHeldWindowOnCommit()
            isActive = false
            return
        }
        scrollView.wantsLayer = true
        if let layer = scrollView.layer {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Self.fadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "launchReveal")
        }
        finishAfterFade()
    }

    /// Ends the reveal once the fades are done. Also reached when the spinner overlay dismisses without a gallery.
    func finishAfterFade() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration + 0.05) {
            MainActor.assumeIsolated { self.isActive = false }
        }
    }
}

/// Placed in the main window's root view. Its joining the window is the earliest point the window exists, and is where a
/// warm launch hides it.
struct LaunchWindowHold: NSViewRepresentable {
    final class HoldView: NSView {
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let newWindow { LaunchReveal.shared.windowWillAppear(newWindow) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> HoldView { HoldView() }
    func updateNSView(_ view: HoldView, context: Context) {}
}

/// The launch spinner, in AppKit, so its fade-out is a Core Animation animation like the gallery's fade-in. It matches the
/// SwiftUI spinner: a regular spinning indicator on a half-opacity control background.
private struct LaunchSpinnerOverlay: NSViewRepresentable {
    let dismissing: Bool

    final class OverlayView: NSView {
        let indicator = NSProgressIndicator()
        var didDismiss = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            indicator.style = .spinning
            indicator.controlSize = .regular
            indicator.isIndeterminate = true
            indicator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(indicator)
            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: centerXAnchor),
                indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            indicator.startAnimation(nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        }

        // Never takes clicks, including while it fades out over the gallery.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func dismiss() {
            guard !didDismiss, let layer else { return }
            didDismiss = true
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = LaunchReveal.fadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.opacity = 0
            layer.add(fade, forKey: "launchReveal")
            LaunchReveal.shared.finishAfterFade()
        }
    }

    func makeNSView(context: Context) -> OverlayView { OverlayView() }

    func updateNSView(_ view: OverlayView, context: Context) {
        if dismissing { view.dismiss() }
    }
}
