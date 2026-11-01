// MARK: - SelectionMenu.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The three selection-scoped submenus, "Add to Queue", "Add to List", and "Show in List", as
// shared SwiftUI menu items. The MenuBar's Film menu and the gallery title bar's selection
// button both build them from here.
//
// Only the items are shared. Each host keeps its own state, loading, and event subscriptions.
// MenuBar's items are `Commands` views that AppKit instantiates lazily, when the menu first
// opens, and they populate from `onAppear`. The toolbar button is always on screen, so its
// menu would be presented before that lifecycle ran and appear empty. This file holds no
// @State, subscribes to no events, and loads nothing; every value arrives as a parameter,
// resolved by the host through SelectionMenuModel (23.80 GalleryMenu.swift).
//
// The gallery's contextual menu builds an NSMenu, so it cannot share this view code (see
// GalleryContextMenu in 23.80 GalleryMenu.swift). SortMenuContent and FilterMenuContent
// (23.71 SortFilterMenu.swift) follow the same pattern.

import SwiftUI

// MARK: - Add to Queue

/// The "Add to Queue" submenu's items: one per Film Queue section, in queue order.
///
/// Every section is always offered. Choosing one moves the whole selection into it, out of any
/// other section. FilmQueueAssignment (29.00 FilmQueue.swift) handles the reconciliation and the
/// deferral past menu dismissal.
///
/// A Toggle, not a plain Button: the checkmark marks the section the whole selection already
/// occupies. Choosing that section again removes the selection from the Film Queue entirely.
/// A split selection shows no checkmark, and choosing a section unifies it there. The add or
/// remove decision is made by FilmQueueAssignment.toggle against live membership, not from
/// `unanimousSection`.
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
        // Sorted explicitly rather than trusting `allCases` to be in queue order, matching
        // GalleryContextMenu.makeAddToQueueSubmenu. Sorting keeps them agreeing if a case is
        // ever inserted out of order.
        ForEach(FilmQueueSection.allCases.sorted { $0.queueOrder < $1.queueOrder }) { section in
            Toggle(section.displayName, isOn: Binding(
                get: { unanimousSection == section },
                // The value SwiftUI computes is ignored. `toggle` re-derives the decision from
                // live membership, so it cannot act on a stale `unanimousSection`.
                set: { _ in
                    FilmQueueAssignment.toggle(filmIDs, section: section, coordinator: coordinator)
                }))
            .disabled(section == .upNext && upNextBlocked)
        }
    }
}

// MARK: - Add to List

/// The "Add to List" submenu's items: "Create New List from Selection…", a divider, then the
/// lists this selection can still join, or a placeholder.
@MainActor
struct AddToListMenuBody: View {
    let filmIDs: Set<UUID>
    /// The lists this selection can still join, and whether the library has any list. Both
    /// come from SelectionMenuModel.addToListOptions. They are separate because the two empty
    /// states need different placeholder text (see addToListPlaceholderTitle,
    /// 90.00 GlobalUtilities.swift).
    let availableLists: [MemoryList]
    let hasAnyLists: Bool

    /// The shortcut for "Create New List from Selection…", or nil for a host that must not
    /// register one.
    ///
    /// The parameter is optional rather than an `if`. A `keyboardShortcut` inside the
    /// always-mounted toolbar button would register a GLOBAL shortcut, so only the menu-bar
    /// host supplies one. An `if` would make the button conditional, and conditionally present
    /// buttons once silently unregistered the Opt+Delete shortcut (see the "Remove from List"
    /// comment in 12.00 MenuBar.swift). A nil shortcut has no effect, so both hosts keep one
    /// view structure.
    let createShortcut: KeyboardShortcut?

    /// Performs the add. The host owns this so each keeps its own logging, as the contextual
    /// menu does.
    let onAddToList: (UUID) -> Void

    var body: some View {
        Button("Create New List from Selection…") {
            // Defensive: both hosts gate this menu on a non-empty selection, so the UI cannot
            // reach this. The guard keeps any future host from sending an empty payload.
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

/// The "Show in List" submenu's items for a single selected film: the "Smart Lists" submenu
/// (when the feature is on), a divider, then the navigable user lists containing the film, or
/// a placeholder.
///
/// Each host keeps the selection-size branching ("Multiple Films Selected", "No Film Selected").
/// MenuBar's copy also decides whether to create this view and ties it to the film with
/// `.id(filmID)`, which resets it per film. Moving the branching here would mean passing the
/// whole selection and losing that reset.
@MainActor
struct ShowInListMenuBody: View {
    let filmID: UUID
    /// The navigable user lists containing this film, from SelectionMenuModel.listsContaining
    /// (which excludes the internal Film Queue lists).
    let containingLists: [MemoryList]
    /// Every smart list containing this film, from SelectionMenuModel.smartListsContaining.
    let containingSmartLists: [SmartListType]
    var appState: AppState

    /// Gates the "Smart Lists" submenu. Read live from the preference, not from
    /// containingSmartLists being empty. With the feature on, the submenu always appears, with
    /// a disabled placeholder if the film is in no smart list. With it off, the submenu and its
    /// divider are omitted. Owned here so the hosts cannot spell the gate two ways; the
    /// @AppStorage key matches the one LeftSidebar uses for its Smart Lists section.
    @AppStorage(preference: Preferences.smartListsKey) private var smartListsEnabled: Bool

    var body: some View {
        // Pinned to the top with a divider beneath, as "Create New List from Selection…"
        // leads the "Add to List" submenu.
        if smartListsEnabled {
            Menu("Smart Lists") {
                if containingSmartLists.isEmpty {
                    Text("Not in Any Smart Lists")
                        .disabled(true)
                } else {
                    ForEach(containingSmartLists) { type in
                        Toggle(type.rawValue, isOn: Binding(
                            // Checked against activeView, not selectedSidebarItem. Sub-variants
                            // share their parent's sidebar row, so only activeView names the
                            // exact smart list on screen.
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
                    // Navigation, selection preservation, and scroll-to-top placement live in
                    // ShowInListNavigation (90.00 GlobalUtilities.swift), shared with the
                    // contextual menu. Re-choosing the list already viewed is a no-op in
                    // navigate, matching this `if $0` gate.
                    set: { if $0 {
                        ShowInListNavigation.navigate(to: .list(listID), preserving: filmID)
                    } }))
            }
        }
    }
}
