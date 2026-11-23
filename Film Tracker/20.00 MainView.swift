// MARK: - MainView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Builds the main window: the sidebar and gallery layout, the toolbar, search handling, and navigation between views.
/// It is wired to DataCoordinator and AppState.

import SwiftUI
import CoreData
import Combine

struct MainView: View, Loggable {
    /// Width of each icon-only toolbar button, so the row spaces evenly.
    static let toolbarButtonWidth: CGFloat = 22

    nonisolated static let logTag = "[MainView]"

    @Environment(\.managedObjectContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SelectionState.self) private var selectionState

    @State private var columnVisibility = NavigationSplitViewVisibility.all
    private let searchController = SearchController.shared
    private let keyboardManager = KeyboardManager.shared

    /// Track the sidebar item before entering search view
    @State private var previousSidebarItem: SidebarItem = .libraryItem(.allFilms)

    // MARK: - Selection Preservation
    ///
    /// Two separate mechanisms handle the two distinct selection-preservation features.
    /// They are intentionally decoupled so each can be reasoned about independently.
    ///
    /// 1. Search-exit selection preservation (Preferences.maintainSelectionOnSearchExit):
    ///    When the user clears a search query and a single film is selected in the results,
    ///    and that film is also present in the prior gallery-based view (All Films, any
    ///    user-generated list, any smart list, or any Recents category), its UUID is armed
    ///    via appState.armSearchExitSelectionPreservation(filmID:).
    ///
    /// 2. Token search activation (sidebar "Search" buttons):
    ///    When navigating INTO the search view via a programmatic token search, the currently-
    ///    selected film is guaranteed to appear in the results, so
    ///    appState.armTokenSearchSelectionPreservation() is called immediately before the
    ///    transition to skip the clear for that single incoming transition only.
    ///
    /// Both tokens live on AppState rather than in @State here, because the clear they
    /// suppress now happens inside appState.navigate(to:) — synchronously, ahead of the item
    /// flip — rather than in a handler reacting to it. See AppState.navigate(to:) for why
    /// that ordering matters and for the validation each token still passes through.

    private let minimumWidth = Preferences.minimumWidth
    private let minimumHeight = Preferences.minimumHeight

