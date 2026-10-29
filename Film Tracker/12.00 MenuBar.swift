// MARK: - MenuBar.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Define all MenuBar commands using SwiftUI's declarative API.

import SwiftUI
import Combine

struct MenuBar: Commands {
    var appState: AppState
    var dataCoordinator: DataCoordinator
    var importsState = ImportsState.shared
    @FocusedValue(\.selectedFilmIDs) private var selectedFilmIDs: Set<UUID>?
    @FocusedValue(\.selectedFilmID) private var selectedFilmID: UUID?

    var selectionCount: Int { selectedFilmIDs?.count ?? 0 }
    var filmCount: Int { dataCoordinator.totalFilmCount }

    /// "Manage Queue Membership" once any selected film already occupies a Film Queue
    /// section — the point at which the submenu's items can remove as well as add — and
    /// the plain "Add to Queue" otherwise. Recomputed from live membership each time the
    /// selection changes (the `selectedFilmIDs` FocusedValue this body already depends
    /// on), matching SelectionMenuModel.anyFilmInQueue, shared with the other two hosts.
    private var addToQueueMenuTitle: String {
        guard let filmIDs = selectedFilmIDs, !filmIDs.isEmpty,
              SelectionMenuModel.anyFilmInQueue(filmIDs: filmIDs, coordinator: dataCoordinator)
        else { return "Add to Queue" }
        return "Manage Queue Membership"
    }
    
    /// True when the single selected film has at least one Notes tab field with saved content.
    /// Drives the enabled state of the Notes menu item and its Opt+3 keyboard shortcut.
    @MainActor
    var notesTabEnabled: Bool {
        guard selectionCount == 1, let id = selectedFilmID,
              let film = dataCoordinator.getFilm(id) else { return false }
        return film.hasNotesContent
    }
    
    // True when any sheet is active OR when an AlertHostView alert (database-error ones
    // included) is being presented. Either condition requires menu items to be locked to
    // prevent background interference.
    @MainActor
    var isSheetActive: Bool {
        appState.sheetCoordinator.activeSheet != nil || appState.isDatabaseErrorAlertActive
            || appState.isHostAlertActive
    }

