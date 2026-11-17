// MARK: - LeftSidebar.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Navigation sidebar showing Library sections and user-created Lists.
///
/// The sidebar lists the Library sections, the smart lists, user lists, saved searches, and the
/// most-used tags. Its selection drives the gallery, and it also accepts drops onto lists and the Queue.

import SwiftUI
import AppKit
import Combine

struct LeftSidebar: View, Loggable {
    nonisolated static let logTag = "[LeftSidebar]"

    @Environment(AppState.self) private var appState
    @Environment(DataCoordinator.self) private var dataCoordinator

    /// Local selection state - isolates the List binding from AppState
    @State private var localSelection: SidebarRow = .item(.libraryItem(.allFilms))
    
    /// Monitor Preferences.smartLists for real-time updates
    @AppStorage(preference: Preferences.smartListsKey) private var smartListsEnabled: Bool
    /// The Tags section's length, 0 when hidden (Preferences.showTagsInSidebar).
    @AppStorage(preference: Preferences.showTagsInSidebarKey) private var sidebarTagCount: Int

    /// Read through the enum, as Preferences.showTagsInSidebar reads it, so a stored value it
    /// does not name falls back to the default rather than listing that many tags.
    private var tagCount: Preferences.SidebarTagCount {
        Preferences.SidebarTagCount(rawValue: sidebarTagCount) ?? .ten
    }

