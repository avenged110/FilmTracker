// MARK: - GalleryTitleBar.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Toolbar at the top of the gallery for all grid-based views. It holds the sort and filter buttons and the
/// context-sensitive menus for film and list operations.

import SwiftUI
import AppKit

struct GalleryTitleBar: View {
    /// The category picker's width and its inset from the title bar's leading edge —
    /// shared with the Reports and Imports title bars, which carry the same picker.
    static let pickerWidth: CGFloat = 220
    static let pickerLeading: CGFloat = 12


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

    /// The sub-tab control shown to the right of the title bar's glyph, for views that have one. Other views
    /// show nothing here.
    ///
    /// All five smart list families share one branch. Each is a picker over its parent's `familyVariants`
    /// (SmartLists.swift). They differ only in the parent, and Alternate Versions uses a segmented style
    /// instead of a dropdown. This replaces five separate branches, each with its own predicate and picker.
    @ViewBuilder
    private var leadingPicker: some View {
        switch viewIdentifier {
        case .recents:
            RecentsCategoryPicker()
                .frame(width: Self.pickerWidth)
                .padding(.leading, Self.pickerLeading)

        case .unwatched:
            UnwatchedCategoryPicker()
                .frame(width: Self.pickerWidth)
                .padding(.leading, Self.pickerLeading)

        case .filmQueue:
            FilmQueueFilterPicker()
                .frame(width: Self.pickerWidth)
                .padding(.leading, Self.pickerLeading)

        /// A family of one, Upcoming Releases, has nothing to pick between.
        case .smartList(let type) where type.familyVariants.count < 2:
            EmptyView()

        case .smartList(let type):
            HStack(spacing: 6) {
                if type.isAlternateVersionsVariant {
                    SmartListVariantPicker(parent: type.sidebarParent, style: .segmented)
                        .frame(width: Self.pickerWidth)
                } else {
                    SmartListVariantPicker(parent: type.sidebarParent, style: .menu)
                        .frame(width: Self.pickerWidth)
                }
                SmartListVariantHelpButton(parent: type)
            }
            .padding(.leading, Self.pickerLeading)

        /// A saved search's Edit and Remove controls live in the sidebar menu and the menu bar. Search's Save
        /// Search button leads the row instead.
        case .allFilms, .list, .reports, .imports, .search, .savedSearch:
            EmptyView()
        }
    }

    // MARK: - Filter Button State
    
    /// Whether the filter button is disabled. It is disabled only when the view is empty for reasons other
    /// than the filters. With filters active, an empty result keeps the button enabled, so the user can clear
    /// them. It is also disabled during initial loading.
    private var shouldDisableFilterButton: Bool {
        /// Disabled during initial loading, as the sort button is. Otherwise it is disabled only when filters
        /// did not cause the empty view, so the user can always reach the button to clear active filters.
        FilterMenuInputs.menuDisabled(coordinator: coordinator)
    }
    
    // MARK: - Button Section
    
