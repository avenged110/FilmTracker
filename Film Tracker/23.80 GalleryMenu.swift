// MARK: - GalleryMenu.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// The secondary-click (contextual) menu for gallery items, shared by the grid (GallerySubview)
/// and the list (GalleryListView). Its items match their counterparts in the MenuBar's "Film"
/// menu (12.00 MenuBar.swift) and in GalleryTitleBar's SelectionMenuButton and TrashMenuButton
/// (23.70 GalleryTitleBar.swift).

import AppKit

// MARK: - GalleryMenuAction

/// Action target for a contextual-menu item, carrying its own closure.
///
/// NSMenuItem holds `target` weakly, so each instance is also stored in its item's
/// `representedObject` (a strong reference), keeping the target alive as long as the item.
/// This avoids subclassing NSMenuItem, whose NSCoding initializer would have to be satisfied
/// for no benefit.
///
/// The closure runs through `deferPastMenuDismissal` (90.00 GlobalUtilities.swift). Every
/// action here presents a sheet or an alert, or switches views. Running one while AppKit is
/// still tearing down the menu risks the presentation glitches the sub-category pickers
/// already defer around. Deferring uniformly leaves no per-item decision to get wrong.
///
/// The selector is `fire(_:)` because `perform(_:)` would collide with NSObject's `perform:`.
@MainActor
private final class GalleryMenuAction: NSObject {
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init()
    }

    @objc fileprivate func fire(_ sender: Any?) {
        let handler = self.handler
        deferPastMenuDismissal { handler() }
    }
}

// MARK: - SelectionMenuModel

/// The data behind the gallery's selection menus, resolved as plain values with no view state.
///
/// The two gallery surfaces show the same three submenus ("Add to Queue", "Add to List",
/// "Show in List") but cannot share their construction: GalleryContextMenu builds an NSMenu,
/// and GalleryTitleBar's SelectionMenuButton builds SwiftUI menus. They can share every
/// decision about what the menus contain, which is what lives here. Each surface translates
/// these results into its own item type, so the two can differ only in presentation.
///
/// Not shared with the MenuBar's AddToListMenuItems or ShowInListMenuItems (12.00 MenuBar.swift).
/// Those are `Commands` views that AppKit instantiates lazily and that populate from
/// `onAppear`, so an always-on-screen toolbar button would show them before that lifecycle
/// ran, as an empty menu.
///
/// Every method is a pure read of MemoryStore-backed caches (dictionary lookups plus a small
/// sort), cheap enough to call synchronously when the menu is built.
@MainActor
enum SelectionMenuModel {

    /// The user lists the selection can still join, plus whether the library has any list.
    ///
    /// A single selection offers only the lists the film is not already in. A multiple
    /// selection offers every list, since adding a film already in a list is a no-op. The two
    /// values are separate because the empty states need different placeholder text (see
    /// addToListPlaceholderTitle, GlobalUtilities.swift). getAllLists() returns the user lists
    /// in displayOrder and already excludes the internal Film Queue lists.
    static func addToListOptions(filmIDs: Set<UUID>,
                                 coordinator: DataCoordinator)
    -> (lists: [MemoryList], hasAnyLists: Bool) {
        let allLists = coordinator.getAllLists()
        guard !filmIDs.isEmpty else { return ([], !allLists.isEmpty) }

        if filmIDs.count == 1, let singleID = filmIDs.first {
            let available = allLists.filter {
                !coordinator.filmExists(filmID: singleID, inList: $0.listID)
            }
            return (available, !allLists.isEmpty)
        }
        return (allLists, !allLists.isEmpty)
    }

    /// The navigable user lists containing a single film, in canonical order.
    /// `userLists(forFilm:)` excludes the internal Film Queue lists, which must not appear in
    /// a "Show in List" menu. It uses the same ordering as the sidebar and the Right Sidebar's
    /// membership table.
    static func listsContaining(filmID: UUID, coordinator: DataCoordinator) -> [MemoryList] {
        coordinator.userLists(forFilm: filmID)
    }

    /// Every smart list containing a single film, in SmartListType.allCases order. Returns
    /// empty when the smart lists feature is off.
    static func smartListsContaining(filmID: UUID, coordinator: DataCoordinator) -> [SmartListType] {
        guard Preferences.smartLists else { return [] }
        return coordinator.getSmartListTypes(forFilm: filmID)
    }

    /// The Film Queue section every selected film already occupies, or nil when the selection
    /// is empty, unqueued, or split. Drives the checkmark in both surfaces' "Add to Queue"
    /// submenu. Choosing the marked section removes the selection from the queue.
    static func unanimousQueueSection(filmIDs: Set<UUID>,
                                      coordinator: DataCoordinator) -> FilmQueueSection? {
        FilmQueueSection.allCases.first {
            FilmQueueAssignment.allFilmsAreInSection(filmIDs, section: $0, coordinator: coordinator)
        }
    }