    var body: some View {
        List(selection: $localSelection) {
            LibrarySection()
            
            if smartListsEnabled {
                SmartListsSection()
            }
            
            ListsSection(
                lists: dataCoordinator.cachedLists,
                dataCoordinator: dataCoordinator,
                onAction: performListAction,
                onMove: moveItems
            )

            /// Shown once there is something in it.
            if !SavedSearchStore.shared.searches.isEmpty {
                SavedSearchesSection()
            }

            /// Shown once there is something in it, as Saved Searches is. SidebarTagRecount, below,
            /// keeps the rows; hidden, it keeps none.
            if SidebarTagRows.shared.hasTags {
                TagsSection()
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
        /// Animates list insertions, deletions, renames, and reorders. Keyed on what the rows
        /// show, not on cachedLists, which also carries film counts that no row displays.
        .animation(.default, value: dataCoordinator.cachedLists.map(ListRowKey.init))
        /// Keyed on what the rows show, as ListRowKey is.
        .animation(.default, value: SavedSearchStore.shared.searches.map(SavedSearchRowKey.init))
        /// Both selection syncs live in their own modifier. Applied here, every click would
        /// re-evaluate this body and every ListRow. See SidebarSelectionSync.
        .modifier(SidebarSelectionSync(
            localSelection: $localSelection,
            onUserSelection: { oldValue, newValue in
                Self.log("User selection: \(String(describing: oldValue)) → \(String(describing: newValue))")
                switch newValue {
                case .item(.smartList(let type)):
                    selectSmartList(type)
                case .item(let item):
                    /// The row of a family with a primary tab is that tab, as a smart list
                    /// family's row is its parent variant.
                    if let primary = SidebarLibraryFamily(item)?.primaryTab {
                        primary.open(appState: appState, immediate: true)
                    } else {
                        appState.navigate(to: item)
                    }
                case .tab(let tab):
                    /// Selected exactly as its title-bar picker selects it. From another view the tab
                    /// loads first (LibraryTab.open), as selectSmartList's variants do. Immediate: a
                    /// sidebar click has no menu fade to wait out.
                    tab.open(appState: appState, immediate: true)
                }
            }))
        .onChange(of: smartListsEnabled) { _, isEnabled in
            /// If smart lists are disabled and we're viewing one, switch to All Films
            if !isEnabled, case .smartList = appState.selectedSidebarItem {
                appState.navigate(to: .libraryItem(.allFilms))
            }
        }
        .onChange(of: sidebarTagCount) { _, count in
            /// Hiding the Tags section while a tag is on screen returns to All Films, as for smart lists.
            if count == 0, case .tag = appState.selectedSidebarItem {
                appState.navigate(to: .libraryItem(.allFilms))
            }
        }
        /// The tag rows are recounted out here, on the List, which is always on screen. A modifier of
        /// its own, as SidebarSelectionSync is, so the film counts it reads invalidate only it.
        .modifier(SidebarTagRecount(limit: tagCount.rawValue))
        /// No initialization task is needed. cachedLists is filled synchronously in
        /// finalizeInitialization(), so the rows appear in the same frame as the grid.
        .onReceive(AppEventBus.shared.listEvents) { event in
            /// Rows track cachedLists through syncListsCache() at each mutation, and per-row feedback comes
            /// from ListRowActivityStore. The one event handled here is the deletion of the list on screen,
            /// which moves the selection off it.
            if case .deleted(let deletedListID) = event,
               appState.selectedSidebarItem == .list(deletedListID) {
                appState.navigate(to: .libraryItem(.allFilms))
            }
        }
    }

    // MARK: - Smart List Rows

    /// A click on a smart list row: a family's parent or one of its variants.
    ///
    /// - Within the family on screen it is exactly the title-bar picker's selection
    ///   (SmartListVariantState.select), so the two controls cannot disagree. That covers
    ///   a click on the parent row while a variant is showing, which returns to the parent.
    /// - A variant from anywhere else takes ShowInListNavigation's order: resolve the
    ///   family to the variant, load it, then flip the sidebar to the parent. Flipping
    ///   first would reset the family to its parent (GalleryView.prepareSidebarTransition
    ///   honors only a variant that is already loaded).
    /// - A parent from anywhere else is an ordinary navigation.
    private func selectSmartList(_ type: SmartListType) {
        let family = SidebarItem.smartList(type.sidebarParent)
        if appState.selectedSidebarItem == family {
            SmartListVariantState.shared(for: type).select(type, immediate: true)
        } else if type != type.sidebarParent {
            SmartListVariantState.syncAll(to: type)
            if dataCoordinator.isInitialized {
                ViewStateManager.shared.switchToViewSync(.smartList(type))
            }
            appState.navigate(to: family)
        } else {
            appState.navigate(to: family)
        }
    }

    // MARK: - Actions

    /// Single entry point for every ListRow contextual-menu action.
    private func performListAction(_ action: ListRowAction, _ listID: UUID) {
        switch action {
        case .edit:
            /// Request the list manager sheet for editing via UICommand;
            /// SheetHostView handles the actual presentation.
            Self.log("Requesting list edit sheet for list: \(listID)")
            AppEventBus.shared.send(.ui(.editList(listID)))
        case .duplicate:
            AppEventBus.shared.send(.ui(.duplicateList(listID)))
        case .clearContents:
            handleClearListContents(listID)
        case .deleteContents:
            handleDeleteListContents(listID)
        case .delete:
            handleDeleteList(listID)
        }
    }

    /// Resolves a list's current display name from the same cached array the rows are
    /// built from. Returns nil — and so aborts the pending action — if the list was
    /// removed between the menu gesture and the action firing.
    private func listName(for listID: UUID) -> String? {
        dataCoordinator.cachedLists.first { $0.listID == listID }?.listName
    }

    private func handleClearListContents(_ listID: UUID) {
        /// Gated by the "list contents" class of the list-edit confirmation preference.
        if !Preferences.shouldConfirmListContents {
            Task {
                _ = ListManager.clearListContents(listID, coordinator: dataCoordinator)
            }
        } else {
            guard let name = listName(for: listID) else { return }
            AppEventBus.shared.sendAlert(.confirmClearContents(
                listID: listID, listName: name))
        }
    }
    
    private func handleDeleteListContents(_ listID: UUID) {
        /// Film IDs are fetched synchronously, since getFilmIDsForListDeletion reads MemoryStore
        /// directly.
        let filmIDs = ListManager.getFilmIDsForListDeletion(listID, coordinator: dataCoordinator)

        guard !filmIDs.isEmpty else {
            /// The list became empty since the menu gesture, for example after a prior deletion.
            Self.log("handleDeleteListContents: list \(listID) has no films — operation skipped")
            return
        }

        if !Preferences.confirmGalleryDelete {
            Task {
                await ListManager.deleteListContents(listID, filmIDs: filmIDs, coordinator: dataCoordinator)
            }
        } else {
            guard let name = listName(for: listID) else { return }
            AppEventBus.shared.sendAlert(.confirmDeleteContents(
                listID: listID, listName: name))
        }
    }
    
    private func handleDeleteList(_ listID: UUID) {
        /// Gated by the "list structure" class of the list-edit confirmation preference.
        if !Preferences.shouldConfirmListStructure {
            Task {
                _ = ListManager.deleteList(listID, coordinator: dataCoordinator)
            }
        } else {
            guard let name = listName(for: listID) else { return }
            AppEventBus.shared.sendAlert(.confirmRemoveList(
                listID: listID, listName: name))
        }
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        /// batchUpdateListOrders applies an optimistic update and calls syncListsCache(), so the
        /// sidebar updates immediately through @Observable.
        Task {
            ListManager.reorderLists(from: source, to: destination,
                coordinator: dataCoordinator)
        }
    }
}

// MARK: - Sidebar Row
/// A sidebar row's selection tag. Every row is a SidebarItem except a library family's tab
/// rows, which exist only here: AppState holds the family's own item whatever tab is showing.
private enum SidebarRow: Hashable {
    case item(SidebarItem)
    case tab(LibraryTab)
}

// MARK: - Library Families
/// The Library rows with tabs of their own, each shown as a disclosure row over those tabs.
/// Internal, not private, only so Preferences can store which are expanded.
enum SidebarLibraryFamily: String, CaseIterable, Sendable {
    case unwatched
    case recents
    case reports
    /// Listed after Imports, and drawn on its own (LibrarySection), since its row is also a drop target.
    case queue

    /// The families LibrarySection draws together, in order. The Queue follows Imports.
    static let grouped: [SidebarLibraryFamily] = [.unwatched, .recents, .reports]
}

extension SidebarLibraryFamily {
    init?(_ item: SidebarItem) {
        switch item {
        case .libraryItem(.unwatched): self = .unwatched
        case .libraryItem(.recents):   self = .recents
        case .libraryItem(.reports):   self = .reports
        case .libraryItem(.filmQueue): self = .queue
        default: return nil
        }
    }

    var sidebarItem: SidebarItem {
        switch self {
        case .unwatched: return .libraryItem(.unwatched)
        case .recents:   return .libraryItem(.recents)
        case .reports:   return .libraryItem(.reports)
        case .queue:     return .libraryItem(.filmQueue)
        }
    }

    /// The tab the family's own row is, as a smart list family's row is its parent variant:
    /// clicking the row opens this tab, and the row is highlighted only while it is showing.
    /// Recents' is its summary tab, which shows a row of each of the others. The Queue's is All.
    var primaryTab: LibraryTab {
        switch self {
        case .unwatched: return .unwatched(.unwatched)
        case .recents:   return .recents(.summary)
        case .reports:   return .reports(.primary)
        case .queue:     return .queue(.all)
        }
    }

    /// The row's title. The Queue's row is the Queue itself; the others' rows are their primary tabs.
    var title: String { self == .queue ? LibraryItem.filmQueue.title : primaryTab.title }

    var glyph: String { primaryTab.glyph }

    /// Every tab, in the title-bar picker's order (allCases, which the Cmd+<digit> tab
    /// shortcuts follow too).
    var tabs: [LibraryTab] {
        switch self {
        case .unwatched: return UnwatchedCategory.allCases.map(LibraryTab.unwatched)
        case .recents:   return RecentsCategory.allCases.map(LibraryTab.recents)
        case .reports:   return ReportsCategory.allCases.map(LibraryTab.reports)
        case .queue:     return FilmQueueFilter.allCases.map(LibraryTab.queue)
        }
    }

    /// The tabs shown as child rows: all but the primary, which is the family's own row.
    var childTabs: [LibraryTab] { tabs.filter { $0 != primaryTab } }

    /// The tab the family's state has selected: the one on screen while the family is.
    @MainActor
    var currentTab: LibraryTab {
        switch self {
        case .unwatched: return .unwatched(UnwatchedState.shared.selectedCategory)
        case .recents:   return .recents(RecentsState.shared.selectedCategory)
        case .reports:   return .reports(ReportsState.shared.selectedCategory)
        case .queue:     return .queue(FilmQueueFilterState.shared.selectedFilter)
        }
    }
}

/// One tab of a library family: its sidebar row, its Left Sidebar menu item, and the one way to open it.
enum LibraryTab: Hashable {
    case unwatched(UnwatchedCategory)
    case recents(RecentsCategory)
    case reports(ReportsCategory)
    case queue(FilmQueueFilter)

    var family: SidebarLibraryFamily {
        switch self {
        case .unwatched: return .unwatched
        case .recents:   return .recents
        case .reports:   return .reports
        case .queue:     return .queue
        }
    }

    var title: String {
        switch self {
        case .unwatched(let category): return category.displayName
        case .recents(let category):   return category.displayName
        case .reports(let category):   return category.displayName
        case .queue(let filter):       return filter.displayName
        }
    }

    /// The outline of the glyph the title bar shows for this tab.
    var glyph: String {
        switch self {
        case .unwatched(let category): return category.symbol.outline
        case .recents(let category):   return category.symbol.outline
        case .reports(let category):   return category.symbol.outline
        case .queue(let filter):       return filter.glyph.outline
        }
    }

    /// Selects this tab through its state's own path, the one the title-bar picker takes.
    /// - Parameter immediate: Switch in this turn rather than after a menu's fade (see
    ///   SubcategoryNavigation.performSwitch). The Queue's tab switch always defers.
    @MainActor
    func select(immediate: Bool) {
        switch self {
        case .unwatched(let category):
            UnwatchedState.shared.selectCategory(category, immediate: immediate)
        case .recents(let category):
            RecentsState.shared.selectCategory(category, immediate: immediate)
        case .reports(let category):
            ReportsState.shared.selectCategory(category, immediate: immediate)
        case .queue(let filter):
            FilmQueueFilterState.shared.selectFilter(filter)
        }
    }

    /// Shows this tab, from anywhere: the LeftSidebar's rows, the Left Sidebar menu, and the Cmd+<digit>
    /// shortcuts all come here.
    ///
    /// From another view the tab is chosen first, in this turn, and the navigation then loads it once. Choosing
    /// it after arriving loaded the family's previous tab on the way (for Reports, built it), then the chosen
    /// one. Within the family it is the title-bar picker's switch, deferred past a menu's fade unless
    /// `immediate`.
    @MainActor
    func open(appState: AppState, immediate: Bool) {
        let item = family.sidebarItem
        guard appState.selectedSidebarItem != item else {
            select(immediate: immediate)
            return
        }
        if case .queue(let filter) = self {
            /// The Queue's tabs share one view, whose state and scroll keys follow the live filter, so setting
            /// it before the navigation is all the switch needs.
            FilmQueueFilterState.shared.preselect(filter)
        } else {
            select(immediate: true)
        }
        appState.navigate(to: item)
    }
}

/// Which library families are expanded. Remembered across launches
/// (Preferences.expandedLibraryFamilies).
@MainActor
@Observable
private final class LibraryFamilyExpansion {
    static let shared = LibraryFamilyExpansion()

    private var expanded: Set<SidebarLibraryFamily> = Preferences.expandedLibraryFamilies

    private init() {}

    func isExpanded(_ family: SidebarLibraryFamily) -> Binding<Bool> {
        Binding(
            get: { self.expanded.contains(family) },
            set: { isExpanded in
                if isExpanded { self.expanded.insert(family) } else { self.expanded.remove(family) }
                Preferences.expandedLibraryFamilies = self.expanded
            })
    }
}

// MARK: - Sidebar Selection Sync
/// Keeps the List's local selection and AppState in step, in both directions. A modifier of
/// its own so that the selection it reads invalidates only this, not LeftSidebar's body.
private struct SidebarSelectionSync: ViewModifier {
    @Environment(AppState.self) private var appState
    @Binding var localSelection: SidebarRow
    /// A user click: the selection moved away from what AppState displays.
    let onUserSelection: (SidebarRow, SidebarRow) -> Void

    func body(content: Content) -> some View {
        content
            /// Sync AppState -> LocalSelection (programmatic changes flow DOWN)
            .onChange(of: displayedSelection) { _, newValue in
                if localSelection != newValue {
                    localSelection = newValue
                }
            }
            /// Sync LocalSelection -> AppState (user clicks flow UP)
            .onChange(of: localSelection) { oldValue, newValue in
                if displayedSelection != newValue {
                    onUserSelection(oldValue, newValue)
                    /// A click that changes nothing on screen leaves the highlight where it was:
                    /// the row of an expanded library family already showing stays on its tab.
                    if localSelection != displayedSelection {
                        localSelection = displayedSelection
                    }
                }
            }
            .onAppear {
                /// Initialize local selection to match app state
                localSelection = displayedSelection
            }
    }

    /// The row the sidebar highlights. AppState holds only a smart list family's parent, so the
    /// displayed variant is read from SmartListVariantState. A variant inside a collapsed family
    /// is hidden, so nothing is highlighted until the family expands.
    ///
    /// Unwatched, Recents and Reports follow the smart lists: the family's row is its primary tab,
    /// and any other tab is its own row, unhighlighted while the family is collapsed.
    private var displayedSelection: SidebarRow {
        let item = appState.selectedSidebarItem
        if case .smartList(let parent) = item {
            return .item(.smartList(SmartListVariantState.shared(for: parent).selected))
        }
        if let family = SidebarLibraryFamily(item) {
            let current = family.currentTab
            return current == family.primaryTab ? .item(item) : .tab(current)
        }
        return .item(item)
    }
}

// MARK: - List Row Animation Key
/// What a sidebar list row displays, and so what its insertion, removal, rename, or
/// reorder animates on. See LeftSidebar's .animation.
private struct ListRowKey: Equatable {
    let listID: UUID
    let listName: String

    init(_ info: ListInfo) {
        listID = info.listID
        listName = info.listName
    }
}

// MARK: - List Row Action
/// The set of contextual-menu actions a list row can raise. Collapsing these into one
/// enum keeps ListsSection and ListRow to a single `onAction` closure each, instead of
/// five parallel closures declared and forwarded at every level.
private enum ListRowAction {
    case edit
    case duplicate
    case clearContents
    case deleteContents
    case delete
}

// MARK: - List Row Drop Highlight
/// Installs the AppKit drop and hover proxy for a sidebar row and paints the native-style drop
/// highlight. The "Queue" row and every ListRow use this pair. The proxy keeps the same
/// conditional shape whatever `isEnabled` is, so ListRow (always `true`) never reinstalls it.
private struct ListRowDropHighlight: ViewModifier {
    let listID: UUID
    let listName: String
    let dataCoordinator: DataCoordinator
    let isEnabled: Bool
    @Binding var isDropTargeted: Bool
    @Binding var isHovered: Bool

    func body(content: Content) -> some View {
        content
            .overlay(
                Group {
                    if isEnabled {
                        ListRowDropTarget(
                            listID: listID,
                            listName: listName,
                            dataCoordinator: dataCoordinator,
                            isDropTargeted: $isDropTargeted,
                            isHovered: $isHovered
                        )
                    }
                }
                .frame(width: 0, height: 0)
            )
            .listRowBackground(
                Group {
                    if isEnabled, isDropTargeted {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accentColor.opacity(0.3))
                            .padding(.horizontal, 10)
                    }
                }
            )
    }
}

// MARK: - Library Section Component
private struct LibrarySection: View {
    var importProgress = ImportProgress.shared