    var body: some View {
        let _ = LaunchTimeline.mark("mainViewBodyFirst")
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                Group {
                    if LaunchExperiment.noLeftSidebar {
                        Color.clear
                    } else {
                        LeftSidebar()
                    }
                }
                    .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
            } detail: {
                mainContentArea
                    .frame(minWidth: minimumWidth, minHeight: minimumHeight)
            }
            .navigationSplitViewStyle(.prominentDetail)
            /// The search field lives in a modifier of its own. SwiftUI reads the field's
            /// text binding while updating the view that applies `.searchable`, so applied
            /// here it made every keystroke re-evaluate this whole body (the split view,
            /// both sidebars' parents, the toolbar). Scoped to the modifier, a keystroke
            /// re-evaluates only the modifier.
            .modifier(SearchFieldModifier(searchController: searchController))
            .onSubmit(of: .search) {
                Self.log("Search submitted")
                searchController.processSearchSubmission()
            }
            /// Reads selectedSidebarItem inside a modifier of its own, for the same reason
            /// as SearchFieldModifier: an onChange reads its value while this body is
            /// evaluated, so applied here it made every navigation re-evaluate this whole
            /// body. The handler itself is unchanged; see SidebarChangeModifier.
            .modifier(SidebarChangeModifier { oldItem, newItem in
                handleViewChange(from: oldItem, to: newItem)
            })
            /// The same again for the search field's hasContent, which flips on entering and leaving search.
            .modifier(SearchContentChangeModifier { hasContent in
                handleSearchContentChange(hasContent)
            })
            .task(priority: .userInitiated) { await initialize() }
            .onAppear {
                /// Setup global keyboard event manager.
                keyboardManager.setup(appState: appState, selectionState: selectionState, dataCoordinator: dataCoordinator)
            }
            /// One subscription for every UICommand this view handles. Each operator chain
            /// (.filter, .compactMap) built a new publisher on every body evaluation, which
            /// SwiftUI answered by resubscribing; the subject itself is a stable instance.
            .onReceive(AppEventBus.shared.uiCommands) { command in
                switch command {
                case .toggleLeftSidebar: toggleSidebarVisibility()
                case .activateTokenSearch(let field, let value):
                    handleActivateTokenSearch(field: field, value: value)
                case .openSavedSearchInField(let id):
                    handleOpenSavedSearchInField(id)
                case .navigateToImportsMetadata: ImportsState.shared.open(.metadata, appState: appState)
                case .navigateToImportsRatings: ImportsState.shared.open(.ratings, appState: appState)
                default: break
                }
            }
        }
    }

    // MARK: - Main Content Area
    private var mainContentArea: some View {
        MainContentSwitcher()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            /// One toolbar item holds all five buttons, because SwiftUI's toolbar bridge pays a cost per item at
            /// launch. The 8 pt HStack spacing matches the toolbar's gaps, and the 9 pt trailing padding stands in
            /// for the former spacer item.
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 8) {
                        AddNewToolbarButton()
                        ImportToolbarMenu()
                        AddNewListToolbarButton()
                        NewSavedSearchToolbarButton()
                        ScanDuplicatesToolbarButton()
                    }
                    .padding(.trailing, 9)
                }
            }
            .modifier(NavigationTitleModifier())
            .navigationSubtitle("")
    }

    // MARK: - Initialization
    /// Data loading is DataCoordinator's (FilmTrackerApp.initializeApp). This only attaches the import services.
    private func initialize() async {
        ImportProgress.shared.attachContext(modelContext)
        ImportProgress.shared.attachCoordinator(dataCoordinator)
        /// Loads the Imports view's session index in the background, so the first visit
        /// to Imports reads it rather than fetching. See ImportHistory.
        ImportHistory.shared.attach(dataCoordinator.persistentContainer)
        
        Self.log("MainView initialized - ImportProgress attached")
    }

    // MARK: - View Change Handling

    /// Post-transition bookkeeping for a sidebar item change.
    ///
    /// Selection clearing is deliberately NOT here. It lives in `AppState.navigate(to:)`,
    /// which runs it synchronously ahead of the item flip so the destination view and the
    /// cleared selection land in the same frame; a handler reacting to the flip is one or
    /// more frames too late by construction. What remains is search teardown, which has no
    /// such frame sensitivity and is still deferred one run loop to keep it clear of the
    /// in-flight view update.
    private func handleViewChange(from oldItem: SidebarItem, to newItem: SidebarItem) {
        /// If user manually switches away from search view, clear the search.
        /// clearSearch() already zeroes searchText, so no separate assignment is needed.
        ///
        /// Guard: this handler is deferred one run loop via DispatchQueue.main.async, which
        /// creates a window where the user can begin a new search query before the deferred
        /// block fires. Specifically:
        ///   1. User deletes all text → hasContent = false → handleSearchContentChange
        ///      switches selectedSidebarItem back to previousSidebarItem (synchronously).
        ///   2. DispatchQueue.main.async defers handleViewChange(from: .search, to: previous).
        ///   3. User immediately starts typing again → hasContent = true →
        ///      handleSearchContentChange switches back to .libraryItem(.search).
        ///   4. Deferred handleViewChange fires → the guard below detects selectedSidebarItem
        ///      is already back to .search and skips clearSearch(), preserving the new query.
        ///
        /// NOTE: Do NOT guard on searchController.hasContent here. When the user manually
        /// navigates away from search while content is present, hasContent is still true —
        /// but clearSearch() must still fire to reset the field. The restarted-search
        /// check alone is the correct and sufficient guard for the race scenario above,
        /// because in that race selectedSidebarItem is already back to .search by the time
        /// this deferred block runs (step 3 above happens before step 4).
        if oldItem == .libraryItem(.search), newItem != oldItem {
            if appState.selectedSidebarItem == .libraryItem(.search) {
                Self.log("Skipping clearSearch() — new search began before deferred handler fired")
            } else {
                Self.log("User switched away from search - clearing search query")
                searchController.clearSearch()
                searchController.holdEmptyFieldMenuIfUnfocused()
            }
        }
    }
    
    /// Handle automatic view switching based on search content
    private func handleSearchContentChange(_ hasContent: Bool) {
        if hasContent {
            /// Already in search view — do not overwrite previousSidebarItem.
            if appState.selectedSidebarItem == .libraryItem(.search) {
                return
            }
            
            /// The guard above has already returned for `.search`, so the exit destination saved
            /// here can never be search itself, which keeps rapid clear/re-enter cycles returning
            /// to the true prior view.
            let current = appState.selectedSidebarItem
            Self.log("Search content entered - switching to search view (previous: \(current))")
            showSearch(from: current)
        } else {
            /// Search cleared - return to previous view only if still in search.
            if appState.selectedSidebarItem == .libraryItem(.search) {
                /// Resolve the destination first. previousSidebarItem is captured at search entry and can become invalid
                /// while search is open, for example if the user deletes the list they searched from. LeftSidebar redirects
                /// only the displayed item, which is never the search view, so the stale value must be checked here.
                let destination = resolvedPreviousSidebarItem()
                if destination != previousSidebarItem {
                    Self.log("Search-exit: previous item \(previousSidebarItem) no longer valid — falling back to \(destination)")
                    previousSidebarItem = destination
                }
                Self.log("Search cleared - returning to previous view: \(destination)")

                // MARK: Search-Exit Pre-load
                /// ViewStateManager.switchToViewSync is called for the destination view
                /// BEFORE setting selectedSidebarItem. This ensures dataCoordinator.films is
                /// populated with the destination view's films before SwiftUI renders the new
                /// GalleryView instance, so GallerySubview.updateNSView fires with correct
                /// data on its first call. Otherwise the gallery would scroll against the stale
                /// search results still in dataCoordinator.films, leaving a blank gap until the
                /// correct films arrive.
                ///
                /// This mirrors the pre-load on search entry (see switchToViewSync(.search)
                /// above). The later switchToViewSync call from GalleryView.handleSidebarChange
                /// is a no-op, so no second reload runs.
                ///
                /// The pre-load runs on every search exit, not only the selection-preservation
                /// path. It runs before the preservation decision below, which depends on it.
                ///
                /// The candidate selection is captured before the pre-load, so the decision uses
                /// the selection as it stood in the search results.
                let candidateFilmID: UUID? = selectionState.selectedFilmIDs.count == 1
                    ? selectionState.selectedFilmID
                    : nil

                let destinationViewID = ViewIdentifier.from(destination)
                GalleryScrollIntent.shared.clear()
                GalleryFocusIntent.shared.clear()
                ViewStateManager.shared.switchToViewSync(destinationViewID)

                // MARK: Search-Exit Selection Preservation
                /// When the preference is enabled, exactly one film is selected in the search
                /// results, the prior view is a gallery-backed view, and that film is actually
                /// present in the destination, preserve the selection and auto-scroll the
                /// destination gallery (whichever style — grid or list — is currently active)
                /// so the film appears in the topmost row of the viewport.
                ///
                /// Membership is tested against dataCoordinator.films, which the pre-load above has
                /// just populated with the destination's final set, including sort, tab, and active
                /// FilterOptions. Raw view membership would keep a film that the filters hide selected.
                if Preferences.maintainSelectionOnSearchExit,
                   let selectedFilmID = candidateFilmID,
                   destination.capabilities.isValidSearchExitDestination,
                   dataCoordinator.films.contains(where: { $0.id == selectedFilmID }) {

                    Self.log("Search-exit: film \(selectedFilmID) present in \(destination) — preserving selection")
                    appState.armSearchExitSelectionPreservation(filmID: selectedFilmID)
                    appState.cancelTokenSearchSelectionPreservation()

                    /// Hands the scroll target to the destination gallery, addressed to its
                    /// ViewIdentifier so no stale instance can consume it. Both gallery styles
                    /// resolve the scroll in viewWillDraw(), so the first painted frame is already
                    /// positioned. The film moves to the top of the viewport, as with Cmd+L.
                    /// The destination is the same mounted gallery, so its update pass, not a fresh makeNSView,
                    /// claims the intent.
                    GalleryScrollIntent.shared.set(filmID: selectedFilmID,
                                                   targetViewID: destinationViewID,
                                                   consumableOnReuse: GalleryReuse.isSharedHostItem(destination))
                    /// Also hands over keyboard focus. Leaving search resigns the gallery
                    /// (GalleryView.resetForReuse), so it would otherwise not be first responder, leaving
                    /// the arrow keys dead until Tab is pressed. Addressed like the scroll intent, under the
                    /// same gate.
                    GalleryFocusIntent.shared.set(targetViewID: destinationViewID)
                } else {
                    /// No preservation on this exit. Clears any preserve ID left by an earlier,
                    /// abandoned transition so navigate(to:) cannot honor it.
                    appState.armSearchExitSelectionPreservation(filmID: nil)
                }

                appState.navigate(to: destination)
            }
        }
    }

    // MARK: - Search-Exit Helpers

    /// Checks that `previousSidebarItem` is still valid at search exit. It is captured on entry
    /// and not updated during the search, so the list may have been deleted since.
    ///
    /// LeftSidebar redirects a deleted list only when that list is selected, which never happens
    /// while search is shown. Without this check, exiting search would restore a deleted list.
    ///
    /// Returns All Films for a list that no longer exists; otherwise returns
    /// `previousSidebarItem` unchanged.
    private func resolvedPreviousSidebarItem() -> SidebarItem {
        switch previousSidebarItem {
        case .list(let listID) where dataCoordinator.getList(listID) == nil:
            return .libraryItem(.allFilms)
        case .savedSearch(let id) where SavedSearchStore.shared.search(id) == nil:
            return .libraryItem(.allFilms)
        case .smartList where !Preferences.smartLists:
            /// Smart lists were turned off while the search was open.
            return .libraryItem(.allFilms)
        case .libraryItem(.recommendations) where !Preferences.recommendationsEnabled:
            /// Recommendations was turned off while the search was open.
            return .libraryItem(.allFilms)
        case .tag(let tag) where !TagActions.canStayOpen(tag, in: dataCoordinator):
            /// The tag has no row to return to: Most-Used Tags was hidden while the search was
            /// open, or the tag left the library (deleted, renamed, or its last film lost it).
            /// A pinned tag keeps its row either way.
            return .libraryItem(.allFilms)
        default:
            return previousSidebarItem
        }
    }

    // MARK: - Search Entry

    /// Shows the search view for the query the field already holds. The one entry path for typing
    /// (handleSearchContentChange), the sidebar "Search" buttons, and opening a saved search in the field.
    ///
    /// From another view, `current` becomes the exit destination and seeds the results' grid or list style,
    /// so they appear in the style of the view the user returns to (see switchToViewSync). Already in search,
    /// the seed is ignored, the session's sort and filters reset as for a new search, and its style is kept.
    ///
    /// The field must be filled first. switchToViewSync injects its query, so the switch loads the results
    /// once; switching first loaded the unfiltered library, then the results. The switch also runs before the
    /// flip, so activeView is .search by the time the debounced triggerSearch() calls updateSearchQuery(),
    /// which drops a query outside search. navigate(to:)'s own pre-switch is then a no-op.
    private func showSearch(from current: SidebarItem) {
        if current != .libraryItem(.search) {
            previousSidebarItem = current
            /// A new search session invalidates any unconsumed scroll or focus handoff from the last one,
            /// including one addressed to search itself, which navigate(to:) would keep.
            GalleryScrollIntent.shared.clear()
            GalleryFocusIntent.shared.clear()
        }
        ViewStateManager.shared.switchToViewSync(.search, matchingStyleOf: ViewIdentifier.from(current))
        appState.navigate(to: .libraryItem(.search))
    }

    /// Opens a saved search in the field, from its menus or the field's drop-down. The view being left
    /// becomes the exit destination. "Update Saved Search…" in the title bar goes to the saved search's own
    /// view instead.
    private func handleOpenSavedSearchInField(_ id: UUID) {
        /// A saved query is never empty (the builder refuses to save one). An empty one would leave the
        /// search view with nothing to show and no content change to return from.
        guard let search = SavedSearchStore.shared.search(id), !search.query.isEmpty else { return }
        let current = appState.selectedSidebarItem
        searchController.applySavedSearch(search)
        showSearch(from: current)
        /// Focuses the field with the caret after the query, once the search view has settled.
        DispatchQueue.main.async { SearchController.focusFieldAtEnd() }
    }

    /// Handles the .activateTokenSearch command from the sidebar "Search" buttons: a single-token search
    /// with instant results.
    private func handleActivateTokenSearch(field: SearchField, value: String) {
        let current = appState.selectedSidebarItem
        /// The selected film is guaranteed to be in the results, so the selection clear in
        /// AppState.navigate(to:) is suppressed. Armed only when this call changes the sidebar item:
        /// otherwise it would stay armed and skip the clear on the next real view change.
        if current != .libraryItem(.search) {
            appState.armTokenSearchSelectionPreservation()
        }
        searchController.programmaticTokenSearch(field: field, value: value)
        showSearch(from: current)
        Self.log("Activated token search: \(field.displayName) = \"\(value)\"")
    }

    // MARK: - Sidebar Toggle
    
    private func toggleSidebarVisibility() {
        withAnimation {
            switch columnVisibility {
            case .all:
                columnVisibility = .detailOnly
            case .detailOnly:
                columnVisibility = .all
            default:
                columnVisibility = .all
            }
        }
    }
}

