// MARK: - GalleryView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Root content view that displays the film grid or list for the active view (all films,
/// user list, smart list, recents, etc.). ViewStateManager, SearchController, and PosterCache
/// are @Observable singletons, so views track only the properties they read.

import SwiftUI
import Combine
import os

/// The eight gallery-backed sidebar items (All Films, Unwatched, Recents, the Film Queue, search, smart
/// lists, user lists and saved searches) share one mounted GalleryView. A move between them is an in-place
/// view switch, the path a Recents tab or smart-list variant takes: the representable sees a new
/// activeViewID, banks the outgoing origin, reloads, and restores the incoming one. No title bar, scroll
/// view, collection or table view, cells or window layout is rebuilt. Insights and Imports are separate
/// branches and mount their own views.
///
/// A remount would reset a few things the shared instance keeps. GalleryView puts them back on each
/// sidebar change (see resetForReuse) or on the switch itself:
///  • keyboard focus: a removed gallery took first-responder status with it;
///  • a post-edit scroll target noted in the outgoing view's last turn;
///  • the grid's prune flag, which belongs to the outgoing item's selection. The grid drops it when the
///    sidebar item changes (see GallerySubview.Coordinator.forgetPrunedSelection).
///  • scroll-position provider registration, which each makeNSView renewed. The shared gallery renews it at
///    each view switch (isSharedHost in GallerySubview and GalleryListView).
/// "Show in List" to another sidebar item marks its scroll intent consumable on reuse when the
/// destination will be this same instance (see ShowInListNavigation.navigate).
enum GalleryReuse {
    /// Whether the shared gallery is on screen but hidden under search's token-entry placeholder: the first token
    /// is being typed into an otherwise empty field, so there are no results to show
    /// (SearchController.isEnteringFirstToken). Text or a pill before the "#" has already narrowed the results,
    /// and they stay in view. Anything that finds the gallery by walking the window (KeyboardManager's Tab route)
    /// must treat it as absent.
    @MainActor
    static func hidesForTokenEntry(_ item: SidebarItem) -> Bool {
        item == .libraryItem(.search) && SearchController.shared.isEnteringFirstToken
    }

    /// hidesForTokenEntry for the sidebar item on screen. The hidden gallery stays mounted and holds the
    /// unfiltered results, so Select All checks this: it must not select films the user cannot see.
    @MainActor
    static var isHiddenForTokenEntry: Bool {
        guard let item = AppDelegate.appState?.selectedSidebarItem else { return false }
        return hidesForTokenEntry(item)
    }

    /// Whether `item` is drawn by the shared GalleryView.
    static func isSharedHostItem(_ item: SidebarItem) -> Bool {
        switch item {
        case .libraryItem(.allFilms), .libraryItem(.unwatched), .libraryItem(.recents),
             .libraryItem(.filmQueue), .libraryItem(.search), .smartList, .list, .savedSearch, .tag:
            return true
        case .libraryItem(.insights), .libraryItem(.imports):
            return false
        }
    }
}

struct GalleryView: View, Loggable {
    nonisolated static let logTag = "[GalleryView]"