    /// The Imports row's icon: its own glyph normally, a checkmark once an import
    /// finishes cleanly, a warning triangle once one finishes with failures.
    ///
    /// Read straight from ImportProgress.completionStatus, which clears it however the user
    /// reaches the Imports view (ImportProgress.viewingImportsDidChange), and a moment after an
    /// import finishes while that view is showing. A new import resets it. The failure's durable
    /// record is on the session card; the badge only points the user there.
    private var importsGlyph: String {
        switch importProgress.completionStatus {
        case .success:           return ViewGlyphs.importsCompletion.outline
        case .successWithErrors: return ViewGlyphs.importsFailure.outline
        case .none:              return ViewGlyphs.imports.outline
        }
    }

    /// The Queue row's momentary completion glyph (ListRowActivityStore.queueActivity).
    private var queueActivity: ListRowActivity { ListRowActivityStore.shared.queueActivity }

    @Environment(DataCoordinator.self) private var dataCoordinator

    /// Mirrors the two Preferences keys governing the "Film Queue" sidebar row's
    /// drop-target behavior. @AppStorage keeps these reactive to changes made in
    /// Settings while this view is on screen.
    @AppStorage(preference: Preferences.queueIsDropTargetKey)
        private var queueIsDropTarget: Bool
    @AppStorage(preference: Preferences.queueSectionOnDropKey)
        private var queueSectionOnDropRaw: Int

    /// Drag and hover state for the "Film Queue" row, as in ListRow. isHovered is not displayed
    /// here but ListRowDropTarget requires it.
    @State private var isQueueDropTargeted = false
    @State private var isQueueHovered = false

    /// Resolves the currently-selected Film Queue section from the raw preference
    /// value, falling back to "Up Next" for any unrecognized/corrupt stored value.
    private var queueDropSection: Preferences.QueueDropSection {
        Preferences.QueueDropSection(rawValue: queueSectionOnDropRaw) ?? .upNext
    }