// MARK: - Add New Toolbar Button
/// Top-level toolbar button that shows the "Add Film" sheet.
@MainActor
private struct AddNewToolbarButton: View {
    var body: some View {
        Button {
            AppEventBus.shared.sendCommand(.addFilm)
        } label: {
            Image(systemName: "plus")
                .offset(y: 1)
                .frame(width: MainView.toolbarButtonWidth)
        }
        .help("Add film")
    }
}

// MARK: - Import Toolbar Menu
/// Top-level toolbar Menu button offering the two import types. Selecting either
/// option navigates to ImportsView and selects the matching tab; it does not open
/// that tab's filesystem picker, which is always a separate, explicit act — see
/// ImportsState.open(_:appState:).
@MainActor
private struct ImportToolbarMenu: View {
    var importsState = ImportsState.shared

    var body: some View {
        Menu {
            /// Neither item is locked during an import, since both only navigate. The lock is on
            /// the Imports title bar's "Select Files" button. Each item is disabled when its own
            /// tab is already on screen.
            Button("Import Metadata…") {
                AppEventBus.shared.sendCommand(.navigateToImportsMetadata)
            }
            .disabled(importsState.isViewingImports && importsState.selectedCategory == .metadata)

            Button("Import Ratings…") {
                AppEventBus.shared.sendCommand(.navigateToImportsRatings)
            }
            .disabled(importsState.isViewingImports && importsState.selectedCategory == .ratings)
        } label: {
            Image(systemName: ViewGlyphs.imports.outline)
        }
        .help("Import metadata and ratings")
    }
}

