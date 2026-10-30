// MARK: - GalleryMenu.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Secondary-click (contextual) menu for gallery items, shared by both gallery
// styles: the NSCollectionView grid (GallerySubview) and the NSTableView list
// (GalleryListView). Every item mirrors the behavior of its counterpart in the
// MenuBar's "Film" menu (12_00_MenuBar.swift) and the GalleryTitleBar's
// SelectionMenuButton / TrashMenuButton (23_70_GalleryTitleBar.swift).

import AppKit

// MARK: - GalleryMenuAction

/// Action target for a contextual-menu item, carrying its own closure.
///
/// NSMenuItem holds `target` weakly, so each instance is ALSO stored in its item's
/// `representedObject` (a strong reference), keeping the target alive for exactly as
/// long as the item itself. This avoids subclassing NSMenuItem, whose NSCoding
/// initializer requirement would have to be satisfied for no benefit here.
///
/// The closure runs through `deferPastMenuDismissal` (90_00_GlobalUtilities.swift)
/// rather than directly. Every action in this menu either presents a sheet
/// (FilmSheet, ListManagerSheet), presents a confirmation alert, or performs a full
/// view switch; running any of those while AppKit is still tearing down the menu's own
/// window risks the same presentation glitches the sub-category pickers already defer
/// around. Deferring uniformly leaves no per-item decision to get wrong.
///
/// The selector is `fire(_:)` rather than the more obvious `perform(_:)`: the latter
/// would collide with NSObject's own `perform:` selector.
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

/// The data behind the gallery's selection menus, resolved as plain values with no view
/// state of its own.
///
/// The two gallery surfaces present the identical three submenus — "Add to Queue", "Add
/// to List", "Show in List" — but cannot share their construction: GalleryContextMenu
/// builds an NSMenu, while GalleryTitleBar's SelectionMenuButton builds SwiftUI Menus.
/// What they CAN share is every decision about what those menus should contain, which is
/// what lives here. Each surface is then a thin translation of these results into its own
/// item type, so the two can only ever differ in presentation, never in content.
///
/// Deliberately NOT shared with the MenuBar's equivalents (AddToListMenuItems /
/// ShowInListMenuItems, 12_00_MenuBar.swift): those are `Commands` views whose contents
/// are instantiated lazily by AppKit when their menu is first opened, and which populate
/// themselves from `onAppear`. Reusing them from an always-on-screen toolbar button would
/// present them before that lifecycle had ever run, showing an empty menu.
///
/// Every method is a pure read of MemoryStore-backed caches (dictionary lookups plus one
/// small sort), cheap enough to call synchronously at menu-build time.
@MainActor
enum SelectionMenuModel {

    /// The user-generated lists the selection can still be added to, plus whether the
    /// library contains any list at all.
    ///
    /// A single selection offers only the lists the film is not already a member of; a
    /// multiple selection offers every list, since "add" is a no-op for films that are
    /// already members. The two counts are returned separately because the two empty
    /// states need different placeholder text — see addToListPlaceholderTitle
    /// (GlobalUtilities.swift). getAllLists() returns the user lists in displayOrder and
    /// already excludes the internal Film Queue lists.
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

    /// The navigable user lists containing a single film, in the canonical list order.
    /// `userLists(forFilm:)` excludes the internal Film Queue lists, which are not
    /// navigable user lists and must not appear in a "Show in List" menu, and applies the
    /// same ordering rule the sidebar and the Right Sidebar's membership table use.
    static func listsContaining(filmID: UUID, coordinator: DataCoordinator) -> [MemoryList] {
        coordinator.userLists(forFilm: filmID)
    }

    /// Every smart list containing a single film, in SmartListType.allCases order.
    /// Returns empty when the smart lists feature is switched off, since nothing is
    /// computed or navigable in that state.
    static func smartListsContaining(filmID: UUID, coordinator: DataCoordinator) -> [SmartListType] {
        guard Preferences.smartLists else { return [] }
        return coordinator.getSmartListTypes(forFilm: filmID)
    }

    /// The Film Queue section every selected film already occupies, or nil when the
    /// selection is empty, unqueued, or split across sections. Drives the checkmark in
    /// both surfaces' "Add to Queue" submenu: the marked section is precisely the one
    /// whose selection would change nothing.
    static func unanimousQueueSection(filmIDs: Set<UUID>,
                                      coordinator: DataCoordinator) -> FilmQueueSection? {
        FilmQueueSection.allCases.first {
            FilmQueueAssignment.allFilmsAreInSection(filmIDs, section: $0, coordinator: coordinator)
        }
    }