    /// True if any selected film is in a Film Queue section. Drives the submenu label: once a
    /// selected film is queued, the items can also remove, so the label becomes "Manage Queue
    /// Membership". Otherwise it stays "Add to Queue", since every item then only adds.
    static func anyFilmInQueue(filmIDs: Set<UUID>, coordinator: DataCoordinator) -> Bool {
        filmIDs.contains { !coordinator.filmQueueListIDs(forFilm: $0).isEmpty }
    }
}

// MARK: - GalleryContextMenu

/// Builds the gallery contextual menu for a set of target films.
///
/// Each coordinator (GallerySubview.Coordinator, DraggableListView.Coordinator) resolves which
/// films the menu acts on (see its `contextMenu(for…)` method). It returns nil from
/// `menu(for:)` when the click missed an item, so clicks in the padding, row insets, or empty
/// space do nothing.
@MainActor
enum GalleryContextMenu: Loggable {
    nonisolated static let logTag = "[GalleryContextMenu]"

    // MARK: - Menu Construction

    /// Returns the contextual menu for `filmIDs`, or nil when no menu should be shown.
    ///
    /// Structure (matching the MenuBar "Film" menu and the GalleryTitleBar buttons):
    ///   • Edit Metadata… (any selection) / Edit Releases… (one film only) / divider
    ///   • Add to Queue ▸ (Up Next / Soon / Later)
    ///   • Add to List ▸  (Create New List from Selection… / divider / the lists)
    ///   • Show in List ▸
    ///   • divider
    ///   • Remove from List                            — only in a view where removing
    ///                                                   from "this" list is meaningful
    ///                                                   (any selection size)
    ///   • Remove from All Lists
    ///   • Delete from Library
    static func makeMenu(for filmIDs: Set<UUID>) -> NSMenu? {
        guard !filmIDs.isEmpty,
              let appState = AppDelegate.appState,
              let coordinator = AppDelegate.dataCoordinator else { return nil }

        /// Mirrors MenuBar.isSheetActive. No film operation may start behind an active sheet or
        /// database-error alert. A sheet blocks the main window in practice, so this is a
        /// safeguard, but it keeps this menu's gating identical to every other entry point.
        guard appState.sheetCoordinator.activeSheet == nil,
              !appState.isSheetPresented,
              !appState.isDatabaseErrorAlertActive else { return nil }

        let isSingleSelection = filmIDs.count == 1

        let menu = NSMenu()
        /// Enablement is set explicitly. With autoenablesItems on, AppKit would override every
        /// isEnabled value below through validateMenuItem(_:).
        menu.autoenablesItems = false

        // MARK: Edit section
        ///
        /// SheetHostView resolves both commands against SelectionState, not a passed ID. This is
        /// safe because the calling coordinator makes the menu's films the live selection first.
        /// As in the menu bar, Edit Metadata… takes any selection (more than one film opens
        /// MultiFilmSheet), and Edit Releases… takes exactly one film (SelectionState.selectedFilmID).
        menu.addItem(actionItem(titled: "Edit Metadata…") {
            AppEventBus.shared.sendCommand(.editFilm)
        })
        if isSingleSelection {
            menu.addItem(actionItem(titled: "Edit Releases…") {
                AppEventBus.shared.sendCommand(.editFilmReleases())
            })
        }
        menu.addItem(.separator())

        // MARK: List membership section
        ///
        /// "Add to Queue" sits above "Add to List" and offers the three Film Queue sections. It
        /// appears for any selection size and in every view, including the Film Queue, where it
        /// moves films between sections.
        let addToQueueTitle = SelectionMenuModel.anyFilmInQueue(filmIDs: filmIDs, coordinator: coordinator)
            ? "Manage Queue Membership" : "Add to Queue"
        let addToQueue = NSMenuItem(title: addToQueueTitle, action: nil, keyEquivalent: "")
        addToQueue.submenu = makeAddToQueueSubmenu(filmIDs: filmIDs, coordinator: coordinator)
        menu.addItem(addToQueue)

        let addToList = NSMenuItem(title: "Add to List", action: nil, keyEquivalent: "")
        addToList.submenu = makeAddToListSubmenu(filmIDs: filmIDs, coordinator: coordinator)
        menu.addItem(addToList)

        let showInList = NSMenuItem(title: "Show in List", action: nil, keyEquivalent: "")
        showInList.submenu = makeShowInListSubmenu(filmIDs: filmIDs,
                                                   appState: appState,
                                                   coordinator: coordinator)
        menu.addItem(showInList)

        menu.addItem(.separator())

        // MARK: Removal section
        ///
        /// "Remove from List" appears in any view where removing from THIS list differs from
        /// removing from every list (a user list or the Film Queue), for any selection size.
        /// Every visible film is a member of that list, so a multiple selection is as valid a
        /// target as a single one, as in MenuBar and TrashMenuButton. The view test is the
        /// ViewCapabilities flag TrashMenuButton uses, so the two always agree.
        ///
        /// Enablement, confirmation gating, membership pre-filtering, and alert payloads live in
        /// FilmRemoval (LibraryManager.swift). The MenuBar's "Film" menu, TrashMenuButton, and
        /// KeyboardManager's Opt+Delete use the same code, so the four cannot disagree.
        /// `clearingSelection: true` is this surface's one local choice. The films leave the view
        /// under the cursor, so the selection clears once an unconfirmed removal completes, as in
        /// TrashMenuButton. The MenuBar and keyboard paths differ, as they always have.
        if appState.selectedSidebarItem.capabilities.showsRemoveFromListInTrashMenu {
            let enabled = FilmRemoval.canRemoveFromCurrentList(filmIDs: filmIDs,
                                                              appState: appState,
                                                              coordinator: coordinator)
            menu.addItem(actionItem(titled: "Remove from List", isEnabled: enabled) {
                FilmRemoval.removeFromCurrentList(filmIDs: filmIDs, appState: appState,
                                                  coordinator: coordinator,
                                                  clearingSelection: true)
            })
        }

        menu.addItem(actionItem(titled: "Remove from All Lists") {
            FilmRemoval.removeFromAllLists(filmIDs: filmIDs, coordinator: coordinator,
                                           clearingSelection: true)
        })

        menu.addItem(actionItem(titled: "Delete from Library") {
            FilmRemoval.deleteFromLibrary(filmIDs: filmIDs, coordinator: coordinator,
                                          clearingSelection: true)
        })

        return menu
    }