    private var buttonSection: some View {
        /// Captures the computed properties as constants, so each is evaluated once. Each does a lookup, and
        /// without this SwiftUI would evaluate it twice on a render pass.
        let filterButtonDisabled = shouldDisableFilterButton
        let viewStyleButtonDisabled = viewStyleToggleDisabled

        return HStack(spacing: 8) {
            /// "Dispatch to ATVQ": Film Queue only, and only while Preferences.atvq is on. It leads the row,
            /// so the other buttons keep their positions.
            if case .filmQueue = viewIdentifier {
                ATVQDispatchButton()
            }

            /// "Save Search": Search only. It leads the row, as Dispatch to ATVQ does.
            if case .search = viewIdentifier {
                SaveSearchButton()
            }

            /// SIZING AND SPACING: do not tidy. The frame, fixedSize, and menuIndicator chains on the buttons
            /// below differ on purpose. Some apply their chain here and some inside their own view, and
            /// TrashMenuButton omits the maxWidth frame its siblings have. Each was tuned against the rendered
            /// toolbar, because SwiftUI menus, plain buttons, and menu-indicator suppression size differently.
            /// Values that look redundant, such as buttonWidth and buttonSpacing, produce the even spacing.
            /// Collapsing them into one modifier or making them symmetric brings the layout artifacts back.
            /// Sort menu button, shown for all views and locked for the fixed-sort views (every Recents tab
            /// and Upcoming Releases; see ViewIdentifier.hasFixedSort). It uses totalFilmCount, not filmCount,
            /// so the sort button stays enabled when filters leave no films.
            ///
            /// It checks viewIdentifier directly, not the capability flag. The flag also covers Reports and
            /// Imports for MenuBar's Sort By, which this button does not disable. The Film Queue's Sort and
            /// Filter menus are enabled whenever it has films.
            ///
            /// The button is not .disabled() as a whole, since that would also block the Jump to Section
            /// submenu. That submenu only navigates. isDisabled is passed through instead. It locks the sort
            /// options and direction, which is what the disable is for. With no films, the submenu does not
            /// render.
            let sortMenuDisabled = SortMenuInputs.optionsLocked(coordinator: coordinator)
            GallerySortMenu(isDisabled: sortMenuDisabled, coordinator: coordinator)
                .frame(maxWidth: Preferences.buttonWidth)
                .fixedSize()
                .frame(width: Preferences.buttonSpacing)
            
            /// Filter menu button, with all filter options.
            GalleryFilterMenu(isDisabled: filterButtonDisabled)
                .frame(maxWidth: Preferences.buttonWidth)
                .fixedSize()
                .frame(width: Preferences.buttonSpacing)
                .disabled(filterButtonDisabled)
            
            /// Selection menu: Add to Queue, Add to List, and Show in List.
            SelectionMenuButton(
                selectionState: selectionState,
                appState: appState,
                coordinator: coordinator
            )
            
            /// Trash menu for selection-based operations.
            TrashMenuButton(
                showsRemoveFromList: appState.selectedSidebarItem.capabilities.showsRemoveFromListInTrashMenu,
                selectionState: selectionState,
                onRemoveFromList: confirmRemoveFromList,
                onRemoveFromAllLists: confirmRemoveFromAllLists,
                onDeleteFromLibrary: confirmDeleteFromLibrary
            )
            
            /// View style toggle. The glyph and help show the action that a click will perform. It is enabled
            /// for every gallery view, including the Film Queue. The list draws the queue's three sections
            /// with labeled divider rows (see ListRowItem in GalleryListView.swift), as the grid draws its own
            /// dividers.
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
        .focusable(false) /// Remove from Tab navigation order
        .padding(.trailing, 18)
    }

    // MARK: - View Style Toggle State
    
    /// The current list-view state, read from the shared view state manager.
    private var isListView: Bool {
        ViewStateManager.shared.activeState.isListView
    }
    
    /// Whether the view style toggle is disabled. It is disabled only when the database has no films.
    private var viewStyleToggleDisabled: Bool {
        coordinator.totalFilmCount == 0
    }
    
    // MARK: - Removal Commands
    /// Each of the three trash-menu commands hands off to FilmRemoval (LibraryManager.swift). FilmRemoval
    /// resolves the context, pre-filters membership, applies the confirmation preference, and builds the alert
    /// for every surface that offers these commands: this toolbar, the gallery context menu, the MenuBar Film
    /// menu, and KeyboardManager's Opt+Delete.
    ///
    /// `clearingSelection: true` is this surface's own choice. The gallery clears the selection, since the
    /// films leave the view, while the MenuBar and keyboard paths do not.
    ///
    /// FilmRemoval reads the active list from appState.selectedSidebarItem. The earlier listID and listName
    /// properties were a cache of that value, one render behind.

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

/// Sub-variant picker for all five smart list families — Up for Rotation, Purchased, Unpurchased, Alternate
/// Versions, and Filtered Library.
///
/// One view covers every family: the options are the family's `familyVariants` and their labels are those
/// types' own raw values. That is exactly what five separate mirror enums (PurchasedFormat,
/// UnpurchasedFormat, RotationVariant, AlternateVersionsVariant, SortingCategory) each spell out by
/// hand — case for case, string for string, in the same order — alongside five near-identical picker views
/// and a `smartListType` mapping in each direction. Deriving the list from the family removes both the
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
            /// Only the menu style skips the deferral. Its action arrives after the menu fades (see
            /// SubcategoryPicker).
            onSelect: { state.select($0, immediate: style is MenuPickerStyle) })
    }
}