    var body: some Commands {
        Group {
            // MARK: - "Application Name" Menu: Customize
            // "About <application>" menu item.
            CommandGroup(replacing: .appInfo) {
                Button("About Film Tracker") {
                    NSApplication.shared.orderFrontStandardAboutPanel(nil) }
                .keyboardShortcut("?", modifiers: .command) }
            // "Settings" menu item.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    AppEventBus.shared.sendCommand(.openSettingsToTab(tab: .general)) }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(isSheetActive) }
            // "Hide <application>"/"Hide Others"/"Show All" menu items.
            CommandGroup(replacing: .appVisibility) {
                Button("Hide Film Tracker") {
                    NSApplication.shared.hide(nil) }
                .keyboardShortcut("h", modifiers: .command)
                Button("Hide Others") {
                    NSApplication.shared.hideOtherApplications(nil) }
                .keyboardShortcut("h", modifiers: [.command, .option])
                Button("Show All") {
                    NSApplication.shared.unhideAllApplications(nil) } }
            // "Quit <application>" menu item.
            // In the normal flow, this calls NSApp.terminate(nil) directly. When the
            // sheet is locked to the Restore tab (database-error recovery), AppKit
            // silently blocks direct termination while a sheet is attached to the main
            // window. Instead, we set a pending-termination flag on AppState and dismiss
            // the sheet; SettingsSheet.onDisappear then calls NSApp.terminate(nil) once
            // the sheet is fully gone from the view hierarchy.
            //
            // Safety: while a restore operation is actively in progress,
            // SettingsCoordinator.isSheetDismissBlocked prevents the sheet from being
            // dismissed (Close, Escape, and the Cmd+Q key monitor intercept all check
            // isBlockingOperationInProgress). dismissSheet() here will be a no-op in
            // that window because the sheet binding is not cleared while blocked — so
            // onDisappear never fires and the pending flag is never acted upon.
            CommandGroup(replacing: .appTermination) {
                Button("Quit Film Tracker") {
                    if appState.isLockedToRestoreTab {
                        // Dismiss-then-terminate: set the flag first so onDisappear
                        // knows to terminate when the sheet has fully left the hierarchy.
                        appState.pendingTerminationAfterSheetDismiss = true
                        appState.sheetCoordinator.dismissSheet()
                    } else {
                        NSApplication.shared.terminate(nil)
                    }
                }
                .keyboardShortcut("q", modifiers: .command) }
            
            // MARK: - "File" Menu: Customize
            CommandGroup(replacing: .newItem) {
                Button("Add Film…") {
                    AppEventBus.shared.sendCommand(.addFilm) }
                .keyboardShortcut("a", modifiers: .option)
                .disabled(isSheetActive)

                Button("Import Metadata…") {
                    // Navigate to the Imports view and select the "Metadata" tab.
                    // Does NOT present the "Select Files" picker — arriving at the
                    // view never opens a dialog by itself; see
                    // MainView.navigateToImports(_:).
                    AppEventBus.shared.sendCommand(.navigateToImportsMetadata) }
                .keyboardShortcut("i", modifiers: [.shift, .command])
                // Deliberately NOT disabled during an import. This item only
                // navigates now, and being unable to reach the Imports view while
                // an import is running is precisely backwards — that is when the
                // user most wants to look at it. The lock belongs on the one
                // control that actually starts an import: the Imports title bar's
                // "Select Files" button.
                .disabled(isSheetActive
                    || (importsState.isViewingImports && importsState.selectedCategory == .metadata))

                Button("Import Ratings…") {
                    // Navigate to the Imports view and select the "Ratings" tab.
                    // Does NOT present the "Select HTML File" picker — see
                    // MainView.navigateToImports(_:).
                    AppEventBus.shared.sendCommand(.navigateToImportsRatings) }
                .keyboardShortcut("i", modifiers: [.option, .command])
                // See the note on the Metadata item above — navigation only, so no
                // import-in-progress lock.
                .disabled(isSheetActive
                    || (importsState.isViewingImports && importsState.selectedCategory == .ratings))

                Divider()

                Button("Create New List…") {
                    AppEventBus.shared.sendCommand(.showListCreation) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(isSheetActive)

                if case .list(let activeListID) = appState.selectedSidebarItem {
                    Button("Duplicate List") {
                        AppEventBus.shared.send(.ui(.duplicateList(activeListID))) }
                    .keyboardShortcut("n", modifiers: [.option, .command])
                    .disabled(isSheetActive)
                }
                Button("Create New Saved Search…") { SavedSearchActions.newSearch() }
                    .keyboardShortcut("s", modifiers: [.shift, .command])
                    .disabled(isSheetActive)

                Divider()

                Button("Scan Library for Duplicates…") {
                    AppEventBus.shared.sendCommand(.findDuplicates) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(filmCount == 0 || isSheetActive)

                Divider()

                Button("Export Database…") {
                    AppEventBus.shared.sendCommand(.openSettingsToTab(tab: .export)) }
                .keyboardShortcut("e", modifiers: [.shift, .command])
                .disabled(isSheetActive)

                Button("Restore Database…") {
                    AppEventBus.shared.sendCommand(.openSettingsToTab(tab: .restore)) }
                .keyboardShortcut("r", modifiers: [.shift, .command])
                .disabled(isSheetActive)

                Divider()

                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(isSheetActive) }
            CommandGroup(replacing: .saveItem) { EmptyView() }
            CommandGroup(replacing: .printItem) { EmptyView() }
            
            // MARK: - "Edit" Menu: Customize
            CommandGroup(replacing: .pasteboard) {
                Button("Undo") {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                .keyboardShortcut("z", modifiers: .command)
                
                Button("Redo") {
                    NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                
                Divider()
                
                Button("Cut") {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                .keyboardShortcut("x", modifiers: .command)
                // Enable when sheet is active (let responder chain handle) OR text field focused
                .disabled(!canUseTextEditing())
                
                Button("Copy") {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                .keyboardShortcut("c", modifiers: .command)
                // Enable when sheet is active (let responder chain handle) OR text field focused
                .disabled(!canUseTextEditing())
                
                Button("Paste") {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                .keyboardShortcut("v", modifiers: .command)
                // Enable when sheet is active (let responder chain handle) OR text field focused
                .disabled(!canUseTextEditing())
                
                Divider()
                
                // Scope-aware "Select All".
                Button("Select All") {
                    handleSelectAll() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!canUseSelectAll()) } }

        Group {
            // MARK: - "Film" Menu: Create
            CommandMenu("Film") {
                // Grouped so the "Film" menu stays comfortably inside ViewBuilder's
                // ten-child limit as items are added.
                Group {
                    // Sits above "Add to List", offering the three internal Film Queue
                    // sections. Available for any selection size and in every view,
                    // including the Film Queue itself, where it acts as a section move.
                    // With no selection (or behind a sheet) each of the three is a
                    // disabled plain item rather than a disabled Menu: Commands does not
                    // carry `.disabled` onto a Menu's own item, so the submenu still opened
                    // (see SortByMenu). Mirrors GalleryTitleBar's SelectionMenuButton, which
                    // is disabled outright in the same state.
                    if selectionCount == 0 || isSheetActive {
                        Button(addToQueueMenuTitle) {}.disabled(true)
                        Button("Add to List") {}.disabled(true)
                        Button("Show in List") {}.disabled(true)
                    } else {
                        Menu(addToQueueMenuTitle) {
                            if let filmIDs = selectedFilmIDs {
                                AddToQueueMenuContent(filmIDs: filmIDs,
                                                      dataCoordinator: dataCoordinator)
                            }
                        }

                        Menu("Add to List") {
                            if let filmIDs = selectedFilmIDs {
                                AddToListMenuContent(filmIDs: filmIDs,
                                                     dataCoordinator: dataCoordinator)
                            }
                        }

                        Menu("Show in List") {
                            if selectionCount == 1, let filmID = selectedFilmID {
                                ShowInListMenuContent(filmID: filmID, appState: appState,
                                                      dataCoordinator: dataCoordinator)
                            } else {
                                Text("Multiple Films Selected")
                                    .disabled(true)
                            }
                        }
                    }
                
                }

                Divider()
                
                Button("Edit Metadata…") {
                    AppEventBus.shared.sendCommand(.editFilm) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(selectionCount != 1 || isSheetActive)
                
                Button("Edit Releases…") {
                    AppEventBus.shared.sendCommand(.editFilmReleases()) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(selectionCount != 1 || isSheetActive)
                
                Divider()
                
                // "Remove from List" menu item.
                // The button is always present in the hierarchy so SwiftUI keeps the
                // Opt+Delete keyboard shortcut permanently registered. Conditional omission
                // (the previous approach via RemoveFromCurrentListButton) caused the shortcut
                // to be unregistered whenever the button was absent — i.e., any time the user
                // was not viewing a list — making it non-functional upon returning to a list.
                // Visibility is communicated via .disabled(), exactly like the sibling buttons.
                //
                // In a user-generated list context, removes the film from that list.
                // In the Hall of Fame tab context, removes the film from the Hall of Fame.
                Button("Remove from List") {
                    if forwardedToTextEditor(#selector(NSResponder.deleteWordBackward(_:))) { return }
                    guard let filmIDs = selectedFilmIDs else { return }
                    FilmRemoval.removeFromCurrentList(filmIDs: filmIDs, appState: appState,
                                                      coordinator: dataCoordinator,
                                                      clearingSelection: false)
                }
                .keyboardShortcut(.delete, modifiers: .option)
                .disabled(!canRemoveFromCurrentList)
                
                Button("Remove from All Lists") {
                    if forwardedToTextEditor(#selector(NSResponder.deleteWordBackward(_:))) { return }
                    guard let filmIDs = selectedFilmIDs else { return }
                    FilmRemoval.removeFromAllLists(filmIDs: filmIDs,
                                                   coordinator: dataCoordinator,
                                                   clearingSelection: false)
                }
                .keyboardShortcut(.delete, modifiers: [.shift, .option])
                .disabled(selectionCount == 0 || isSheetActive)
                
                Button("Delete from Library") {
                    if forwardedToTextEditor(#selector(NSResponder.deleteToBeginningOfLine(_:))) { return }
                    guard let filmIDs = selectedFilmIDs else { return }
                    FilmRemoval.deleteFromLibrary(filmIDs: filmIDs,
                                                  coordinator: dataCoordinator,
                                                  clearingSelection: false)
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selectionCount == 0 || isSheetActive)
            }
            
            // MARK: - "Search" Menu: Create
            // Declared after "Film", so it follows it in the menu bar.
            CommandMenu("Search") {
                Button("Search Film Library") {
                    if let toolbar = NSApp.keyWindow?.toolbar,
                       let search = toolbar.items.first(where: { $0.itemIdentifier.rawValue == "com.apple.SwiftUI.search" }) as? NSSearchToolbarItem {
                        search.beginSearchInteraction()
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(isSheetActive)
                SaveSearchMenuItem(isSheetActive: isSheetActive)
                // Only in a saved search's view, as Duplicate List is only in a list's (the
                // two share ⌥⌘N, so they must never be offered together).
                if case .savedSearch(let id) = appState.selectedSidebarItem {
                    Divider()
                    Button("Edit Saved Search…") { SavedSearchActions.edit(id) }
                        .disabled(isSheetActive)
                    Button("Duplicate Saved Search…") { SavedSearchActions.duplicate(id) }
                        .keyboardShortcut("n", modifiers: [.option, .command])
                        .disabled(isSheetActive)
                    Button("Open in Search Field") { SavedSearchActions.openInSearchField(id) }
                        .disabled(isSheetActive)
                    Divider()
                    Button("Remove Saved Search") { SavedSearchActions.delete(id) }
                        .disabled(isSheetActive)
                }
            }

            // MARK: - View Menu: Customize
            CommandGroup(replacing: .sidebar) {
                Button("Scroll to Selection") {
                    AppEventBus.shared.sendCommand(.scrollToSelection) }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(selectionCount == 0 || isSheetActive)
                Divider()
                ViewAsListMenu(filmCount: filmCount, isSheetActive: isSheetActive, selectedSidebarItem: appState.selectedSidebarItem)
                SortByMenu(filmCount: filmCount, isSheetActive: isSheetActive,
                           selectedSidebarItem: appState.selectedSidebarItem,
                           coordinator: dataCoordinator)
                FilterItemsMenu(filmCount: filmCount, isSheetActive: isSheetActive, selectedSidebarItem: appState.selectedSidebarItem,
                                dataCoordinator: dataCoordinator)
                Divider()
                LeftSidebarMenu(appState: appState, isSheetActive: isSheetActive)
                RightSidebarMenu(isSheetActive: isSheetActive, selectionCount: selectionCount,
                                 notesTabEnabled: notesTabEnabled)
                ListsMenu(appState: appState, dataCoordinator: dataCoordinator, isSheetActive: isSheetActive)
                Divider() }
            
            // MARK: - "Window" Menu: the standard one, completed by hand
            // AppKit supplies the Window menu, its tiling items (Fill, Center, Move & Resize)
            // and the window list. Minimize, Zoom and Bring All to Front are SwiftUI's own
            // items, and `.commandsRemoved()` drops them with everything else, so they are
            // put back here: Minimize and Zoom at the top, Bring All to Front at the end.
            // Neither group replaces `.windowArrangement`: replacing the slot makes SwiftUI
            // strip AppKit's items again a few frames later, and the menu visibly snaps.
            // A `CommandMenu("Window")` would be a second, hand-built menu of the same name.
            CommandGroup(before: .windowArrangement) {
                Button("Minimize") { NSApp.keyWindow?.performMiniaturize(nil) }
                    .keyboardShortcut("m", modifiers: .command)
                Button("Zoom") { NSApp.keyWindow?.performZoom(nil) } }
            CommandGroup(after: .windowArrangement) {
                Divider()
                Button("Bring All to Front") { NSApp.arrangeInFront(nil) } }
        }
    }
    
    // MARK: - Scope-Aware Helper Methods
    
    /// Checks if a text field is currently focused.
    /// This works across both main window and sheet contexts.
    private func isTextFieldFocused() -> Bool {
        // Check both the key window AND any active sheets
        var windowsToCheck: [NSWindow] = []
        
        // Add key window if available
        if let keyWindow = NSApp.keyWindow {
            windowsToCheck.append(keyWindow)
        }
        
        // Add any sheet windows attached to the main window
        if let mainWindow = NSApp.mainWindow {
            if let sheet = mainWindow.attachedSheet {
                windowsToCheck.append(sheet)
            }
        }
        
        // Check all candidate windows for focused text fields
        for window in windowsToCheck {
            if isTextFieldFocusedInWindow(window) {
                return true
            }
        }
        
        return false
    }
    
    /// Delegates to `TextInputFocus` (InputUtilities.swift) — the single definition
    /// shared with KeyboardManager's shortcut gating and SettingsSheet's Return-key
    /// monitor. The two private helpers that used to live here (a type check plus a
    /// `isTextRelatedClassName` keyword list) were a byte-for-byte second copy of
    /// KeyboardManager's, kept in agreement by hand.
    private func isTextFieldFocusedInWindow(_ window: NSWindow) -> Bool {
        TextInputFocus.isActive(in: window)
    }
    
    /// Verify if Select All should be enabled (for menu item state only)
    @MainActor
    private func canUseSelectAll() -> Bool {
        // Sheet active: always enable and let the responder chain handle it.
        if isSheetActive { return true }
        // Text field focused in main window: allow native text selection.
        if isTextFieldFocused() { return true }
        // Gallery-style view with at least one film: allow multi-select.
        return appState.selectedSidebarItem.capabilities.supportsMultiSelection && dataCoordinator.totalFilmCount > 0
    }
    
    /// Verify if text editing operations (Cut/Copy/Paste) should be enabled
    /// Uses the same sheet-aware logic as Select All - when sheets are active,
    /// always enable and let the responder chain handle availability.
    @MainActor
    private func canUseTextEditing() -> Bool {
        // If a sheet is active, always enable and let responder chain handle it
        // This ensures Cut/Copy/Paste work reliably in sheet and popover text fields
        if isSheetActive {
            return true
        }
        
        // No sheet active - only enable if we detect a focused text field
        return isTextFieldFocused()
    }
    
    /// Handle Select All menu item click (keyboard shortcut handled in KeyboardManager)
    @MainActor
    private func handleSelectAll() {
        // When a sheet is active, always route through the responder chain so the
        // sheet's own text fields handle Cmd+A correctly.
        if isSheetActive {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            return
        }
        if isTextFieldFocused() {
            // Text field focused in the main window — use native text selection.
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        } else if appState.selectedSidebarItem.capabilities.supportsMultiSelection {
            // Gallery view — select all films.
            AppEventBus.shared.selectAllFilms()
        }
    }

    /// Hands a removal shortcut back to the text being edited, when there is some.
    ///
    /// The three removal items are bound to Cmd+Delete, Opt+Delete and Shift+Opt+Delete —
    /// line and word deletion in any text field. Menu key equivalents are matched before
    /// the field editor sees the key, and the selection is a scene-wide focused value, so
    /// the items stay enabled while the search field is being edited: Cmd+Delete there
    /// deleted the selected films from the library (immediately, with confirmation off).
    /// KeyboardManager passes these keys through for text input expecting the field to
    /// receive them; this is where they actually arrive.
    ///
    /// Only for a keystroke: a click on the menu item is a deliberate choice of the film
    /// action, whatever holds focus. The field-editor test is the precise one
    /// KeyboardManager's Releases-tab Cmd+Delete path uses — a field editor is first
    /// responder only while text is actually being edited, so it cannot latch.
    @MainActor
    private func forwardedToTextEditor(_ action: Selector) -> Bool {
        guard NSApp.currentEvent?.type == .keyDown,
              NSApp.keyWindow?.firstResponder is NSText else { return false }
        NSApp.sendAction(action, to: nil, from: nil)
        return true
    }

    // MARK: - Menu Action Handlers
    //
    // The three removal commands above are one-line hand-offs to FilmRemoval
    // (LibraryManager.swift), which owns the context resolution (user list / Film Queue /
    // Hall of Fame), the membership pre-filter, the confirmation-preference gating, and
    // the alert payloads for every surface that offers these commands — this menu, the
    // GalleryTitleBar trash menu, the gallery contextual menu, and KeyboardManager's
    // Opt+Delete. The five hand-written handlers that used to live here were a fourth
    // copy of that logic.
    //
    // `clearingSelection: false` preserves this menu's long-standing behavior: unlike the
    // two gallery surfaces, the MenuBar and keyboard paths leave the selection standing
    // after an unconfirmed removal.

    /// True when "Remove from List" should be enabled — at least one selected film is
    /// actually resident in whatever list context is currently on screen. Shares its
    /// implementation with the command itself, so the item can never be enabled for a
    /// selection the command would decline to act on, or vice versa.
    @MainActor
    private var canRemoveFromCurrentList: Bool {
        guard !isSheetActive, let filmIDs = selectedFilmIDs else { return false }
        return FilmRemoval.canRemoveFromCurrentList(filmIDs: filmIDs, appState: appState,
                                                    coordinator: dataCoordinator)
    }
}

// MARK: - Save Search Menu Item
/// "Search ▸ Save Search…". A view of its own because its enabled state reads the search
/// field's text, which changes on every keystroke: read in MenuBar's body, that made each
/// keystroke re-evaluate the whole menu bar. Here a keystroke re-evaluates only this item.
///
/// Follows the title bar's SaveSearchButton for a saved search opened in the field: off
/// until the field changes, then joined by "Update Saved Search…".
struct SaveSearchMenuItem: View {
    let isSheetActive: Bool

    var body: some View {
        let canSave = !isSheetActive && SearchController.shared.isActive
            && !SearchController.shared.currentQuery.isEmpty
        let origin = SavedSearchActions.fieldOrigin
        let originChanged = origin.map(SavedSearchActions.fieldDiffers(from:)) ?? false
        Button("Save Search…") { SavedSearchActions.saveCurrentSearch() }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!canSave || (origin != nil && !originChanged))
        if let origin, originChanged {
            Button("Update Saved Search…") { SavedSearchActions.updateFromField(origin.id) }
                .disabled(!canSave)
        }
    }
}

// MARK: - View As List Menu
/// Toggling menu item that switches the active gallery view between the
/// NSCollectionView grid (default) and the SwiftUI List-based view. The item's
/// title always describes the action that will occur — "View as List" while
/// in grid view, "View as Grid" while in list view — rather than showing a
/// checkmark. Mirrors the SortByMenu / FilterItemsMenu pattern for state sync
/// and disabled-state handling.
struct ViewAsListMenu: View {
    let filmCount: Int
    let isSheetActive: Bool
    let selectedSidebarItem: SidebarItem

    @State private var isListView: Bool = false

    /// The menu is disabled when there are no films, a sheet is active, or
    /// the active view is one that doesn't use a gallery (Reports, Imports).
    @MainActor
    private var isMenuDisabled: Bool {
        filmCount == 0 || isSheetActive || !selectedSidebarItem.capabilities.supportsListGridToggle
    }

    var body: some View {
        Button(isListView ? "View as Grid" : "View as List") {
            // Derive the target style by negating the LIVE value rather than the local
            // `isListView` mirror. The mirror drives the item's title and is refreshed
            // on view-state changes, on menu tracking, and on appear — but a keyboard
            // shortcut invokes this action without opening the menu, so it must never be
            // the input to the toggle itself. If the mirror were ever stale, negating it
            // could name the style already in effect, updateListViewStyle's equality
            // guard would discard the request, and Cmd+K would appear to do nothing while
            // still flashing the menu (exactly the failure this guards against).
            //
            // Reading through ViewStateManager also makes this a true toggle of whatever
            // is actually on screen, and the mirror is realigned immediately so the title
            // is correct on the very next frame even if the broadcast were missed.
            let target = !ViewStateManager.shared.activeState.isListView
            ViewStateManager.shared.updateListViewStyle(target)
            syncFromViewStateManager()
        }
        .keyboardShortcut("k", modifiers: .command)
        .disabled(isMenuDisabled)
        .onAppear { syncFromViewStateManager() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            syncFromViewStateManager()
        }
        .onViewStateChanged { syncFromViewStateManager() }
    }

    @MainActor
    private func syncFromViewStateManager() {
        isListView = ViewStateManager.shared.activeState.isListView
    }
}

// MARK: - Sort By Menu
// Sort menu that reads from and writes to ViewStateManager. Embeds the shared
// SortMenuContent (see SortFilterMenu.swift) so the actual menu items are defined
// in exactly one place and can never diverge from GallerySortMenu's version — the
// "Jump to Section" submenu included, which is why this host supplies the same
// jumpTargets/onJumpToSection pair GallerySortMenu does rather than reimplementing
// the submenu locally.
struct SortByMenu: View {
    let filmCount: Int
    let isSheetActive: Bool
    let selectedSidebarItem: SidebarItem
    /// Source for the menu's inputs, exactly as GallerySortMenu takes one. Both hosts
    /// build the same SortMenuInputs, so neither menu can offer a band the gallery is not
    /// drawing or disable an option the other leaves live.
    let coordinator: DataCoordinator

    /// Mirror of everything this menu displays, refreshed at the points below.
    ///
    /// One mirror rather than the five it replaced (sort, direction, section dividers,
    /// the dividers lock, and the jump targets). NSMenu-backed Commands items don't
    /// participate in SwiftUI's observation system, so the values have to be pushed in —
    /// but pushing them one at a time made the resync ORDER load-bearing, since the jump
    /// targets are derived from the dividers setting and reading the stale mirror left the
    /// submenu describing the previous view for a pass. Resolving all of them in a single
    /// SortMenuInputs.current call makes that ordering structural.
    ///
    /// The refresh points include NSMenu.didBeginTrackingNotification, so everything is
    /// re-read as the menu bar opens and cannot be stale by the time it is drawn.
    @State private var inputs = SortMenuInputs()

    /// The jump targets this menu will actually offer.
    ///
    /// Suppressed entirely while a sheet is up — the one input that is this host's own
    /// rather than the shared derivation's. The menu bar stays reachable behind a modal
    /// sheet, and scrolling the gallery underneath one is not navigation the user can see
    /// the result of.
    @MainActor
    private var jumpTargets: [GallerySectionJumpTarget] {
        isSheetActive ? [] : inputs.jumpTargets
    }

    /// Computed property that determines if the menu is disabled
    @MainActor
    private var isMenuDisabled: Bool {
        isSheetActive || SortMenuInputs.optionsLocked(coordinator: coordinator)
    }

    /// True for views with no gallery at all (Reports, Imports): nothing in the menu applies,
    /// so `body` shows a disabled item in place of the submenu.
    @MainActor
    private var isMenuNotApplicable: Bool {
        let capabilities = selectedSidebarItem.capabilities
        return capabilities.sortMenuFullyDisabled && !capabilities.supportsSectionDividers
    }

    var body: some View {
        Group {
            if isMenuNotApplicable {
                // A disabled plain item, not a disabled Menu. In menu-bar Commands SwiftUI does
                // not carry `.disabled` onto a Menu's own NSMenuItem — only into its children —
                // so a sealed "Sort By" still opened, onto a submenu of locked items with the
                // left-behind gallery view's sort and direction checked. These views are ordered
                // manually, which no option here describes. A Button does honor `.disabled`,
                // so the item is grayed and never opens.
                Button("Sort By") {}
                    .disabled(true)
            } else {
                sortMenu
            }
        }
        .onAppear { syncFromViewStateManager() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            syncFromViewStateManager() }
        // Section dividers need no dedicated .onChange: the value lives in ViewState, so
        // every change to it goes through commitActiveStateChange and arrives here on the
        // same viewStateChanged event the sort mirrors ride, which re-derives the jump
        // targets rather than merely re-rendering the existing ones.
        .onViewStateChanged { syncFromViewStateManager() }
    }

    private var sortMenu: some View {
        Menu("Sort By") {
            SortMenuContent(
                isDisabled: isMenuDisabled,
                disabledSortOptions: inputs.disabledSortOptions,
                currentSortOption: inputs.sortOption,
                currentSortDirection: inputs.sortDirection,
                onSelectSortOption: { option in
                    // Realign the mirror immediately so the checkmark is correct without
                    // waiting for the event-driven resync.
                    inputs.sortOption = option
                    ViewStateManager.shared.updateSortOption(option)
                },
                onSelectSortDirection: { direction in
                    inputs.sortDirection = direction
                    ViewStateManager.shared.updateSortDirection(direction)
                },
                currentShowSectionDividers: inputs.showSectionDividers,
                onSelectShowSectionDividers: { showDividers in
                    // Realigned immediately, exactly as the sort and direction setters
                    // above are — and so the jump targets recomputed by the resync that
                    // follows are derived from the value the user just chose.
                    inputs.showSectionDividers = showDividers
                    ViewStateManager.shared.updateShowSectionDividers(showDividers)
                },
                sectionDividersLocked: inputs.sectionDividersLocked,
                jumpTargets: jumpTargets,
                onJumpToSection: { ViewStateManager.shared.jumpToSectionBand($0) }
            )
        }
        // Never sealed as a whole, matching GallerySortMenu. Every view that reaches this
        // Menu is gallery-backed (Reports and Imports get `isMenuNotApplicable`'s item), so
        // its "Section Dividers" pair is always live, even where `isMenuDisabled` locks the
        // sort options: every Recents tab and "Upcoming Releases". A previous seal of
        // `isMenuDisabled && jumpTargets.isEmpty` grayed out the whole menu, dividers pair
        // included, on exactly those views whenever their dividers were off.
    }

    @MainActor
    private func syncFromViewStateManager() {
        inputs = SortMenuInputs.current(coordinator: coordinator)
    }
}

// MARK: - Filter Items Menu
// Filter menu that reads from and writes to ViewStateManager. Embeds the shared
// FilterMenuContent (see SortFilterMenu.swift) so the actual menu items are defined
// in exactly one place and can never diverge from GalleryFilterMenu's version.
struct FilterItemsMenu: View {
    let filmCount: Int
    let isSheetActive: Bool
    let selectedSidebarItem: SidebarItem
    /// Source for the shared `FilterMenuInputs.menuDisabled` rule.
    let dataCoordinator: DataCoordinator

    /// Mirror of the active filters and the blocks disabled for this view, resolved
    /// together through the shared FilterMenuInputs so this always agrees with
    /// GalleryFilterMenu for the same view. Blocks are disabled, not hidden, so the full
    /// menu stays visually consistent across every view.
    @State private var inputs = FilterMenuInputs()

    /// Computed property that determines if the menu is disabled
    @MainActor
    private var isMenuDisabled: Bool {
        isSheetActive || FilterMenuInputs.menuDisabled(coordinator: dataCoordinator)
    }

    /// True for views with no gallery at all (Reports, Imports), the same test SortByMenu's
    /// `isMenuNotApplicable` makes: `body` shows a disabled item in place of the submenu.
    @MainActor
    private var isMenuNotApplicable: Bool {
        let capabilities = selectedSidebarItem.capabilities
        return capabilities.filterMenuFullyDisabled && !capabilities.supportsSectionDividers
    }

    var body: some View {
        Group {
            if isMenuNotApplicable || isMenuDisabled {
                // A disabled plain item, for the reason SortByMenu gives: Commands does not
                // carry `.disabled` onto a Menu's own item, so the submenu still opened.
                // Also wherever GalleryTitleBar disables its Filter button outright (an
                // empty view with no filters to clear, initial loading), and behind a sheet.
                Button("Filter") {}
                    .disabled(true)
            } else {
                filterMenu
            }
        }
        .onAppear { syncFromViewStateManager() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            syncFromViewStateManager() }
        .onViewStateChanged { syncFromViewStateManager() }
    }

    private var filterMenu: some View {
        Menu("Filter") {
            FilterMenuContent(
                currentFilters: inputs.filters,
                isDisabled: isMenuDisabled,
                disabledBlocks: inputs.disabledBlocks,
                onClearFilters: {
                    inputs.filters = []
                    ViewStateManager.shared.clearFilters()
                },
                onToggleFilter: { option, isOn in
                    let updated = FilterToggleLogic.applying(option, isOn: isOn,
                                                             to: inputs.filters)
                    inputs.filters = updated
                    ViewStateManager.shared.updateFilterOptions(updated)
                }
            )
        }
    }

    @MainActor
    private func syncFromViewStateManager() {
        inputs = FilterMenuInputs.current()
    }
}

// MARK: - Top-Level Sidebar Shortcuts

/// The ten Cmd+<digit> shortcuts that jump directly to a top-level Library section or
/// smart list. The single source of truth for what each digit does — used by both
/// LeftSidebarMenu's Toggle rows (the visible menu, via SwiftUI Commands) and
/// KeyboardManager's raw NSEvent fallback handler, so the two paths can never
/// silently drift apart on what a given digit navigates to. Before this existed, the
/// same ten-case mapping was hand-written independently in both files; adding
/// Unwatched at Cmd+2 required editing both switches identically by hand, with
/// nothing enforcing that they matched.
enum TopLevelSidebarShortcut: Int, CaseIterable, Sendable {
    case allFilms = 1
    case unwatched = 2
    case recents = 3
    case reports = 4
    case filmQueue = 5
    case upForRotation = 6
    case purchased = 7
    case unpurchased = 8
    // Cmd+9 belonged to Alternate Versions until Upcoming Releases took it; Alternate
    // Versions keeps its menu item, without a shortcut.
    case upcomingReleases = 9
    case filteredLibrary = 0

    /// The digit key this shortcut is bound to under Cmd (e.g. "2" for Unwatched).
    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(Character(String(rawValue)))
    }

    /// The top-level shortcut a given smart list type maps to, or nil for a smart
    /// list without one of its own (its own sub-variants, or the Purchased/
    /// Unpurchased 4K/Blu-ray/DVD format variants — all reachable only via their
    /// gallery Picker or the Opt+Cmd+# in-view tab switching KeyboardManager handles
    /// separately).
    init?(smartListType: SmartListType) {
        guard let match = Self.allCases.first(where: { $0.smartListType == smartListType }) else {
            return nil
        }
        self = match
    }

    /// The smart list this shortcut navigates to, or nil for the five Library sections.
    /// The one direction the mapping is written in; `init?(smartListType:)` above inverts
    /// it, and `activate` reads it, so the two can no longer disagree about which digit
    /// belongs to which list.
    var smartListType: SmartListType? {
        switch self {
        case .upForRotation:     return .upForRotation
        case .purchased:         return .purchased
        case .unpurchased:       return .unpurchased
        case .upcomingReleases:  return .upcomingReleases
        case .filteredLibrary:   return .filteredLibrary
        case .allFilms, .unwatched, .recents, .reports, .filmQueue: return nil
        }
    }

    /// Performs the navigation this shortcut represents. Deliberately does not check
    /// Preferences.smartLists for the six smart-list cases — this matches the
    /// existing behavior of the fallback path this replaces, which has never gated
    /// on that preference either.
    @MainActor
    func activate(appState: AppState) {
        switch self {
        case .allFilms:
            appState.navigate(to: .libraryItem(.allFilms))

        case .unwatched:
            appState.navigate(to: .libraryItem(.unwatched))
            UnwatchedState.shared.selectCategory(.unwatched)

        // Recents and Reports are the two sub-tabbed views whose last-selected tab can be
        // remembered across sessions (Preferences.rememberTabSelection / tabRememberScope).
        // Navigating INTO them is not a tab choice, so it must neither force the first tab
        // over a remembered one nor persist anything: forcing .recentlyViewed here wrote
        // that value straight back over the remembered category on every Cmd+3 / Go-menu
        // navigation, which is what made the restore look intermittent — it survived only
        // when the view was entered by clicking the sidebar row, which routes through
        // GalleryView.handleSidebarChange → ensureInitialViewLoad instead. When the
        // preference is off, the historical reset-to-first-tab behavior is preserved.
        case .recents:
            appState.navigate(to: .libraryItem(.recents))
            RecentsState.shared.selectCategory(
                Preferences.rememberRecentsTab ? RecentsState.shared.selectedCategory
                                               : .recentlyViewed,
                persist: false)

        case .reports:
            appState.navigate(to: .libraryItem(.reports))
            ReportsState.shared.selectCategory(
                Preferences.rememberReportsTab ? ReportsState.shared.selectedCategory
                                               : .costTracker,
                persist: false)

        case .filmQueue:
            appState.navigate(to: .libraryItem(.filmQueue))
            FilmQueueFilterState.shared.selectFilter(.all)

        // All five smart lists take the identical three steps and differ only in the type,
        // which `smartListType` already holds — so they share one arm rather than five
        // copies of the same body.
        case .upForRotation, .purchased, .unpurchased, .upcomingReleases, .filteredLibrary:
            guard let type = smartListType else { return }
            ViewStateManager.shared.switchToViewSync(.smartList(type))
            appState.navigate(to: .smartList(type))
            SmartListVariantState.syncAll(to: type)
        }
    }
}

// MARK: - Left Sidebar Menu
struct LeftSidebarMenu: View {
    var appState: AppState
    let isSheetActive: Bool

    // Monitor Preferences.smartLists to show/hide smart list entries
    @AppStorage(preference: Preferences.smartListsKey) private var smartListsEnabled: Bool

    var body: some View {
        Menu("Left Sidebar") {
            // All Films
            Toggle("All Films", isOn: Binding(
                get: { isItemActive(.allFilms) },
                set: { if $0 { TopLevelSidebarShortcut.allFilms.activate(appState: appState) } }))
            .keyboardShortcut(TopLevelSidebarShortcut.allFilms.keyEquivalent, modifiers: .command)
            .disabled(isSheetActive)
            
            Divider()
            
            // Unwatched Tabs
            // Cmd+2 navigates to the Unwatched view (Unwatched tab).
            // Opt+Cmd+1–2 switch tabs within Unwatched, but only when already there.
            Toggle("Unwatched", isOn: Binding(
                get: { isItemActive(.unwatched(.unwatched)) },
                set: { if $0 { TopLevelSidebarShortcut.unwatched.activate(appState: appState) } }))
            .keyboardShortcut(TopLevelSidebarShortcut.unwatched.keyEquivalent, modifiers: .command)
            .disabled(isSheetActive)
            
            Toggle("Not Rated", isOn: Binding(
                get: { isItemActive(.unwatched(.notRated)) },
                set: { if $0 { selectUnwatched(.notRated) } }))
            .disabled(isSheetActive)
            
            Divider()
            
            // Recents Categories
            // Cmd+3 navigates to the Recents view (Most Recently Viewed tab).
            // Opt+Cmd+1–5 switch tabs within Recents, but only when already in Recents.
            Toggle("Most Recently Viewed", isOn: Binding(
                get: { isItemActive(.recents(.recentlyViewed)) },
                set: { if $0 { TopLevelSidebarShortcut.recents.activate(appState: appState) } }))
            .keyboardShortcut(TopLevelSidebarShortcut.recents.keyEquivalent, modifiers: .command)
            .disabled(isSheetActive)
            
            Toggle("Recently Come Up for Rotation", isOn: Binding(
                get: { isItemActive(.recents(.recentlyRotated)) },
                set: { if $0 { selectRecents(.recentlyRotated) } }))
            .disabled(isSheetActive)
            
            Toggle("Recently Added", isOn: Binding(
                get: { isItemActive(.recents(.recentlyAdded)) },
                set: { if $0 { selectRecents(.recentlyAdded) } }))
            .disabled(isSheetActive)
            
            Toggle("Recently Updated", isOn: Binding(
                get: { isItemActive(.recents(.recentlyUpdated)) },
                set: { if $0 { selectRecents(.recentlyUpdated) } }))
            .disabled(isSheetActive)
            
            Toggle("Recently Purchased", isOn: Binding(
                get: { isItemActive(.recents(.recentlyPurchased)) },
                set: { if $0 { selectRecents(.recentlyPurchased) } }))
            .disabled(isSheetActive)
            
            Divider()
            
            // Reports Categories
            // Cmd+4 navigates to Reports (Purchase and Expense Tracker tab).
            // Opt+Cmd+1–5 switch tabs within Reports, but only when already in Reports.
            Toggle("Purchase and Expense Tracker", isOn: Binding(
                get: { isItemActive(.reports(.costTracker)) },
                set: { if $0 { TopLevelSidebarShortcut.reports.activate(appState: appState) } }))
            .keyboardShortcut(TopLevelSidebarShortcut.reports.keyEquivalent, modifiers: .command)
            .disabled(isSheetActive)
            
            Toggle("Price Tracker", isOn: Binding(
                get: { isItemActive(.reports(.priceTracker)) },
                set: { if $0 { selectReports(.priceTracker) } }))
            .disabled(isSheetActive)
            
            Toggle("Hall of Fame", isOn: Binding(
                get: { isItemActive(.reports(.hallOfFame)) },
                set: { if $0 { selectReports(.hallOfFame) } }))
            .disabled(isSheetActive)

            Toggle("Release Wishlist", isOn: Binding(
                get: { isItemActive(.reports(.releaseWishlist)) },
                set: { if $0 { selectReports(.releaseWishlist) } }))
            .disabled(isSheetActive)
            
            Toggle("Visualizations and Insights", isOn: Binding(
                get: { isItemActive(.reports(.dataVisualizations)) },
                set: { if $0 { selectReports(.dataVisualizations) } }))
            .disabled(isSheetActive)
            
            Divider()
            
            // Imports Categories
            // Imports has no top-level Cmd+# shortcut (freed up to make room for the
            // shifts above).
            // Opt+Cmd+1–2 switch tabs within Imports (handled by KeyboardManager):
            //   Opt+Cmd+1 → Metadata, Opt+Cmd+2 → Ratings.
            Toggle("Import Metadata", isOn: Binding(
                get: { isItemActive(.imports(.metadata)) },
                set: { if $0 { selectImports(.metadata) } }))
            .disabled(isSheetActive)

            Toggle("Import Ratings", isOn: Binding(
                get: { isItemActive(.imports(.ratings)) },
                set: { if $0 { selectImports(.ratings) } }))
            .disabled(isSheetActive)

            Divider()

            // Film Queue — the internal, application-owned viewing queue.
            // Cmd+5 navigates here (unchanged); the smart-list shortcuts below still
            // shift down accordingly (Up for Rotation → Cmd+6 … Filtered Library → Cmd+0).
            // "Queue" itself is equivalent to the segmented picker's "All" section;
            // "Up Next"/"Soon"/"Later" map to the same picker's other three sections.
            // Opt+Cmd+1–4 switch tabs within the Film Queue, but only when already there.
            Toggle("Queue", isOn: Binding(
                get: { isItemActive(.filmQueue) },
                set: { if $0 { TopLevelSidebarShortcut.filmQueue.activate(appState: appState) } }))
            .keyboardShortcut(TopLevelSidebarShortcut.filmQueue.keyEquivalent, modifiers: .command)
            .disabled(isSheetActive)
            
            Toggle("Up Next", isOn: Binding(
                get: { isItemActive(.filmQueueSection(.upNext)) },
                set: { if $0 { selectFilmQueueSection(.upNext) } }))
            .disabled(isSheetActive)
            
            Toggle("Soon", isOn: Binding(
                get: { isItemActive(.filmQueueSection(.soon)) },
                set: { if $0 { selectFilmQueueSection(.soon) } }))
            .disabled(isSheetActive)
            
            Toggle("Later", isOn: Binding(
                get: { isItemActive(.filmQueueSection(.later)) },
                set: { if $0 { selectFilmQueueSection(.later) } }))
            .disabled(isSheetActive)
            
            if smartListsEnabled {
                Divider()
                
                // Smart Lists - with keyboard shortcuts for the five top-level lists,
                // plus sub-variant items nested directly beneath their parent (e.g.
                // "Viewed Over One Year Ago" under "Up for Rotation"). Sub-variants
                // never carry a shortcut of their own.
                ForEach(SmartListType.sidebarCases) { type in
                    Group {
                        if let shortcut = TopLevelSidebarShortcut(smartListType: type) {
                            Toggle(type.rawValue, isOn: Binding(
                                get: { isItemActive(.smartList(type)) },
                                set: { if $0 { shortcut.activate(appState: appState) } }))
                            .keyboardShortcut(shortcut.keyEquivalent, modifiers: .command)
                            .disabled(isSheetActive)
                        } else {
                            Toggle(type.rawValue, isOn: Binding(
                                get: { isItemActive(.smartList(type)) },
                                set: { if $0 { selectSmartList(type) } }))
                            .disabled(isSheetActive)
                        }

                        ForEach(subVariants(for: type), id: \.self) { subType in
                            Toggle(subVariantLabel(for: subType), isOn: Binding(
                                get: { isItemActive(.smartList(subType)) },
                                set: { if $0 { selectSmartList(subType) } }))
                            .disabled(isSheetActive)
                        }
                    }
                }
                // Note: Opt+Cmd+1–9 in-view tab switching for every smart list group (one
                // digit per variant, up to Filtered Library's six) is handled entirely by
                // KeyboardManager.
            }
            
            Divider()
            
            Button("Toggle Sidebar") {
                AppEventBus.shared.sendCommand(.toggleLeftSidebar) }
            .keyboardShortcut("s", modifiers: [.option, .command])
            .disabled(isSheetActive) } }
    
    // MARK: - Menu Item Type
    
    /// Represents all possible menu items in the Left Sidebar menu
    private enum MenuItem: Equatable {
        case allFilms
        case unwatched(UnwatchedCategory)
        case recents(RecentsCategory)
        case reports(ReportsCategory)
        case imports(ImportsCategory)
        case filmQueue
        case filmQueueSection(FilmQueueFilter)
        case smartList(SmartListType)
    }
    
    // MARK: - Active Item Check
    
    /// Unified check for whether a specific menu item is currently active
    /// This ensures mutual exclusivity across all menu items
    @MainActor
    private func isItemActive(_ item: MenuItem) -> Bool {
        switch item {
        case .allFilms:
            return appState.selectedSidebarItem == .libraryItem(.allFilms)
            
        case .unwatched(let category):
            // Check if we're in the Unwatched view AND have the specific tab selected
            guard case .libraryItem(.unwatched) = appState.selectedSidebarItem else {
                return false
            }
            if case .unwatched(let activeCategory) = ViewStateManager.shared.activeView {
                return activeCategory == category
            }
            return false
            
        case .recents(let category):
            // Check if we're in Recents view AND have the specific category selected
            guard case .libraryItem(.recents) = appState.selectedSidebarItem else {
                return false
            }
            if case .recents(let activeCategory) = ViewStateManager.shared.activeView {
                return activeCategory == category
            }
            return false
            
        case .reports(let category):
            // Check if we're in Reports view AND have the specific category selected
            guard case .libraryItem(.reports) = appState.selectedSidebarItem else {
                return false
            }
            return ReportsState.shared.selectedCategory == category
            
        case .imports(let category):
            // Check if we're in Imports view and have the specific category selected
            guard case .libraryItem(.imports) = appState.selectedSidebarItem else {
                return false
            }
            return ImportsState.shared.selectedCategory == category
            
        case .filmQueue:
            // "Queue" represents the segmented picker's "All" section specifically, so
            // it stays mutually exclusive with the three named sections below.
            guard appState.selectedSidebarItem == .libraryItem(.filmQueue) else {
                return false
            }
            return FilmQueueFilterState.shared.selectedFilter == .all
            
        case .filmQueueSection(let filter):
            guard appState.selectedSidebarItem == .libraryItem(.filmQueue) else {
                return false
            }
            return FilmQueueFilterState.shared.selectedFilter == filter
            
        case .smartList(let type):
            if case .smartList(let activeType) = ViewStateManager.shared.activeView {
                return activeType == type
            }
            return false
        }
    }
    
    // MARK: - Navigation Helpers
    
    /// Select an Unwatched view tab
    @MainActor
    private func selectUnwatched(_ category: UnwatchedCategory) {
        // Update sidebar selection to the Unwatched view
        appState.navigate(to: .libraryItem(.unwatched))
        // Update UnwatchedState to the selected tab
        UnwatchedState.shared.selectCategory(category)
    }
    
    /// Select a recents category
    @MainActor
    private func selectRecents(_ category: RecentsCategory) {
        // Update sidebar selection to Recents
        appState.navigate(to: .libraryItem(.recents))
        // Update RecentsState to the selected category
        RecentsState.shared.selectCategory(category)
    }
    
    /// Select a reports category
    @MainActor
    private func selectReports(_ category: ReportsCategory) {
        // Update sidebar selection to Reports
        appState.navigate(to: .libraryItem(.reports))
        // Update ReportsState to the selected category
        ReportsState.shared.selectCategory(category)
    }
    
    /// Select an imports category
    @MainActor
    private func selectImports(_ category: ImportsCategory) {
        // Update sidebar selection to Imports
        appState.navigate(to: .libraryItem(.imports))
        // Update ImportsState to the selected category
        ImportsState.shared.selectCategory(category)
    }

    /// Select a specific Film Queue section — equivalent to choosing "Up Next",
    /// "Soon", or "Later" in the segmented picker in GalleryTitleBar.
    @MainActor
    private func selectFilmQueueSection(_ filter: FilmQueueFilter) {
        appState.navigate(to: .libraryItem(.filmQueue))
        FilmQueueFilterState.shared.selectFilter(filter)
    }
    
    /// Select a smart list (updates both ViewStateManager and AppState)
    @MainActor
    private func selectSmartList(_ type: SmartListType) {
        // Resolve the sub-variant pickers FIRST, before either the view switch or the
        // sidebar assignment below. This ordering is load-bearing: the sidebar assignment
        // fires GalleryView.handleSidebarChange, which resyncs these same picker states and
        // re-derives the destination view from the sidebar item — both of which must
        // already see the variant this call is selecting. (Previously these ran last, so
        // that handler observed stale picker state and, for a sub-variant reached from a
        // different sidebar item, briefly re-switched the view to the parent list.)
        //
        // syncAll hands the type to every family and only the one that owns it changes,
        // which is exactly as correct as dispatching on the family flags and has one fewer
        // place to get out of step. Mirrors ShowInListNavigation.navigate.
        SmartListVariantState.syncAll(to: type)

        // Update ViewStateManager (single source of truth)
        ViewStateManager.shared.switchToViewSync(.smartList(type))

        // Update AppState.selectedSidebarItem for sidebar highlighting. Only the five
        // parents have a sidebar row of their own, so a sub-variant pins the highlight to
        // its parent — the mapping lives on SmartListType.sidebarParent (a parent returns
        // itself), replacing the hand-maintained family if-chain this method used to
        // carry. Shared with
        // ShowInListNavigation so the two navigation paths cannot disagree about which row
        // a given smart list belongs to.
        appState.navigate(to: .smartList(type.sidebarParent))
    }

    /// Returns the sub-variant SmartListTypes that should appear nested directly
    /// beneath the given parent smart list in the Left Sidebar menu (e.g. "Viewed
    /// Over One Year Ago" under "Up for Rotation"). Returns an empty array for parents
    /// with no menu-visible sub-items — the Purchased/Unpurchased format variants
    /// (4K/Blu-ray/DVD) remain accessible only via their gallery Picker, unaffected.
    private func subVariants(for type: SmartListType) -> [SmartListType] {
        switch type {
        case .upForRotation:     return [.viewedOverOneYearAgo]
        case .alternateVersions: return [.edited]
        case .filteredLibrary:
            return [.waitingForEdit, .temporarilyOnHold, .indefinitelyOnHold, .ignore, .blacklisted]
        default:
            return []
        }
    }
    
    /// Display label for a sub-variant menu item. Every case matches its
    /// SmartListType.rawValue except `.ignore`, whose raw value is "Ignore" but whose
    /// menu label here is "Ignored".
    private func subVariantLabel(for type: SmartListType) -> String {
        type == .ignore ? "Ignored" : type.rawValue
    }
}

// MARK: - Right Sidebar Menu
struct RightSidebarMenu: View {
    let isSheetActive: Bool
    let selectionCount: Int
    let notesTabEnabled: Bool
    private var viewStateManager = ViewStateManager.shared

    // Explicit initializer required because the private stored property above causes the
    // synthesized memberwise initializer to be private, making it inaccessible at the call
    // site in MenuBar. This init exposes only the three meaningful parameters.
    init(isSheetActive: Bool, selectionCount: Int, notesTabEnabled: Bool) {
        self.isSheetActive = isSheetActive
        self.selectionCount = selectionCount
        self.notesTabEnabled = notesTabEnabled
    }

    var body: some View {
        Menu("Right Sidebar") {
            ForEach(RightSidebarTab.allCases) { tab in
                Toggle(tab.displayName, isOn: Binding(
                    get: { viewStateManager.selectedRightSidebarTab == tab },
                    set: { if $0 { viewStateManager.setRightSidebarTab(tab) } }
                ))
                .keyboardShortcut(keyForTab(tab), modifiers: .option)
                .disabled(selectionCount != 1 || (tab == .notes && !notesTabEnabled))
            }
        }
        .disabled(selectionCount != 1 || isSheetActive)
    }

    // Helper function to return the correct keyboard shortcut for each sidebar tab.
    private func keyForTab(_ tab: RightSidebarTab) -> KeyEquivalent {
        switch tab {
        case .details:  return "1"
        case .releases: return "2"
        case .notes:    return "3"
        }
    }
}

// MARK: - Lists Menu
struct ListsMenu: View {
    var appState: AppState
    var dataCoordinator: DataCoordinator
    let isSheetActive: Bool

    @State private var availableLists: [MemoryList] = []

    var body: some View {
        Menu("Lists") {
            if availableLists.isEmpty {
                Text("No Lists Available")
                    .disabled(true)
            } else {
                ForEach(availableLists, id: \.listID) { list in
                    Toggle(truncateListName(list.listName), isOn: Binding(
                        get: { isListSelected(list.listID) },
                        set: { if $0 {
                            appState.navigate(to: .list(list.listID))
                            // Switch the ViewStateManager to the selected list view
                            ViewStateManager.shared.switchToViewSync(.list(list.listID))
                        } }))
                }
            }
        }
        .disabled(isSheetActive)
        .onAppear { loadLists() }
        .onListDataChanged { loadLists() }
        // Also refresh when the coordinator's database state changes (e.g., after initial load).
        // DataCoordinator is now @Observable; .onReceive($publisher) is no longer available.
        // .onChange(of:) uses SwiftUI's observation graph to deliver the same notification.
        .onChange(of: dataCoordinator.hasDatabaseFilms) { _, _ in
            loadLists()
        }
    }

    @MainActor
    private func loadLists() {
        availableLists = dataCoordinator.getAllLists()
    }
    
    /// Check if a specific list is currently selected
    @MainActor
    private func isListSelected(_ listID: UUID) -> Bool {
        if case .list(let selectedListID) = appState.selectedSidebarItem {
            return selectedListID == listID
        }
        return false
    }
}

// MARK: - Add to Queue Menu Content

/// The "Add to Queue" submenu's contents for the MenuBar's "Film" menu.
///
/// This view — like its "Add to List" and "Show in List" siblings below — is the LOADING
/// half only. It populates itself from `onAppear`, so it cannot be hosted anywhere its menu
/// is not the thing being opened, which is why GalleryTitleBar's SelectionMenuButton keeps
/// its own copy of the loading rather than reusing this. The ITEMS both build come from the
/// shared AddToQueueMenuBody (23_72_SelectionMenuContent.swift); GalleryContextMenu builds
/// its own, in AppKit, because it is an NSMenu. All three resolve the checkmark through
/// SelectionMenuModel (23_80_GalleryMenu.swift), which is what keeps all three in agreement.
struct AddToQueueMenuContent: View {
    let filmIDs: Set<UUID>
    let dataCoordinator: DataCoordinator

    var body: some View {
        // Identity tied to the selection so the checkmark state is recomputed from
        // scratch whenever the selection changes, exactly as AddToListMenuContent does.
        AddToQueueMenuItems(filmIDs: filmIDs, dataCoordinator: dataCoordinator)
            .id(filmIDs)
    }
}

struct AddToQueueMenuItems: View {
    let filmIDs: Set<UUID>
    let dataCoordinator: DataCoordinator

    /// The section every selected film currently occupies, or nil when the selection is
    /// empty, unqueued, or split across sections. Cached in @State (rather than computed
    /// in the body) so the per-film membership lookups run only when the underlying data
    /// actually changes, not on every menu re-evaluation.
    @State private var unanimousSection: FilmQueueSection?
    /// Adding the selection would overflow "Up Next"; see AddToQueueMenuBody.upNextBlocked.
    @State private var upNextBlocked = false

    var body: some View {
        // Items from the shared definition (23_72_SelectionMenuContent.swift); only the
        // loading below is this host's own.
        // Wrapped in a Group so the lifecycle modifiers below attach exactly as they did
        // when the items were written out here inline — the shared view replaces the item
        // construction, not the host's structure.
        Group {
            AddToQueueMenuBody(filmIDs: filmIDs,
                               unanimousSection: unanimousSection,
                               coordinator: dataCoordinator,
                               upNextBlocked: upNextBlocked)
        }
        .onAppear {
            loadUnanimousSection()
        }
        // Queue membership is stored as ordinary list membership, so every mutation path
        // — this menu, the FilmSheet picker, the sidebar drop target, the midnight
        // auto-enqueue, a removal — announces itself via .membershipChanged. Narrowed to
        // the three internal lists: a user-generated list's membership cannot affect which
        // Queue section a film occupies, so recomputing on those events would be pure
        // waste during bulk operations (an import, a restore, a multi-list add).
        .onListEvent { event in
            if case .membershipChanged(let listID) = event,
               FilmQueue.isInternalList(listID) {
                loadUnanimousSection()
            }
        }
    }

    @MainActor
    private func loadUnanimousSection() {
        unanimousSection = SelectionMenuModel.unanimousQueueSection(filmIDs: filmIDs,
                                                                    coordinator: dataCoordinator)
        upNextBlocked = FilmQueue.upNextOverflow(adding: filmIDs, coordinator: dataCoordinator) > 0
    }
}

// MARK: - Add to List Menu Content
struct AddToListMenuContent: View {
    let filmIDs: Set<UUID>
    let dataCoordinator: DataCoordinator
    var body: some View {
        // Recreate the menu content whenever the selection changes
        // so we do not reuse stale state between openings.
        AddToListMenuItems(
            filmIDs: filmIDs,
            dataCoordinator: dataCoordinator
        )
        .id(filmIDs)
    }
}

struct AddToListMenuItems: View {
    let filmIDs: Set<UUID>
    let dataCoordinator: DataCoordinator
    @State private var availableLists: [MemoryList] = []
    /// Whether the library contains any list at all, independent of whether this
    /// selection can still be added to one. Tracked separately from availableLists
    /// because the two empty states need different placeholder text — see
    /// addToListPlaceholderTitle (GlobalUtilities.swift).
    @State private var hasAnyLists = false

    var body: some View {
        // Items from the shared definition (23_72_SelectionMenuContent.swift). This host
        // is the one that supplies the ⇧⌘N shortcut: it owns a real menu-bar menu, whereas
        // the GalleryTitleBar's copy passes nil because a shortcut registered from an
        // always-mounted toolbar button would be global.
        // Wrapped in a Group so the lifecycle modifiers below attach exactly as they did
        // when the items were written out here inline.
        Group {
            AddToListMenuBody(
                filmIDs: filmIDs,
                availableLists: availableLists,
                hasAnyLists: hasAnyLists,
                createShortcut: KeyboardShortcut("n", modifiers: [.shift, .command]),
                onAddToList: { listID in
                    Task {
                        // Use batched background operation.
                        // Progress indication happens in LeftSidebar, not here.
                        FilmManager.addFilmsToList(filmIDs, listID: listID,
                                                   coordinator: dataCoordinator)
                    }
                })
        }
        .onAppear {
            loadAvailableLists()
        }
        // One subscription covering every list DATA change, matching SelectionMenuButton
        // (23_70_GalleryTitleBar.swift) rather than the previous pair of overlapping
        // listeners (.onListDataChanged for created/updated/deleted plus a second
        // .onListEvent for membershipChanged). Both are needed — a list appearing or
        // disappearing and a membership being added or removed each change which lists this
        // selection can still be added to — but they are one switch, so there is no longer
        // a second subscription to forget to keep in step. The progress-only cases carry no
        // data change and are skipped, so a bulk add or a restore does not trigger a reload
        // per event.
        .onListEvent { event in
            switch event {
            case .created, .updated, .deleted, .membershipChanged:
                loadAvailableLists()
            case .operationStarted, .operationCompleted, .queueAdditionCompleted:
                break
            }
        }
    }

    @MainActor
    private func loadAvailableLists() {
        // Resolved through SelectionMenuModel — the same call GalleryContextMenu's
        // "Add to List" submenu and GalleryTitleBar's selection-menu button make. This
        // method used to carry its own copy of the single-vs-multiple selection rule and
        // the hasAnyLists distinction; three hand-maintained copies of one rule are three
        // chances for the surfaces to disagree about which lists a selection can be added
        // to, which is exactly what the shared model exists to prevent.
        let options = SelectionMenuModel.addToListOptions(filmIDs: filmIDs,
                                                          coordinator: dataCoordinator)
        availableLists = options.lists
        hasAnyLists = options.hasAnyLists
    }
}

// MARK: - Show In List Menu Content
struct ShowInListMenuContent: View {
    let filmID: UUID
    var appState: AppState
    let dataCoordinator: DataCoordinator

    var body: some View {
        // Tie identity to filmID so list membership is recomputed when selection changes.
        ShowInListMenuItems(
            filmID: filmID,
            appState: appState,
            dataCoordinator: dataCoordinator
        )
        .id(filmID)
    }
}

struct ShowInListMenuItems: View {
    let filmID: UUID
    var appState: AppState
    let dataCoordinator: DataCoordinator

    @State private var containingLists: [MemoryList] = []
    /// Every smart list containing this film, in SmartListType.allCases order. Empty
    /// whenever the smart lists feature is switched off — but the submenu's own visibility
    /// is driven by the preference inside ShowInListMenuBody, not by this being empty,
    /// because an empty result with the feature ON means "in none of them" and must still
    /// render the submenu with its disabled placeholder.
    @State private var containingSmartLists: [SmartListType] = []

    var body: some View {
        // Items from the shared definition (23_72_SelectionMenuContent.swift), which also
        // owns the smart-lists visibility gate. Only ever built for a single selection,
        // which is already guaranteed: ShowInListMenuContent is instantiated only when
        // selectionCount == 1 (a multiple selection shows the "Multiple Films Selected"
        // placeholder in place of this whole view).
        // Wrapped in a Group so the lifecycle modifiers below attach exactly as they did
        // when the items were written out here inline.
        Group {
            ShowInListMenuBody(filmID: filmID,
                               containingLists: containingLists,
                               containingSmartLists: containingSmartLists,
                               appState: appState)
        }
        .onAppear {
            loadContainingLists()
            loadContainingSmartLists()
        }
        // Every list DATA change, membershipChanged INCLUDED. The membership case was
        // previously missing here (this used .onListDataChanged, which covers only
        // created/updated/deleted), which left this the one "Show in List" surface that
        // could go stale: Commands menu content is instantiated once and kept — `.id`
        // rebuilds it only when the SELECTION changes — so adding the selected film to a
        // list from the title bar or the gallery contextual menu, without touching the
        // selection, left that list absent from this menu until the selection changed.
        // The gallery contextual menu rebuilds its NSMenu on every open and
        // SelectionMenuButton already watched all four cases, so this menu was the only
        // one affected. Now all three watch the same set.
        .onListEvent { event in
            switch event {
            case .created, .updated, .deleted, .membershipChanged:
                loadContainingLists()
                loadContainingSmartLists()
            case .operationStarted, .operationCompleted, .queueAdditionCompleted:
                break
            }
        }
        // Smart list membership is recomputed by the SmartLists manager rather than stored,
        // so it changes without any LIST event firing. Two sources are watched, mirroring
        // the shape of the onViewStateChanged / onFilmEvent helpers in AppEventBus.swift:
        // the manager's own full-recalculation broadcast (startup, midnight rotation, a
        // restore, a preference flip), and any change to this specific film, whose edits
        // and release changes drive the per-film recalculation that emits no view event.
        .onReceive(AppEventBus.shared.viewEvents) { event in
            if case .smartListsRecalculated = event { loadContainingSmartLists() }
        }
        .onFilmEvent { event in
            switch event {
            case .updated(let id), .releaseChanged(let id):
                if id == filmID { loadContainingSmartLists() }
            default:
                break
            }
        }
    }

    @MainActor
    private func loadContainingLists() {
        // Resolved through SelectionMenuModel, matching GalleryContextMenu's and
        // GalleryTitleBar's "Show in List" submenus rather than restating their rule.
        // The shared helper reads the same in-memory MemoryStore relationships (so no
        // stale SwiftData fetch is involved) and excludes the internal Film Queue lists,
        // which are not navigable user lists and must not appear in this menu.
        containingLists = SelectionMenuModel.listsContaining(filmID: filmID,
                                                             coordinator: dataCoordinator)
    }

    @MainActor
    private func loadContainingSmartLists() {
        // Through SelectionMenuModel like every other membership read on this surface.
        // This called DataCoordinator.getSmartListTypes directly before — the one place a
        // selection menu reached past the shared model. The two are equivalent (the
        // coordinator applies the same Preferences.smartLists gate internally), so this is
        // a consistency fix rather than a behavior change, but "equivalent by inspection"
        // is exactly what the model exists to replace.
        containingSmartLists = SelectionMenuModel.smartListsContaining(filmID: filmID,
                                                                        coordinator: dataCoordinator)
    }
}

// MARK: - Focused Value Extension
extension FocusedValues {
    struct SelectedFilmIDsKey: FocusedValueKey { typealias Value = Set<UUID> }
    struct SelectedFilmIDKey: FocusedValueKey { typealias Value = UUID }
    var selectedFilmIDs: Set<UUID>? {
        get { self[SelectedFilmIDsKey.self] }
        set { self[SelectedFilmIDsKey.self] = newValue } }
    var selectedFilmID: UUID? {
        get { self[SelectedFilmIDKey.self] }
        set { self[SelectedFilmIDKey.self] = newValue } }
}