// MARK: - Add New List Toolbar Button
/// Top-level toolbar button that shows the list-creation sheet.
@MainActor
private struct AddNewListToolbarButton: View {
    var body: some View {
        Button {
            AppEventBus.shared.sendCommand(.showListCreation)
        } label: {
            Image(systemName: "note.text.badge.plus")
                .frame(width: MainView.toolbarButtonWidth)
        }
        .help("Create new list")
    }
}

// MARK: - New Saved Search Toolbar Button
/// Top-level toolbar button that opens a blank saved-search builder, so a search can be
/// built without typing one into the field first.
@MainActor
private struct NewSavedSearchToolbarButton: View {
    var body: some View {
        Button {
            SavedSearchActions.newSearch()
        } label: {
            Image(systemName: "plus.magnifyingglass")
                .frame(width: MainView.toolbarButtonWidth)
        }
        .help("Create new saved search")
    }
}

// MARK: - Scan Duplicates Toolbar Button
/// Top-level toolbar button that shows the duplicate-scan sheet.
/// Invokes DuplicateSheet exactly as the former "Scan for Duplicates" item
/// in GalleryTitleBar's ellipsis menu did.
@MainActor
private struct ScanDuplicatesToolbarButton: View {
    var body: some View {
        Button {
            AppEventBus.shared.send(.ui(.findDuplicates))
        } label: {
            Image(systemName: "rectangle.and.text.magnifyingglass")
                .frame(width: MainView.toolbarButtonWidth)
        }
        .help("Scan library for duplicates")
    }
}