// MARK: - Smart List Variant Help Button

/// The help popover shown beside the sub-variant picker for the two families whose membership rule the list
/// name does not explain.
///
/// It is its own view, not a @ViewBuilder method on GalleryTitleBar. The title bar read the family's
/// selection and the exclude-queued preference in its own body, so changing either re-rendered every button
/// beside it. Here, each read registers against this button alone.
///
/// It reads the picker's own selection, not the ViewIdentifier. SubcategoryNavigation defers the view switch
/// past the menu fade, so the selection updates first, and the note should follow the control the user just
/// used.
private struct SmartListVariantHelpButton: View {
    /// The family whose variant picker this button sits beside.
    let parent: SmartListType

    /// Drives the rotation-family note as the Settings preference changes. @AppStorage keeps it in sync with
    /// UserDefaults.
    @AppStorage(preference: Preferences.excludeQueuedFromUpForRotationKey)
        private var excludeQueuedFromUpForRotation: Bool

    var body: some View {
        let selected = SmartListVariantState.shared(for: parent).selected
        if selected.isRotationVariant && excludeQueuedFromUpForRotation {
            /// Shown for either rotation variant, since SmartLists.filmIDs(for:) applies the exclusion to
            /// both. The earlier condition named both cases of a two-case enum, so it could never be false.
            HelpPopoverButton(helpText: "Films which have already been added to the Queue are currently excluded from this list. This can be changed in Settings.")
        } else if selected == .filteredLibrary {
            HelpPopoverButton(helpText: "This list contains films which are marked as having been watched and which do not contain any \u{201C}special sorting\u{201D} parameter.")
        }
    }
}

// MARK: - Film Queue Filter Picker

/// Segmented picker with four equal-width segments (All, Up Next, Soon, Later), bound to
/// FilmQueueFilterState. Choosing a section shows only that section, with no divider bands. All shows all
/// three sections with dividers.
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

/// Segmented picker with two equal-width segments (Unwatched and Not Rated), bound to UnwatchedState. It uses
/// the segmented style of FilmQueueFilterPicker, not the dropdown of RecentsCategoryPicker.
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

/// The selection-scoped menu button in the gallery title bar. It is its own view, so a selection change
/// re-renders only this button.
///
/// It opens three submenus: Add to Queue, Add to List, and Show in List. The MenuBar Film menu and the
/// gallery context menu offer the same ones. All three resolve values through SelectionMenuModel, and the two
/// SwiftUI surfaces build their items from the shared views in 23.72 SelectionMenu.swift. The context
/// menu builds its own items, since it is an NSMenu.
///
/// The loading is not shared with the MenuBar. Those wrappers are Commands views, which AppKit instantiates
/// only when the menu opens. Inside this always-visible toolbar they would show an empty menu, so this view
/// keeps its own state. It loads on appearance and refreshes on the events below.
private struct SelectionMenuButton: View, Loggable {
    nonisolated static let logTag = "[SelectionMenuButton]"

    var selectionState: SelectionState
    var appState: AppState
    let coordinator: DataCoordinator

    /// The user lists this selection can still be added to, and whether the library has any list. They are
    /// tracked separately, since the two empty states need different placeholder text (see
    /// addToListPlaceholderTitle in GlobalUtilities.swift).
    @State private var availableLists: [MemoryList] = []
    @State private var hasAnyLists = false
    /// The Film Queue section that every selected film occupies, or nil if the selection is unqueued, mixed,
    /// or empty.
    @State private var unanimousQueueSection: FilmQueueSection?
    /// True once any selected film is in a Film Queue section. Then the Add to Queue submenu can also remove
    /// films. It drives that submenu's label (see SelectionMenuModel.anyFilmInQueue).
    @State private var anyFilmInQueue = false
    /// True when adding the selection would overflow "Up Next" (see AddToQueueMenuBody.upNextBlocked).
    @State private var upNextBlocked = false
    /// The Show in List contents. Both this and the list above are empty unless exactly one film is selected,
    /// and the placeholder branches below handle other cases.
    @State private var containingLists: [MemoryList] = []
    @State private var containingSmartLists: [SmartListType] = []
    /// Watched to drive `reload()` when the smart lists feature is switched on mid-session. The submenu's
    /// visibility is gated inside ShowInListMenuBody. @AppStorage alone only re-renders, so the memberships
    /// that were never computed while the feature was off still need loading.
    @AppStorage(preference: Preferences.smartListsKey) private var smartListsEnabled: Bool