    var body: some View {
        Section("Library") {
            Label(LibraryItem.allFilms.title, systemImage: ViewGlyphs.allFilms.outline)
                .tag(SidebarRow.item(.libraryItem(.allFilms)))
            /// Unwatched, Recents and Reports, each a disclosure row over its own tabs, as the
            /// smart list families are. See SidebarLibraryFamily. The Queue is one too, below.
            ForEach(SidebarLibraryFamily.grouped, id: \.self) { family in
                DisclosureGroup(isExpanded: LibraryFamilyExpansion.shared.isExpanded(family)) {
                    childRows(of: family)
                } label: {
                    Label(family.title, systemImage: family.glyph)
                        .tag(SidebarRow.item(family.sidebarItem))
                }
            }
            HStack {
                Label {
                    Text(LibraryItem.imports.title)
                } icon: {
                    Image(systemName: importsGlyph)
                        .contentTransition(.symbolEffect(.replace))
                }
                Spacer()
                if importProgress.isImporting {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                        .transition(.opacity)
                }
            }
            .tag(SidebarRow.item(.libraryItem(.imports)))
            .animation(.easeInOut(duration: 0.2), value: importProgress.isImporting)

            /// The Queue's row is its All tab. Its three sections are child rows, as Recents' tabs are.
            DisclosureGroup(isExpanded: LibraryFamilyExpansion.shared.isExpanded(.queue)) {
                childRows(of: .queue)
            } label: {
                Label {
                    Text(SidebarLibraryFamily.queue.title)
                } icon: {
                    Image(systemName: queueActivity.showCompletionGlyph
                        ? ViewGlyphs.rowCompletion.outline
                        : ViewGlyphs.filmQueue.outline)
                        .contentTransition(.symbolEffect(.replace))
                }
                    .tag(SidebarRow.item(.libraryItem(.filmQueue)))
                    /// The shared row modifier targets the Film Queue section chosen in
                    /// Preferences.queueSectionOnDrop. With queueIsDropTarget off, isEnabled is false
                    /// and no proxy or highlight is installed.
                    .modifier(ListRowDropHighlight(
                        listID: queueDropSection.filmQueueSection.listID,
                        listName: queueDropSection.filmQueueSection.displayName,
                        dataCoordinator: dataCoordinator,
                        isEnabled: queueIsDropTarget,
                        isDropTargeted: $isQueueDropTargeted,
                        isHovered: $isQueueHovered
                    ))
            }
        }
    }

    /// A family's tab rows, under its own row.
    private func childRows(of family: SidebarLibraryFamily) -> some View {
        ForEach(family.childTabs, id: \.self) { tab in
            Label(tab.title, systemImage: tab.glyph)
                .tag(SidebarRow.tab(tab))
        }
    }
}

// MARK: - Smart Lists Section Component
/// Each family is a native disclosure row: the parent's row selects the parent list, its
/// triangle reveals the family's variants as indented child rows (familyVariants, the same
/// list the title-bar picker offers). Which families are expanded is remembered across
/// launches (Preferences.expandedSmartListFamilies).
private struct SmartListsSection: View {
    /// SmartListType.sidebarCases is the static source of truth. This view takes no
    /// DataCoordinator, so no unneeded @Observable subscription runs on each body evaluation.

    @State private var expanded: Set<SmartListType> = Preferences.expandedSmartListFamilies

    var body: some View {
        Section("Smart Lists") {
            ForEach(SmartListType.sidebarCases) { parent in
                /// A family with no variants (Upcoming Releases) is a plain row: a disclosure
                /// triangle over nothing would offer an expansion that reveals nothing.
                if parent.familyVariants.count > 1 {
                    DisclosureGroup(isExpanded: isExpanded(parent)) {
                        ForEach(parent.familyVariants.dropFirst()) { variant in
                            row(variant)
                        }
                    } label: {
                        row(parent)
                    }
                } else {
                    row(parent)
                }
            }
        }
    }

    private func row(_ type: SmartListType) -> some View {
        Label {
            Text(type.rawValue)
        } icon: {
            Image(systemName: type.icon)
        }
        .tag(SidebarRow.item(.smartList(type)))
    }

    private func isExpanded(_ parent: SmartListType) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(parent) },
            set: { isExpanded in
                if isExpanded { expanded.insert(parent) } else { expanded.remove(parent) }
                Preferences.expandedSmartListFamilies = expanded
            })
    }
}

// MARK: - Lists Section Component
private struct ListsSection: View {
    
    let lists: [ListInfo]
    let dataCoordinator: DataCoordinator
    let onAction: (ListRowAction, UUID) -> Void
    let onMove: (IndexSet, Int) -> Void

    var body: some View {
        Section("Lists") {
            ForEach(lists) { listInfo in
                ListRow(
                    listInfo: listInfo,
                    dataCoordinator: dataCoordinator,
                    onAction: { onAction($0, listInfo.listID) }
                )
            }
            .onMove(perform: onMove)
        }
    }
}

// MARK: - List Row Component
private struct ListRow: View {
    
    let listInfo: ListInfo
    let dataCoordinator: DataCoordinator
    let onAction: (ListRowAction) -> Void

    /// This row's spinner and completion glyph, driven by ListRowActivityStore's shared subscription.
    private var activity: ListRowActivity { ListRowActivityStore.shared.activity(for: listInfo.listID) }

    /// Hover state, which shows the options button.
    @State private var isHovered = false

    /// Drag-and-drop state
    @State private var isDropTargeted = false

    /// The trailing accessory slot shows one item at a time:
    ///   • spinner: while an operation runs (takes priority)
    ///   • ellipsis: while the cursor hovers and nothing runs
    ///
    /// Both use the same fixed slot, rendered as an overlay on the title (see `body`).
    @ViewBuilder
    private var trailingAccessory: some View {
        if activity.showProgressIndicator {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: RowAccessory.slotWidth, height: RowAccessory.slotWidth)
                .transition(.opacity)
        } else if isHovered {
            RowOptionsButton(help: "List Options") { contextMenuItems() }
        }
    }

    /// True while the trailing slot is occupied. The title's trailing inset follows this, so
    /// the title runs the full row width until an accessory appears and truncates further
    /// only for as long as one is showing.
    private var isAccessoryShowing: Bool { activity.showProgressIndicator || isHovered }

    var body: some View {
        Label {
            /// The title is JUST the text, laid out as though no accessory existed; the
            /// accessory is layered over it and reserved for by a constant trailing inset.
            ///
            /// The accessory is an overlay, not an HStack sibling. A view entering or leaving a
            /// stack shifts the stack's baseline, so the icon jiggled on every hover. An overlay
            /// is outside the layout, so it cannot move the icon. The trailing inset that makes
            /// room for it applies only while it shows. It changes only the title's width, so the
            /// icon stays put. The change is unanimated on purpose.
            Text(listInfo.listName)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, isAccessoryShowing ? RowAccessory.slotWidth + 4 : 0)
                .animation(nil, value: isAccessoryShowing)
                .overlay(alignment: .trailing) { trailingAccessory }
        } icon: {
            Image(systemName: activity.showCompletionGlyph ? ViewGlyphs.rowCompletion.outline : ViewGlyphs.userList.outline)
                .contentTransition(.symbolEffect(.replace))
        }
        .tag(SidebarRow.item(.list(listInfo.listID)))
        /// Secondary-click anywhere on the row opens the same menu as the ellipsis button.
        .contextMenu {
            contextMenuItems()
        }
        /// ListRowDropTarget is a zero-size anchor. It installs a RowDragProxyView on the
        /// NSTableRowView, covering the full row. That proxy supplies hover state and drag
        /// callbacks, since .onHover covers only the inset content. User lists are always
        /// drop targets, so isEnabled is true.
        .modifier(ListRowDropHighlight(
            listID: listInfo.listID,
            listName: listInfo.listName,
            dataCoordinator: dataCoordinator,
            isEnabled: true,
            isDropTargeted: $isDropTargeted,
            isHovered: $isHovered
        ))
    }

    // MARK: - Context Menu Items
    /// Shared by the secondary-click .contextMenu and the ellipsis Menu, so both stay identical.
    @ViewBuilder
    private func contextMenuItems() -> some View {
        Button("Clear List Contents") {
            onAction(.clearContents)
        }
        .disabled(listInfo.filmCount == 0)

        Button("Delete All List Contents from Library") {
            onAction(.deleteContents)
        }
        .disabled(listInfo.filmCount == 0)

        Divider()

        Button("Duplicate List") {
            onAction(.duplicate)
        }

        Button("Edit List Name…") {
            onAction(.edit)
        }

        Button("Remove List") {
            onAction(.delete)
        }
    }
}