    /// True if at least one selected film already occupies some Film Queue section.
    /// Drives the "Add to Queue" submenu's own label: once any selected film is actually
    /// in the queue, the submenu's items can remove as well as add, so the label switches
    /// to "Manage Queue Membership" to reflect that. A selection with none of its films
    /// queued keeps the plain "Add to Queue" label, since every item there can only add.
    static func anyFilmInQueue(filmIDs: Set<UUID>, coordinator: DataCoordinator) -> Bool {
        filmIDs.contains { !coordinator.filmQueueListIDs(forFilm: $0).isEmpty }
    }
}

// MARK: - GalleryContextMenu

/// Builds the gallery contextual menu for a given set of target films.
///
/// The caller (GallerySubview.Coordinator / DraggableListView.Coordinator) is
/// responsible for resolving which films the menu acts on — see each coordinator's
/// `contextMenu(for…)` method for the selection rules — and for returning nil from its
/// `menu(for:)` override when the secondary-click did not land on an item, so clicks in
/// the inter-item padding, the row inset margins, or the empty space below the content
/// remain a no-op.
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

        // Mirrors MenuBar.isSheetActive: no film operation may be initiated from behind
        // an active sheet or a database-error alert. A sheet blocks the main window in
        // practice, so this is belt-and-braces rather than load-bearing — but it keeps
        // this menu's gating identical to every other entry point for these commands.
        guard appState.sheetCoordinator.activeSheet == nil,
              !appState.isSheetPresented,
              !appState.isDatabaseErrorAlertActive else { return nil }

        let isSingleSelection = filmIDs.count == 1

        let menu = NSMenu()
        // Explicit enablement throughout: with autoenablesItems left on, AppKit would
        // override every isEnabled value set below via the validateMenuItem(_:) protocol.
        menu.autoenablesItems = false

        // MARK: Edit section
        //
        // Both commands are resolved by SheetHostView against SelectionState rather than an
        // explicitly passed ID. That is safe here because the calling coordinator makes the
        // menu's films the live selection before this menu is built. As in the menu bar,
        // Edit Metadata… takes any selection — more than one film opens the MultiFilmSheet —
        // while Edit Releases… is for exactly one film (SelectionState.selectedFilmID).
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
        //
        // "Add to Queue" sits above "Add to List" and offers the three internal Film
        // Queue sections. It is present for any selection size and in every view,
        // including the Film Queue itself — where it acts as a move between sections.
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
        //
        // "Remove from List" appears whenever the active view is one where "remove from
        // THIS list" is a distinct operation from "remove from every list" — a
        // user-generated list or the Film Queue — irrespective of how many films are
        // selected. Every film visible in such a view is by definition a member of that
        // same list, so a multiple selection is just as coherent a target as a single
        // one, exactly as in MenuBar and TrashMenuButton. The view test is the same
        // ViewCapabilities flag TrashMenuButton uses, so the two can never disagree
        // about when the item is meaningful.
        //
        // Enablement, the confirmation-preference gating, the membership pre-filter, and
        // the alert payloads all live in FilmRemoval (LibraryManager.swift), shared with
        // the MenuBar's "Film" menu, the GalleryTitleBar's TrashMenuButton, and
        // KeyboardManager's Opt+Delete, so no two of those four can disagree about what
        // these three commands do. `clearingSelection: true` is this surface's one local
        // choice: the films visibly leave the view under the user's cursor, so the
        // selection is cleared once an unconfirmed removal completes — matching
        // TrashMenuButton and differing, as it always has, from the MenuBar and keyboard
        // paths.
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

    /// One item per Film Queue section, in queue order — the AppKit rendering of
    /// SelectionMenuModel, shared verbatim in content with the GalleryTitleBar's
    /// "Add to Queue" submenu.
    ///
    /// Every section is always offered, for any selection size. Choosing one assigns the
    /// entire selection to it, moving any film that currently sits in a different section
    /// — the reconciliation is DataCoordinator.enforceFilmQueueExclusivity's job, reached
    /// through the shared FilmQueueAssignment.toggle (29_00_FilmQueue.swift).
    ///
    /// A section is checkmarked only when EVERY selected film already occupies it; a mixed
    /// selection therefore shows no checkmark, correctly signaling that a choice here
    /// will unify the selection. Choosing the checked section again removes the selection
    /// from the Film Queue — FilmQueueAssignment.toggle re-tests live membership and takes
    /// the remove branch — matching the Toggle items of the title-bar and MenuBar hosts
    /// (AddToQueueMenuBody, 23.72 SelectionMenu.swift).
    private static func makeAddToQueueSubmenu(filmIDs: Set<UUID>,
                                              coordinator: DataCoordinator) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let currentSection = SelectionMenuModel.unanimousQueueSection(filmIDs: filmIDs,
                                                                      coordinator: coordinator)
        // allCases is declared in queue order (Up Next → Soon → Later); sorted explicitly
        // so the menu cannot silently reorder if a case is ever inserted out of order.
        for section in FilmQueueSection.allCases.sorted(by: { $0.queueOrder < $1.queueOrder }) {
            // "Up Next" is unavailable when the selection would not fit; evaluated as the
            // menu is built, so it is always current when the menu opens.
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

    /// The AppKit rendering of SelectionMenuModel.addToListOptions, including the leading
    /// "Create New List from Selection…" entry and the divider that follows it. Shared
    /// verbatim in content with the GalleryTitleBar's "Add to List" submenu, and matching
    /// the MenuBar's AddToListMenuItems.
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

        // Two distinct empty states, one placeholder each — see
        // addToListPlaceholderTitle (GlobalUtilities.swift).
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
                    // Batched background operation; progress indication is LeftSidebar's
                    // responsibility, exactly as on the MenuBar and title-bar paths.
                    FilmManager.addFilmsToList(filmIDs, listID: listID,
                                               coordinator: coordinator)
                }
            })
        }
        return submenu
    }

    /// The AppKit rendering of SelectionMenuModel.listsContaining: the navigable user
    /// lists containing the single selected film, with a checkmark on the one currently
    /// being viewed. Shared verbatim in content with the GalleryTitleBar's "Show in List"
    /// submenu, and matching the MenuBar's ShowInListMenuItems.
    private static func makeShowInListSubmenu(filmIDs: Set<UUID>,
                                              appState: AppState,
                                              coordinator: DataCoordinator) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        guard filmIDs.count == 1, let filmID = filmIDs.first else {
            submenu.addItem(disabledItem(titled: "Multiple Films Selected"))
            return submenu
        }

        // "Smart Lists" submenu, pinned to the top with a divider beneath it — mirroring
        // how "Create New List from Selection…" leads makeAddToListSubmenu. Present only
        // for a single selection (guaranteed by the guard above, which returns the
        // "Multiple Films Selected" placeholder instead) and only while the smart lists
        // feature is switched on: with it off, none of the lists is computed or navigable,
        // so the submenu and its divider are omitted entirely rather than shown empty.
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
                // Navigation, selection preservation, and the scroll-to-top placement all
                // live in ShowInListNavigation (GlobalUtilities.swift), shared with
                // ShowInListMenuItems in the MenuBar so the two cannot diverge.
                // Re-selecting the list already being viewed remains a no-op — handled
                // inside navigate, which matches the Toggle binding's `if $0` gate.
                ShowInListNavigation.navigate(to: .list(listID), preserving: filmID)
            })
        }
        return submenu
    }

    /// The "Smart Lists" sub-submenu: every smart list containing the single selected film,
    /// in SmartListType.allCases order, with a checkmark on the one currently displayed.
    ///
    /// Sub-variants ("Purchased 4K", "Viewed Over One Year Ago", "Blacklisted", …) appear
    /// alongside their parents rather than being folded into them, since each is a distinct
    /// destination. Membership comes from DataCoordinator.getSmartListTypes(forFilm:), the
    /// same source ShowInListMenuItems uses.
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
            // Checked against the active ViewIdentifier, not selectedSidebarItem: the
            // thirteen sub-variants share their parent's sidebar row, so the sidebar item
            // cannot distinguish "Purchased" from "Purchased 4K". activeView always names
            // the exact smart list on screen.
            let isCurrent = ViewStateManager.shared.activeView == .smartList(type)
            submenu.addItem(actionItem(titled: type.rawValue,
                                       state: isCurrent ? .on : .off) {
                ShowInListNavigation.navigate(to: .smartList(type), preserving: filmID)
            })
        }
        return submenu
    }
}
