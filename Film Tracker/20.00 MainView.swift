// MARK: - MainView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Primary window construction for FilmTracker.app with DataCoordinator integration.

import SwiftUI
import SwiftData
import Combine

struct MainView: View, Loggable {
    nonisolated static let logTag = "[MainView]"

    @Environment(\.modelContext) private var modelContext
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
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                LeftSidebar()
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
            .onChange(of: appState.selectedSidebarItem) { oldItem, newItem in
                // Defer handler work to next run loop to prevent "Publishing changes from
                // within view updates" errors. selectionState.clearImmediate() is an
                // @Observable mutation that must not fire synchronously inside the onChange
                // callback while SwiftUI is mid-render.
                //
                // DispatchQueue.main.async is used rather than Task { @MainActor in }
                // because onChange fires on the AppKit event thread at User-Interactive QoS.
                // A bare Task defaults to .default QoS, producing the "Thread running at
                // User-interactive quality-of-service class waiting on a lower QoS thread"
                // runtime warning. DispatchQueue.main.async inherits the caller's QoS
                // automatically, avoiding that inversion — consistent with SelectionState.select()
                // and RecentsState.selectCategory().
                DispatchQueue.main.async {
                    handleViewChange(from: oldItem, to: newItem)
                }
            }
            .onChange(of: searchController.hasContent) { _, hasContent in
                handleSearchContentChange(hasContent)
            }
            .task(priority: .userInitiated) { await initialize() }
            .onAppear {
                // Setup global keyboard event manager.
                keyboardManager.setup(appState: appState, selectionState: selectionState, dataCoordinator: dataCoordinator)
            }
            .onReceive(AppEventBus.shared.uiCommands
                .filter { if case .toggleLeftSidebar = $0 { return true
                } else { return false } }) { _ in
                toggleSidebarVisibility() }
            .onReceive(AppEventBus.shared.uiCommands
                .compactMap { command -> (field: SearchField, value: String)? in
                    if case .activateTokenSearch(let field, let value) = command {
                        return (field, value)
                    }
                    return nil
                }) { payload in
                handleActivateTokenSearch(field: payload.field, value: payload.value)
            }
            .onReceive(AppEventBus.shared.uiCommands) { command in
                switch command {
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
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    AddNewToolbarButton()
                }
                ToolbarItem(placement: .automatic) {
                    ImportToolbarMenu()
                }
                ToolbarItem(placement: .automatic) {
                    AddNewListToolbarButton()
                }
                ToolbarItem(placement: .automatic) {
                    ScanDuplicatesToolbarButton()
                }
                // Doubles the automatically-inserted gap between the last toolbar
                // button and the search field. macOS inserts a standard ~8pt gap
                // between adjacent toolbar items by default; adding a second,
                // matching fixed-width spacer item here inserts one additional
                // gap's worth of space, doubling the total space to ~16pt without
                // altering any other spacing, ordering, or toolbar behavior.
                ToolbarItem(placement: .automatic) {
                    Spacer()
                        .frame(width: 8)
                }
            }
            .navigationTitle(navigationTitleText)
            .navigationSubtitle("")
    }

    // MARK: - Navigation Title Text
    private var navigationTitleText: String {
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
            return listName(for: uuid)
        }
    }
    
    private func listName(for uuid: UUID) -> String {
        if let list = dataCoordinator.getList(uuid) {
            return list.listName
        }
        return "List"
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
        ImportHistory.shared.attach(dataCoordinator.modelContainer)
        
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
                // Resolve the destination first: previousSidebarItem is captured at search
                // entry and can be invalidated while the search session is still open (e.g.
                // the user deletes the list they searched from, or disables smart lists).
                // LeftSidebar only redirects selectedSidebarItem when that item is the one
                // currently displayed — which it never is while search is showing — so the
                // stale value would otherwise be navigated back to.
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
                // data on its very first call. Without this, the first updateNSView receives
                // the stale search results (still in dataCoordinator.films at render time),
                // consuming GalleryScrollIntent and computing scroll geometry against the
                // wrong film set — producing a multi-frame blank gap before the correct films
                // arrive in a subsequent update pass.
                //
                // This mirrors the same pre-load pattern used on search entry (see
                // switchToViewSync(.search) above). The subsequent switchToViewSync call from
                // GalleryView.handleSidebarChange is a no-op: isViewChange=false,
                // stateChanged=false → no reload triggered.
                //
                // The pre-load is unconditional — it runs on every search exit, not only the
                // selection-preservation path — and it deliberately happens BEFORE the
                // preservation decision below, because it is what makes that decision exact
                // (see the membership check).
                //
                // The candidate selection is captured before the pre-load so the decision is
                // made against the selection as it stood in the search results, independent
                // of anything the reload might touch.
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
                // Membership is tested against dataCoordinator.films, which the pre-load
                // above just populated with the destination's real, final film set. That set
                // already has the destination's own sort, membership, sub-category tab, and
                // — critically — its active FilterOptions applied. An earlier hand-rolled
                // per-view membership helper checked raw view membership only, so a film
                // excluded by the destination's active filters was preserved as "selected"
                // while being absent from the grid, leaving SelectionState and the right
                // sidebar pointing at a film the user could not see or deselect. Using the
                // loaded set is both exact and self-maintaining: a new view type needs no
                // new membership case here.
                if Preferences.maintainSelectionOnSearchExit,
                   let selectedFilmID = candidateFilmID,
                   destination.capabilities.isValidSearchExitDestination,
                   dataCoordinator.films.contains(where: { $0.id == selectedFilmID }) {

                    Self.log("Search-exit: film \(selectedFilmID) present in \(destination) — preserving selection")
                    appState.armSearchExitSelectionPreservation(filmID: selectedFilmID)
                    appState.cancelTokenSearchSelectionPreservation()

                    // Hand the scroll target to the destination gallery, addressed to
                    // the destination ViewIdentifier so no other (stale) instance can
                    // consume or clear it during the transition. Both gallery styles —
                    // GallerySubview (grid) and DraggableListView (list) — resolve the
                    // scroll in their own scroll view's viewWillDraw(), so the
                    // destination's first painted frame is already positioned at the
                    // selected film regardless of which style is currently active. The
                    // film's row is placed at the top of the viewport (as far as the
                    // content allows), like Cmd+L, even if the film is already visible.
                    GalleryScrollIntent.shared.set(filmID: selectedFilmID,
                                                   targetViewID: destinationViewID)
                    // And hand it keyboard focus. The preserved film reads to the user as
                    // "still selected in the gallery I came back to", and before the
                    // search that gallery was where the arrow keys went; the destination
                    // is a fresh instance, though, and without this it never becomes first
                    // responder — the arrows are dead until a Tab press moves focus to
                    // where it already appears to be. Addressed like the scroll intent,
                    // and armed under the same preference gate.
                    GalleryFocusIntent.shared.set(targetViewID: destinationViewID)
                } else {
                    // No preservation on this exit — make sure a preserve ID left over from
                    // an earlier, abandoned transition cannot be honored by navigate(to:).
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

    /// Resolves `previousSidebarItem` to a destination that is still valid at search-exit
    /// time. `previousSidebarItem` is captured when search is entered and is not updated
    /// while the search session is open, so a user-generated list that existed then may
    /// have been deleted since.
    ///
    /// LeftSidebar already redirects to All Films when a list is deleted — but only when
    /// that list is the item currently selected, which it never is while the search view
    /// is displayed. Without this check, exiting search restores `.list(deletedID)`:
    /// MainContentSwitcher builds a GalleryView keyed to a list that no longer exists,
    /// `updateListInfo` resolves it to nil, and the LeftSidebar is asked to highlight a
    /// row that isn't there.
    ///
    /// Returns All Films for a list that no longer exists; otherwise returns
    /// `previousSidebarItem` unchanged.
    private func resolvedPreviousSidebarItem() -> SidebarItem {
        guard case .list(let listID) = previousSidebarItem else { return previousSidebarItem }
        return dataCoordinator.getList(listID) == nil ? .libraryItem(.allFilms) : previousSidebarItem
    }

    // MARK: - Token Search Activation
    
    /// Handles the .activateTokenSearch UICommand fired by sidebar "Search" buttons.
    /// Saves the current view as the return destination, then activates a programmatic
    /// token search so the user sees instant results with no intermediate state.
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

        // Eagerly switch ViewStateManager to the search view before the token is applied
        // so that triggerSearchImmediate() inside programmaticTokenSearch finds an active
        // search context and writes the query correctly (mirrors handleSearchContentChange).
        // Also suppress the selection clear that handleViewChange would normally fire:
        // since the currently-selected film is guaranteed to appear in the results, passing
        // the selection through produces a smoother experience.
        //
        // The flag is set ONLY when this call will actually cause a sidebar transition.
        // These Search buttons live in the RightSidebar, which is displayed alongside the
        // search view itself, so activating one while already in search assigns
        // selectedSidebarItem its existing value — a no-op that never fires onChange, and
        // therefore never runs the handleViewChange that consumes the flag. Setting it
        // unconditionally left it armed indefinitely, causing the *next* genuine view
        // change (to any view) to silently skip its selection and focus-ring clear.
        if !isAlreadyInSearch {
            appState.armTokenSearchSelectionPreservation()
        }
        // matchingStyleOf: current seeds this search session's initial grid/list style
        // from the view being left, matching the standard search-entry path in
        // handleSearchContentChange — see switchToViewSync's doc comment for rationale.
        // When already in search there is no view being left, so no seed is supplied and
        // switchToViewSync preserves whatever style the live session is using.
        ViewStateManager.shared.switchToViewSync(
            .search,
            matchingStyleOf: isAlreadyInSearch ? nil : viewIdentifier(for: current))

        // Apply the token and trigger immediate search. This also sets hasContent = true,
        // which fires onChange(of: searchController.hasContent) → handleSearchContentChange,
        // but handleSearchContentChange guards against overwriting previousSidebarItem or
        // calling switchToViewSync again when already in the search view.
        searchController.programmaticTokenSearch(field: field, value: value)

        // Switch the sidebar item last so MainView's onChange(of: selectedSidebarItem) fires
        // after the search state is fully set up, preventing any window where the search view
        // is visible but the query hasn't been applied yet.
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
                .frame(width: 22)
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
            // Neither item is locked while an import runs: both only navigate, and
            // reaching the Imports view is exactly what a user wants to do mid-import.
            // The import-in-progress lock lives on the Imports title bar's "Select
            // Files" button, the one control that actually starts one. Each item is
            // still disabled when its own tab is already the one on screen, where
            // selecting it would do nothing.
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
                .frame(width: 22)
        }
        .help("Create new list")
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
                .frame(width: 22)
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
        
        // Determine if this view should show the sidebar and status bar
        // Both the sidebar and status bar share this same visibility logic; see
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
                            .frame(height: 29)
                            .background(Color(NSColor.controlBackgroundColor))
                            .overlay(Divider(), alignment: .top)
                    }
                }
            }
            // Lower layout priority allows gallery to compress first
            // when space is constrained at smaller window sizes
            .layoutPriority(0)
            
            // Conditionally show the sidebar. This genuinely destroys and recreates
            // RightSidebar when showsChrome flips — every piece of its @State
            // (selectedFilm, hasSelection, the table-expansion flags, neighborsReadyFilmID)
            // is discarded and starts fresh on the way back in. RightSidebar resolves its
            // content only from onChange(of: selectionState.selectedFilmIDs), which does
            // not fire on mount, so a selection that OUTLIVED the flip would come back as
            // the "Nothing Selected" placeholder over a live selection.
            //
            // That cannot happen today because both paths that flip this flag clear the
            // selection first: a full view switch (handleViewChange, above) and a Reports
            // category switch to/from Data Visualizations (ReportsView's onChange of
            // selectedCategory). Any future view that toggles showsGalleryChrome while
            // preserving selection must either clear it likewise or give RightSidebar a
            // mount-time resolve.
            if showsChrome {
                Divider()
                
                RightSidebar()
                    .frame(width: 300)
                    .background(Color(NSColor.controlBackgroundColor))
                    .layoutPriority(1)
            }
        }
        // Disable animations on the layout container only to prevent 'jiggle' on
        // left sidebar state change, but allow animations in child views.
        .transaction { transaction in
            transaction.animation = nil
        }
    }
    
    // MARK: - Content View Switcher

    /// Returns the appropriate content view with stable identity.
    ///
    /// Only three sidebar items render something other than the gallery; the remaining six
    /// are all a plain `GalleryView(sidebarItem: item)` differing solely in the item they
    /// are mounted for, which also gives them their stable `.id`. Those six share one branch rather than being written out
    /// separately, so a modifier added to the gallery here is added once instead of six
    /// times. The switch stays exhaustive with no `default`, so a new SidebarItem case is
    /// still a compile error until it is placed on the correct side of this split.
    ///
    /// (The Film Queue is one of the six: it reuses the standard gallery pipeline — grid +
    /// title bar + right sidebar — with its section-divider grouping driven entirely inside
    /// GallerySubview / the layout, gated to that view.)
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
             .libraryItem(.filmQueue), .smartList, .list:
            // `item` IS the identity. Each of the six is a distinct SidebarItem value, so
            // this is exactly as discriminating as the six hand-written strings it
            // replaces ("gallery-all-films", "gallery-smartlist-<type>", "gallery-list-
            // <uuid>", …) — including per-smart-list-type and per-list-UUID distinctness —
            // with no string table to keep in step with the enum. That distinctness is
            // load-bearing: navigating between two gallery-backed views must tear the old
            // GalleryView down and mount a fresh one, which parts of the scroll-handoff
            // machinery rely on (see GalleryScrollIntent.consumableOnReuse).
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

/// MainView's toolbar search field, tokens, and "#field" suggestions. See its use site.
private struct SearchFieldModifier: ViewModifier {
    let searchController: SearchController

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
                SearchFieldSuggestions(searchController: searchController)
            }
    }
}

/// The search field's "#field" suggestions. A view of its own so that the search text it
/// reads invalidates only this. See SearchFieldModifier.
private struct SearchFieldSuggestions: View {
    let searchController: SearchController

    var body: some View {
        if searchController.searchText.contains("#") {
            fieldSuggestions
        }
    }

    @ViewBuilder
    private var fieldSuggestions: some View {
        let suggestedFields = searchController.getSuggestedFields()
        // Both mode flags are derived from the same searchText and are identical for every
        // row, so they are resolved once here rather than re-scanning the string twice per
        // suggested field (up to 40 redundant scans per keystroke).
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
