// MARK: - GalleryTitleBar.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Toolbar displayed at top of the gallery for all grid-based views, including
// sort/filter menu buttons and context-sensitive menus with film/list operations.

import SwiftUI
import AppKit

struct GalleryTitleBar: View {

    let viewIdentifier: ViewIdentifier

    @Environment(AppState.self) private var appState
    @Environment(DataCoordinator.self) private var coordinator
    @Environment(SelectionState.self) private var selectionState

    var body: some View {
        GenericTitleBar(
            glyph: viewIdentifier.glyph,
            leadingContent: { leadingPicker },
            trailingButtons: {
                buttonSection
            }
        )
    }
    
    // MARK: - Leading Picker

    /// The 220pt sub-tab control shown to the right of the title bar's glyph, for the
    /// views that have one; every other view renders nothing here.
    ///
    /// All five smart list families share one branch. Each is a picker over its parent's
    /// `familyVariants` (SmartLists.swift), so the only thing that varies between them is
    /// the parent — and, for Alternate Versions alone, a segmented style rather than a
    /// dropdown. This replaces five sibling `else if` clauses that each named a family
    /// predicate, a bespoke picker view, and the same frame and padding over again.
    @ViewBuilder
    private var leadingPicker: some View {
        switch viewIdentifier {
        case .recents:
            RecentsCategoryPicker()
                .frame(width: 220)
                .padding(.leading, 12)

        case .unwatched:
            UnwatchedCategoryPicker()
                .frame(width: 220)
                .padding(.leading, 12)

        case .filmQueue:
            FilmQueueFilterPicker()
                .frame(width: 220)
                .padding(.leading, 12)

        // A family of one (Upcoming Releases) has nothing to pick between.
        case .smartList(let type) where type.familyVariants.count < 2:
            EmptyView()

        case .smartList(let type):
            HStack(spacing: 6) {
                if type.isAlternateVersionsVariant {
                    SmartListVariantPicker(parent: type.sidebarParent, style: .segmented)
                        .frame(width: 220)
                } else {
                    SmartListVariantPicker(parent: type.sidebarParent, style: .menu)
                        .frame(width: 220)
                }
                SmartListVariantHelpButton(parent: type)
            }
            .padding(.leading, 12)

        // A saved search's own controls (Edit, Remove) live in the sidebar's menu and the
        // menu bar; Search's "Save Search" leads the button row instead.
        case .allFilms, .list, .reports, .imports, .search, .savedSearch:
            EmptyView()
        }
    }

    // MARK: - Filter Button State
    
    /// Determines if the filter button should be disabled.
    /// The button should only be disabled when the view is empty for reasons OTHER than filters.
    /// If filters are active and causing an empty view, the button stays enabled so users can clear them.
    /// Also disabled during initial loading (before data is ready).
    private var shouldDisableFilterButton: Bool {
        // Disabled during initial loading (matching the sort button), and otherwise only
        // when this view is empty for a reason filters did not cause: with filters
        // active, an empty result is exactly when the button must stay reachable so the
        // user can clear them.
        FilterMenuInputs.menuDisabled(coordinator: coordinator)
    }
    
    // MARK: - Button Section
    