// MARK: - Row Accessory
/// The trailing accessory slot ListRow and SavedSearchRow share: the options button, or ListRow's spinner.
private enum RowAccessory {
    static let slotWidth: CGFloat = 18
}

// MARK: - Row Options Button
/// The chromeless ellipsis a hovered ListRow or SavedSearchRow shows in its trailing slot. The glyph is a
/// plain Image, so it takes the row's selection and focus coloring like the row's text. An invisible,
/// identically sized Menu on top catches the click and presents the row's menu.
///
/// The row shows this only while hovered, so the press state is dropped with it when the cursor leaves.
private struct RowOptionsButton<Items: View>: View {
    let help: String
    @ViewBuilder let items: () -> Items

    @State private var isPressed = false

    var body: some View {
        Image(systemName: "ellipsis.circle")
            .frame(width: RowAccessory.slotWidth, height: RowAccessory.slotWidth)
            /// Dims the glyph on mouse-down and restores it on release.
            .opacity(isPressed ? 0.4 : 1.0)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            .overlay {
                Menu { items() } label: { Color.clear }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: RowAccessory.slotWidth, height: RowAccessory.slotWidth)
                    .focusable(false)
                    .focusEffectDisabled()
            }
            /// Drives the opacity feedback only. It does not consume the tap, so the Menu still gets the click.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false })
            .help(help)
    }
}

// MARK: - Saved Search Row Animation Key
private struct SavedSearchRowKey: Equatable {
    let id: UUID
    let name: String

    init(_ search: SavedSearch) {
        id = search.id
        name = search.name
    }
}

// MARK: - Saved Searches Section Component
/// One row per saved search, in the order the user dragged them into. A row opens the
/// search's own gallery view (ViewIdentifier.savedSearch); its menu edits it, opens it in
/// the search field, duplicates or removes it. Not a drop target: films cannot be added to
/// a query.
private struct SavedSearchesSection: View {
    private var store: SavedSearchStore { .shared }

    var body: some View {
        Section("Saved Searches") {
            ForEach(store.searches) { search in
                SavedSearchRow(search: search)
            }
            .onMove { store.move(fromOffsets: $0, toOffset: $1) }
        }
    }
}

// MARK: - Tags Section Component
/// The library's most-used tags (SidebarTags.mostUsed), `count` of them, most-used first. A row
/// opens the gallery of the films carrying its tag (ViewIdentifier.tag), as a smart list row
/// opens its own. Not a drop target, and no menu.
///
/// The rows come from SidebarTagRows, so the sidebar's own body does not read the library.
private struct TagsSection: View {
    var body: some View {
        Section("Tags") {
            ForEach(SidebarTagRows.shared.tags, id: \.self) { tag in
                Label {
                    Text(tag)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } icon: {
                    Image(systemName: ViewGlyphs.tag.outline)
                }
                .tag(SidebarRow.item(.tag(SidebarTag(tag))))
            }
        }
    }
}

// MARK: - Tag Rows
/// The Tags section's rows: the `limit` most-used tags (SidebarTags.mostUsed), none while the
/// section is hidden (limit 0). Held here rather than in TagsSection so the sidebar can leave the
/// section out while it is empty, and so the recount triggers (SidebarTagRecount) sit on the List,
/// which is always on screen, not on rows that may not be.
@MainActor
@Observable
private final class SidebarTagRows {
    static let shared = SidebarTagRows()

    private(set) var tags: [String] = []
    /// Whether there are any rows, read by LeftSidebar's body on its own, so a change of tags that
    /// leaves some invalidates only TagsSection.
    private(set) var hasTags = false

    @ObservationIgnored private var limit = 0
    @ObservationIgnored private var recountPending = false

    private init() {}

    func recount(limit: Int, in coordinator: DataCoordinator) {
        self.limit = limit
        let ranked = limit > 0 ? SidebarTags.mostUsed(limit, in: coordinator) : []
        guard ranked != tags else { return }
        /// The first fill, as the sidebar appears, lands at once; later changes animate.
        if tags.isEmpty {
            apply(ranked)
        } else {
            withAnimation(.default) { apply(ranked) }
        }
    }

    /// Film events arrive one per film from an import or bulk edit; a burst is recounted once, a
    /// turn after the first, at the limit current then.
    func scheduleRecount(in coordinator: DataCoordinator) {
        guard limit > 0, !recountPending else { return }
        recountPending = true
        DispatchQueue.main.async {
            self.recountPending = false
            self.recount(limit: self.limit, in: coordinator)
        }
    }

    private func apply(_ ranked: [String]) {
        tags = ranked
        hasTags = !ranked.isEmpty
    }
}

/// Keeps SidebarTagRows current: on appearing, when the section's length changes, and when the
/// films change. A modifier of its own so that the film counts it reads invalidate only this.
private struct SidebarTagRecount: ViewModifier {
    /// The section's length, 0 while it is hidden.
    let limit: Int

    @Environment(DataCoordinator.self) private var dataCoordinator

    func body(content: Content) -> some View {
        content
            .onAppear { recount() }
            .onChange(of: limit) { recount() }
            .onChange(of: dataCoordinator.isInitialized) { recount() }
            .onChange(of: dataCoordinator.totalFilmCount) { recount() }
            .onFilmEvent { event in
                if case .releaseChanged = event { return }
                SidebarTagRows.shared.scheduleRecount(in: dataCoordinator)
            }
    }

    private func recount() {
        SidebarTagRows.shared.recount(limit: limit, in: dataCoordinator)
    }
}

// MARK: - Saved Search Row Component
private struct SavedSearchRow: View {
    let search: SavedSearch

    @Environment(DataCoordinator.self) private var dataCoordinator

