// MARK: - MenuBar.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Defines the app's menu bar commands with SwiftUI's Commands API. Items enable or disable from live app state.

import SwiftUI
import Combine

struct MenuBar: Commands {
    var appState: AppState
    var dataCoordinator: DataCoordinator
    var importsState = ImportsState.shared
    @FocusedValue(\.selectedFilmIDs) private var selectedFilmIDs: Set<UUID>?
    @FocusedValue(\.selectedFilmID) private var selectedFilmID: UUID?

    var selectionCount: Int { selectedFilmIDs?.count ?? 0 }
    /// Zero until LaunchReveal allows menu refreshes, so the library load does not re-render the menu bar
    /// before the first gallery frame.
    var filmCount: Int {
        LaunchReveal.shared.menuRefreshAllowed ? dataCoordinator.totalFilmCount : 0
    }

    /// "Manage Queue Membership" when a selected film is already in a Film Queue section, since the submenu can
    /// then also remove. Otherwise "Add to Queue". Uses SelectionMenuModel.anyFilmInQueue, which the other menu
    /// hosts share, and recomputes whenever the selection changes.
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
    
    /// The FilmSheet on screen, or nil when no sheet is up or the sheet is another kind.
    /// Shows the Film menu's "Add New Release" submenu.
    @MainActor
    private var activeFilmSheet: FilmSheet? {
        guard let sheet = appState.sheetCoordinator.activeSheet,
              case .film(_, let filmSheet) = sheet.content else { return nil }
        return filmSheet
    }

    /// True when a sheet or an AlertHostView alert (including database-error alerts) is presented.
    /// Menu items lock while either is up.
    @MainActor
    var isSheetActive: Bool {
        appState.sheetCoordinator.activeSheet != nil || appState.isDatabaseErrorAlertActive
            || appState.isHostAlertActive
    }

