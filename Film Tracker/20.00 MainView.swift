// MARK: - MainView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Builds the main window: the sidebar and gallery layout, the toolbar, search handling, and navigation between views.
// It is wired to DataCoordinator and AppState.

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
    @State private var searchController = SearchController.shared
    var keyboardManager = KeyboardManager.shared
    
    // Track the sidebar item before entering search view
    @State private var previousSidebarItem: SidebarItem = .libraryItem(.allFilms)

    // MARK: - Selection Preservation
    //
    // Two separate mechanisms handle the two distinct selection-preservation features.
    // They are intentionally decoupled so each can be reasoned about independently.
    //
    // 1. Search-exit selection preservation (Preferences.maintainSelectionOnSearchExit):
    //    When the user clears a search query and a single film is selected in the results,
    //    and that film is also present in the prior gallery-based view (All Films, any
    //    user-generated list, any smart list, or any Recents category), its UUID is armed
    //    via appState.armSearchExitSelectionPreservation(filmID:).
    //
    // 2. Token search activation (sidebar "Search" buttons):
    //    When navigating INTO the search view via a programmatic token search, the currently-
    //    selected film is guaranteed to appear in the results, so
    //    appState.armTokenSearchSelectionPreservation() is called immediately before the
    //    transition to skip the clear for that single incoming transition only.
    //
    // Both tokens live on AppState rather than in @State here, because the clear they
    // suppress now happens inside appState.navigate(to:) — synchronously, ahead of the item
    // flip — rather than in a handler reacting to it. See AppState.navigate(to:) for why
    // that ordering matters and for the validation each token still passes through.

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
            // The search field lives in a modifier of its own. SwiftUI reads the field's
            // text binding while updating the view that applies `.searchable`, so applied
            // here it made every keystroke re-evaluate this whole body (the split view,
            // both sidebars' parents, the toolbar). Scoped to the modifier, a keystroke
            // re-evaluates only the modifier.
            .modifier(SearchFieldModifier(searchController: searchController))
            .onSubmit(of: .search) {
                Self.log("Search submitted")
                searchController.processSearchSubmission()
            }
            // Reads selectedSidebarItem inside a modifier of its own, for the same reason
            // as SearchFieldModifier: an onChange reads its value while this body is
            // evaluated, so applied here it made every navigation re-evaluate this whole
            // body. The handler itself is unchanged; see SidebarChangeModifier.
            .modifier(SidebarChangeModifier { oldItem, newItem in
                handleViewChange(from: oldItem, to: newItem)
            })
            .onChange(of: searchController.hasContent) { _, hasContent in
                handleSearchContentChange(hasContent)
            }
            .task(priority: .userInitiated) { await initialize() }
            .onAppear {
                // Setup global keyboard event manager.
                keyboardManager.setup(appState: appState, selectionState: selectionState, dataCoordinator: dataCoordinator)
            }
            // One subscription for every UICommand this view handles. Each operator chain
            // (.filter, .compactMap) built a new publisher on every body evaluation, which
            // SwiftUI answered by resubscribing; the subject itself is a stable instance.
            .onReceive(AppEventBus.shared.uiCommands) { command in
                switch command {
                case .toggleLeftSidebar: toggleSidebarVisibility()
                case .activateTokenSearch(let field, let value):
                    handleActivateTokenSearch(field: field, value: value)
                case .openSavedSearchInField(let id):
                    handleOpenSavedSearchInField(id)
                case .navigateToImportsMetadata: navigateToImports(.metadata)
                case .navigateToImportsRatings: navigateToImports(.ratings)
                default: break
                }
            }
        }
    }

    /// Switches to the Imports view and selects `category`'s tab. It deliberately stops
    /// there: arriving at the Imports view NEVER opens a file picker on its own, however
    /// the user got here. Starting an import is always a second, explicit act — the title
    /// bar's "Select Files" button, or pressing the same shortcut again once this view
    /// holds it.
    ///
    /// ImportsState is a singleton mutated directly here (rather than via an AppEventBus
    /// round-trip) so the tab selection is guaranteed to be applied before ImportsView's
    /// next render, regardless of whether the view already exists or is about to be
    /// created by the sidebar-item switch above.
    private func navigateToImports(_ category: ImportsCategory) {
        appState.navigate(to: .libraryItem(.imports))
        ImportsState.shared.requestCategory(category)
    }


    // MARK: - Main Content Area
    private var mainContentArea: some View {
        MainContentSwitcher()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // One toolbar item holds all five buttons, because SwiftUI's toolbar bridge pays a cost per item at
            // launch. The 8 pt HStack spacing matches the toolbar's gaps, and the 9 pt trailing padding stands in
            // for the former spacer item.
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
    @MainActor
    private func initialize() async {
        // Removed redundant database probe and loadFilmsImmediate()
        // DataCoordinator.initializeMemoryStore() already handles all data loading
        // in FilmTrackerApp.initializeApp()
        
        ImportProgress.shared.attachContext(modelContext)
        ImportProgress.shared.attachCoordinator(dataCoordinator)
        // Loads the Imports view's session index in the background, so the first visit
        // to Imports reads it rather than fetching. See ImportHistory.
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
        // If user manually switches away from search view, clear the search.
        // clearSearch() already zeroes searchText, so no separate assignment is needed.
        //
        // Guard: this handler is deferred one run loop via DispatchQueue.main.async, which
        // creates a window where the user can begin a new search query before the deferred
        // block fires. Specifically:
        //   1. User deletes all text → hasContent = false → handleSearchContentChange
        //      switches selectedSidebarItem back to previousSidebarItem (synchronously).
        //   2. DispatchQueue.main.async defers handleViewChange(from: .search, to: previous).
        //   3. User immediately starts typing again → hasContent = true →
        //      handleSearchContentChange switches back to .libraryItem(.search).
        //   4. Deferred handleViewChange fires → the guard below detects selectedSidebarItem
        //      is already back to .search and skips clearSearch(), preserving the new query.
        //
        // NOTE: Do NOT guard on searchController.hasContent here. When the user manually
        // navigates away from search while content is present, hasContent is still true —
        // but clearSearch() must still fire to reset the field. The searchAlreadyRestarted
        // check alone is the correct and sufficient guard for the race scenario above,
        // because in that race selectedSidebarItem is already back to .search by the time
        // this deferred block runs (step 3 above happens before step 4).
        if case .libraryItem(.search) = oldItem, newItem != oldItem {
            let searchAlreadyRestarted: Bool
            if case .libraryItem(.search) = appState.selectedSidebarItem {
                searchAlreadyRestarted = true
            } else {
                searchAlreadyRestarted = false
            }
            
            if searchAlreadyRestarted {
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
            // Already in search view — do not overwrite previousSidebarItem.
            if case .libraryItem(.search) = appState.selectedSidebarItem {
                return
            }
            
            // Save the current view as the return destination. The guard above has
            // already returned for `.search`, so `current` can never be search here —
            // which is what keeps rapid clear/re-enter cycles returning to the true prior
            // destination rather than to search itself.
            let current = appState.selectedSidebarItem
            previousSidebarItem = current
            Self.log("Search content entered - switching to search view (previous: \(previousSidebarItem))")

            // A new search session invalidates any unconsumed scroll intent from a
            // previous session — a search-exit handoff whose destination was never
            // rendered, or a grid⟷list toggle handoff addressed to the view being
            // left for search. Neither can legitimately resolve once search is
            // entered, since GalleryView.handleSidebarChange won't fire again until exit.
            GalleryScrollIntent.shared.clear()
            GalleryFocusIntent.shared.clear()

            appState.navigate(to: .libraryItem(.search))
            
            // Eagerly promote ViewStateManager to the search view in the same run-loop tick
            // that selectedSidebarItem is set.
            //
            // Without this, ViewStateManager.activeView remains on the prior view until the
            // GalleryView embedded inside InlineSearchView fires its onAppear callback (which
            // happens in a subsequent SwiftUI layout pass — asynchronously). During that gap,
            // SearchController's debounced triggerSearch() Task can fire and call
            // updateSearchQuery(), which guards `activeView.isSearch` and silently drops the
            // query — leaving the search view present but empty with no results.
            //
            // By calling switchToViewSync(.search) here, activeView becomes .search
            // immediately. The debounce Task's updateSearchQuery() call always finds
            // activeView.isSearch == true and writes the query correctly.
            // The subsequent onAppear-triggered switchToViewSync(.search) from the embedded
            // GalleryView becomes a complete no-op: isViewChange is false (activeView is
            // already .search), the state is identical, so no reload or AppEventBus post fires.
            //
            // matchingStyleOf: current seeds the search session's initial grid/list style
            // from the view being left, so results appear in the same style as the
            // destination the user will return to on search exit (see
            // switchToViewSync's doc comment for the full rationale).
            ViewStateManager.shared.switchToViewSync(.search, matchingStyleOf: viewIdentifier(for: current))
        } else {
            // Search cleared - return to previous view only if still in search.
            if case .libraryItem(.search) = appState.selectedSidebarItem {
                // Resolve the destination first. previousSidebarItem is captured at search entry and can become invalid
                // while search is open, for example if the user deletes the list they searched from. LeftSidebar redirects
                // only the displayed item, which is never the search view, so the stale value must be checked here.
                let destination = resolvedPreviousSidebarItem()
                if destination != previousSidebarItem {
                    Self.log("Search-exit: previous item \(previousSidebarItem) no longer valid — falling back to \(destination)")
                    previousSidebarItem = destination
                }
                Self.log("Search cleared - returning to previous view: \(destination)")

                // MARK: Search-Exit Pre-load
                // ViewStateManager.switchToViewSync is called for the destination view
                // BEFORE setting selectedSidebarItem. This ensures dataCoordinator.films is
                // populated with the destination view's films before SwiftUI renders the new
                // GalleryView instance, so GallerySubview.updateNSView fires with correct
                // data on its first call. Otherwise the gallery would scroll against the stale
                // search results still in dataCoordinator.films, leaving a blank gap until the
                // correct films arrive.
                //
                // This mirrors the pre-load on search entry (see switchToViewSync(.search)
                // above). The later switchToViewSync call from GalleryView.handleSidebarChange
                // is a no-op, so no second reload runs.
                //
                // The pre-load runs on every search exit, not only the selection-preservation
                // path. It runs before the preservation decision below, which depends on it.
                //
                // The candidate selection is captured before the pre-load, so the decision uses
                // the selection as it stood in the search results.
                let candidateFilmID: UUID? = selectionState.selectedFilmIDs.count == 1
                    ? selectionState.selectedFilmID
                    : nil

                let destinationViewID = viewIdentifier(for: destination)
                GalleryScrollIntent.shared.clear()
                GalleryFocusIntent.shared.clear()
                ViewStateManager.shared.switchToViewSync(destinationViewID)

                // MARK: Search-Exit Selection Preservation
                // When the preference is enabled, exactly one film is selected in the search
                // results, the prior view is a gallery-backed view, and that film is actually
                // present in the destination, preserve the selection and auto-scroll the
                // destination gallery (whichever style — grid or list — is currently active)
                // so the film appears in the topmost row of the viewport.
                //
                // Membership is tested against dataCoordinator.films, which the pre-load above has
                // just populated with the destination's final set, including sort, tab, and active
                // FilterOptions. Raw view membership would keep a film that the filters hide selected.
                if Preferences.maintainSelectionOnSearchExit,
                   let selectedFilmID = candidateFilmID,
                   destination.capabilities.isValidSearchExitDestination,
                   dataCoordinator.films.contains(where: { $0.id == selectedFilmID }) {

                    Self.log("Search-exit: film \(selectedFilmID) present in \(destination) — preserving selection")
                    appState.armSearchExitSelectionPreservation(filmID: selectedFilmID)
                    appState.cancelTokenSearchSelectionPreservation()

                    // Hands the scroll target to the destination gallery, addressed to its
                    // ViewIdentifier so no stale instance can consume it. Both gallery styles
                    // resolve the scroll in viewWillDraw(), so the first painted frame is already
                    // positioned. The film moves to the top of the viewport, as with Cmd+L.
                    GalleryScrollIntent.shared.set(filmID: selectedFilmID,
                                                   targetViewID: destinationViewID)
                    // Also hands over keyboard focus. The destination is a fresh instance that
                    // would otherwise never become first responder, leaving the arrow keys dead
                    // until Tab is pressed. Addressed like the scroll intent, under the same gate.
                    GalleryFocusIntent.shared.set(targetViewID: destinationViewID)
                } else {
                    // No preservation on this exit. Clears any preserve ID left by an earlier,
                    // abandoned transition so navigate(to:) cannot honor it.
                    appState.armSearchExitSelectionPreservation(filmID: nil)
                }

                appState.navigate(to: destination)
            }
        }
    }

    // MARK: - Search-Exit Helpers

    /// Converts a SidebarItem to its corresponding ViewIdentifier.
    /// Delegates to the canonical ViewIdentifier.from(_:) so that the translation
    /// logic lives in exactly one place across the entire codebase.
    private func viewIdentifier(for item: SidebarItem) -> ViewIdentifier {
        ViewIdentifier.from(item)
    }

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
            // Smart lists were turned off while the search was open.
            return .libraryItem(.allFilms)
        default:
            return previousSidebarItem
        }
    }

    // MARK: - Saved Search Editing

    /// Opens a saved search in the field. It promotes to the search view eagerly, as
    /// handleActivateTokenSearch does. The view being left becomes the exit destination.
    /// "Update Saved Search…" in the title bar goes to the saved search's own view instead.
    private func handleOpenSavedSearchInField(_ id: UUID) {
        guard let search = SavedSearchStore.shared.search(id) else { return }
        let current = appState.selectedSidebarItem
        let isAlreadyInSearch = current == .libraryItem(.search)
        ViewStateManager.shared.switchToViewSync(
            .search, matchingStyleOf: isAlreadyInSearch ? nil : viewIdentifier(for: current))
        searchController.applySavedSearch(search)
        // Focuses the field with the caret after the query, once the search view has settled.
        DispatchQueue.main.async {
            guard let item = NSApp.keyWindow?.toolbar?.items.lazy
                    .compactMap({ $0 as? NSSearchToolbarItem }).first else { return }
            item.beginSearchInteraction()
            if let editor = item.searchField.currentEditor() {
                editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
            }
        }
    }

    // MARK: - Token Search Activation
    
    /// Handles the .activateTokenSearch command from the sidebar "Search" buttons. It saves the
    /// current view as the return destination, then runs a token search with instant results.
    private func handleActivateTokenSearch(field: SearchField, value: String) {
        // Save the current sidebar item as the return destination, matching the
        // same guard used in handleSearchContentChange to prevent search→search cycles.
        let current = appState.selectedSidebarItem
        let isAlreadyInSearch: Bool
        if case .libraryItem(.search) = current {
            // Already in search view — skip saving previousSidebarItem, just replace query.
            isAlreadyInSearch = true
        } else {
            isAlreadyInSearch = false
            previousSidebarItem = current
        }

        // Switches to the search view before the token is applied, so triggerSearchImmediate()
        // finds an active search context (as in handleSearchContentChange). It also suppresses
        // the selection clear in handleViewChange, since the selected film stays in the results.
        //
        // The suppression flag is set only when this call causes a sidebar transition. Otherwise
        // it would stay armed and skip the selection clear on the next real view change.
        if !isAlreadyInSearch {
            appState.armTokenSearchSelectionPreservation()
        }
        // matchingStyleOf seeds the search's grid or list style from the view being left, as in
        // handleSearchContentChange (see switchToViewSync). Already in search, no seed is passed.
        ViewStateManager.shared.switchToViewSync(
            .search,
            matchingStyleOf: isAlreadyInSearch ? nil : viewIdentifier(for: current))

        // Applies the token and runs the search. This sets hasContent, which calls
        // handleSearchContentChange. That handler does not overwrite previousSidebarItem here.
        searchController.programmaticTokenSearch(field: field, value: value)

        // The sidebar item is switched last, so the search state is complete before the search
        // view appears.
        appState.navigate(to: .libraryItem(.search))
        
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
/// MainView.navigateToImports(_:).
@MainActor
private struct ImportToolbarMenu: View {
    var importsState = ImportsState.shared

    var body: some View {
        Menu {
            // Neither item is locked during an import, since both only navigate. The lock is on
            // the Imports title bar's "Select Files" button. Each item is disabled when its own
            // tab is already on screen.
            Button("Import Metadata…") {
                AppEventBus.shared.sendCommand(.navigateToImportsMetadata)
            }
            .disabled(importsState.isViewingImports && importsState.selectedCategory == .metadata)

            Button("Import Ratings…") {
                AppEventBus.shared.sendCommand(.navigateToImportsRatings)
            }
            .disabled(importsState.isViewingImports && importsState.selectedCategory == .ratings)
        } label: {
            Image(systemName: "arrow.down.document")
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
    @AppStorage(preference: Preferences.showStatusBarKey) private var showStatusBar: Bool

    var body: some View {
        let selectedItem = appState.selectedSidebarItem
        
        // The sidebar and status bar share this visibility rule. See
        // ViewCapabilities.showsGalleryChrome (ViewState.swift) for the per-view rules.
        let showsChrome = selectedItem.capabilities.showsGalleryChrome
        
        // Single, stable layout structure that persists across view switches
        HStack(spacing: 0) {
            // Main content area with status bar overlay
            ZStack(alignment: .bottom) {
                // Content switcher with stable identities
                contentView(for: selectedItem)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                
                // StatusBar as overlay - doesn't affect layout of content above
                // Only show if preference is enabled and view supports it
                if showStatusBar && showsChrome {
                    VStack(spacing: 0) {
                        StatusBar()
                            .frame(height: StatusBar.height)
                            .background(Color(NSColor.controlBackgroundColor))
                            .overlay(Divider(), alignment: .top)
                    }
                }
            }
            // Lower layout priority allows gallery to compress first
            // when space is constrained at smaller window sizes
            .layoutPriority(0)
            
            // The sidebar is shown conditionally. Flipping showsChrome destroys and recreates
            // RightSidebar, discarding all of its @State. RightSidebar resolves its content only
            // on selection change, not on mount, so a selection that survived the flip would
            // show as "Nothing Selected". Both flipping paths clear the selection first: a view
            // switch (handleViewChange) and a Reports category change (ReportsView). Any future
            // view that toggles this flag must clear the selection too, or add a mount-time resolve.
            if showsChrome {
                Divider()
                
                Group {
                    if RSBProfileFlags.noSidebar { Color.clear } else { RightSidebar() }
                }
                    .frame(width: 300)
                    .background(Color(NSColor.controlBackgroundColor))
                    .layoutPriority(1)
            }
        }
        // Disables animations on the layout container to prevent a jiggle when the left sidebar
        // changes. Child views still animate.
        .transaction { transaction in
            transaction.animation = nil
        }
    }
    
    // MARK: - Content View Switcher

    /// Returns the appropriate content view with stable identity.
    ///
    /// Only three sidebar items render something other than the gallery. The other six are a plain
    /// `GalleryView(sidebarItem:)` that differ only in the item, which also gives each a stable `.id`.
    /// They share one branch, so a gallery modifier is added once. The switch has no `default`,
    /// so a new SidebarItem case is a compile error until it is placed.
    ///
    /// The Film Queue is one of the six. It uses the standard gallery pipeline, and its section
    /// dividers come from GallerySubview and the layout.
    @ViewBuilder
    private func contentView(for item: SidebarItem) -> some View {
        switch item {
        case .libraryItem(.search):
            InlineSearchView()
                .id("search")
        case .libraryItem(.reports):
            ReportsView()
                .id("reports")
        case .libraryItem(.imports):
            ImportsView()
                .id("imports")
        case .libraryItem(.allFilms), .libraryItem(.unwatched), .libraryItem(.recents),
             .libraryItem(.filmQueue), .smartList, .list, .savedSearch:
            // `item` is the identity. Each sidebar item is distinct, including per smart-list
            // type and per list UUID. Navigating between two gallery views must mount a fresh
            // GalleryView, which the scroll handoff relies on (see GalleryScrollIntent.consumableOnReuse).
            GalleryView(sidebarItem: item)
                .id(item)
        }
    }
}

// MARK: - Inline Search View
/// Shows placeholder when entering token, otherwise displays GalleryView with search results.
@MainActor
private struct InlineSearchView: View {
    @Environment(DataCoordinator.self) private var dataCoordinator
    @State private var searchController = SearchController.shared
    
    var body: some View {
        ZStack {
            // Show placeholder only when entering the first token (no confirmed tokens yet)
            if searchController.isEnteringToken && searchController.currentTokens.isEmpty {
                tokenEntryPlaceholder
            }
            // Show GalleryView with search results when search is active
            // PosterCache is now @Observable — read isReady directly; no wrapper class needed.
            else if dataCoordinator.isInitialized && PosterCache.shared.isReady {
                GalleryView(sidebarItem: .libraryItem(.search))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // Loading indicator
            if !dataCoordinator.isInitialized || !PosterCache.shared.isReady {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            }
        }
    }
    
    // Token entry placeholder.
    private var tokenEntryPlaceholder: some View {
        StandardPlaceholder(
            glyph: "magnifyingglass",
            title: "Enter Search Token",
            message: "Type a value after the field name, then press Return."
        )
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
        case .libraryItem(.allFilms):
            return "All Films"
        case .libraryItem(.search):
            return "Searching Library…"
        case .libraryItem(.unwatched):
            return "Unwatched"
        case .libraryItem(.recents):
            return "Recents"
        case .libraryItem(.reports):
            return "Reports"
        case .libraryItem(.imports):
            return "Imports"
        case .libraryItem(.filmQueue):
            return "Queue"
        case .smartList(let type):
            return type.rawValue
        case .list(let uuid):
            return dataCoordinator.cachedLists.first { $0.listID == uuid }?.listName ?? "List"
        case .savedSearch(let id):
            return SavedSearchStore.shared.search(id)?.name ?? "Saved Search"
        }
    }
}

/// MainView's sidebar-item onChange. See its use site.
private struct SidebarChangeModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    let action: (SidebarItem, SidebarItem) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: appState.selectedSidebarItem) { oldItem, newItem in
                // Defers the handler to the next run loop. selectionState.clearImmediate() is an
            // @Observable mutation and must not run during SwiftUI's render, which would produce
            // "Publishing changes from within view updates" errors.
            //
            // DispatchQueue.main.async is used instead of Task { @MainActor in }. onChange runs at
            // User-Interactive QoS, and a bare Task defaults to a lower QoS, which triggers a
            // priority-inversion warning. DispatchQueue.main.async keeps the caller's QoS.
            DispatchQueue.main.async {
                action(oldItem, newItem)
            }
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
            // Typing proves the field has the keyboard, even if the focus state never
            // flipped (it may have stayed true throughout).
            .onChange(of: searchController.searchText.isEmpty) { _, isEmpty in
                if !isEmpty { searchController.releaseEmptyFieldMenu() }
            }
            .onAppear { searchController.suggestionSource = dataCoordinator }
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
        let fields = searchController.searchText.contains("#")
            ? Array(searchController.getSuggestedFields().prefix(limit)) : []
        let values = showSearchSuggestions
            ? Array(searchController.valueSuggestions.prefix(limit - fields.count)) : []
        // Saved searches lead the empty field's menu, above the recent searches. Each
        // header takes one of the rows.
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
                // One Text, so the prefix and value share a single line that truncates as a
                // whole at the menu's width.
                Text("\(Text(suggestion.prefix).foregroundStyle(.secondary))\(suggestion.value)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if !saved.isEmpty {
            Text("Saved Searches:")
                .foregroundStyle(.secondary)
                .selectionDisabled()
            ForEach(saved) { search in
                Button {
                    searchController.applySavedSearch(search)
                } label: {
                    Text(search.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        if !recents.isEmpty {
            Text("Recent Searches:")
                .foregroundStyle(.secondary)
                .selectionDisabled()
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

    /// Saved searches show on the same terms as recent ones, but follow only the suggestions
    /// setting: they are not session history.
    private var savedSearchesShown: Bool {
        isFieldFocused && !searchController.isEmptyFieldMenuHeld && showSearchSuggestions
            && searchController.searchText.isEmpty && searchController.currentTokens.isEmpty
    }

    /// Recent searches fill the drop-down only while the field is focused and entirely empty.
    private var recentSearchesShown: Bool {
        isFieldFocused && !searchController.isEmptyFieldMenuHeld && showSearchSuggestions && showRecentSearches
            && searchController.searchText.isEmpty && searchController.currentTokens.isEmpty
    }

    @ViewBuilder
    private func fieldSuggestions(_ suggestedFields: [SearchField]) -> some View {
        // Both mode flags come from the same searchText, so they are resolved once here
        // rather than rescanned for each suggested field.
        let isOrMode = searchController.isOrMode
        let isInvertedMode = searchController.isInvertedMode

        if !suggestedFields.isEmpty {
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
}