    // MARK: - Item Factories

    /// Builds an actionable menu item wired to `handler`. See GalleryMenuAction for why
    /// the target is retained via `representedObject`.
    private static func actionItem(titled title: String,
                                   isEnabled: Bool = true,
                                   state: NSControl.StateValue = .off,
                                   handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let action = GalleryMenuAction(handler: handler)
        let item = NSMenuItem(title: title,
                              action: #selector(GalleryMenuAction.fire(_:)),
                              keyEquivalent: "")
        item.target = action
        item.representedObject = action
        item.isEnabled = isEnabled
        item.state = state
        return item
    }

    /// A non-actionable informational row (no target/action, permanently disabled).
    private static func disabledItem(titled title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Submenus

    /// One item per Film Queue section, in queue order: the AppKit rendering of
    /// SelectionMenuModel, with the same content as GalleryTitleBar's "Add to Queue" submenu.
    ///
    /// Every section is always offered. Choosing one moves the whole selection into it, out of
    /// any other section. DataCoordinator.enforceFilmQueueExclusivity handles the reconciliation,
    /// reached through FilmQueueAssignment.toggle (29.00 FilmQueue.swift).
    ///
    /// A section is checkmarked only when every selected film is in it. A mixed selection shows
    /// no checkmark. Choosing the checked section removes the selection from the Film Queue:
    /// FilmQueueAssignment.toggle re-tests live membership and takes the remove branch, as the
    /// Toggle items in AddToQueueMenuBody (23.72 SelectionMenu.swift) do.
    private static func makeAddToQueueSubmenu(filmIDs: Set<UUID>,
                                              coordinator: DataCoordinator) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let currentSection = SelectionMenuModel.unanimousQueueSection(filmIDs: filmIDs,
                                                                      coordinator: coordinator)
        /// Sorted explicitly, as in AddToQueueMenuBody, so the menu stays in queue order if a
        /// case is ever inserted out of order.
        for section in FilmQueueSection.allCases.sorted(by: { $0.queueOrder < $1.queueOrder }) {
            /// "Up Next" is disabled when the selection would not fit. This is evaluated at build
            /// time, so it is current when the menu opens.
            let blocked = section == .upNext
                && FilmQueue.upNextOverflow(adding: filmIDs, coordinator: coordinator) > 0
            submenu.addItem(actionItem(titled: section.displayName,
                                       isEnabled: !blocked,
                                       state: section == currentSection ? .on : .off) {
                FilmQueueAssignment.toggle(filmIDs, section: section, coordinator: coordinator)
            })
        }
        return submenu
    }