// MARK: - Main Content Switcher
@MainActor
private struct MainContentSwitcher: View {
    @Environment(AppState.self) private var appState
    /// Whether the StatusBar shows here, and in which form (StatusBar.swift).
    @CurrentStatusBar private var statusBar

    var body: some View {
        let selectedItem = appState.selectedSidebarItem
        
        /// The right sidebar's visibility rule, which StatusBarLayout also applies. See
        /// ViewCapabilities.showsGalleryChrome (ViewState.swift) for the per-view rules.
        let showsChrome = selectedItem.capabilities.showsGalleryChrome
        /// Resolved once per pass: the overlay below and the gallery's bottom inset both come from it.
        let statusBar = self.statusBar
        
        /// Single, stable layout structure that persists across view switches
        HStack(spacing: 0) {
            /// Main content area with status bar overlay
            ZStack(alignment: .bottom) {
                /// Content switcher with stable identities
                contentView(for: selectedItem, statusBarHeight: statusBar.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                
                /// StatusBar as overlay - doesn't affect layout of content above. StatusBarLayout decides whether it
                /// shows (the preference and showsChrome) and its form; the bar sizes and draws its own chrome.
                if statusBar.isVisible {
                    StatusBar(layout: statusBar)
                }
            }
            /// Lower layout priority allows gallery to compress first
            /// when space is constrained at smaller window sizes
            .layoutPriority(0)
            
            /// The sidebar is shown conditionally. Flipping showsChrome destroys and recreates
            /// RightSidebar, discarding all of its @State. RightSidebar resolves its content only
            /// on selection change, not on mount, so a selection that survived the flip would
            /// show as "Nothing Selected". Both flipping paths clear the selection first: a view
            /// switch (AppState.navigate(to:)) and a Insights category change (InsightsView). Any future
            /// view that toggles this flag must clear the selection too, or add a mount-time resolve.
            if showsChrome {
                Divider()
                
                RightSidebar()
                    .frame(width: 300)
                    .background(Color(NSColor.controlBackgroundColor))
                    .layoutPriority(1)
            }
        }
        /// Disables animations on the layout container to prevent a jiggle when the left sidebar
        /// changes. Child views still animate.
        .transaction { transaction in
            transaction.animation = nil
        }
    }
    
    // MARK: - Content View Switcher

    /// Returns the appropriate content view with stable identity.
    ///
    /// Only Insights and Imports render something other than the gallery. The other eight share one branch,
    /// and so one mounted `GalleryView`; that branch must list exactly the items GalleryReuse.isSharedHostItem
    /// accepts. The switch has no `default`, so a new SidebarItem case is a compile error until it is placed.
    ///
    /// The Film Queue is one of the eight. It uses the standard gallery pipeline, and its section dividers come
    /// from GallerySubview and the layout.
    @ViewBuilder
    private func contentView(for item: SidebarItem, statusBarHeight: CGFloat) -> some View {
        switch item {
        case .libraryItem(.insights):
            InsightsView()
                .id("reports")
        case .libraryItem(.imports):
            ImportsView()
                .id("imports")
        case .libraryItem(.recommendations):
            RecommendationsView()
                .id("recommendations")
        case .libraryItem(.allFilms), .libraryItem(.unwatched), .libraryItem(.recents),
             .libraryItem(.filmQueue), .libraryItem(.search), .smartList, .list, .savedSearch, .tag:
            /// One GalleryView for all of them. A move between them is an in-place view switch, the same path a
            /// Recents tab or smart-list variant takes. See GalleryReuse.
            GalleryView(sidebarItem: item, statusBarHeight: statusBarHeight)
                .modifier(SearchTokenEntryCover(item: item))
        }
    }
}

// MARK: - Search Token Entry Cover
/// While the first search token is being entered, hides the shared gallery and shows a placeholder over it,
/// rather than removing the gallery, so it stays mounted. A modifier of its own so the search state it reads
/// invalidates only this.
private struct SearchTokenEntryCover: ViewModifier {
    let item: SidebarItem

