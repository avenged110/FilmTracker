// MARK: - SelectionMenu.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The single "master" definition of the three selection-scoped submenus — "Add to
// Queue", "Add to List", and "Show in List" — as SwiftUI menu items.
//
// THREE SURFACES, TWO RENDERINGS. The same three submenus are offered by the MenuBar's
// "Film" menu, by the GalleryTitleBar's selection-menu button, and by the gallery
// contextual menu. The contextual menu builds an NSMenu and so cannot share view code at
// all (see GalleryContextMenu, 23_80_GalleryMenu.swift); the other two are both SwiftUI
// and had no reason to be written twice beyond the accident of where they are hosted.
// They were, though — the same ForEach/Toggle bodies, checkmark bindings, placeholder
// strings, divider placement and smart-lists gate, spelled out in two files and held in
// agreement by hand, with a dozen comments across three files asserting that agreement.
// The item construction lives here once instead.
//
// WHAT IS SHARED AND WHAT IS NOT. Only the items themselves. Each host keeps its own
// state, loading, and event subscriptions, because that is the one thing the two hosts
// genuinely cannot share: MenuBar's are `Commands` views whose contents AppKit
// instantiates lazily, when their menu is first opened, and which populate themselves
// from `onAppear`. Hosted inside the always-on-screen toolbar button they would be
// presented before that lifecycle had run, showing an empty menu. Nothing in this file
// holds @State, subscribes to an event, or loads anything — every value arrives as a
// parameter, resolved by the host through SelectionMenuModel (23_80_GalleryMenu.swift),
// which is what keeps all THREE surfaces agreeing on content while these two additionally
// agree on presentation.
//
// This mirrors SortMenuContent/FilterMenuContent (23_71_SortFilterMenu.swift), which
// already does exactly this for the Sort and Filter menus across the same two hosts.

import SwiftUI

// MARK: - Add to Queue

/// The "Add to Queue" submenu's items: one per Film Queue section, in queue order.
///
/// Every section is always offered, for any selection size. Choosing one assigns the whole
/// selection to it, moving any film currently in a different section — see
/// FilmQueueAssignment (29_00_FilmQueue.swift), which owns the reconciliation and the
/// deferral past menu dismissal.
///
/// A genuine Toggle, not just a checkmarked Button: the checkmark marks the section every
/// selected film already occupies, and clicking that same section again removes the
/// selection from the Film Queue entirely rather than no-opping. A selection split across
/// sections shows no checkmark; choosing a section there unifies the whole selection into
/// it, exactly as clicking an unchecked section always has. See FilmQueueAssignment.toggle
/// (29_00_FilmQueue.swift) for the add/remove decision, which is re-tested there against
/// live membership rather than trusted from `unanimousSection`.
@MainActor
struct AddToQueueMenuBody: View {
    let filmIDs: Set<UUID>
    /// The section every selected film already occupies, or nil for an empty, unqueued, or
    /// mixed selection. Resolved by the host via SelectionMenuModel.unanimousQueueSection.
    let unanimousSection: FilmQueueSection?
    let coordinator: DataCoordinator
    /// True when adding the selection would overflow "Up Next" (it is full, or has too few
    /// vacancies). Disables the "Up Next" item so the refusal alert is never reachable
    /// from a menu; a selection already entirely in "Up Next" never overflows.
    var upNextBlocked = false

    var body: some View {
        // Sorted explicitly rather than trusting `allCases` to be declared in queue order,
        // matching GalleryContextMenu.makeAddToQueueSubmenu. The two agree today; this is
        // what keeps them agreeing if a case is ever inserted out of order.
        ForEach(FilmQueueSection.allCases.sorted { $0.queueOrder < $1.queueOrder }) { section in
            Toggle(section.displayName, isOn: Binding(
                get: { unanimousSection == section },
                // The new value SwiftUI computes (the checkmark's opposite) is not read
                // here: `toggle` re-derives the same on/off decision itself from live
                // membership, so this binding cannot act on a stale `unanimousSection`.
                set: { _ in
                    FilmQueueAssignment.toggle(filmIDs, section: section, coordinator: coordinator)
                }))
            .disabled(section == .upNext && upNextBlocked)
        }
    }
}

// MARK: - Add to List

/// The "Add to List" submenu's items: the leading "Create New List from Selection…" entry,
/// a divider, and then either the lists this selection can still be added to or one of the
/// two placeholders.
@MainActor
struct AddToListMenuBody: View {
    let filmIDs: Set<UUID>
    /// The lists this selection can still be added to, and whether the library holds any
    /// list at all. Both come from SelectionMenuModel.addToListOptions; they are separate
    /// values because the two empty states need different placeholder text — see
    /// addToListPlaceholderTitle (90_00_GlobalUtilities.swift).
    let availableLists: [MemoryList]
    let hasAnyLists: Bool