    private var filmIDs: Set<UUID> { selectionState.selectedFilmIDs }

    var body: some View {
        Menu {
            /// All three submenus come from the shared definition (23.72 SelectionMenu.swift). This
            /// button and the MenuBar Film menu differ only in how they load values, never in what they show.
            /// `createShortcut: nil` is this host's one deliberate difference. A keyboard shortcut inside this
            /// always-mounted button would register globally, so ⇧⌘N belongs to the menu bar alone.
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
                /// The selection-size branching stays here, matching the MenuBar's copy. See
                /// ShowInListMenuBody for why it is not shared.
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
        /// Any list data change (created, renamed, deleted, or membership changed) can alter all three
        /// submenus, so one subscription covers them. The progress-only events carry no data change and are
        /// skipped, so a bulk operation reloads once.
        .onListEvent { event in
            switch event {
            case .created, .updated, .deleted, .membershipChanged:
                reload()
            case .operationStarted, .operationCompleted, .queueAdditionCompleted:
                break
            }
        }
        /// Smart list membership is recalculated, not stored, so it can change with no list event. Two sources
        /// are watched, as in ShowInListMenuItems: the manager's full recalculation (startup, midnight
        /// rotation, restore, preference change), and any change to the selected film, whose per-film
        /// recalculation emits no view event.
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
        /// Turning the feature on mid-session must load the submenu that was hidden while it was off.
        /// @AppStorage alone only re-renders. Flipping the master toggle also runs clearAllLists() and
        /// calculateAllLists(), which broadcast smartListsRecalculated. The subscription above already listens
        /// for that, so this load also refreshes the other two submenus.
        .onChange(of: smartListsEnabled) { _, _ in
            reload()
        }
        .disabled(filmIDs.isEmpty)
        .help("Add to queue or list")
    }

    /// Resolves the contents of all three submenus in one pass. Every value comes from SelectionMenuModel, so
    /// this button and the gallery context menu differ only in how they render the result.
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

        /// Show in List is a single-selection command. For any other selection the placeholder branches are
        /// used, and these lists stay empty.
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
            /// Runs as a batched background operation. Progress shows in LeftSidebar, as on the MenuBar and
            /// context-menu paths. Selection is kept after adding, as in FilmSheet and MenuBar.
            FilmManager.addFilmsToList(ids, listID: listID, coordinator: coordinator)
        }
    }
}

// MARK: - TrashMenuButton

/// The trash menu, as its own view, so selection changes do not redraw the main view.
private struct TrashMenuButton: View {
    /// Whether "Remove from List" appears alongside "Remove from All Lists" and "Delete from Library". It is
    /// true for a user list or the Film Queue. See ViewCapabilities.showsRemoveFromListInTrashMenu.
    let showsRemoveFromList: Bool
    let selectionState: SelectionState
    let onRemoveFromList: () -> Void
    let onRemoveFromAllLists: () -> Void
    let onDeleteFromLibrary: () -> Void
    
    var body: some View {
        Menu {
            /// For the Film Queue, "Remove from List" removes each selected film from its current section
            /// only. User-list memberships are untouched, as with a single user list. "Remove from All Lists"
            /// still clears every membership, queue and user lists alike.
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
        /// No .frame(maxWidth:) here, unlike the sibling buttons. This was tuned against the rendered toolbar.
        /// See the sizing note at the top of GalleryTitleBar.buttonSection before changing it.
        .fixedSize()
        .menuIndicator(.hidden)
        .frame(width: Preferences.buttonSpacing)
        .disabled(selectionState.selectedFilmIDs.isEmpty)
        .help("Delete items or remove them from lists")
    }
}