    func body(content: Content) -> some View {
        /// Reads SearchController's token state only for search, so other items take no dependency on it.
        let covers = GalleryReuse.hidesForTokenEntry(item)
        content
            .opacity(covers ? 0 : 1)
            .allowsHitTesting(!covers)
            .accessibilityHidden(covers)
            .overlay {
                if covers {
                    StandardPlaceholder(
                        glyph: ViewGlyphs.search.outline,
                        title: "Enter Search Token",
                        message: "Type a value after the field name, then press Return."
                    )
                }
            }
    }
}

/// The window title for the sidebar item on screen. A modifier of its own so that the
/// selectedSidebarItem and list name it reads invalidate only this, not MainView's body.
///
/// A list's name is read from cachedLists rather than DataCoordinator.getList(_:): the
/// latter reads MemoryStore, which is not observed, so a renamed list kept its old title
/// until something unrelated re-evaluated the view.
private struct NavigationTitleModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(DataCoordinator.self) private var dataCoordinator

    func body(content: Content) -> some View {
        content.navigationTitle(titleText)
    }

    private var titleText: String {
        switch appState.selectedSidebarItem {
        case .libraryItem(.search):
            return "Searching Library…"
        case .libraryItem(let item):
            return item.title
        case .smartList(let type):
            return type.rawValue
        case .list(let uuid):
            return dataCoordinator.cachedLists.first { $0.listID == uuid }?.listName ?? "List"
        case .savedSearch(let id):
            return SavedSearchStore.shared.search(id)?.name ?? "Saved Search"
        case .tag(let tag):
            return truncateListName(tag.name)
        }
    }
}