    private var buttonSection: some View {
        // Capture computed properties as constants to prevent double evaluation.
        // Each is a computed property that performs dictionary/coordinator lookups;
        // without capturing, SwiftUI evaluates them once for the modifier argument
        // and again for the .disabled() call on the same render pass.
        let filterButtonDisabled = shouldDisableFilterButton
        let viewStyleButtonDisabled = viewStyleToggleDisabled

        return HStack(spacing: 8) {
            // "Dispatch to ATVQ" — the Film Queue only, and only while Preferences.atvq is
            // on. Leads the row so the existing buttons keep their positions when absent.
            if case .filmQueue = viewIdentifier {
                ATVQDispatchButton()
            }

            // "Save Search" — Search only. Leads the row as "Dispatch to ATVQ" does.
            if case .search = viewIdentifier {
                SaveSearchButton()
            }

            // SIZING/SPACING — DO NOT "TIDY". The frame/fixedSize/menuIndicator chains on
            // the five buttons below are NOT accidentally inconsistent, and they are not a
            // repeated boilerplate chain waiting to be factored into one shared modifier.
            // They differ deliberately, button by button: some carry their chain here at
            // the call site and some apply it inside their own view; TrashMenuButton omits
            // the `.frame(maxWidth:)` its siblings carry. Each was hand-tuned against the
            // rendered toolbar to settle bizarre spacing and sizing behavior — SwiftUI
            // Menus, plain Buttons, and menu-indicator suppression do not size alike, and
            // the values that look redundant on paper (Preferences.buttonWidth and
            // buttonSpacing are equal today) are what actually produce even optical
            // spacing across the row.
            //
            // Collapsing these into a single `.galleryToolbarButton()` modifier, or
            // "fixing" the odd one out for symmetry, reintroduces those layout artifacts.
            // Leave them alone.
            // Sort menu button (shown for all views, but locked for fixed-sort views:
            // every Recents tab and Upcoming Releases — ViewIdentifier.hasFixedSort).
            // Use totalFilmCount (library-wide) rather than filmCount (current view),
            // so the sort button stays enabled when active filters reduce results to zero.
            //
            // NOTE: this intentionally checks viewIdentifier directly rather than
            // appState.selectedSidebarItem.capabilities.sortMenuFullyDisabled — the two
            // are NOT interchangeable here. The capability flag also covers Reports/
            // Imports for MenuBar's "Sort By" menu item, but this inline button has
            // only ever disabled itself for the fixed-sort views. The Film Queue's capability flag
            // was removed (it previously disabled MenuBar's Sort By/Filter menus
            // for the Queue while this inline button stayed enabled); both now agree
            // that the Film Queue's Sort/Filter menus are enabled whenever it has films.
            //
            // The button itself is deliberately NOT `.disabled()` any more. Locking it
            // wholesale also sealed off the "Jump to Section" submenu, which is pure
            // navigation: it changes no sort state, and the bands it lists are exactly as
            // real on a Recents tab (whose sorting is fixed, not absent) as anywhere else.
            // `isDisabled` is passed through instead, which locks every sort option and the
            // direction pair — the interaction the disable was actually there to prevent —
            // while leaving the menu openable. With no films loaded there are no bands
            // either, so the submenu simply does not render and the menu is inert.
            let sortMenuDisabled = SortMenuInputs.optionsLocked(coordinator: coordinator)
            GallerySortMenu(isDisabled: sortMenuDisabled, coordinator: coordinator)
                .frame(maxWidth: Preferences.buttonWidth)
                .fixedSize()
                .frame(width: Preferences.buttonSpacing)
            
            // Filter menu button (all filter options)
            GalleryFilterMenu(isDisabled: filterButtonDisabled)
                .frame(maxWidth: Preferences.buttonWidth)
                .fixedSize()
                .frame(width: Preferences.buttonSpacing)
                .disabled(filterButtonDisabled)
            
            // Selection menu: Add to Queue / Add to List / Show in List
            SelectionMenuButton(
                selectionState: selectionState,
                appState: appState,
                coordinator: coordinator
            )
            
            // Trash menu (selection-based operations)
            TrashMenuButton(
                showsRemoveFromList: appState.selectedSidebarItem.capabilities.showsRemoveFromListInTrashMenu,
                selectionState: selectionState,
                onRemoveFromList: confirmRemoveFromList,
                onRemoveFromAllLists: confirmRemoveFromAllLists,
                onDeleteFromLibrary: confirmDeleteFromLibrary
            )
            
            // View style toggle button (replaces the former ellipsis menu).
            // Glyph/help reflect the action that will occur on click, not the current state.
            // Enabled for every gallery view, the Film Queue included: the list gallery
            // renders the queue's three sections with its own labeled divider rows (see
            // ListRowItem in GalleryListView.swift), matching what the grid draws with its
            // section-divider decoration views.
            Button {
                ViewStateManager.shared.updateListViewStyle(!isListView)
            } label: {
                Image(systemName: isListView ? "rectangle.grid.3x2" : "rectangle.grid.1x2")
                    .offset(y: 1)
                    .font(.system(size: 14))
                    .frame(width: 14)
            }
            .frame(maxWidth: Preferences.buttonWidth)
            .fixedSize()
            .frame(width: Preferences.buttonSpacing)
            .disabled(!appState.selectedSidebarItem.capabilities.supportsListGridToggle || viewStyleButtonDisabled)
            .help(isListView ? "View as grid" : "View as list")
        }
        .focusable(false) // Remove from Tab navigation order
        .padding(.trailing, 18)
    }

    // MARK: - View Style Toggle State
    
    /// Current list-view state, read from the shared view state manager.
    private var isListView: Bool {
        ViewStateManager.shared.activeState.isListView
    }
    