    /// Hover state, which shows the options button, as ListRow's.
    @State private var isHovered = false
    /// Required by the row proxy's interface; a saved search row never becomes a drop target.
    @State private var isDropTargeted = false

    var body: some View {
        /// Laid out as ListRow is — the ellipsis an overlay on the title, reserved for by a
        /// trailing inset only while it shows — for the same reason: the icon must not move.
        Label {
            Text(search.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, isHovered ? RowAccessory.slotWidth + 4 : 0)
                .animation(nil, value: isHovered)
                .overlay(alignment: .trailing) {
                    if isHovered {
                        RowOptionsButton(help: "Saved Search Options") { menuItems() }
                    }
                }
        } icon: {
            Image(systemName: ViewGlyphs.savedSearch.outline)
        }
        .tag(SidebarRow.item(.savedSearch(search.id)))
        .contextMenu { menuItems() }
        /// The list rows' full-row hover tracking (see ListRow), with drops turned off.
        .overlay(
            ListRowDropTarget(listID: search.id, listName: search.name, dataCoordinator: dataCoordinator,
                              isDropTargeted: $isDropTargeted, isHovered: $isHovered, acceptsDrops: false)
                .frame(width: 0, height: 0))
    }

    /// Shared by the context menu and the ellipsis, as ListRow's are.
    @ViewBuilder
    private func menuItems() -> some View {
        Button("Edit Saved Search…") { SavedSearchActions.edit(search.id) }
        Button("Duplicate Saved Search…") { SavedSearchActions.duplicate(search.id) }
        Button("Open in Search Field") { SavedSearchActions.openInSearchField(search.id) }
        Divider()
        Button("Remove Saved Search") { SavedSearchActions.delete(search.id) }
    }
}

// MARK: - List Row Activity
/// A list row's transient feedback: the spinner shown once an operation on it has run for a
/// moment, and the momentary completion glyph. One per list, kept by ListRowActivityStore,
/// so a row reads (and is invalidated by) only its own.
@MainActor
@Observable
private final class ListRowActivity {
    var showProgressIndicator = false
    var showCompletionGlyph = false

    @ObservationIgnored fileprivate var isOperationInProgress = false
    @ObservationIgnored fileprivate var progressDelayTask: Task<Void, Never>?
    @ObservationIgnored fileprivate var completionTask: Task<Void, Never>?

    func operationStarted() {
        isOperationInProgress = true

        progressDelayTask?.cancel()
        progressDelayTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled, self.isOperationInProgress else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                self.showProgressIndicator = true
            }
        }
    }

    func operationCompleted(showGlyph: Bool) {
        isOperationInProgress = false
        progressDelayTask?.cancel()

        if showProgressIndicator {
            withAnimation(.easeOut(duration: 0.2)) {
                showProgressIndicator = false
            }
        }

        if showGlyph { flashCompletionGlyph() }
    }

    /// Shows the completion glyph for two seconds. A second completion restarts the interval.
    func flashCompletionGlyph() {
        completionTask?.cancel()
        showCompletionGlyph = true
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.showCompletionGlyph = false
        }
    }

    func cancel() {
        progressDelayTask?.cancel()
        completionTask?.cancel()
    }
}

/// Routes listEvents to the one row each event names. Activity outlives a row's cell, so a
/// scrolled or rebuilt row keeps its spinner until its list is deleted.
@MainActor
private final class ListRowActivityStore {
    static let shared = ListRowActivityStore()

    private var activities: [UUID: ListRowActivity] = [:]
    /// The Queue row's: only its completion glyph, for an addition to any of the Queue's sections
    /// (.queueAdditionCompleted, never a removal).
    let queueActivity = ListRowActivity()
    private var cancellable: AnyCancellable?