/// MainView's sidebar-item onChange. See its use site.
private struct SidebarChangeModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    let action: (SidebarItem, SidebarItem) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: appState.selectedSidebarItem) { oldItem, newItem in
            /// Defers the handler to the next run loop, clear of the view update that draws the
            /// switch: clearing the search field writes the toolbar field's bound text.
            ///
            /// DispatchQueue.main.async is used instead of Task { @MainActor in }. onChange runs at
            /// User-Interactive QoS, and a bare Task defaults to a lower QoS, which triggers a
            /// priority-inversion warning. DispatchQueue.main.async keeps the caller's QoS.
            DispatchQueue.main.async {
                action(oldItem, newItem)
            }
        }
    }
}

/// MainView's search-content onChange, in a modifier of its own for the same reason as
/// SidebarChangeModifier. Runs synchronously: the entry and exit it drives clear the selection
/// in navigate(to:), which must land in the same frame as the switch.
private struct SearchContentChangeModifier: ViewModifier {
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: SearchController.shared.hasContent) { _, hasContent in
            action(hasContent)
        }
    }
}

/// MainView's toolbar search field, tokens, and "#field" suggestions. See its use site.
private struct SearchFieldModifier: ViewModifier {
    let searchController: SearchController
    @Environment(DataCoordinator.self) private var dataCoordinator
    /// Whether the search field holds keyboard focus. See SearchFieldSuggestions.isFieldFocused.
    @FocusState private var isFieldFocused: Bool

    func body(content: Content) -> some View {
        content
            .searchable(
                text: Bindable(searchController).searchText,
                tokens: Bindable(searchController).currentTokens,
                placement: .toolbar,
                prompt: "Search all films"
            ) { token in
                Text(token.displayName)
            }
            .searchSuggestions {
                SearchFieldSuggestions(searchController: searchController, dataCoordinator: dataCoordinator,
                                       isFieldFocused: isFieldFocused)
            }
            .searchFocused($isFieldFocused)
            .onChange(of: isFieldFocused) { _, focused in
                if focused { searchController.releaseEmptyFieldMenu() }
            }
            /// Typing proves the field has the keyboard, even if the focus state never
            /// flipped (it may have stayed true throughout).
            .onChange(of: searchController.searchText.isEmpty) { _, isEmpty in
                if !isEmpty { searchController.releaseEmptyFieldMenu() }
            }
            .onAppear { searchController.suggestionSource = dataCoordinator }
            .background(MainWindowFocusSink(searchController: searchController))
    }
}

/// The main window's invisible holder of keyboard focus: where SearchController's focus guard
/// puts focus that would otherwise fall to the search field unasked. Zero-size, draws nothing,
/// and passes every key up the responder chain, so holding focus here is the same as no view
/// holding it, except that AppKit and SwiftUI stop looking for somewhere else to put it.
private struct MainWindowFocusSink: NSViewRepresentable {
    let searchController: SearchController

    func makeNSView(context: Context) -> SinkView {
        let view = SinkView()
        searchController.focusSink = view
        /// After the view is in its window, which is not yet the case here.
        Task { @MainActor [weak view] in
            guard let view, let window = unsafe view.window else { return }
            searchController.watchFieldFocus(in: window)
        }
        return view
    }