    /// Determines if the view style toggle button should be disabled.
    /// Disabled when there are no films in the database.
    private var viewStyleToggleDisabled: Bool {
        coordinator.totalFilmCount == 0
    }
    
    // MARK: - Removal Commands
    //
    // Each of the three trash-menu commands is a one-line hand-off to FilmRemoval
    // (LibraryManager.swift), which owns the context resolution, the membership
    // pre-filter, the confirmation-preference gating, and the alert payloads for every
    // surface that offers these commands — this toolbar, the gallery contextual menu, the
    // MenuBar's "Film" menu, and KeyboardManager's Opt+Delete.
    //
    // `clearingSelection: true` is this surface's one local choice, and preserves the
    // long-standing split between the gallery surfaces (which clear, because the films
    // visibly leave the view the user is looking at) and the MenuBar/keyboard paths
    // (which do not).
    //
    // The active list is resolved from appState.selectedSidebarItem inside FilmRemoval
    // rather than from listID/listName properties passed down from GalleryView. Those
    // properties were a cache of exactly the same thing, refreshed a render later, so
    // reading the sidebar item directly is both simpler and strictly more current.

    @MainActor
    private func confirmRemoveFromList() {
        FilmRemoval.removeFromCurrentList(filmIDs: selectionState.selectedFilmIDs,
                                          appState: appState,
                                          coordinator: coordinator,
                                          clearingSelection: true)
    }

    @MainActor
    private func confirmRemoveFromAllLists() {
        FilmRemoval.removeFromAllLists(filmIDs: selectionState.selectedFilmIDs,
                                       coordinator: coordinator,
                                       clearingSelection: true)
    }

    @MainActor
    private func confirmDeleteFromLibrary() {
        FilmRemoval.deleteFromLibrary(filmIDs: selectionState.selectedFilmIDs,
                                      coordinator: coordinator,
                                      clearingSelection: true)
    }
}

// MARK: - Smart List Variant Picker

/// Sub-variant picker for all five smart list families — Up for Rotation, Purchased,
/// Unpurchased, Alternate Versions, and Filtered Library.
///
/// One view covers every family: the options are the family's `familyVariants` and their
/// labels are those types' own raw values. That is exactly what five separate mirror enums
/// (PurchasedFormat, UnpurchasedFormat, RotationVariant, AlternateVersionsVariant,
/// SortingCategory) each used to spell out by hand — case for case, string for string, in
/// the same order — alongside five near-identical picker views and a `smartListType`
/// mapping in each direction. Deriving the list from the family removes both the
/// duplication and the standing obligation to keep the two spellings in agreement.
private struct SmartListVariantPicker<Style: PickerStyle>: View {
    let parent: SmartListType
    let style: Style

    private var state: SmartListVariantState { SmartListVariantState.shared(for: parent) }

    var body: some View {
        SubcategoryPicker(
            label: "\(parent.rawValue) Variant",
            style: style,
            options: state.variants,
            selection: state.selected,
            title: \.rawValue,
            // Only the menu style skips the deferral: it is an NSPopUpButton whose action
            // arrives after the menu's fade (see SubcategoryPicker).
            onSelect: { state.select($0, immediate: style is MenuPickerStyle) })
    }
}

// MARK: - Smart List Variant Help Button

/// The help popover shown beside the sub-variant picker for the two families that have a
/// membership rule the list's own name does not explain.
///
/// A view of its own rather than a `@ViewBuilder` method on GalleryTitleBar, for exactly
/// the reason SmartListVariantPicker and its sibling pickers are: both of the values this
/// needs — the family's live selection and the exclude-queued preference — were read
/// inside GalleryTitleBar's own body, which registered the WHOLE title bar against them,
/// so changing a sub-variant or flipping that Setting re-rendered every button beside it.
/// Read here instead, each registers against this button alone.
///
/// Reads the picker's own selection rather than the ViewIdentifier's type:
/// SubcategoryNavigation defers the view switch past the menu-dismissal animation, so the
/// selection updates a beat before the ViewIdentifier does, and the note has to follow the
/// control the user just used rather than lag a frame behind it.
private struct SmartListVariantHelpButton: View {
    /// The family whose variant picker this button sits beside.
    let parent: SmartListType

    /// Drives the real-time appearance/disappearance of the rotation-family (Up for
    /// Rotation / Viewed Over One Year Ago) note as the preference is toggled in Settings
    /// — @AppStorage keeps this in sync with UserDefaults changes without requiring a
    /// manual event subscription.
    @AppStorage(preference: Preferences.excludeQueuedFromUpForRotationKey)
        private var excludeQueuedFromUpForRotation: Bool