    @Environment(AppState.self) private var appState
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SelectionState.self) private var selectionState
    /// The sidebar item MainView last passed in. isOutgoing compares it with the live selection.
    let sidebarItem: SidebarItem
    /// The StatusBar's height, 0 when hidden (StatusBarLayout.height). MainView resolves it and passes it in, and this view
    /// hands it to the grid, list, and Recents summary as their bottom inset. It is not resolved here: resolving reads the
    /// view's capabilities, which read RecentsState.selectedCategory. That would invalidate this body inside the Recents
    /// picker's menu-fade transaction, which RecentsState.selectCategory defers the switch to avoid.
    let statusBarHeight: CGFloat

    /// Identifies this instance in the log.
    @State private var viewID = UUID()
    @State private var hasInitialized = false
    @State private var hasLoadedInitialView = false  /// Prevents duplicate loads
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
                /// The films on screen. This lags activeState only during a Film Queue tab switch (see
                /// ViewStateManager.displayedGalleryState).
                let shown = viewStateManager.displayedGalleryState(
                    loadedQueueFilter: dataCoordinator.loadedFilmQueueFilter)
                if !isOutgoing && hasGalleryContent && PosterCache.shared.isReady && !shouldShowLoading {
                    /// showSectionDividers is read here, from `shown`, so the style and the dividers always come from
                    /// the same tab. Passing it down makes a change an ordinary value change on the representable.
                    ///
                    /// The Recents summary tab has its own layout, a row per category, and no list style.
                    if viewStateManager.activeView == .recents(.summary) {
                        RecentsSummaryView(statusBarHeight: statusBarHeight)
                            .environment(dataCoordinator)
                            .environment(selectionState)
                    } else if shown.isListView {
                        GalleryListView(activeViewID: viewStateManager.activeView,
                                        scrollRequest: scrollRequest,
                                        subtitleProvider: subtitleProvider,
                                        showSectionDividers: shown.showSectionDividers,
                                        statusBarHeight: statusBarHeight,
                                        isSharedHost: true)
                            .environment(dataCoordinator)
                            .environment(selectionState)
                    } else {
                        GallerySubview(scrollRequest: scrollRequest, activeViewID: viewStateManager.activeView, subtitleProvider: subtitleProvider, showSectionDividers: shown.showSectionDividers, statusBarHeight: statusBarHeight, isSharedHost: true)
                            .environment(dataCoordinator)
                            .environment(selectionState)
                    }
                }
                
                if shouldShowPlaceholder {
                    placeholderView
                        .onAppear { LaunchReveal.shared.placeholderAppeared() }
                }
                
                /// At launch LaunchReveal owns the spinner. Afterward the ordinary spinner below takes over.
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
        /// No .focusedSceneValue for selectedFilmIDs or selectedFilmID here. FilmTrackerApp publishes both
        /// at the scene root, which keeps MenuBar's @FocusedValue working in every view. Reading selection in
        /// this body would also re-evaluate the whole gallery on every click.
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

    /// The user list on screen, or nil. Used by the loading and placeholder logic; removal commands resolve
    /// the active list through FilmRemoval instead. Derived from the sidebar item rather than cached in onChange,
    /// which runs after the body that first draws the new item.
    private var listID: UUID? {
        if case .list(let id) = appState.selectedSidebarItem, dataCoordinator.getList(id) != nil {
            return id
        }
        return nil
    }

    /// True for the one update pass after the sidebar has moved to another item, just before SwiftUI
    /// removes this instance. The destination's state is already in place, so this pass renders nothing.
    /// dismantleNSView still saves the outgoing scroll origin.
    ///
    /// MainView hands the shared instance (GalleryReuse) the current item on every pass it makes. This guards
    /// only a pass of the gallery's own, should one land after the sidebar moves to Insights or Imports.
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
              let dateType = viewStateManager.activeView.recentsCategory?.dateType else { return nil }

        return GallerySubtitleProvider(kind: dateType.rawValue) { filmID in
            MetadataCache.shared.getFormattedDate(for: filmID, type: dateType)
        }
    }
    
    /// True when the gallery has something to draw: films, or the empty "Up Next" tab's slots, which take the place of
    /// its empty-section placeholder exactly as an empty "Up Next" band does on the "All" tab.
    private var hasGalleryContent: Bool {
        !dataCoordinator.films.isEmpty
            || UpNextSlots.showsSlotsWithoutFilms(coordinator: dataCoordinator, isNarrowed: isNarrowed)
    }

    private var shouldShowPlaceholder: Bool {
        guard dataCoordinator.isInitialized, PosterCache.shared.isReady, !hasGalleryContent else { return false }

        /// The spinner and the placeholder are mutually exclusive. While films are still loading, only the
        /// spinner shows. Otherwise an empty user list would show "List is Empty" under it.
        guard !shouldShowLoading else { return false }

        /// Recents, smart lists, the Film Queue, and Unwatched show a placeholder when empty. See
        /// ViewIdentifier.treatsEmptyAsValidState.
        if viewStateManager.activeView.treatsEmptyAsValidState {
            /// An empty Film Queue is a valid state and shows its own placeholder.
            return true
        }

        return !dataCoordinator.hasDatabaseFilms || isNarrowed || listID != nil
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

        /// Empty is a valid state for these views (see ViewIdentifier.treatsEmptyAsValidState).
        guard !viewStateManager.activeView.treatsEmptyAsValidState,
              dataCoordinator.films.isEmpty else { return false }

        /// Token-only searches, such as OR, count as narrowing. Without this, the spinner could stay up
        /// after an OR token is confirmed.
        guard !isNarrowed else { return false }

        if let listID {
            return dataCoordinator.getList(listID)?.filmIDs.isEmpty == false
        }
        return dataCoordinator.hasDatabaseFilms
    }

    // MARK: - Placeholder Views
    
    @ViewBuilder
    private var placeholderView: some View {
        let activeView = viewStateManager.activeView
        let hasFilters = !viewStateManager.activeState.filterOptions.isEmpty
        let hasSearchQuery = hasSearchContent
        let isListView = listID != nil
        
        /// A saved search stored with rules this version cannot read shows no films until
        /// it is saved again (SavedSearchStore.needsReview) — this, not a "No Results", is
        /// what says so, whatever filters are on.
        if case .savedSearch(let id) = activeView, SavedSearchStore.shared.needsReview(id) {
            StandardPlaceholder(
                glyph: "exclamationmark.triangle.fill",
                title: "Search Configuration Changed",
                message: "There was an issue restoring this saved search\u{2019}s configuration and it needs to be updated.",
                actionTitle: "Edit Saved Search\u{2026}",
                action: { SavedSearchActions.edit(id) }
            )
        } else if hasFilters && !hasSearchQuery && dataCoordinator.viewHasFilmsBeforeFilters(activeView) {
            /// The view has films and the filters hide every one: clearing them helps, so say that. A view
            /// with no films falls through to its own copy whatever the filters, since clearing them would
            /// show nothing. A search query explains an empty search first (below).
            filtersPlaceholder
        } else if case .savedSearch(let id) = activeView {
            savedSearchPlaceholder(for: id)
        } else if case .recents(let category) = activeView {
            recentsCategoryPlaceholder(for: category)
        } else if case .unwatched(let category) = activeView {
            unwatchedCategoryPlaceholder(for: category)
        } else if case .smartList(let type) = activeView {
            smartListPlaceholder(for: type)
        } else if case .filmQueue = activeView {
            filmQueuePlaceholder()
        } else if case .tag(let tag) = activeView, dataCoordinator.hasDatabaseFilms {
            /// The last film carrying the tag lost it. A Most-Used row leaves the sidebar with
            /// it; a pinned row stays and opens here.
            StandardPlaceholder(
                glyph: ViewGlyphs.tag.filled,
                title: "No Films Tagged",
                message: "No films in your library carry the \u{201C}\(truncateListName(tag.name, maxLength: 42))\u{201D} tag."
            )
        } else if hasSearchQuery {
            StandardPlaceholder(
                glyph: ViewGlyphs.search.outline,
                title: "No Results",
                message: "Try adjusting your search query.",
                actionTitle: "Clear Query",
                action: clearFiltersAndSearch
            )
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

    /// Shown only when the view has films and the filters hide all of them (see placeholderView), so its
    /// copy can say that rather than suggest the view is empty. "Filter" or "filters" follows how many options
    /// are selected in the Filter menu.
    private var filtersPlaceholder: some View {
        let noun = viewStateManager.activeState.filterOptions.noun
        let verb = noun == "filter" ? "hides" : "hide"
        return StandardPlaceholder(
            glyph: ViewGlyphs.activeFilters.filled,
            title: "No Films Match the \(noun.capitalized)",
            message: "This view has films, but the active \(noun) \(verb) all of them.",
            actionTitle: "Clear \(noun.capitalized)",
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

    /// An empty saved search that the filters do not explain (placeholderView handles those): an empty
    /// library, or rules that match no film.
    @ViewBuilder
    private func savedSearchPlaceholder(for id: UUID) -> some View {
        if !dataCoordinator.hasDatabaseFilms {
            emptyLibraryPlaceholder
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
        /// dataCoordinator.films is filtered to the selected section, so an empty result says only that the
        /// current section is empty. getFilmQueueFilmIDs() covers all three sections and is the reliable check.
        if selectedFilter == .all || dataCoordinator.getFilmQueueFilmIDs().isEmpty {
            /// The queue as a whole has nothing assigned yet.
            StandardPlaceholder(
                glyph: selectedFilter.glyph.filled,
                title: "Your Queue Is Empty",
                message: "Assign films to the Up Next, Soon, or Later section from a film's Details tab to build your queue."
            )
        } else {
            /// The queue has films overall, but none in this section.
            StandardPlaceholder(
                glyph: selectedFilter.glyph.filled,
                title: "\(selectedFilter.displayName) Is Empty",
                message: "No films are currently assigned to the \(selectedFilter.displayName) section. Select \u{201C}All\u{201D} to see the rest of your queue.",
                actionTitle: "Show All",
                action: { FilmQueueFilterState.shared.selectFilter(.all) }
            )
        }
    }
    
    /// A Recents or Unwatched tab with no films: its title-bar glyph over its own copy (each category's
    /// emptyState), as smartListPlaceholder does for the smart lists.
    private func recentsCategoryPlaceholder(for category: RecentsCategory) -> some View {
        let copy = category.emptyState
        return StandardPlaceholder(glyph: category.glyph, title: copy.title, message: copy.message)
    }

    private func unwatchedCategoryPlaceholder(for category: UnwatchedCategory) -> some View {
        let copy = category.emptyState
        return StandardPlaceholder(glyph: category.glyph, title: copy.title, message: copy.message)
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

        /// No singleton registration is needed here. The sub-category state singletons reach the shared
        /// SelectionState and AppState directly, through SubcategoryNavigation.

        /// Only load if both caches ready and we haven't loaded yet
        if PosterCache.shared.isReady && dataCoordinator.isInitialized && !hasLoadedInitialView {
            Self.log("Cache ready on appear - loading view immediately")
            hasLoadedInitialView = true
            ViewStateManager.shared.switchToViewSync(viewIDFromSidebar())
        }
    }
    
    /// Re-subscribes event handlers on every appear, since onDisappear cancels them. initializeIfNeeded()
    /// runs only once, so the setup must be idempotent and repeatable here.
    private func setupEventHandlersIfNeeded() {
        /// If cancellables are already populated the handlers are still active.
        guard eventHandler.cancellables.isEmpty else { return }
        setupEventHandlers()
    }
    
    /// Guard against duplicate initial loads
    private func handleReadyState() {
        guard !hasLoadedInitialView else {
            Self.log("Skipping handleReadyState - already loaded initial view")
            return
        }
        
        Self.log("DataCoordinator and cache ready - loading initial view")
        hasLoadedInitialView = true
        ViewStateManager.shared.switchToViewSync(viewIDFromSidebar())
    }
    
    private func setupEventHandlers() {
        let handler = eventHandler
        
        /// Search query changes are applied synchronously by SearchController.triggerSearch(), so no event
        /// subscriber is needed.
        
        /// There is deliberately no .membershipChanged subscription. DataCoordinator.addFilmsToList and
        /// removeFilmsFromList call refreshFilms() themselves when the affected list is on screen.
        
        /// Film changes and smart-list recalculations underneath an open smart list. Each change that can
        /// alter this view is noted on the holder. The holder flushes once per turn and reloads only if no full
        /// load has happened since the latest change. A single edit loads itself in DataCoordinator.reloadCurrentView,
        /// so it is not reloaded again. A burst of per-film events costs one load.
        ///
        /// The subscription runs synchronously, so the load generation is read at the moment of the event, before
        /// the sender's own reload moves it on. Only the flush waits one turn.
        AppEventBus.shared.filmEvents
            .sink { [weak dataCoordinator] event in
                guard let dataCoordinator else { return }
                switch event {
                case .updated(let filmID):
                    /// Edits also ask the gallery to keep the edited film in view, except a
                    /// many-film edit made away from the gallery (a tag rename), which leaves
                    /// the scroll where it is (DataCoordinator.suppressesEditScroll).
                    if !dataCoordinator.suppressesEditScroll {
                        handler.notePendingScrollTarget(filmID)
                    }
                case .added:
                    break
                case .deleted:
                    /// Already loaded by every sender, which reloads after removing the films from MemoryStore. The films are gone, so no membership change can alter that load. See DataCoordinator.deleteFilms.
                    return
                case .releaseChanged:
                    return
                }
                handler.noteChange(coordinator: dataCoordinator, flush: flushChanges)
            }
            .store(in: &handler.cancellables)

        /// Smart list membership changed underneath an open gallery. Two sources post this: the midnight
        /// rotation recalculation, and any full recalculation (startup, re-enabling the feature, a restore or import,
        /// or a rotation-threshold reset). A full recalculation can change any list, so this refreshes whenever the
        /// active view is any smart list. Non-smart-list views are skipped. The refresh is an in-memory filter pass,
        /// so an occasional redundant refresh costs little.
        AppEventBus.shared.viewEvents
            .filter { if case .smartListsRecalculated = $0 { return true } else { return false } }
            .sink { [weak dataCoordinator] _ in
                guard let dataCoordinator else { return }
                switch ViewStateManager.shared.activeView {
                case .smartList, .savedSearch: break
                /// Search results that name a smart list through #list.
                case .search where SearchController.shared.dependsOnLists: break
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
            /// Refresh data without reloading view state, keeping search query intact.
            ViewStateManager.shared.forceReload()
        }
        /// Signals the gallery to evaluate the post-edit scroll. The request is one-shot on the gallery's side, so
        /// it is left in place rather than cleared later.
        if let scrollTarget { scrollRequest = FilmScrollRequest(filmID: scrollTarget) }
    }

    // MARK: - Sidebar Handling

    private func handleSidebarChange(from oldItem: SidebarItem, to newItem: SidebarItem) {
        guard dataCoordinator.isInitialized else {
            Self.log("Ignoring sidebar change - coordinator not initialized")
            return
        }
        
        Self.log("Sidebar selection changed: \(String(describing: newItem))")

        resetForReuse()

        /// For a gallery-backed destination, AppState.navigate(to:) has already run this preparation before the
        /// flip. Here every step re-applies a result already in place, so it is a no-op. It is the path for every
        /// other destination.
        let isSubcategoryView = Self.prepareSidebarTransition(from: oldItem, to: newItem)

        /// Selection clearing is handled by AppState.navigate(to:), which covers every view switch.

        /// switchToViewSync runs only for views that are not subcategory tabs. Those handle their own switch.
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
        /// A real navigation invalidates any unconsumed scroll intent aimed at a view other than the destination. Without
        /// this, a stale target could cause a surprise scroll on a later visit. An intent aimed at the destination, such as
        /// the search-exit handoff, must survive so the destination's makeNSView can consume it.
        GalleryScrollIntent.shared.clear(unlessTargeting: ViewIdentifier.from(newItem))
        GalleryFocusIntent.shared.clear(unlessTargeting: ViewIdentifier.from(newItem))

        /// Syncs each subcategory-tab state with this navigation and checks whether newItem belongs to one. If it does,
        /// ensureInitialViewLoad has already switched the view, so the final switchToViewSync is skipped.
        var isSubcategoryView = false
        for state in subcategoryStates {
            let wasActive = oldItem == state.scopedSidebarItem
            let isActive = newItem == state.scopedSidebarItem
            if isActive {
                isSubcategoryView = true
            }
            if isActive && !wasActive {
                /// Switching TO this state's view - ensure initial load
                state.ensureInitialViewLoad()
            } else if wasActive && !isActive {
                /// Switching AWAY from this state's view - reset for next visit
                state.resetInitialization()
            }
        }
        
        /// Sync the smart list family's sub-variant picker when switching to a smart list
        if case .smartList(let parent) = newItem {
            /// Syncs the sub-variant pickers to the smart list actually displayed, not just the sidebar row clicked. For an
            /// ordinary sidebar click the two are the same, so each picker resets to its parent. They differ for
            /// ShowInListNavigation and the search-exit pre-load, which promote the view before the flip. Those can land on a
            /// sub-variant with no sidebar row of its own, such as "Purchased 4K". Syncing to the parent would then disagree
            /// with the films on screen. The sidebarParent test keeps an unrelated family from being mistaken for a sub-variant.
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
    /// The pass that draws the flip reads whatever view is active at that moment. Switching first makes it the only
    /// reload, in the correct style. The switch is unconditional. For a subcategory tab it is a no-op re-entry after the first switch.
    static func preSwitchBeforeSidebarFlip(from oldItem: SidebarItem, to newItem: SidebarItem) {
        _ = prepareSidebarTransition(from: oldItem, to: newItem)
        ViewStateManager.shared.switchToViewSync(ViewIdentifier.from(newItem))
    }

    /// Puts back what a remount used to reset (see GalleryReuse). Runs from the
    /// sidebar onChange, in the update that draws the destination, before its frame commits. The outgoing
    /// view's pending flush is dropped by SubscriptionHolder itself, since it can land before this runs.
    private func resetForReuse() {
        /// A removed gallery took first-responder status with it, leaving the window itself as first
        /// responder. A kept one would stay focused, so arrow keys would move a cursor the old setting
        /// never had. Only the gallery's own grid or table is resigned; focus anywhere else is left alone.
        /// Looked up by its first responder rather than as NSApp.mainWindow, which is nil while the app is
        /// inactive, as it is when a menu item or a harness run navigates. Sheets are skipped: no navigation
        /// happens while one is up, and none of them hosts this gallery.
        for window in NSApp.windows where Self.isGalleryFocused(in: window) {
            window.makeFirstResponder(nil)
        }
    }

    /// Whether a window's first responder is a gallery's own grid or table (the Recents summary's rows are grids
    /// too). Sheets are skipped: none of them hosts a gallery.
    private static func isGalleryFocused(in window: NSWindow) -> Bool {
        window.sheetParent == nil
            && (window.firstResponder is GalleryCollectionView || window.firstResponder is DraggableListTableView)
    }

    /// Whether any gallery holds keyboard focus, which is exactly what resetForReuse takes away at a sidebar change.
    /// ShowInListNavigation reads it to decide whether to hand focus to the destination.
    static var galleryHoldsKeyboardFocus: Bool {
        NSApp.windows.contains(where: isGalleryFocused(in:))
    }

    private func viewIDFromSidebar() -> ViewIdentifier {
        ViewIdentifier.from(appState.selectedSidebarItem)
    }

    private func clearFiltersAndSearch() {
        Self.log("Clearing filters and search")
        /// One committed state change, so only one film reload runs.
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
    private var pendingScrollTarget: UUID?
    /// DataCoordinator.fullLoadGeneration when the latest change of this turn arrived.
    private var generationAtLatestChange: Int?
    /// The sidebar item on screen when the scroll target and the latest change were noted. The shared gallery
    /// outlives a sidebar change (see performFlush).
    private var scrollTargetItem: SidebarItem?
    private var latestChangeItem: SidebarItem?
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
        latestChangeItem = AppDelegate.appState?.selectedSidebarItem
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

    /// Records the film an edit asked to keep in view, for the turn's flush. noteChange follows.
    func notePendingScrollTarget(_ filmID: UUID) {
        pendingScrollTarget = filmID
        scrollTargetItem = AppDelegate.appState?.selectedSidebarItem
    }

    private func performFlush() {
        isFlushScheduled = false
        var reload = generationAtLatestChange != nil
            && generationAtLatestChange == coordinator?.fullLoadGeneration
        var target = pendingScrollTarget
        /// The shared gallery's holder can outlive a sidebar change made in the same turn as the change it
        /// noted. A remounted gallery would have canceled that flush with its subscriptions, so the parts noted
        /// under another item are dropped: the destination's own load already covers the reload, and the
        /// target names a film in the view just left.
        let current = AppDelegate.appState?.selectedSidebarItem
        if latestChangeItem != current { reload = false }
        if scrollTargetItem != current { target = nil }
        generationAtLatestChange = nil
        pendingScrollTarget = nil
        scrollTargetItem = nil
        latestChangeItem = nil
        flush?(reload, target)
    }

    /// Also drops a flush already scheduled, since canceling the subscription cancels its delivery.
    func cancel() {
        cancellables.removeAll()
        flushSubscription = nil
        isFlushScheduled = false
        generationAtLatestChange = nil
        pendingScrollTarget = nil
        scrollTargetItem = nil
        latestChangeItem = nil
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
    private(set) var menuRefreshAllowed = false

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
    private(set) var menuContentAllowed = false

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
            /// Not held: the window is about to be seen as it is.
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
        /// A reveal that never ends must not leave the menu bar showing pre-load state.
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

        /// Never takes clicks, including while it fades out over the gallery.
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