    /// The AppKit rendering of SelectionMenuModel.addToListOptions, led by "Create New List
    /// from Selection…" and a divider. Its content matches GalleryTitleBar's "Add to List"
    /// submenu and the MenuBar's AddToListMenuItems.
    private static func makeAddToListSubmenu(filmIDs: Set<UUID>,
                                             coordinator: DataCoordinator) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        submenu.addItem(actionItem(titled: "Create New List from Selection…") {
            AppEventBus.shared.sendCommand(.showListCreationFromSelection(filmIDs: filmIDs))
        })
        submenu.addItem(.separator())

        let options = SelectionMenuModel.addToListOptions(filmIDs: filmIDs,
                                                          coordinator: coordinator)

        /// Two empty states, each with its own placeholder (see addToListPlaceholderTitle,
        /// GlobalUtilities.swift).
        guard !options.lists.isEmpty else {
            submenu.addItem(disabledItem(
                titled: addToListPlaceholderTitle(hasAnyLists: options.hasAnyLists)))
            return submenu
        }

        for list in options.lists {
            let listID = list.listID
            submenu.addItem(actionItem(titled: truncateListName(list.listName)) {
                Self.log("Adding \(filmIDs.count) film(s) to list \(listID)")
                Task {
                        /// Progress indication is LeftSidebar's job, as on the MenuBar and title-bar paths.
                    FilmManager.addFilmsToList(filmIDs, listID: listID,
                                               coordinator: coordinator)
                }
            })
        }
        return submenu
    }

    /// The AppKit rendering of SelectionMenuModel.listsContaining, with a checkmark on the list
    /// being viewed. Its content matches GalleryTitleBar's "Show in List" submenu and the
    /// MenuBar's ShowInListMenuItems.
    private static func makeShowInListSubmenu(filmIDs: Set<UUID>,
                                              appState: AppState,
                                              coordinator: DataCoordinator) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        guard filmIDs.count == 1, let filmID = filmIDs.first else {
            submenu.addItem(disabledItem(titled: "Multiple Films Selected"))
            return submenu
        }

        /// The "Smart Lists" submenu leads the list, with a divider beneath, as "Create New List
        /// from Selection…" leads makeAddToListSubmenu. The guard above ensures a single
        /// selection. The submenu appears only while the smart lists feature is on. With it off,
        /// nothing is computed or navigable, so the submenu and its divider are omitted.
        if Preferences.smartLists {
            let smartList = NSMenuItem(title: "Smart Lists", action: nil, keyEquivalent: "")
            smartList.submenu = makeSmartListsSubmenu(filmID: filmID, coordinator: coordinator)
            submenu.addItem(smartList)
            submenu.addItem(.separator())
        }

        let lists = SelectionMenuModel.listsContaining(filmID: filmID, coordinator: coordinator)

        guard !lists.isEmpty else {
            submenu.addItem(disabledItem(titled: "Not in Any Lists"))
            return submenu
        }

        for list in lists {
            let listID = list.listID
            let isCurrent = appState.selectedSidebarItem == .list(listID)
            submenu.addItem(actionItem(titled: truncateListName(list.listName),
                                       state: isCurrent ? .on : .off) {
                /// Navigation and selection preservation live in ShowInListNavigation
                /// (GlobalUtilities.swift), shared with the MenuBar's ShowInListMenuItems.
                /// Re-selecting the list being viewed is a no-op in navigate, matching the
                /// Toggle binding's `if $0` gate.
                ShowInListNavigation.navigate(to: .list(listID), preserving: filmID)
            })
        }
        return submenu
    }

    /// The "Smart Lists" submenu: every smart list containing the selected film, in
    /// SmartListType.allCases order, with a checkmark on the one displayed.
    ///
    /// Sub-variants (for example "Purchased 4K") appear alongside their parents, since each is
    /// a distinct destination. Membership comes from DataCoordinator.getSmartListTypes(forFilm:),
    /// the same source ShowInListMenuItems uses.
    private static func makeSmartListsSubmenu(filmID: UUID,
                                              coordinator: DataCoordinator) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let types = SelectionMenuModel.smartListsContaining(filmID: filmID,
                                                            coordinator: coordinator)

        guard !types.isEmpty else {
            submenu.addItem(disabledItem(titled: "Not in Any Smart Lists"))
            return submenu
        }

        for type in types {
            /// Checked against activeView, not selectedSidebarItem. The thirteen sub-variants
            /// share their parent's sidebar row, so the sidebar item cannot tell "Purchased" from
            /// "Purchased 4K". activeView names the exact smart list on screen.
            let isCurrent = ViewStateManager.shared.activeView == .smartList(type)
            submenu.addItem(actionItem(titled: type.rawValue,
                                       state: isCurrent ? .on : .off) {
                ShowInListNavigation.navigate(to: .smartList(type), preserving: filmID)
            })
        }
        return submenu
    }
}