    var body: some View {
        let selected = SmartListVariantState.shared(for: parent).selected
        if selected.isRotationVariant && excludeQueuedFromUpForRotation {
            // Shown for either rotation variant: SmartLists.filmIDs(for:) applies the
            // exclusion on read to both rotation lists alike (SmartLists.swift). The
            // condition previously spelled out both cases of a two-case enum
            // explicitly and so could never be false.
            HelpPopoverButton(helpText: "Films which have already been added to the Queue are currently excluded from this list. This can be changed in Settings.")
        } else if selected == .filteredLibrary {
            HelpPopoverButton(helpText: "This list contains films which are marked as having been watched and which do not contain any \u{201C}special sorting\u{201D} parameter.")
        }
    }
}

// MARK: - Film Queue Filter Picker

/// Segmented picker with four equal-width segments — "All", "Up Next", "Soon", "Later" —
/// bound to FilmQueueFilterState. Selecting a section narrows the gallery to that section
/// alone (no divider bands); "All" restores the full three-section view with dividers.
private struct FilmQueueFilterPicker: View {
    private var filterState = FilmQueueFilterState.shared

    var body: some View {
        SubcategoryPicker(
            label: "Film Queue Filter",
            style: .segmented,
            options: FilmQueueFilter.allCases,
            selection: filterState.selectedFilter,
            title: \.displayName,
            onSelect: { filterState.selectFilter($0) })
    }
}

// MARK: - Recents Category Picker

private struct RecentsCategoryPicker: View {
    private var recentsState = RecentsState.shared

    var body: some View {
        SubcategoryPicker(
            label: "Recents Category",
            style: .menu,
            options: RecentsCategory.allCases,
            selection: recentsState.selectedCategory,
            title: \.displayName,
            onSelect: { recentsState.selectCategory($0, immediate: true) })
    }
}

// MARK: - Unwatched Category Picker

/// Segmented picker with two equal-width segments — "Unwatched" and "Not Rated" —
/// bound to UnwatchedState. Mirrors FilmQueueFilterPicker's segmented style rather
/// than RecentsCategoryPicker's dropdown menu style.
private struct UnwatchedCategoryPicker: View {
    private var unwatchedState = UnwatchedState.shared

    var body: some View {
        SubcategoryPicker(
            label: "Unwatched Tab",
            style: .segmented,
            options: UnwatchedCategory.allCases,
            selection: unwatchedState.selectedCategory,
            title: \.displayName,
            onSelect: { unwatchedState.selectCategory($0) })
    }
}

// MARK: - SelectionMenuButton

/// Selection-scoped menu button in the gallery title bar. Extracted as its own view so
/// selection changes re-render only this button rather than the whole title bar.
///
/// The button opens a menu of three submenus — "Add to Queue", "Add to List", and "Show in
/// List" — offered identically by the MenuBar's "Film" menu and the gallery contextual
/// menu (23_80_GalleryMenu.swift). Agreement across all three is enforced twice over: every
/// option is resolved through the shared SelectionMenuModel, and the two SwiftUI surfaces
/// additionally build their items from the shared views in 23_72_SelectionMenuContent
/// .swift. The contextual menu still constructs its own items, because it is an NSMenu.
///
/// What is NOT shared with the MenuBar is the LOADING, and that is deliberate. The
/// MenuBar's wrappers (AddToQueueMenuContent / AddToListMenuContent / ShowInListMenuContent,
/// 12_00_MenuBar.swift) are `Commands` views: AppKit instantiates their contents lazily,
/// when their menu is first opened, and they populate themselves from `onAppear`. Hosted
/// inside this always-on-screen toolbar button they would be presented before that
/// lifecycle had run, showing an empty menu. This view therefore keeps its own state,
/// loaded on appearance and refreshed on the events below — exactly the pattern the
/// previous "Add to list" button used, and for the same reason.
private struct SelectionMenuButton: View, Loggable {
    nonisolated static let logTag = "[SelectionMenuButton]"

    var selectionState: SelectionState
    var appState: AppState
    let coordinator: DataCoordinator