    private init() {
        /// AppEventBus is @MainActor, so this sink runs synchronously on the main actor.
        cancellable = AppEventBus.shared.listEvents.sink { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    func activity(for listID: UUID) -> ListRowActivity {
        if let existing = activities[listID] { return existing }
        let created = ListRowActivity()
        activities[listID] = created
        return created
    }

    private func handle(_ event: ListEvent) {
        switch event {
        case .operationStarted(let listID):
            activity(for: listID).operationStarted()
        case .operationCompleted(let listID):
            /// Only show the completion glyph when the user is NOT currently viewing this
            /// list — if they are, the change is self-evident.
            let isViewing = AppDelegate.appState?.selectedSidebarItem == .list(listID)
            activity(for: listID).operationCompleted(showGlyph: !isViewing)
        case .queueAdditionCompleted:
            /// Likewise not while the Queue is on screen.
            if AppDelegate.appState?.selectedSidebarItem != .libraryItem(.filmQueue) {
                queueActivity.flashCompletionGlyph()
            }
        case .deleted(let listID):
            activities.removeValue(forKey: listID)?.cancel()
        default:
            break
        }
    }
}

// MARK: - AppKit Drop Target
/// An NSViewRepresentable used as a lifecycle anchor in the SwiftUI cell. On attachment it
/// installs a RowDragProxyView on NSTableRowView, which owns the full row highlight. SwiftUI
/// content is inset from that view, so the proxy must attach there to cover the whole row.
private struct ListRowDropTarget: NSViewRepresentable, Loggable {
    nonisolated static let logTag = "[LeftSidebar]"

    let listID: UUID
    let listName: String
    let dataCoordinator: DataCoordinator
    @Binding var isDropTargeted: Bool
    @Binding var isHovered: Bool
    /// False for a row that only wants the full-row hover tracking (a saved search: films
    /// cannot be dropped onto a query). Its proxy then registers for no drag types, so a
    /// drag passes over it as over any unregistered view.
    var acceptsDrops = true

    func makeNSView(context: Context) -> DropTargetAnchorView {
        let view = DropTargetAnchorView()
        /// Seed initial values; updateNSView also runs immediately after makeNSView.
        view.acceptsDrops = acceptsDrops
        view.listID = listID
        view.listName = listName
        view.dataCoordinator = dataCoordinator
        view.onTargetChanged = { isTargeted in
            self.isDropTargeted = isTargeted
        }
        view.onHoverChanged = { hovering in
            self.isHovered = hovering
        }
        return view
    }
    
    func updateNSView(_ nsView: DropTargetAnchorView, context: Context) {
        /// Always keep the anchor's cached values current. The anchor copies them
        /// to the proxy in viewDidMoveToWindow; updates after that go direct to proxy.
        nsView.listID = listID
        nsView.listName = listName
        nsView.dataCoordinator = dataCoordinator
        /// Also update proxy directly for the rename / reuse case where proxy exists —
        /// but only while this anchor still owns it. A recycled row view can lend its
        /// proxy to a newly arrived anchor before this one has left; writing this row's
        /// list into it then would send drops on the other row to this list.
        guard let proxy = nsView.proxy, proxy.owner === nsView else { return }
        proxy.listID = listID
        proxy.listName = listName
        proxy.dataCoordinator = dataCoordinator
    }
    
    // MARK: - Anchor View
    /// Zero-size. It manages the RowDragProxyView's lifecycle and caches the values needed to seed
    /// the proxy, because updateNSView runs before the proxy exists.
    @MainActor
    final class DropTargetAnchorView: NSView, Loggable {
        nonisolated static let logTag = "[LeftSidebar]"

        var listID: UUID = UUID()
        var listName: String = ""
        var acceptsDrops = true
        weak var dataCoordinator: DataCoordinator?
        var onTargetChanged: ((Bool) -> Void)?
        var onHoverChanged: ((Bool) -> Void)?
        /// Weak reference so the proxy's own removal from NSTableRowView releases it.
        weak var proxy: RowDragProxyView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            /// viewDidMoveToWindow fires once the full view hierarchy exists. viewDidMoveToSuperview is too
            /// early: the NSTableRowView ancestor is not yet reachable, so no proxy would be created.
            guard unsafe window != nil else { return }
            guard proxy == nil,
                  let rowView = findAncestor(ofType: NSTableRowView.self) else { return }
            /// NSOutlineView recycles row views as the sidebar scrolls. The proxy stays with its row view
            /// and is lent to whichever anchor arrives, rather than being rebuilt for every row.
            let existing = rowView.subviews.lazy.compactMap { $0 as? RowDragProxyView }.first
            let p = existing ?? RowDragProxyView()
            if existing == nil {
                rowView.addSubview(p, positioned: .below, relativeTo: nil)
                p.frame = rowView.bounds
            }
            p.activate(for: self)
            proxy = p
            Self.noteProxy(created: existing == nil)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            /// The anchor leaves its window when its cell is recycled for another row,
            /// when the row is deleted, or when the sidebar is torn down.
            if newWindow == nil { releaseProxy() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewWillMove(toSuperview newSuperview: NSView?) {
            if newSuperview == nil { releaseProxy() }
            super.viewWillMove(toSuperview: newSuperview)
        }

        /// Returns the proxy to its row view, inert until the next anchor claims it. One
        /// already claimed by another anchor (whose cell arrived first) is left alone.
        private func releaseProxy() {
            guard let p = proxy else { return }
            if p.owner === self { p.deactivate() }
            proxy = nil
        }

        // MARK: Proxy digest
        /// Proxies are created once per row view. The digest should show creations only as the sidebar
        /// first fills, and reuses while scrolling. One line is written per burst.
        private static var createdTotal = 0
        private static var createdSinceDigest = 0
        private static var reusedSinceDigest = 0
        private static var isDigestScheduled = false
        /// How long a burst may run before its digest is written.
        private static let digestDelay: TimeInterval = 0.5

        private static func noteProxy(created: Bool) {
            if created {
                createdTotal += 1
                createdSinceDigest += 1
            } else {
                reusedSinceDigest += 1
            }
            guard !isDigestScheduled else { return }
            isDigestScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + digestDelay) {
                isDigestScheduled = false
                /// A reuse-only burst is ordinary scrolling; only creations are worth a line.
                if createdSinceDigest > 0 {
                    log("RowDragProxyViews: \(createdTotal) created "
                        + "(+\(createdSinceDigest) new, \(reusedSinceDigest) reused since last digest)")
                }
                createdSinceDigest = 0
                reusedSinceDigest = 0
            }
        }

        /// Walk up the superview chain looking for a specific NSView subclass.
        private func findAncestor<T: NSView>(ofType type: T.Type) -> T? {
            var current: NSView? = unsafe superview
            while let view = current {
                if let match = view as? T { return match }
                current = unsafe view.superview
            }
            return nil
        }
    }

    // MARK: - Row Drag Proxy View
    /// Attached directly to NSTableRowView and always sized to fill it. It handles the full
    /// NSDraggingDestination protocol for this row. NSHostingView does not register for filmIDs,
    /// so the drag hit test falls through to this proxy, the only registered view in the padding.
    @MainActor
    final class RowDragProxyView: NSView, Loggable {
        nonisolated static let logTag = "[LeftSidebar]"

        var listID: UUID = UUID()
        var listName: String = ""
        weak var dataCoordinator: DataCoordinator?
        var onTargetChanged: ((Bool) -> Void)?
        var onHoverChanged: ((Bool) -> Void)?

        /// The anchor whose row this proxy currently serves; nil while the row view sits
        /// unused in the outline view's reuse pool.
        private(set) weak var owner: DropTargetAnchorView?

        /// Takes on `anchor`'s row: its list, callbacks, and whether it accepts drops.
        func activate(for anchor: DropTargetAnchorView) {
            owner = anchor
            Self.activeProxies.add(self)
            listID = anchor.listID
            listName = anchor.listName
            dataCoordinator = anchor.dataCoordinator
            onTargetChanged = anchor.onTargetChanged
            onHoverChanged = anchor.onHoverChanged
            if anchor.acceptsDrops { registerForDraggedTypes([.filmIDs]) } else { unregisterDraggedTypes() }
            /// A drag already over this proxy now targets the arriving row, so the highlight moves to it,
            /// or ends when that row takes no drops.
            if isDropTargetReported {
                if anchor.acceptsDrops { reportTarget(true) } else { isDropTargetReported = false }
            }
            reconcileHover()
        }

        /// Clears the departing row's state so the proxy reports nothing for it.
        func deactivate() {
            setHovered(false)
            /// The departing row loses any drop highlight a drag over this proxy gave it. Otherwise it
            /// stays lit, since the drag's exit and end callbacks reach only the next owner.
            if isDropTargetReported { reportTarget(false) }
            owner = nil
            Self.activeProxies.remove(self)
            onTargetChanged = nil
            onHoverChanged = nil
            unregisterDraggedTypes()
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            /// No layer, no drawing — fully transparent. Exists only for drag protocol
            /// and hover tracking.
            registerForDraggedTypes([.filmIDs])
            /// One tracking area for the proxy's life. `.inVisibleRect` keeps it matched to the visible
            /// bounds, so it is never replaced while the cursor is inside. Replacing it would drop the
            /// mouseExited for the old area and leave the row's hover state stuck.
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

        /// Keep frame = superview.bounds through every AppKit layout cycle.
        override func layout() {
            super.layout()
            if let sv = unsafe superview, frame != sv.bounds {
                frame = sv.bounds
            }
        }

        // MARK: Hover reconciliation
        ///
        /// Enter and exit events alone are not reliable. AppKit sends no mouseExited when a row scrolls
        /// under a still cursor, when the app deactivates, while an ellipsis menu tracks the mouse, or
        /// when the proxy is removed mid-hover. So hover belongs to one row at a time, and each of these
        /// moments re-derives it from the actual cursor position.

        /// The one row currently reporting hover. Entering another row clears it.
        private static weak var hoveredProxy: RowDragProxyView?
        private static var observersInstalled = false

        // MARK: Live scroll
        ///
        /// Rows report no hover while the sidebar live-scrolls, as Finder's do. Otherwise each row that
        /// passes under a still cursor would build and tear down its ellipsis button. Hover is re-derived
        /// once the scroll ends.

        /// The sidebar's scroll view. Scroll notifications from any other scroll view in
        /// the app (the gallery, the list view, sheets) are ignored.
        private static weak var sidebarScrollView: NSScrollView?
        private static var isLiveScrolling = false
        /// Proxies currently serving a row — the ones re-derived when a scroll ends.
        private static let activeProxies = NSHashTable<RowDragProxyView>.weakObjects()

        private var isHoverReported = false

        private func setHovered(_ hovering: Bool) {
            let hovering = hovering && !Self.isLiveScrolling
            if hovering {
                if let other = Self.hoveredProxy, other !== self { other.setHovered(false) }
                Self.hoveredProxy = self
            } else if Self.hoveredProxy === self {
                Self.hoveredProxy = nil
            }
            guard hovering != isHoverReported else { return }
            isHoverReported = hovering
            onHoverChanged?(hovering)
        }

        /// Re-derives this row's hover state from the live cursor position.
        fileprivate func reconcileHover() {
            guard let window = unsafe window, NSApp.isActive, window.isVisible,
                  (unsafe superview) != nil else {
                setHovered(false)
                return
            }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            setHovered(visibleRect.contains(point))
        }

        /// Reconciles the currently hovered row, if any.
        private static func reconcileCurrent() {
            hoveredProxy?.reconcileHover()
        }

        /// Whether a notification's object (passed as its identity, which is Sendable) is
        /// the sidebar's scroll view.
        private static func isSidebar(_ object: ObjectIdentifier?) -> Bool {
            guard let object, let sidebarScrollView else { return false }
            return object == ObjectIdentifier(sidebarScrollView)
        }

        private static func installObserversIfNeeded() {
            guard !observersInstalled else { return }
            observersInstalled = true
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSApplication.didResignActiveNotification,
                NSApplication.didBecomeActiveNotification,
                NSMenu.didEndTrackingNotification,
                NSWindow.didResignKeyNotification,
            ]
            for name in names {
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { reconcileCurrent() }
                }
            }
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main) { note in
                let object = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard isSidebar(object) else { return }
                    isLiveScrolling = true
                    hoveredProxy?.setHovered(false)
                }
            }
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: nil, queue: .main) { note in
                let object = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard isSidebar(object) else { return }
                    isLiveScrolling = false
                    /// The row under the cursor now is not the one it was over when the
                    /// scroll began, so every row serving one is asked; only the one the
                    /// cursor is in reports hover.
                    for proxy in activeProxies.allObjects { proxy.reconcileHover() }
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Self.installObserversIfNeeded()
            if let scrollView = enclosingScrollView { Self.sidebarScrollView = scrollView }
            /// The proxy is never removed from its row view; it leaves the window with it.
            if unsafe window == nil { setHovered(false) }
        }