    var body: some Commands {
        let _ = LaunchTimeline.mark("menuBodyFirst")
        Group {
            // MARK: - "Application Name" Menu: Customize
            /// "About <application>" menu item.
            CommandGroup(replacing: .appInfo) {
                Button("About Film Tracker") {
                    NSApplication.shared.orderFrontStandardAboutPanel(nil) }
                .keyboardShortcut("?", modifiers: .command) }
            /// "Settings" menu item.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    AppEventBus.shared.sendCommand(.openSettingsToTab(tab: .general)) }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(isSheetActive) }
            /// "Hide <application>"/"Hide Others"/"Show All" menu items.
            CommandGroup(replacing: .appVisibility) {
                Button("Hide Film Tracker") {
                    NSApplication.shared.hide(nil) }
                .keyboardShortcut("h", modifiers: .command)
                Button("Hide Others") {
                    NSApplication.shared.hideOtherApplications(nil) }
                .keyboardShortcut("h", modifiers: [.command, .option])
                Button("Show All") {
                    NSApplication.shared.unhideAllApplications(nil) } }
            /// "Quit <application>" menu item.
            /// Normally this calls NSApp.terminate(nil). When locked to the Restore tab (database-error recovery),
            /// AppKit blocks termination while a sheet is attached, so the pending-termination flag is set and the
            /// sheet dismissed. SettingsSheet.onDisappear then terminates.
            ///
            /// During a restore, SettingsCoordinator.isSheetDismissBlocked keeps the sheet up. The dismiss is then a
            /// no-op, onDisappear never fires, and the flag is never acted on.
            CommandGroup(replacing: .appTermination) {
                Button("Quit Film Tracker") {
                    if appState.isLockedToRestoreTab {
                        /// Set the flag before dismissing, so onDisappear knows to terminate.
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
                    /// Opens the Metadata tab of Imports. It does not open the file picker.
                    AppEventBus.shared.sendCommand(.navigateToImportsMetadata) }
                .keyboardShortcut("i", modifiers: [.shift, .command])
                /// Not disabled during an import, because this item only navigates. The lock belongs on the
                /// Imports title bar's "Select Files" button, which starts an import.
                .disabled(isSheetActive
                    || (importsState.isViewingImports && importsState.selectedCategory == .metadata))

                Button("Import Ratings…") {
                    /// Opens the Ratings tab of Imports. It does not open the file picker.
                    AppEventBus.shared.sendCommand(.navigateToImportsRatings) }
                .keyboardShortcut("i", modifiers: [.option, .command])
                /// Navigation only, so no import lock.
                .disabled(isSheetActive
                    || (importsState.isViewingImports && importsState.selectedCategory == .ratings))

                Divider()

                Button("Create New List…") {
                    AppEventBus.shared.sendCommand(.showListCreation) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(isSheetActive)

                Button("Create New Saved Search…") { SavedSearchActions.newSearch() }
                    .keyboardShortcut("s", modifiers: [.shift, .command])
                    .disabled(isSheetActive)

                Divider()

                Button("Scan Library for Duplicates…") {
                    AppEventBus.shared.sendCommand(.findDuplicates) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(filmCount == 0 || isSheetActive)

                /// Always here, so tags can be pinned with no tag row in the sidebar to open it from.
                Button("View All Tags…") { TagActions.viewAll() }
                .disabled(isSheetActive)

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
            /// Cut, Copy, Paste and Select All are always enabled and route through the responder chain.
            ///
            /// They used to be disabled unless a text field held first responder. That test read AppKit state
            /// SwiftUI does not observe, so it ran only when this Commands body happened to re-render, and a click
            /// into a selectable field (the RightSidebar's value rows) does not cause one. The items stayed
            /// disabled, Cmd+C copied nothing, and they recovered only when a window activation re-rendered
            /// the menu. Re-rendering on every focus change would rebuild the whole menu bar each time.
            ///
            /// No responder outside text controls implements cut:, copy: or paste:, so with no text focused
            /// the action reaches nothing and the item does nothing. KeyboardManager still consumes these
            /// shortcuts inside a sheet with no text field focused, and handleSelectAll picks its own scope.
            CommandGroup(replacing: .pasteboard) {
                Button("Undo") {
                    NSApp.sendAction(#selector(UndoRedoActions.undo(_:)), to: nil, from: nil) }
                .keyboardShortcut("z", modifiers: .command)
                
                Button("Redo") {
                    NSApp.sendAction(#selector(UndoRedoActions.redo(_:)), to: nil, from: nil) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                
                Divider()
                
                Button("Cut") {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                .keyboardShortcut("x", modifiers: .command)
                
                Button("Copy") {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                .keyboardShortcut("c", modifiers: .command)
                
                Button("Paste") {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                .keyboardShortcut("v", modifiers: .command)
                
                Divider()
                
                /// Scope-aware "Select All".
                Button("Select All") {
                    handleSelectAll() }
                .keyboardShortcut("a", modifiers: .command) } }

        Group {
            // MARK: - "Film" Menu: Create
            CommandMenu("Film") {
                /// Present only while a FilmSheet is open, at the top of the menu. Its items are
                /// the Releases tab's own "Add New Release" menu (AddReleaseMenuContent).
                if let filmSheet = activeFilmSheet {
                    AddReleaseMenuBarItem(filmSheet: filmSheet,
                                          isAlertActive: appState.isDatabaseErrorAlertActive
                                              || appState.isHostAlertActive)
                    Divider()
                }

                /// Grouped so the "Film" menu stays comfortably inside ViewBuilder's
                /// ten-child limit as items are added.
                Group {
                    /// The three Film Queue sections, shown above "Add to List". They are available for any selection
                    /// and in every view. With no selection or a sheet up, each is a disabled plain item, because
                    /// Commands does not carry .disabled onto a Menu's own item (see SortByMenu).
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
                
                /// With more than one film selected this opens the MultiFilmSheet.
                Button("Edit Metadata…") {
                    AppEventBus.shared.sendCommand(.editFilm) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(selectionCount == 0 || isSheetActive)
                
                Button("Edit Releases…") {
                    AppEventBus.shared.sendCommand(.editFilmReleases()) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(selectionCount != 1 || isSheetActive)
                
                Divider()
                
                /// Always present, so SwiftUI keeps the Opt+Delete shortcut registered. Conditional omission made the
                /// shortcut stop working whenever the button was absent. Availability shows through .disabled().
                /// In a user list it removes the film from that list. On the Hall of Fame tab it removes the film from
                /// the Hall of Fame.
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
            
            // MARK: - "List" Menu: Create
            /// Declared after "Film", so it follows it in the menu bar. The selected user
            /// list's sidebar menu (ListActions), or, with a tag selected, the tag's
            /// (TagActions); disabled otherwise. The three shortcuts are shared by the two sets,
            /// which are never offered together, and ⌘D also by Search > Duplicate Saved Search…. ⌘D is also the FilmSheet's Duplicate This
            /// Release, but menus are locked while a sheet is up (isSheetActive), and the
            /// sheet's own handler (KeyboardManager) takes it first in any case.
            CommandMenu("List") {
                if case .tag(let tag) = appState.selectedSidebarItem {
                    Button(PinnedTagStore.shared.isPinned(tag) ? "Unpin Tag" : "Pin Tag") {
                        TagActions.togglePin(tag) }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(isSheetActive)
                    Button("Edit Tag Name\u{2026}") { TagActions.rename(tag) }
                    .keyboardShortcut("r", modifiers: [.option, .command])
                    .disabled(isSheetActive)
                    Button("Delete Tag") {
                        if typingInTextField { return }
                        TagActions.delete(tag) }
                    .keyboardShortcut(.delete, modifiers: [.option, .command])
                    .disabled(isSheetActive)
                } else {
                    let listID = selectedUserListID
                    let isEmpty = listID.map { id in
                        (dataCoordinator.cachedLists.first { $0.listID == id }?.filmCount ?? 0) == 0 } ?? true
                    Button("Clear List Contents") {
                        if let listID { ListActions.perform(.clearContents, on: listID, coordinator: dataCoordinator) } }
                    .disabled(listID == nil || isEmpty || isSheetActive)
                    Button("Delete All List Contents from Library") {
                        if let listID { ListActions.perform(.deleteContents, on: listID, coordinator: dataCoordinator) } }
                    .disabled(listID == nil || isEmpty || isSheetActive)
                    Divider()
                    Button("Duplicate List") {
                        if let listID { ListActions.perform(.duplicate, on: listID, coordinator: dataCoordinator) } }
                    /// Bound only while a list is selected: a disabled item holding ⌘D, ahead of
                    /// Search in the menu bar, would swallow Duplicate Saved Search's ⌘D.
                    .keyboardShortcut(listID == nil ? nil : KeyboardShortcut("d", modifiers: .command))
                    .disabled(listID == nil || isSheetActive)
                    Button("Edit List Name\u{2026}") {
                        if let listID { ListActions.perform(.edit, on: listID, coordinator: dataCoordinator) } }
                    .keyboardShortcut("r", modifiers: [.option, .command])
                    .disabled(listID == nil || isSheetActive)
                    Button("Remove List") {
                        if typingInTextField { return }
                        if let listID { ListActions.perform(.delete, on: listID, coordinator: dataCoordinator) } }
                    .keyboardShortcut(.delete, modifiers: [.option, .command])
                    .disabled(listID == nil || isSheetActive)
                }
            }

            // MARK: - "Search" Menu: Create
            /// Declared after "Film", so it follows it in the menu bar.
            CommandMenu("Search") {
                Button("Search Film Library") { SearchController.focusField() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(isSheetActive)
                SaveSearchMenuItem(isSheetActive: isSheetActive)
                /// Only in a saved search's view.
                if case .savedSearch(let id) = appState.selectedSidebarItem {
                    Divider()
                    Button("Edit Saved Search…") { SavedSearchActions.edit(id) }
                        .disabled(isSheetActive)
                    /// ⌘D, as Duplicate List and Pin Tag: the three selections never coexist, and
                    /// Duplicate List gives up ⌘D while no list is selected.
                    Button("Duplicate Saved Search…") { SavedSearchActions.duplicate(id) }
                        .keyboardShortcut("d", modifiers: .command)
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
                if LaunchReveal.shared.menuContentAllowed {
                    LeftSidebarMenu(appState: appState, isSheetActive: isSheetActive)
                } else {
                    /// Its items wait for the first frame; see LaunchReveal.menuContentAllowed.
                    Menu("Left Sidebar") {}
                }
                RightSidebarMenu(isSheetActive: isSheetActive, selectionCount: selectionCount,
                                 notesTabEnabled: notesTabEnabled)
                ListsMenu(appState: appState, dataCoordinator: dataCoordinator, isSheetActive: isSheetActive)
                Divider() }
            
            // MARK: - "Window" Menu: the standard one, completed by hand
            /// AppKit supplies the Window menu's tiling items and window list. `.commandsRemoved()` drops SwiftUI's
            /// Minimize, Zoom, and Bring All to Front, so they are restored here. The groups do not replace
            /// `.windowArrangement`, because SwiftUI would then strip AppKit's items again a few frames later.
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
        /// Check both the key window AND any active sheets
        var windowsToCheck: [NSWindow] = []
        
        /// Add key window if available
        if let keyWindow = NSApp.keyWindow {
            windowsToCheck.append(keyWindow)
        }
        
        /// Add any sheet windows attached to the main window
        if let mainWindow = NSApp.mainWindow {
            if let sheet = mainWindow.attachedSheet {
                windowsToCheck.append(sheet)
            }
        }
        
        /// Check all candidate windows for focused text fields
        for window in windowsToCheck {
            if isTextFieldFocusedInWindow(window) {
                return true
            }
        }
        
        return false
    }
    
    /// Delegates to `TextInputFocus` (InputUtilities.swift), the single definition shared with KeyboardManager
    /// and SettingsSheet.
    private func isTextFieldFocusedInWindow(_ window: NSWindow) -> Bool {
        TextInputFocus.isActive(in: window)
    }
    
    /// Handle Select All menu item click (keyboard shortcut handled in KeyboardManager)
    @MainActor
    private func handleSelectAll() {
        /// When a sheet is active, always route through the responder chain so the
        /// sheet's own text fields handle Cmd+A correctly.
        if isSheetActive {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            return
        }
        if isTextFieldFocused() {
            /// Text field focused in the main window — use native text selection.
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        } else if appState.selectedSidebarItem.capabilities.supportsMultiSelection {
            /// Gallery view — select all films.
            AppEventBus.shared.selectAllFilms()
        }
    }

    /// Passes a removal shortcut to the text being edited, when there is one.
    ///
    /// The removal items use Cmd+Delete, Opt+Delete, and Shift+Opt+Delete, which mean line and word deletion in a
    /// text field. Menu key equivalents match before the field editor sees the key, so the items must hand these
    /// keystrokes back to the field. Only keystrokes are redirected. A click on the menu item always takes the film action.
    /// The field-editor test is the same one KeyboardManager's Releases-tab Cmd+Delete path uses.
    @MainActor
    /// The user list on screen, if one is.
    private var selectedUserListID: UUID? {
        if case .list(let id) = appState.selectedSidebarItem { return id }
        return nil
    }

    /// True when ⌥⌘⌫ arrives while text is being edited: Remove List and Delete Tag then do
    /// nothing, rather than act on the list or tag behind the field.
    private var typingInTextField: Bool {
        NSApp.currentEvent?.type == .keyDown && NSApp.keyWindow?.firstResponder is NSText
    }

    private func forwardedToTextEditor(_ action: Selector) -> Bool {
        guard NSApp.currentEvent?.type == .keyDown,
              NSApp.keyWindow?.firstResponder is NSText else { return false }
        NSApp.sendAction(action, to: nil, from: nil)
        return true
    }

    // MARK: - Menu Action Handlers
    ///
    /// The three removal commands above hand off to FilmRemoval (LibraryManager.swift). FilmRemoval resolves the
    /// context (user list, Film Queue, or Hall of Fame), applies the membership filter and confirmation preference,
    /// and builds the alert for every surface that offers these commands, including KeyboardManager's Opt+Delete.
    ///
    /// `clearingSelection: false` keeps the selection after an unconfirmed removal here. The gallery surfaces clear it.

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

// MARK: - Undo Actions

/// Spells the responder-chain actions `undo:` and `redo:` for `#selector`. AppKit implements them
/// (text views, and windows through their undo manager) without exposing them to Swift. Nothing
/// instantiates it; it only names the selectors. A class rather than an `@objc` protocol,
/// which `#selector` would need written as `(any UndoRedoActions)`.
///
/// A string-built `Selector(("undo:"))` drew a warning in Release builds only: whole-module
/// compilation also sees SettingsKit's private class that declares the same methods, so the
/// compiler suggested `#selector`. A Debug build, and Xcode's live per-file check, did not.
private final class UndoRedoActions: NSObject {
    @objc func undo(_ sender: Any?) {}
    @objc func redo(_ sender: Any?) {}
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
        let canSave = !isSheetActive && SavedSearchActions.canSaveCurrentSearch
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
/// Toggles the active gallery between the grid (NSCollectionView, the default) and the SwiftUI list. The title
/// names the action that will occur: "View as List" in grid view, or "View as Grid" in list view. It follows the
/// same state-sync pattern as SortByMenu and FilterItemsMenu.
struct ViewAsListMenu: View {
    let filmCount: Int
    let isSheetActive: Bool
    let selectedSidebarItem: SidebarItem

    @State private var isListView: Bool = false

    /// The menu is disabled when there are no films, a sheet is active, or
    /// the active view is one that doesn't use a gallery (Insights, Imports).
    @MainActor
    private var isMenuDisabled: Bool {
        filmCount == 0 || isSheetActive || !selectedSidebarItem.capabilities.supportsListGridToggle
    }

    var body: some View {
        Button(isListView ? "View as Grid" : "View as List") {
            /// Negate the LIVE value, not the local `isListView` mirror. A keyboard shortcut runs this action without
            /// opening the menu, so a stale mirror could name the style already in effect. updateListViewStyle would
            /// then ignore the request, and the shortcut would appear to do nothing.
            ///
            /// Reading through ViewStateManager makes this a toggle of what is actually on screen. The mirror is then
            /// realigned at once, so the title is correct on the next frame.
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
        .onChange(of: LaunchReveal.shared.menuRefreshAllowed) { syncFromViewStateManager() }
    }

    @MainActor
    private func syncFromViewStateManager() {
        /// Held until the launch's first frame is on screen; see LaunchReveal.menuRefreshAllowed.
        guard LaunchReveal.shared.menuRefreshAllowed else { return }
        isListView = ViewStateManager.shared.activeState.isListView
    }
}

// MARK: - Add New Release Menu
/// The Film menu's copy of the FilmSheet Releases tab's "Add New Release" menu. It embeds the
/// shared AddReleaseMenuContent (ReleasesView.swift), so its items are defined once and match
/// the tab's menu, and it is the host that shows their shortcuts. KeyboardManager handles the
/// keys themselves, through the same FilmSheet.requestAddRelease.
///
/// Available from any tab of the sheet, except "Duplicate This Release", which needs the
/// Releases tab. A choice switches the sheet to that tab, which carries it out once its
/// carousel is ready, so the user sees the new card arrive.
struct AddReleaseMenuBarItem: View {
    let filmSheet: FilmSheet
    /// An AlertHostView alert is up over the sheet. MenuBar.isSheetActive cannot say this,
    /// since the sheet itself makes it true.
    let isAlertActive: Bool

    /// Mirror of FilmSheet.addReleaseAvailability, refreshed as the menu bar opens.
    /// NSMenu-backed Commands items do not take part in SwiftUI observation, so values are
    /// pushed in. See SortByMenu.
    @State private var availability = AddReleaseAvailability()

    var body: some View {
        Group {
            if availability.canAdd && !isAlertActive {
                Menu("Add New Release") {
                    AddReleaseMenuContent(canDuplicate: availability.canDuplicate,
                                          showsShortcuts: true) { request in
                        filmSheet.requestAddRelease(request)
                    }
                }
            } else {
                /// A disabled plain item, not a disabled Menu: Commands does not carry
                /// `.disabled` onto a Menu's own item. See SortByMenu.
                Button("Add New Release") {}
                    .disabled(true)
            }
        }
        .onAppear { sync() }
        /// Only the menu bar's own tracking. The notification is also posted for every pop-up
        /// button's menu, which includes the many pickers on a release card, and a resync there
        /// that found a change would rebuild menu-bar items while the picker opens.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { note in
            guard let menu = note.object as? NSMenu, menu === NSApp.mainMenu else { return }
            sync()
        }
    }

    @MainActor
    private func sync() {
        let current = filmSheet.addReleaseAvailability
        /// Written only on a change, so an unchanged state does not invalidate the menu.
        if current != availability { availability = current }
    }
}

// MARK: - Sort By Menu
/// Sort menu backed by ViewStateManager. It embeds the shared SortMenuContent (SortFilterMenu.swift), so its items
/// are defined once and match GallerySortMenu, including the Jump to Section submenu.
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
    /// One mirror holds everything the menu shows. NSMenu-backed Commands items do not take part in SwiftUI
    /// observation, so values are pushed in. The jump targets depend on the dividers setting, so all values are
    /// resolved in one SortMenuInputs.current call. That keeps the resync order consistent.
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
        /// Locked until LaunchReveal allows the refresh, as it is before the library loads
        /// (no films), without reading the coordinator that early.
        isSheetActive || !LaunchReveal.shared.menuRefreshAllowed
            || SortMenuInputs.optionsLocked(coordinator: coordinator)
    }

    /// True for views with no gallery at all (Insights, Imports): nothing in the menu applies,
    /// so `body` shows a disabled item in place of the submenu.
    @MainActor
    private var isMenuNotApplicable: Bool {
        let capabilities = selectedSidebarItem.capabilities
        return capabilities.sortMenuFullyDisabled && !capabilities.supportsSectionDividers
    }

    var body: some View {
        Group {
            /// Also the Recents summary tab, where every item would be locked (ViewIdentifier.sortMenuUnavailable).
            if isMenuNotApplicable || inputs.menuUnavailable {
                /// A disabled plain item, not a disabled Menu. In menu-bar Commands SwiftUI does
                /// not carry `.disabled` onto a Menu's own NSMenuItem — only into its children —
                /// so a sealed "Sort By" still opened, onto a submenu of locked items with the
                /// left-behind gallery view's sort and direction checked. These views are ordered
                /// manually, which no option here describes. A Button does honor `.disabled`,
                /// so the item is grayed and never opens.
                Button("Sort By") {}
                    .disabled(true)
            } else if !LaunchReveal.shared.menuContentAllowed {
                /// Its items wait for the first frame; see LaunchReveal.menuContentAllowed.
                Menu("Sort By") {}
            } else {
                sortMenu
            }
        }
        .onAppear { syncFromViewStateManager() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            syncFromViewStateManager() }
        /// Section dividers need no .onChange. The value lives in ViewState, and its changes arrive on the same
        /// viewStateChanged event as the sort mirrors, which re-derives the jump targets.
        .onViewStateChanged { syncFromViewStateManager() }
        .onChange(of: LaunchReveal.shared.menuRefreshAllowed) { syncFromViewStateManager() }
    }

    private var sortMenu: some View {
        Menu("Sort By") {
            SortMenuContent(
                isDisabled: isMenuDisabled,
                disabledSortOptions: inputs.disabledSortOptions,
                currentSortOption: inputs.sortOption,
                currentSortDirection: inputs.sortDirection,
                onSelectSortOption: { option in
                    /// Realign the mirror immediately so the checkmark is correct without
                    /// waiting for the event-driven resync.
                    inputs.sortOption = option
                    ViewStateManager.shared.updateSortOption(option)
                },
                onSelectSortDirection: { direction in
                    inputs.sortDirection = direction
                    ViewStateManager.shared.updateSortDirection(direction)
                },
                currentShowSectionDividers: inputs.showSectionDividers,
                onSelectShowSectionDividers: { showDividers in
                    /// Realigned immediately, exactly as the sort and direction setters
                    /// above are — and so the jump targets recomputed by the resync that
                    /// follows are derived from the value the user just chose.
                    inputs.showSectionDividers = showDividers
                    ViewStateManager.shared.updateShowSectionDividers(showDividers)
                },
                sectionDividersLocked: inputs.sectionDividersLocked,
                jumpTargets: jumpTargets,
                onJumpToSection: { ViewStateManager.shared.jumpToSectionBand($0) }
            )
        }
        /// Not sealed as a whole, matching GallerySortMenu. Every view that reaches this menu is gallery-backed,
        /// so its Section Dividers items stay live even where `isMenuDisabled` locks the sort options.
    }

    @MainActor
    private func syncFromViewStateManager() {
        /// Held until the launch's first frame is on screen; see LaunchReveal.menuRefreshAllowed.
        guard LaunchReveal.shared.menuRefreshAllowed else { return }
        inputs = SortMenuInputs.current(coordinator: coordinator)
    }
}

// MARK: - Filter Items Menu
/// Filter menu backed by ViewStateManager. It embeds the shared FilterMenuContent (SortFilterMenu.swift), so its
/// items are defined once and match GalleryFilterMenu.
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
        /// Disabled until LaunchReveal allows the refresh, as it is before the library is
        /// initialized, without reading the coordinator that early.
        isSheetActive || !LaunchReveal.shared.menuRefreshAllowed
            || FilterMenuInputs.menuDisabled(coordinator: dataCoordinator)
    }

    /// True for views with no gallery at all (Insights, Imports), the same test SortByMenu's
    /// `isMenuNotApplicable` makes: `body` shows a disabled item in place of the submenu.
    @MainActor
    private var isMenuNotApplicable: Bool {
        let capabilities = selectedSidebarItem.capabilities
        return capabilities.filterMenuFullyDisabled && !capabilities.supportsSectionDividers
    }

    var body: some View {
        Group {
            if isMenuNotApplicable || isMenuDisabled {
                /// A disabled plain item, for the reason SortByMenu gives: Commands does not
                /// carry `.disabled` onto a Menu's own item, so the submenu still opened.
                /// Also wherever GalleryTitleBar disables its Filter button outright (an
                /// empty view with no filters to clear, initial loading), and behind a sheet.
                Button(inputs.menuTitle) {}
                    .disabled(true)
            } else {
                filterMenu
            }
        }
        .onAppear { syncFromViewStateManager() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            syncFromViewStateManager() }
        .onViewStateChanged { syncFromViewStateManager() }
        .onChange(of: LaunchReveal.shared.menuRefreshAllowed) { syncFromViewStateManager() }
    }

    private var filterMenu: some View {
        Menu(inputs.menuTitle) {
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
        /// Held until the launch's first frame is on screen; see LaunchReveal.menuRefreshAllowed.
        guard LaunchReveal.shared.menuRefreshAllowed else { return }
        inputs = FilterMenuInputs.current()
    }
}

// MARK: - Top-Level Sidebar Shortcuts

/// The ten Cmd+<digit> shortcuts that jump to a top-level Library section or smart list. This is the single source
/// for what each digit does. LeftSidebarMenu (the visible menu) and KeyboardManager's NSEvent fallback both use it,
/// so the two cannot disagree.
enum TopLevelSidebarShortcut: Int, CaseIterable, Sendable {
    case allFilms = 1
    case unwatched = 2
    case recents = 3
    case insights = 4
    case filmQueue = 5
    case upForRotation = 6
    case purchased = 7
    case unpurchased = 8
    /// Alternate Versions has a menu item but no shortcut, since Cmd+9 is Upcoming Releases.
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

    /// The smart list this shortcut navigates to, or nil for the five Library sections. This is the one place the
    /// mapping is written. `init?(smartListType:)` inverts it, so the two always agree.
    var smartListType: SmartListType? {
        switch self {
        case .upForRotation:     return .upForRotation
        case .purchased:         return .purchased
        case .unpurchased:       return .unpurchased
        case .upcomingReleases:  return .upcomingReleases
        case .filteredLibrary:   return .filteredLibrary
        case .allFilms, .unwatched, .recents, .insights, .filmQueue: return nil
        }
    }

    /// Performs the navigation this shortcut represents. It does not check Preferences.smartLists for the
    /// smart-list cases.
    @MainActor
    func activate(appState: AppState) {
        switch self {
        case .allFilms:
            appState.navigate(to: .libraryItem(.allFilms))

        /// Each family opens through LibraryTab.open, which picks the tab before navigating so the view loads once.
        case .unwatched:
            LibraryTab.unwatched(.unwatched).open(appState: appState, immediate: false)

        /// Recents and Insights open on their first tab (Recents' summary, InsightsView's Insights tab), the tab each
        /// sidebar row stands for.
        case .recents:
            LibraryTab.recents(.summary).open(appState: appState, immediate: false)

        case .insights:
            LibraryTab.insights(.primary).open(appState: appState, immediate: false)

        case .filmQueue:
            LibraryTab.queue(.all).open(appState: appState, immediate: false)

        /// All five smart lists take the identical three steps and differ only in the type,
        /// which `smartListType` already holds — so they share one arm rather than five
        /// copies of the same body.
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

    /// Monitor Preferences.smartLists to show/hide smart list entries
    @AppStorage(preference: Preferences.smartListsKey) private var smartListsEnabled: Bool

    var body: some View {
        Menu("Left Sidebar") {
            /// Every Library item and tab below takes its title from its own type (LibraryItem.title and each
            /// category's displayName) and is listed from that type's allCases, the order the title-bar pickers
            /// and the Opt+Cmd+<digit> tab shortcuts follow. A new tab appears here with no edit to this menu.
            /// Each family's first item carries its Cmd+<digit> shortcut (TopLevelSidebarShortcut), which
            /// performs that shortcut's own navigation.
            tabToggle(LibraryItem.allFilms.title, item: .allFilms, shortcut: .allFilms) {}

            Divider()

            ForEach(UnwatchedCategory.allCases, id: \.self) { category in
                tabToggle(category.displayName, item: .unwatched(category),
                          shortcut: category == .unwatched ? .unwatched : nil) { selectUnwatched(category) }
            }

            Divider()

            ForEach(RecentsCategory.allCases, id: \.self) { category in
                tabToggle(category.displayName, item: .recents(category),
                          shortcut: category == .summary ? .recents : nil) { selectRecents(category) }
            }

            Divider()

            ForEach(InsightsCategory.allCases, id: \.self) { category in
                tabToggle(category.displayName, item: .insights(category),
                          shortcut: category == .primary ? .insights : nil) { selectInsights(category) }
            }

            Divider()

            /// Imports has no top-level Cmd+<digit> shortcut.
            ForEach(ImportsCategory.allCases, id: \.self) { category in
                tabToggle("Import \(category.displayName)", item: .imports(category)) { selectImports(category) }
            }

            Divider()

            /// The Film Queue. Its All tab is the Queue itself, titled as the section is.
            ForEach(FilmQueueFilter.allCases, id: \.self) { filter in
                tabToggle(filter == .all ? LibraryItem.filmQueue.title : filter.displayName,
                          item: .filmQueueSection(filter),
                          shortcut: filter == .all ? .filmQueue : nil) { selectFilmQueueSection(filter) }
            }
            
            if smartListsEnabled {
                Divider()
                
                /// Smart Lists - with keyboard shortcuts for the five top-level lists,
                /// plus sub-variant items nested directly beneath their parent (e.g.
                /// "Viewed Over One Year Ago" under "Up for Rotation"). Sub-variants
                /// never carry a shortcut of their own.
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
                /// Note: Opt+Cmd+1–9 in-view tab switching for every smart list group (one
                /// digit per variant, up to Filtered Library's six) is handled entirely by
                /// KeyboardManager.
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
        case insights(InsightsCategory)
        case imports(ImportsCategory)
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
            /// Check if we're in the Unwatched view AND have the specific tab selected
            guard case .libraryItem(.unwatched) = appState.selectedSidebarItem else {
                return false
            }
            if case .unwatched(let activeCategory) = ViewStateManager.shared.activeView {
                return activeCategory == category
            }
            return false
            
        case .recents(let category):
            /// Check if we're in Recents view AND have the specific category selected
            guard case .libraryItem(.recents) = appState.selectedSidebarItem else {
                return false
            }
            if case .recents(let activeCategory) = ViewStateManager.shared.activeView {
                return activeCategory == category
            }
            return false
            
        case .insights(let category):
            /// Check if we're in Insights view AND have the specific category selected
            guard case .libraryItem(.insights) = appState.selectedSidebarItem else {
                return false
            }
            return InsightsState.shared.selectedCategory == category
            
        case .imports(let category):
            /// Check if we're in Imports view and have the specific category selected
            guard case .libraryItem(.imports) = appState.selectedSidebarItem else {
                return false
            }
            return ImportsState.shared.selectedCategory == category
            
        /// The Queue's own item is its All tab, so it is exclusive with the three sections.
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
    
    // MARK: - Tab Toggles

    /// One Library item or tab: checked while it is showing. Choosing it runs `shortcut`'s navigation when it
    /// has one (the family's first item), else `select`.
    @MainActor
    private func tabToggle(_ title: String, item: MenuItem, shortcut: TopLevelSidebarShortcut? = nil,
                           select: @escaping @MainActor () -> Void) -> some View {
        Toggle(title, isOn: Binding(
            get: { isItemActive(item) },
            set: { isOn in
                guard isOn else { return }
                if let shortcut { shortcut.activate(appState: appState) } else { select() }
            }))
        .keyboardShortcut(shortcut.map { KeyboardShortcut($0.keyEquivalent, modifiers: .command) })
        .disabled(isSheetActive)
    }

    // MARK: - Navigation Helpers
    /// The family tabs open through LibraryTab.open (LeftSidebar), as their sidebar rows do, deferred past the
    /// menu's fade when the family is already on screen.
    
    @MainActor
    private func selectUnwatched(_ category: UnwatchedCategory) {
        LibraryTab.unwatched(category).open(appState: appState, immediate: false)
    }
    
    @MainActor
    private func selectRecents(_ category: RecentsCategory) {
        LibraryTab.recents(category).open(appState: appState, immediate: false)
    }
    
    @MainActor
    private func selectInsights(_ category: InsightsCategory) {
        LibraryTab.insights(category).open(appState: appState, immediate: false)
    }
    
    /// Select an imports category. The item names its tab, so it lands there even while an import of
    /// the other kind runs (see ImportsState.categoryRequestedByName).
    @MainActor
    private func selectImports(_ category: ImportsCategory) {
        ImportsState.shared.open(category, appState: appState)
    }

    @MainActor
    private func selectFilmQueueSection(_ filter: FilmQueueFilter) {
        LibraryTab.queue(filter).open(appState: appState, immediate: false)
    }
    
    /// Select a smart list (updates both ViewStateManager and AppState)
    @MainActor
    private func selectSmartList(_ type: SmartListType) {
        /// Sets the sub-variant pickers first. The sidebar assignment below fires
        /// GalleryView.handleSidebarChange, which resyncs these pickers and re-derives the
        /// destination view, so it must already see the selected variant.
        /// syncAll updates only the family that owns the type. It mirrors
        /// ShowInListNavigation.navigate.
        SmartListVariantState.syncAll(to: type)

        /// Update ViewStateManager (single source of truth)
        ViewStateManager.shared.switchToViewSync(.smartList(type))

        /// Update AppState.selectedSidebarItem for sidebar highlighting. Only the five
        /// parents have sidebar rows, so a sub-variant highlights its parent via
        /// SmartListType.sidebarParent. ShowInListNavigation uses the same mapping.
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

    /// Explicit initializer required because the private stored property above causes the
    /// synthesized memberwise initializer to be private, making it inaccessible at the call
    /// site in MenuBar. This init exposes only the three meaningful parameters.
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

    /// Helper function to return the correct keyboard shortcut for each sidebar tab.
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
                            /// Switch the ViewStateManager to the selected list view
                            ViewStateManager.shared.switchToViewSync(.list(list.listID))
                        } }))
                }
            }
        }
        .disabled(isSheetActive)
        .onAppear { loadLists() }
        .onListDataChanged { loadLists() }
        /// Also refresh when the coordinator's database state changes (e.g., after initial load).
        /// DataCoordinator is @Observable, so .onReceive($publisher) is unavailable.
        /// .onChange(of:) uses SwiftUI's observation graph to deliver the same notification.
        /// One onChange for both triggers, so the gate opening with films loaded reloads once,
        /// not twice. The `&&` reads hasDatabaseFilms only once the gate is open, so the
        /// library load does not re-render this menu ahead of the first frame.
        .onChange(of: [LaunchReveal.shared.menuRefreshAllowed,
                       LaunchReveal.shared.menuRefreshAllowed && dataCoordinator.hasDatabaseFilms]) {
            loadLists()
        }
    }

    @MainActor
    private func loadLists() {
        /// Held until the launch's first frame is on screen; see LaunchReveal.menuRefreshAllowed.
        guard LaunchReveal.shared.menuRefreshAllowed else { return }
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
/// Like its "Add to List" and "Show in List" siblings, this view handles only the loading.
/// It populates itself in `onAppear`, so GalleryTitleBar's SelectionMenuButton keeps its own
/// loading. The items come from the shared AddToQueueMenuBody (23.72 SelectionMenu.swift).
/// GalleryContextMenu builds its own items in AppKit because it is an NSMenu. All three resolve
/// the checkmark through SelectionMenuModel (23.80 GalleryMenu.swift).
struct AddToQueueMenuContent: View {
    let filmIDs: Set<UUID>
    let dataCoordinator: DataCoordinator

    var body: some View {
        /// Identity tied to the selection so the checkmark state is recomputed from
        /// scratch whenever the selection changes, exactly as AddToListMenuContent does.
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
        /// Items from the shared definition (23.72 SelectionMenu.swift); only the
        /// loading below is this host's own.
        /// The shared view supplies only the item construction. The Group keeps this host's
        /// structure, so the lifecycle modifiers below attach to the same view.
        Group {
            AddToQueueMenuBody(filmIDs: filmIDs,
                               unanimousSection: unanimousSection,
                               coordinator: dataCoordinator,
                               upNextBlocked: upNextBlocked)
        }
        .onAppear {
            loadUnanimousSection()
        }
        /// Queue membership is ordinary list membership, so every change announces itself
        /// via .membershipChanged. Only the three internal Queue lists are watched, because
        /// user lists cannot change a film's Queue section.
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
        /// Recreate the menu content whenever the selection changes
        /// so we do not reuse stale state between openings.
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
        /// Items come from the shared definition (23.72 SelectionMenu.swift). Only this
        /// menu-bar host supplies the ⇧⌘N shortcut, because a shortcut on the always-mounted
        /// toolbar button would be global. The Group keeps the lifecycle modifiers below attached.
        Group {
            AddToListMenuBody(
                filmIDs: filmIDs,
                availableLists: availableLists,
                hasAnyLists: hasAnyLists,
                createShortcut: KeyboardShortcut("n", modifiers: [.shift, .command]),
                onAddToList: { listID in
                    Task {
                        /// Use batched background operation.
                        /// Progress indication happens in LeftSidebar, not here.
                        FilmManager.addFilmsToList(filmIDs, listID: listID,
                                                   coordinator: dataCoordinator)
                    }
                })
        }
        .onAppear {
            loadAvailableLists()
        }
        /// One subscription covers every list DATA change, matching SelectionMenuButton
        /// (23.70 GalleryTitleBar.swift). Lists appearing or disappearing and memberships
        /// changing both affect which lists a selection can join. Progress-only events carry
        /// no data change and are skipped, so a bulk add or restore reloads once per burst.
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
        /// Resolved through SelectionMenuModel, the same call the gallery context menu and
        /// title bar make. Sharing one rule keeps all three surfaces in agreement.
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
        /// Tie identity to filmID so list membership is recomputed when selection changes.
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
        /// Items from the shared definition (23.72 SelectionMenu.swift), which also
        /// owns the smart-lists visibility gate. Only ever built for a single selection,
        /// which is already guaranteed: ShowInListMenuContent is instantiated only when
        /// selectionCount == 1 (a multiple selection shows the "Multiple Films Selected"
        /// placeholder in place of this whole view).
        /// The Group keeps the lifecycle modifiers below attached to the shared body.
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
        /// Every list DATA change, including membershipChanged. The membership case is required
        /// because the Commands menu content is kept until the selection changes, so a film
        /// added to a list elsewhere would otherwise leave this menu stale.
        .onListEvent { event in
            switch event {
            case .created, .updated, .deleted, .membershipChanged:
                loadContainingLists()
                loadContainingSmartLists()
            case .operationStarted, .operationCompleted, .queueAdditionCompleted:
                break
            }
        }
        /// Smart list membership is recalculated rather than stored, so it changes without a
        /// LIST event. Two sources are watched, as in onViewStateChanged and onFilmEvent
        /// (AppEventBus.swift): the manager's full-recalculation broadcast, and changes to this
        /// film, whose per-film recalculation emits no view event.
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
        /// Resolved through SelectionMenuModel, matching GalleryContextMenu's and
        /// GalleryTitleBar's "Show in List" submenus rather than restating their rule.
        /// The shared helper reads the same in-memory MemoryStore relationships (so no
        /// stale store fetch is involved) and excludes the internal Film Queue lists,
        /// which are not navigable user lists and must not appear in this menu.
        containingLists = SelectionMenuModel.listsContaining(filmID: filmID,
                                                             coordinator: dataCoordinator)
    }

    @MainActor
    private func loadContainingSmartLists() {
        /// Reads membership through SelectionMenuModel, like the rest of this surface.
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