    /// The user lists this selection can still be added to, and whether the library has
    /// any list at all. Tracked separately because the two empty states need different
    /// placeholder text — see addToListPlaceholderTitle (GlobalUtilities.swift).
    @State private var availableLists: [MemoryList] = []
    @State private var hasAnyLists = false
    /// The Film Queue section every selected film already occupies, if they all share
    /// one. nil for an unqueued, mixed, or empty selection.
    @State private var unanimousQueueSection: FilmQueueSection?
    /// True once any selected film already occupies some Film Queue section — the point
    /// at which the "Add to Queue" submenu's items can remove as well as add. Drives that
    /// submenu's own label; see SelectionMenuModel.anyFilmInQueue.
    @State private var anyFilmInQueue = false
    /// Adding the selection would overflow "Up Next"; see AddToQueueMenuBody.upNextBlocked.
    @State private var upNextBlocked = false
    /// "Show in List" contents. Both are empty for any selection other than exactly one
    /// film, which is what leaves the placeholder branches below in charge.
    @State private var containingLists: [MemoryList] = []
    @State private var containingSmartLists: [SmartListType] = []
    /// Watched solely to drive `reload()` when the feature is switched on mid-session —
    /// the submenu's own visibility is gated inside ShowInListMenuBody, which owns that
    /// rule for both hosts. Kept here because @AppStorage alone only re-renders; the
    /// smart-list memberships that were never computed while the feature was off still
    /// have to be loaded.
    @AppStorage(preference: Preferences.smartListsKey) private var smartListsEnabled: Bool

    private var filmIDs: Set<UUID> { selectionState.selectedFilmIDs }

    var body: some View {
        Menu {
            // All three submenus' items come from the shared definition
            // (23_72_SelectionMenuContent.swift), so this button and the MenuBar's "Film"
            // menu can differ only in how they load their values, never in what they show.
            // `createShortcut: nil` is this host's one deliberate divergence: a
            // keyboardShortcut attached inside this always-mounted toolbar button would
            // register a GLOBAL shortcut, so ⇧⌘N belongs to the menu-bar host alone.
            Menu(anyFilmInQueue ? "Manage Queue Membership" : "Add to Queue") {
                AddToQueueMenuBody(filmIDs: filmIDs,
                                   unanimousSection: unanimousQueueSection,
                                   coordinator: coordinator,
                                   upNextBlocked: upNextBlocked)
            }

            Menu("Add to List") {
                AddToListMenuBody(filmIDs: filmIDs,
                                  availableLists: availableLists,
                                  hasAnyLists: hasAnyLists,
                                  createShortcut: nil,
                                  onAddToList: { addToList($0) })
            }

            Menu("Show in List") {
                // The selection-size branching stays here, matching the MenuBar's own copy
                // in its "Film" menu — see ShowInListMenuBody's note for why it is not
                // shared.
                if filmIDs.count == 1, let filmID = filmIDs.first {
                    ShowInListMenuBody(filmID: filmID,
                                       containingLists: containingLists,
                                       containingSmartLists: containingSmartLists,
                                       appState: appState)
                } else if filmIDs.count > 1 {
                    Text("Multiple Films Selected")
                        .disabled(true)
                } else {
                    Text("No Film Selected")
                        .disabled(true)
                }
            }
        } label: {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 14))
                .frame(width: Preferences.buttonWidth)
        }
        .frame(maxWidth: Preferences.buttonWidth)
        .fixedSize()
        .menuIndicator(.hidden)
        .frame(width: Preferences.buttonSpacing)
        .onAppear {
            reload()
        }
        .onChange(of: selectionState.selectedFilmIDs) { _, _ in
            reload()
        }
        // Any list DATA change — created, renamed, deleted, or a membership added or
        // removed — can alter all three submenus, so one subscription covers them. Wider
        // than the previous button's membershipChanged-only listener because "Show in
        // List" is now built here too and must react to a list appearing or disappearing.
        // The progress-only cases (operationStarted / operationCompleted /
        // queueAdditionCompleted) carry no data change and are skipped, so a bulk add or
        // a restore does not trigger a reload per event.
        .onListEvent { event in
            switch event {
            case .created, .updated, .deleted, .membershipChanged:
                reload()
            case .operationStarted, .operationCompleted, .queueAdditionCompleted:
                break
            }
        }
        // Smart list membership is recomputed rather than stored, so it changes without
        // any list event firing. Two sources, mirroring ShowInListMenuItems: the manager's
        // own full-recalculation broadcast (startup, midnight rotation, a restore, a
        // preference flip), and any change to the selected film itself, whose edits and
        // release changes drive a per-film recalculation that emits no view event.
        .onReceive(AppEventBus.shared.viewEvents) { event in
            if case .smartListsRecalculated = event { reload() }
        }
        .onFilmEvent { event in
            switch event {
            case .updated(let id), .releaseChanged(let id):
                if filmIDs.contains(id) { reload() }
            default:
                break
            }
        }
        // Turning the feature on mid-session must populate the submenu that was empty (and
        // hidden) while it was off; @AppStorage alone only re-renders, it does not reload.
        // Belt-and-braces: flipping the master toggle also runs clearAllLists() and
        // calculateAllLists(), both of which broadcast smartListsRecalculated, which the
        // subscription above already rides. Kept because it is free and because it also
        // refreshes the other two submenus.
        .onChange(of: smartListsEnabled) { _, _ in
            reload()
        }
        .disabled(filmIDs.isEmpty)
        .help("Add to queue or list")
    }

    /// Resolves all three submenus' contents in one pass. Every value comes from
    /// SelectionMenuModel, so this button and the gallery contextual menu can only ever
    /// differ in how they render the result, never in what the result is.
    @MainActor
    private func reload() {
        let ids = filmIDs

        let options = SelectionMenuModel.addToListOptions(filmIDs: ids, coordinator: coordinator)
        availableLists = options.lists
        hasAnyLists = options.hasAnyLists

        unanimousQueueSection = SelectionMenuModel.unanimousQueueSection(filmIDs: ids,
                                                                        coordinator: coordinator)
        anyFilmInQueue = SelectionMenuModel.anyFilmInQueue(filmIDs: ids, coordinator: coordinator)
        upNextBlocked = FilmQueue.upNextOverflow(adding: ids, coordinator: coordinator) > 0

        // "Show in List" is a single-selection command; for any other selection size the
        // placeholder branches take over and these are deliberately left empty.
        if ids.count == 1, let filmID = ids.first {
            containingLists = SelectionMenuModel.listsContaining(filmID: filmID,
                                                                 coordinator: coordinator)
            containingSmartLists = SelectionMenuModel.smartListsContaining(filmID: filmID,
                                                                           coordinator: coordinator)
        } else {
            containingLists = []
            containingSmartLists = []
        }
    }

    @MainActor
    private func addToList(_ listID: UUID) {
        let ids = filmIDs
        guard !ids.isEmpty else { return }

        Self.log("Adding \(ids.count) film(s) to list \(listID)")

        Task {
            // Batched background operation; progress indication is LeftSidebar's
            // responsibility, exactly as on the MenuBar and contextual-menu paths.
            // Selection is kept after adding, matching FilmSheet and MenuBar behavior.
            FilmManager.addFilmsToList(ids, listID: listID, coordinator: coordinator)
        }
    }
}