    func updateNSView(_ nsView: SinkView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SinkView, context: Context) -> CGSize? {
        .zero
    }

    final class SinkView: NSView {
        override var acceptsFirstResponder: Bool { true }
        override var focusRingType: NSFocusRingType { get { .none } set {} }
    }
}

/// The search field's drop-down: the "#field" suggestions, the value suggestions for what
/// is being typed, and the recent searches while the field is empty. At most
/// SearchSuggestionLimits.menuRows rows in all, in that order of priority. A view of its
/// own so that the search text it reads invalidates only this. See SearchFieldModifier.
private struct SearchFieldSuggestions: View {
    let searchController: SearchController
    let dataCoordinator: DataCoordinator
    /// The field holds keyboard focus. The drop-down opens whenever its content goes from empty to
    /// not empty, focused or not. Clearing the field on leaving search would pop the menu over the
    /// new view, so recent searches are offered only while focused.
    let isFieldFocused: Bool
    @AppStorage(preference: Preferences.showSearchSuggestionsKey)
        private var showSearchSuggestions: Bool
    @AppStorage(preference: Preferences.showRecentSearchesKey)
        private var showRecentSearches: Bool

    var body: some View {
        let limit = SearchSuggestionLimits.menuRows
        let fields = Array(searchController.getSuggestedFields().prefix(limit))
        let values = showSearchSuggestions
            ? Array(searchController.valueSuggestions.prefix(limit - fields.count)) : []
        /// Saved searches lead the empty field's menu, above the recent searches. Each
        /// header takes one of the rows.
        let saved = savedSearchesShown
            ? Array(SavedSearchStore.shared.searches.prefix(max(0, limit - fields.count - values.count - 1)))
            : []
        let savedRows = saved.isEmpty ? 0 : saved.count + 1
        let recents = recentSearchesShown
            ? Array(searchController.recentSearches.prefix(max(0, min(SearchSuggestionLimits.recentSearches,
                                                                     limit - fields.count - values.count - savedRows - 1))))
            : []

        fieldSuggestions(fields)
        ForEach(values, id: \.self) { suggestion in
            Button {
                searchController.applySuggestion(suggestion)
            } label: {
                /// One Text, so the prefix and value share a single line that truncates as a
                /// whole at the menu's width.
                Text("\(Text(suggestion.prefix).foregroundStyle(.secondary))\(suggestion.field == .tags ? truncateListName(suggestion.value) : suggestion.value)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if !saved.isEmpty {
            /// A native section: the system's header style, never selectable.
            Section("Saved Searches") {
                ForEach(saved) { search in
                    Button {
                        SavedSearchActions.openInSearchField(search.id)
                    } label: {
                        Text(search.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        if !recents.isEmpty {
            /// A native section: the system's header style, never selectable.
            Section("Recent Searches") {
                ForEach(recents, id: \.self) { recent in
                    Button {
                        searchController.applyRecentSearch(recent)
                    } label: {
                        Text(recent.label)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Saved searches show on the same terms as recent ones, but follow only the suggestions
    /// setting: they are not session history.
    private var savedSearchesShown: Bool {
        isFieldFocused && !searchController.isEmptyFieldMenuHeld && showSearchSuggestions
            && searchController.searchText.isEmpty && searchController.currentTokens.isEmpty
    }

    /// Recent searches fill the drop-down on the same terms, while they are kept.
    private var recentSearchesShown: Bool {
        savedSearchesShown && showRecentSearches
    }

    @ViewBuilder
    private func fieldSuggestions(_ suggestedFields: [SearchField]) -> some View {
        /// Both mode flags come from the same searchText, so they are resolved once here
        /// rather than rescanned for each suggested field.
        let isOrMode = searchController.isOrMode
        let isInvertedMode = searchController.isInvertedMode

        ForEach(suggestedFields, id: \.self) { field in
            Button {
                searchController.insertField(field)
            } label: {
                HStack(spacing: 4) {
                    if isOrMode {
                        Text("Or")
                            .foregroundStyle(.green)
                    }
                    if isInvertedMode {
                        Text("Not")
                            .foregroundStyle(.red)
                    }
                    Text(field.displayName)
                }
            }
        }
    }
}