        override func mouseEntered(with event: NSEvent) {
            setHovered(true)
        }

        override func mouseExited(with event: NSEvent) {
            setHovered(false)
        }

        // MARK: - NSDraggingDestination

        /// True while this proxy has reported a drag over it as a drop target to its owner. It lets the
        /// highlight follow the proxy when its row view is lent to another row mid-drag (see activate and
        /// deactivate), and keeps a proxy whose new row takes no drops from accepting one.
        private var isDropTargetReported = false

        /// Reports the drop-target state to the current owner. The write is deferred one turn, because
        /// activate and deactivate run while the outline view moves row views, which can be inside a
        /// SwiftUI update, where a synchronous state write is not allowed.
        private func reportTarget(_ isTargeted: Bool) {
            isDropTargetReported = isTargeted
            guard let onTargetChanged else { return }
            DispatchQueue.main.async { onTargetChanged(isTargeted) }
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard sender.draggingPasteboard.availableType(from: [.filmIDs]) != nil else {
                return []
            }
            isDropTargetReported = true
            onTargetChanged?(true)
            return .copy
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            isDropTargetReported ? .copy : []
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            isDropTargetReported = false
            onTargetChanged?(false)
        }

        override func draggingEnded(_ sender: any NSDraggingInfo) {
            isDropTargetReported = false
            onTargetChanged?(false)
        }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            isDropTargetReported && sender.draggingPasteboard.availableType(from: [.filmIDs]) != nil
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            /// Decodes through the shared FilmDragDecoder, which adds logging.
            guard let filmIDs = FilmDragDecoder.decode(from: sender),
                  !filmIDs.isEmpty,
                  let coordinator = dataCoordinator,
                  let list = coordinator.getList(listID) else {
                return false
            }

            /// Only the films not already in this list. The rest are where the user dropped them, so they
            /// take no part in the capacity check, the confirmation, or the add. A drop with none is
            /// refused, so the preview flies back and the row shows no completion glyph, as an "Up Next"
            /// slot does (UpNextSlots.performDrop).
            let newcomers = filmIDs.subtracting(list.filmIDs)
            guard !newcomers.isEmpty else {
                log("Refused drop of \(filmIDs.count) film(s) on '\(listName)' — all already in it")
                return false
            }

            /// "Up Next" holds at most eight films. A drop that would overflow is not added there. The
            /// alert offers "Soon" instead. The drop is still accepted, so the preview does not fly back.
            if listID == FilmQueueSection.upNext.listID,
               FilmQueue.upNextOverflow(adding: newcomers, coordinator: coordinator) > 0 {
                log("Drop of \(newcomers.count) film(s) on '\(listName)' would overflow it — offering 'Soon'")
                /// Adding films already in "Up Next" to "Soon" would move them out of it, so only the
                /// newcomers are offered.
                AppEventBus.shared.sendAlert(.offerSoonForFullUpNextDrop(
                    filmIDs: newcomers,
                    message: FilmQueue.upNextFullDropOfferMessage(newcomers, coordinator: coordinator)))
                return true
            }

            /// Special-sorting confirmation gate, using the same rule as the Add to Queue menus and the
            /// FilmSheet picker. It applies only to the three internal Film Queue lists. If a dropped film has
            /// a specialSorting value, the add waits for AlertHostView's confirmation. Canceling drops the
            /// whole drop, and confirming adds the full set.
            if FilmQueue.isInternalList(listID),
               FilmQueue.addNeedsConfirmation(newcomers, coordinator: coordinator) {
                log("Deferring add of \(newcomers.count) film(s) to list '\(listName)' pending special-sorting confirmation")
                /// Sent synchronously, on the same call stack as the drop. AlertHostView stashes the payload and
                /// freezes the message at drop time. It presents the alert only when the .dragSessionDidEnd notice
                /// arrives. AppKit defers that callback past its drag-completion pass, so the alert animates without
                /// contention. Presenting here would drop frames, and sending now ensures the stash exists in time.
                AppEventBus.shared.sendAlert(.confirmFilmQueueAddOnDrop(filmIDs: newcomers, listID: listID))
                return true
            }

            log("Adding \(newcomers.count) film(s) to list '\(listName)'")

            /// Called synchronously, not in Task { ... }. performDragOperation runs inside the drag session's
            /// event-tracking loop, which defers main-actor continuations until the session ends. A Task would
            /// run only after AppKit's completion pass, roughly a second later. A synchronous call lets the
            /// membership change and its events post before teardown begins.
            FilmManager.addFilmsToList(newcomers, listID: listID, coordinator: coordinator)
            return true
        }

        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
            isDropTargetReported = false
            onTargetChanged?(false)
            /// Dismisses the drag-preview flyback window in step with the highlight clearing. AppKit defers
            /// the endedAt callback past its completion pass, which would leave a visible lag. GalleryDragEngine
            /// observes this notification and calls dismissFlybackImmediately().
            NotificationCenter.default.post(name: .dismissDragPreviewImmediately, object: nil)
        }
    }
}