// MARK: - TrashMenuButton

/// Extracted view for trash menu to prevent main view redraws on selection changes.
private struct TrashMenuButton: View {
    /// Whether "Remove from List" should appear alongside "Remove from All Lists" /
    /// "Delete from Library" — true for a user-generated list or the Film Queue.
    /// See ViewCapabilities.showsRemoveFromListInTrashMenu.
    let showsRemoveFromList: Bool
    let selectionState: SelectionState
    let onRemoveFromList: () -> Void
    let onRemoveFromAllLists: () -> Void
    let onDeleteFromLibrary: () -> Void
    
    var body: some View {
        Menu {
            // For the Film Queue, "Remove from List" removes each selected film
            // from whichever internal section it currently occupies only — leaving
            // any user-generated list memberships untouched, exactly like removing a
            // film from a single user-generated list. "Remove from All Lists" remains
            // available for clearing every membership (queue and user lists) at once.
            if showsRemoveFromList {
                Button("Remove from List") {
                    onRemoveFromList()
                }
            }
            Button("Remove from All Lists") {
                onRemoveFromAllLists()
            }
            Button("Delete from Library") {
                onDeleteFromLibrary()
            }
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 14))
                .frame(width: Preferences.buttonWidth)
        }
        // No `.frame(maxWidth:)` here, unlike the sibling buttons — deliberate, and
        // hand-tuned against the rendered toolbar rather than derived. See the sizing note
        // at the top of GalleryTitleBar.buttonSection before changing any of this.
        .fixedSize()
        .menuIndicator(.hidden)
        .frame(width: Preferences.buttonSpacing)
        .disabled(selectionState.selectedFilmIDs.isEmpty)
        .help("Delete items or remove them from lists")
    }
}