    /// The shortcut for "Create New List from Selection…", or nil for a host that must not
    /// register one.
    ///
    /// THIS IS WHY THE PARAMETER IS AN OPTIONAL VALUE RATHER THAN AN `if`. A
    /// `keyboardShortcut` attached inside the always-mounted toolbar button would register
    /// a GLOBAL shortcut, so only the menu-bar host may supply one — but expressing that as
    /// `if hasShortcut { … } else { … }` would put the button behind a conditional, and
    /// conditionally-present buttons are exactly what silently unregistered the Opt+Delete
    /// shortcut once already (see the "Remove from List" comment in 12_00_MenuBar.swift).
    /// The optional overload of `keyboardShortcut(_:)` has no effect when passed nil, which
    /// keeps a single view structure for both hosts and no conditional anywhere near a
    /// shortcut registration.
    let createShortcut: KeyboardShortcut?

    /// Performs the add. Left to the host rather than called directly here so each keeps
    /// its own logging, exactly as the contextual menu does.
    let onAddToList: (UUID) -> Void

    var body: some View {
        Button("Create New List from Selection…") {
            // Defensive: both hosts already gate this whole menu on a non-empty selection,
            // so this is unreachable through the UI. It is cheap, and it means the command
            // cannot be sent with an empty payload from any future host either.
            guard !filmIDs.isEmpty else { return }
            AppEventBus.shared.sendCommand(.showListCreationFromSelection(filmIDs: filmIDs))
        }
        .keyboardShortcut(createShortcut)

        Divider()

        if availableLists.isEmpty {
            Text(addToListPlaceholderTitle(hasAnyLists: hasAnyLists))
                .disabled(true)
        } else {
            ForEach(availableLists, id: \.listID) { list in
                Button(truncateListName(list.listName)) {
                    onAddToList(list.listID)
                }
            }
        }
    }
}

// MARK: - Show in List

/// The "Show in List" submenu's items FOR A SINGLE SELECTED FILM: the "Smart Lists"
/// sub-submenu (when the feature is on), a divider, and then the navigable user lists
/// containing the film, or a placeholder.
///
/// The selection-size branching that precedes this — "Multiple Films Selected" for more
/// than one, "No Film Selected" for none — deliberately stays with each host. Both spell it
/// identically already, and MenuBar's copy sits one level up in the "Film" menu, where it
/// also decides whether to instantiate ShowInListMenuContent at all and ties that view's
/// identity to the film with `.id(filmID)`. Pulling the branching in here would mean
/// passing a whole selection set down and giving up that identity reset.
@MainActor
struct ShowInListMenuBody: View {
    let filmID: UUID
    /// The navigable user lists containing this film, from SelectionMenuModel
    /// .listsContaining (which excludes the internal Film Queue lists).
    let containingLists: [MemoryList]
    /// Every smart list containing this film, from SelectionMenuModel.smartListsContaining.
    let containingSmartLists: [SmartListType]
    var appState: AppState

    /// Gates the "Smart Lists" sub-submenu's presence. Read live from the preference — not
    /// derived from containingSmartLists being empty: with the feature ON the submenu is
    /// always shown, carrying a disabled placeholder when the film belongs to none of the
    /// lists, whereas with it OFF the submenu and its divider are omitted entirely (nothing
    /// is computed or navigable in that state). Owned here rather than by each host, so the
    /// gate cannot be spelled two ways; @AppStorage mirrors how LeftSidebar gates its own
    /// Smart Lists section on the same key.
    @AppStorage(preference: Preferences.smartListsKey) private var smartListsEnabled: Bool

    var body: some View {
        // Pinned to the top with a divider beneath it — mirroring how "Create New List from
        // Selection…" leads the "Add to List" submenu.
        if smartListsEnabled {
            Menu("Smart Lists") {
                if containingSmartLists.isEmpty {
                    Text("Not in Any Smart Lists")
                        .disabled(true)
                } else {
                    ForEach(containingSmartLists) { type in
                        Toggle(type.rawValue, isOn: Binding(
                            // Checked against the active ViewIdentifier, not
                            // selectedSidebarItem: the sub-variants share their parent's
                            // sidebar row, so only activeView can name the exact smart list
                            // on screen.
                            get: { ViewStateManager.shared.activeView == .smartList(type) },
                            set: { if $0 {
                                ShowInListNavigation.navigate(to: .smartList(type),
                                                              preserving: filmID)
                            } }))
                    }
                }
            }

            Divider()
        }

        if containingLists.isEmpty {
            Text("Not in Any Lists")
                .disabled(true)
        } else {
            ForEach(containingLists, id: \.listID) { list in
                let listID = list.listID
                Toggle(truncateListName(list.listName), isOn: Binding(
                    get: { appState.selectedSidebarItem == .list(listID) },
                    // Navigation, selection preservation, and the scroll-to-top placement
                    // all live in ShowInListNavigation (90_00_GlobalUtilities.swift), shared
                    // with the gallery contextual menu. Re-choosing the list already being
                    // viewed is a no-op inside navigate, which matches this binding's
                    // `if $0` gate.
                    set: { if $0 {
                        ShowInListNavigation.navigate(to: .list(listID), preserving: filmID)
                    } }))
            }
        }
    }
}
