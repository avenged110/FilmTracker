// MARK: - LeftSidebar.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Navigation sidebar showing Library sections and user-created Lists.
//
// The sidebar lists the library's smart lists, Film Queue, Reports, Imports, and user lists.
// Its selection drives the gallery, and it also accepts drops onto lists and the Queue.

import SwiftUI
import AppKit
import Combine

struct LeftSidebar: View, Loggable {
    nonisolated static let logTag = "[LeftSidebar]"

    @Environment(AppState.self) private var appState
    @Environment(DataCoordinator.self) private var dataCoordinator

    @State private var importsGlyphState: ImportsGlyphState = .normal
    
    // Local selection state - isolates the List binding from AppState
    @State private var localSelection: SidebarItem = .libraryItem(.allFilms)
    
    // Monitor Preferences.smartLists for real-time updates
    @AppStorage(preference: Preferences.smartListsKey) private var smartListsEnabled: Bool

    var body: some View {
        List(selection: $localSelection) {
            LibrarySection(importsGlyphState: importsGlyphState)
            
            if smartListsEnabled {
                SmartListsSection()
            }
            
            ListsSection(
                lists: dataCoordinator.cachedLists,
                dataCoordinator: dataCoordinator,
                onAction: performListAction,
                onMove: moveItems
            )

            // Shown once there is something in it.
            if !SavedSearchStore.shared.searches.isEmpty {
                SavedSearchesSection()
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
        // Animates list insertions, deletions, renames, and reorders. Keyed on what the rows
        // show, not on cachedLists, which also carries film counts that no row displays.
        .animation(.default, value: dataCoordinator.cachedLists.map(ListRowKey.init))
        // Keyed on what the rows show, as ListRowKey is.
        .animation(.default, value: SavedSearchStore.shared.searches.map(SavedSearchRowKey.init))
        // Both selection syncs live in their own modifier. Applied here, every click would
        // re-evaluate this body and every ListRow. See SidebarSelectionSync.
        .modifier(SidebarSelectionSync(
            localSelection: $localSelection,
            onUserSelection: { oldValue, newValue in
                Self.log("User selection: \(String(describing: oldValue)) → \(String(describing: newValue))")
                if case .smartList(let type) = newValue {
                    selectSmartList(type)
                } else {
                    appState.navigate(to: newValue)
                }
                handleSelectionChange(newValue: newValue)
            }))
        .onChange(of: smartListsEnabled) { _, isEnabled in
            // If smart lists are disabled and we're viewing one, switch to All Films
            if !isEnabled, case .smartList = appState.selectedSidebarItem {
                appState.navigate(to: .libraryItem(.allFilms))
            }
        }
        .onAppear {
            ListRowActivityStore.shared.attach(appState)
        }
        // No initialization task is needed. cachedLists is filled synchronously in
        // finalizeInitialization(), so the rows appear in the same frame as the grid.
        .setupEvents(appState: appState,
            importsGlyphState: $importsGlyphState)
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

    /// Side effects of a user-driven selection change. The .onChange handler above already logs
    /// the transition, so only the cases that need action appear here.
    private func handleSelectionChange(newValue: SidebarItem) {
        switch newValue {
        case .libraryItem(.imports):
            // Clear the imports glyph state when navigating to Imports.
            if importsGlyphState.isFinished {
                importsGlyphState = .normal
            }
        case .list(let id):
            if !ListManager.listExists(id, coordinator: dataCoordinator) {
                log("WARNING: Selected list \(id) does not exist")
            }
        default:
            break
        }
    }

    /// Single entry point for every ListRow contextual-menu action.
    private func performListAction(_ action: ListRowAction, _ listID: UUID) {
        switch action {
        case .edit:
            // Request the list manager sheet for editing via UICommand;
            // SheetHostView handles the actual presentation.
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
        // Gated by the "list contents" class of the list-edit confirmation preference.
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
        // Film IDs are fetched synchronously, since getFilmIDsForListDeletion reads MemoryStore
        // directly.
        let filmIDs = ListManager.getFilmIDsForListDeletion(listID, coordinator: dataCoordinator)

        guard !filmIDs.isEmpty else {
            // The list became empty since the menu gesture, for example after a prior deletion.
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
        // Gated by the "list structure" class of the list-edit confirmation preference.
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
        // batchUpdateListOrders applies an optimistic update and calls syncListsCache(), so the
        // sidebar updates immediately through @Observable.
        Task {
            ListManager.reorderLists(from: source, to: destination,
                coordinator: dataCoordinator)
        }
    }
}

// MARK: - Sidebar Selection Sync
// Keeps the List's local selection and AppState in step, in both directions. A modifier of
// its own so that the selection it reads invalidates only this, not LeftSidebar's body.
private struct SidebarSelectionSync: ViewModifier {
    @Environment(AppState.self) private var appState
    @Binding var localSelection: SidebarItem
    /// A user click: the selection moved away from what AppState displays.
    let onUserSelection: (SidebarItem, SidebarItem) -> Void

    func body(content: Content) -> some View {
        content
            // Sync AppState -> LocalSelection (programmatic changes flow DOWN)
            .onChange(of: displayedSelection) { _, newValue in
                if localSelection != newValue {
                    localSelection = newValue
                }
            }
            // Sync LocalSelection -> AppState (user clicks flow UP)
            .onChange(of: localSelection) { oldValue, newValue in
                if displayedSelection != newValue {
                    onUserSelection(oldValue, newValue)
                }
            }
            .onAppear {
                // Initialize local selection to match app state
                localSelection = displayedSelection
            }
    }

    /// The row the sidebar highlights. AppState holds only a smart list family's parent, so the
    /// displayed variant is read from SmartListVariantState. A variant inside a collapsed family
    /// is hidden, so nothing is highlighted until the family expands.
    private var displayedSelection: SidebarItem {
        if case .smartList(let parent) = appState.selectedSidebarItem {
            return .smartList(SmartListVariantState.shared(for: parent).selected)
        }
        return appState.selectedSidebarItem
    }
}

// MARK: - List Row Animation Key
// What a sidebar list row displays, and so what its insertion, removal, rename, or
// reorder animates on. See LeftSidebar's .animation.
private struct ListRowKey: Equatable {
    let listID: UUID
    let listName: String

    init(_ info: ListInfo) {
        listID = info.listID
        listName = info.listName
    }
}

// MARK: - Imports Glyph State
private enum ImportsGlyphState {
    case normal
    case importing
    case completed
    /// Finished, but at least one item failed. Held exactly as long as `completed`
    /// is — the durable record of the failure lives on the session card itself, so
    /// the sidebar badge is only ever the pointer that sends the user there.
    case completedWithErrors

    /// True for both finished states. Every place that treats "the import is over"
    /// as one condition uses this rather than enumerating the two cases, so adding
    /// a third finished state later can't silently miss a call site.
    var isFinished: Bool { self == .completed || self == .completedWithErrors }
}

// MARK: - List Row Action
// The set of contextual-menu actions a list row can raise. Collapsing these into one
// enum keeps ListsSection and ListRow to a single `onAction` closure each, instead of
// five parallel closures declared and forwarded at every level.
private enum ListRowAction {
    case edit
    case duplicate
    case clearContents
    case deleteContents
    case delete
}

// MARK: - Momentary Glyph Helper
// Shows a transient confirmation glyph for a fixed interval, then hides it. The "Queue" row and
// every ListRow use it. A second completion restarts the full interval, and the stored handle
// lets onDisappear cancel a pending hide.
private enum MomentaryGlyph {
    // Immutable and Sendable, so it needs no actor isolation of its own.
    static let duration: Duration = .seconds(2)

    @MainActor
    static func show(_ isVisible: Binding<Bool>, task: Binding<Task<Void, Never>?>) {
        task.wrappedValue?.cancel()
        isVisible.wrappedValue = true
        task.wrappedValue = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            isVisible.wrappedValue = false
        }
    }
}

// MARK: - List Row Drop Highlight
// Installs the AppKit drop and hover proxy for a sidebar row and paints the native-style drop
// highlight. The "Queue" row and every ListRow use this pair. The proxy keeps the same
// conditional shape whatever `isEnabled` is, so ListRow (always `true`) never reinstalls it.
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
    let importsGlyphState: ImportsGlyphState

    // The Imports row's icon: its own glyph normally, a checkmark once an import
    // finishes cleanly, a warning triangle once one finishes with failures.
    private var importsGlyph: String {
        switch importsGlyphState {
        case .completed:           return ViewGlyphs.importsCompletion.outline
        case .completedWithErrors: return ViewGlyphs.importsFailure.outline
        case .normal, .importing:  return ViewGlyphs.imports.outline
        }
    }

    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(AppState.self) private var appState

    // Mirrors the two Preferences keys governing the "Film Queue" sidebar row's
    // drop-target behavior. @AppStorage keeps these reactive to changes made in
    // Settings while this view is on screen.
    @AppStorage(preference: Preferences.queueIsDropTargetKey)
        private var queueIsDropTarget: Bool
    @AppStorage(preference: Preferences.queueSectionOnDropKey)
        private var queueSectionOnDropRaw: Int

    // Drag and hover state for the "Film Queue" row, as in ListRow. isHovered is not displayed
    // here but ListRowDropTarget requires it.
    @State private var isQueueDropTargeted = false
    @State private var isQueueHovered = false

    // Momentary completion glyph, as in ListRow. Driven by .queueAdditionCompleted, which fires
    // only when a film is added to an internal Film Queue list, never on removals.
    @State private var showQueueCompletionGlyph = false
    @State private var queueCompletionTask: Task<Void, Never>?

    // Resolves the currently-selected Film Queue section from the raw preference
    // value, falling back to "Up Next" for any unrecognized/corrupt stored value.
    private var queueDropSection: Preferences.QueueDropSection {
        Preferences.QueueDropSection(rawValue: queueSectionOnDropRaw) ?? .upNext
    }

    var body: some View {
        Section("Library") {
            Label("All Films", systemImage: ViewGlyphs.allFilms.outline)
                .tag(SidebarItem.libraryItem(.allFilms))
            Label("Unwatched", systemImage: ViewGlyphs.unwatched.outline)
                .tag(SidebarItem.libraryItem(.unwatched))
            Label("Recents", systemImage: ViewGlyphs.recents.outline)
                .tag(SidebarItem.libraryItem(.recents))
            Label("Reports", systemImage: ViewGlyphs.reports.outline)
                .tag(SidebarItem.libraryItem(.reports))
            HStack {
                Label {
                    Text("Imports")
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
            .tag(SidebarItem.libraryItem(.imports))
            .animation(.easeInOut(duration: 0.2), value: importProgress.isImporting)

            Label {
                Text("Queue")
            } icon: {
                Image(systemName: showQueueCompletionGlyph
                    ? ViewGlyphs.rowCompletion.outline
                    : ViewGlyphs.filmQueue.outline)
                    .contentTransition(.symbolEffect(.replace))
            }
                .tag(SidebarItem.libraryItem(.filmQueue))
                // The shared row modifier targets the Film Queue section chosen in
                // Preferences.queueSectionOnDrop. With queueIsDropTarget off, isEnabled is false
                // and no proxy or highlight is installed.
                .modifier(ListRowDropHighlight(
                    listID: queueDropSection.filmQueueSection.listID,
                    listName: queueDropSection.filmQueueSection.displayName,
                    dataCoordinator: dataCoordinator,
                    isEnabled: queueIsDropTarget,
                    isDropTargeted: $isQueueDropTargeted,
                    isHovered: $isQueueHovered
                ))
                .onReceive(AppEventBus.shared.listEvents) { event in
                    guard case .queueAdditionCompleted = event else { return }

                    // Only show the completion glyph when the user is NOT currently
                    // viewing the Film Queue — if they are, the change is self-evident.
                    // Mirrors ListRowActivityStore's identical guard.
                    guard appState.selectedSidebarItem != .libraryItem(.filmQueue) else { return }

                    MomentaryGlyph.show($showQueueCompletionGlyph, task: $queueCompletionTask)
                }
                .onDisappear {
                    queueCompletionTask?.cancel()
                }
        }
    }
}

// MARK: - Smart Lists Section Component
// Each family is a native disclosure row: the parent's row selects the parent list, its
// triangle reveals the family's variants as indented child rows (familyVariants, the same
// list the title-bar picker offers). Which families are expanded is remembered across
// launches (Preferences.expandedSmartListFamilies).
private struct SmartListsSection: View {
    // SmartListType.sidebarCases is the static source of truth. This view takes no
    // DataCoordinator, so no unneeded @Observable subscription runs on each body evaluation.

    @State private var expanded: Set<SmartListType> = Preferences.expandedSmartListFamilies

    var body: some View {
        Section("Smart Lists") {
            ForEach(SmartListType.sidebarCases) { parent in
                // A family with no variants (Upcoming Releases) is a plain row: a disclosure
                // triangle over nothing would offer an expansion that reveals nothing.
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
        .tag(SidebarItem.smartList(type))
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

    // Hover / ellipsis button state
    @State private var isHovered = false
    @State private var isEllipsisPressed = false

    // Drag-and-drop state
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
                .frame(width: Self.accessorySlotWidth, height: Self.accessorySlotWidth)
                .transition(.opacity)
        } else if isHovered {
            // Chromeless ellipsis button, shown only while hovering this row.
            //
            // The glyph is a plain Image — so it inherits the List row's automatic
            // selection/focus emphasis coloring like the row's text. An invisible,
            // identically-sized Menu sits on top to catch the click and present the
            // contextual menu.
            Image(systemName: "ellipsis.circle")
                .frame(width: Self.accessorySlotWidth, height: Self.accessorySlotWidth)
                // Dims the glyph on mouse-down and restores it on release.
                .opacity(isEllipsisPressed ? 0.4 : 1.0)
                .animation(.easeOut(duration: 0.08), value: isEllipsisPressed)
                .overlay {
                    Menu {
                        contextMenuItems()
                    } label: {
                        Color.clear
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: Self.accessorySlotWidth, height: Self.accessorySlotWidth)
                    .focusable(false)
                    .focusEffectDisabled()
                }
                // Simultaneous gesture drives opacity feedback only; does not consume the
                // tap, so the Menu overlay still receives the click.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in isEllipsisPressed = true }
                        .onEnded   { _ in isEllipsisPressed = false }
                )
                .help("List Options")
        }
    }

    /// Width of the trailing accessory slot.
    private static let accessorySlotWidth: CGFloat = 18

    /// True while the trailing slot is occupied. The title's trailing inset follows this, so
    /// the title runs the full row width until an accessory appears and truncates further
    /// only for as long as one is showing.
    private var isAccessoryShowing: Bool { activity.showProgressIndicator || isHovered }

    var body: some View {
        Label {
            // The title is JUST the text, laid out as though no accessory existed; the
            // accessory is layered over it and reserved for by a constant trailing inset.
            //
            // The accessory is an overlay, not an HStack sibling. A view entering or leaving a
            // stack shifts the stack's baseline, so the icon jiggled on every hover. An overlay
            // is outside the layout, so it cannot move the icon. The trailing inset that makes
            // room for it applies only while it shows. It changes only the title's width, so the
            // icon stays put. The change is unanimated on purpose.
            Text(listInfo.listName)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, isAccessoryShowing ? Self.accessorySlotWidth + 4 : 0)
                .animation(nil, value: isAccessoryShowing)
                .overlay(alignment: .trailing) { trailingAccessory }
        } icon: {
            Image(systemName: activity.showCompletionGlyph ? ViewGlyphs.rowCompletion.outline : ViewGlyphs.userList.outline)
                .contentTransition(.symbolEffect(.replace))
        }
        .tag(SidebarItem.list(listInfo.listID))
        // Secondary-click anywhere on the row opens the same menu as the ellipsis button.
        .contextMenu {
            contextMenuItems()
        }
        // Clears press state when the cursor leaves the row, so the glyph does not stay dim.
        .onChange(of: isHovered) { _, hovering in
            if !hovering, isEllipsisPressed { isEllipsisPressed = false }
        }
        // ListRowDropTarget is a zero-size anchor. It installs a RowDragProxyView on the
        // NSTableRowView, covering the full row. That proxy supplies hover state and drag
        // callbacks, since .onHover covers only the inset content. User lists are always
        // drop targets, so isEnabled is true.
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
    // Shared by the secondary-click .contextMenu and the ellipsis Menu, so both stay identical.
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
// One row per saved search, in the order the user dragged them into. A row opens the
// search's own gallery view (ViewIdentifier.savedSearch); its menu edits it, opens it in
// the search field, duplicates or removes it. Not a drop target: films cannot be added to
// a query.
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

// MARK: - Saved Search Row Component
private struct SavedSearchRow: View {
    let search: SavedSearch

    @Environment(DataCoordinator.self) private var dataCoordinator

    // Hover / ellipsis button state, as ListRow's.
    @State private var isHovered = false
    @State private var isEllipsisPressed = false
    /// Required by the row proxy's interface; a saved search row never becomes a drop target.
    @State private var isDropTargeted = false

    private static let accessorySlotWidth: CGFloat = 18

    var body: some View {
        // Laid out as ListRow is — the ellipsis an overlay on the title, reserved for by a
        // trailing inset only while it shows — for the same reason: the icon must not move.
        Label {
            Text(search.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, isHovered ? Self.accessorySlotWidth + 4 : 0)
                .animation(nil, value: isHovered)
                .overlay(alignment: .trailing) { ellipsis }
        } icon: {
            Image(systemName: ViewGlyphs.savedSearch.outline)
        }
        .tag(SidebarItem.savedSearch(search.id))
        .contextMenu { menuItems() }
        .onChange(of: isHovered) { _, hovering in
            if !hovering, isEllipsisPressed { isEllipsisPressed = false }
        }
        // The list rows' full-row hover tracking (see ListRow), with drops turned off.
        .overlay(
            ListRowDropTarget(listID: search.id, listName: search.name, dataCoordinator: dataCoordinator,
                              isDropTargeted: $isDropTargeted, isHovered: $isHovered, acceptsDrops: false)
                .frame(width: 0, height: 0))
    }

    /// ListRow's hover ellipsis: a plain glyph that takes the row's selection coloring, under
    /// an invisible Menu that catches the click.
    @ViewBuilder
    private var ellipsis: some View {
        if isHovered {
            Image(systemName: "ellipsis.circle")
                .frame(width: Self.accessorySlotWidth, height: Self.accessorySlotWidth)
                .opacity(isEllipsisPressed ? 0.4 : 1.0)
                .animation(.easeOut(duration: 0.08), value: isEllipsisPressed)
                .overlay {
                    Menu { menuItems() } label: { Color.clear }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: Self.accessorySlotWidth, height: Self.accessorySlotWidth)
                        .focusable(false)
                        .focusEffectDisabled()
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in isEllipsisPressed = true }
                        .onEnded { _ in isEllipsisPressed = false })
                .help("Saved Search Options")
        }
    }

    // Shared by the context menu and the ellipsis, as ListRow's are.
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
// A list row's transient feedback: the spinner shown once an operation on it has run for a
// moment, and the momentary completion glyph. One per list, kept by ListRowActivityStore,
// so a row reads (and is invalidated by) only its own.
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

        guard showGlyph else { return }
        // Same discipline as MomentaryGlyph: a second completion restarts the interval.
        completionTask?.cancel()
        showCompletionGlyph = true
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: MomentaryGlyph.duration)
            guard let self, !Task.isCancelled else { return }
            self.showCompletionGlyph = false
        }
    }

    func cancel() {
        progressDelayTask?.cancel()
        completionTask?.cancel()
    }
}

// Routes listEvents to the one row each event names. Activity outlives a row's cell, so a
// scrolled or rebuilt row keeps its spinner until its list is deleted.
@MainActor
private final class ListRowActivityStore {
    static let shared = ListRowActivityStore()

    private var activities: [UUID: ListRowActivity] = [:]
    private weak var appState: AppState?
    private var cancellable: AnyCancellable?

    private init() {
        // AppEventBus is @MainActor, so this sink runs synchronously on the main actor.
        cancellable = AppEventBus.shared.listEvents.sink { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    /// Supplies the AppState the completion glyph's "not viewing this list" check reads.
    func attach(_ appState: AppState) {
        self.appState = appState
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
            // Only show the completion glyph when the user is NOT currently viewing this
            // list — if they are, the change is self-evident.
            let isViewing = appState?.selectedSidebarItem == .list(listID)
            activity(for: listID).operationCompleted(showGlyph: !isViewing)
        case .deleted(let listID):
            activities.removeValue(forKey: listID)?.cancel()
        default:
            break
        }
    }
}

// MARK: - AppKit Drop Target
// An NSViewRepresentable used as a lifecycle anchor in the SwiftUI cell. On attachment it
// installs a RowDragProxyView on NSTableRowView, which owns the full row highlight. SwiftUI
// content is inset from that view, so the proxy must attach there to cover the whole row.
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
        // Seed initial values; updateNSView also runs immediately after makeNSView.
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
        // Always keep the anchor's cached values current. The anchor copies them
        // to the proxy in viewDidMoveToWindow; updates after that go direct to proxy.
        nsView.listID = listID
        nsView.listName = listName
        nsView.dataCoordinator = dataCoordinator
        // Also update proxy directly for the rename / reuse case where proxy exists —
        // but only while this anchor still owns it. A recycled row view can lend its
        // proxy to a newly arrived anchor before this one has left; writing this row's
        // list into it then would send drops on the other row to this list.
        guard let proxy = nsView.proxy, proxy.owner === nsView else { return }
        proxy.listID = listID
        proxy.listName = listName
        proxy.dataCoordinator = dataCoordinator
        // onHoverChanged closure captures a Binding; re-seat it so identity stays
        // consistent if SwiftUI re-evaluates the parent view with new binding storage.
        proxy.onHoverChanged = nsView.onHoverChanged
    }
    
    // MARK: - Anchor View
    // Zero-size. It manages the RowDragProxyView's lifecycle and caches the values needed to seed
    // the proxy, because updateNSView runs before the proxy exists.
    @MainActor
    final class DropTargetAnchorView: NSView, Loggable {
        nonisolated static let logTag = "[LeftSidebar]"

        var listID: UUID = UUID()
        var listName: String = ""
        var acceptsDrops = true
        weak var dataCoordinator: DataCoordinator?
        var onTargetChanged: ((Bool) -> Void)?
        var onHoverChanged: ((Bool) -> Void)?
        // Weak reference so the proxy's own removal from NSTableRowView releases it.
        weak var proxy: RowDragProxyView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // viewDidMoveToWindow fires once the full view hierarchy exists. viewDidMoveToSuperview is too
            // early: the NSTableRowView ancestor is not yet reachable, so no proxy would be created.
            guard unsafe window != nil else { return }
            guard proxy == nil,
                  let rowView = findAncestor(ofType: NSTableRowView.self) else { return }
            // NSOutlineView recycles row views as the sidebar scrolls. The proxy stays with its row view
            // and is lent to whichever anchor arrives, rather than being rebuilt for every row.
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
            // The anchor leaves its window when its cell is recycled for another row,
            // when the row is deleted, or when the sidebar is torn down.
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
        // Proxies are created once per row view. The digest should show creations only as the sidebar
        // first fills, and reuses while scrolling. One line is written per burst.
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
                // A reuse-only burst is ordinary scrolling; only creations are worth a line.
                if createdSinceDigest > 0 {
                    log("RowDragProxyViews: \(createdTotal) created "
                        + "(+\(createdSinceDigest) new, \(reusedSinceDigest) reused since last digest)")
                }
                createdSinceDigest = 0
                reusedSinceDigest = 0
            }
        }

        // Walk up the superview chain looking for a specific NSView subclass.
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
    // Attached directly to NSTableRowView and always sized to fill it. It handles the full
    // NSDraggingDestination protocol for this row. NSHostingView does not register for filmIDs,
    // so the drag hit test falls through to this proxy, the only registered view in the padding.
    @MainActor
    final class RowDragProxyView: NSView, Loggable {
        nonisolated static let logTag = "[LeftSidebar]"

        var listID: UUID = UUID()
        var listName: String = ""
        weak var dataCoordinator: DataCoordinator?
        var onTargetChanged: ((Bool) -> Void)?
        var onHoverChanged: ((Bool) -> Void)?

        // The single tracking area covering the proxy's entire bounds. Rebuilt
        // whenever the bounds change so it always matches the full NSTableRowView.
        private var hoverTrackingArea: NSTrackingArea?

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
            reconcileHover()
        }

        /// Clears the departing row's state so the proxy reports nothing for it.
        func deactivate() {
            setHovered(false)
            owner = nil
            Self.activeProxies.remove(self)
            onTargetChanged = nil
            onHoverChanged = nil
            unregisterDraggedTypes()
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // No layer, no drawing — fully transparent. Exists only for drag protocol
            // and hover tracking.
            registerForDraggedTypes([.filmIDs])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

        // Keep frame = superview.bounds through every AppKit layout cycle, then
        // rebuild the tracking area so it stays in sync with the new bounds.
        override func layout() {
            super.layout()
            if let sv = unsafe superview, frame != sv.bounds {
                frame = sv.bounds
            }
            rebuildTrackingArea()
        }

        // The tracking area is installed once. `.inVisibleRect` lets AppKit keep it matched to the
        // visible bounds, so it is never replaced while the cursor is inside. Replacing it would drop
        // the mouseExited for the old area and leave the row's hover state stuck.
        private func rebuildTrackingArea() {
            guard hoverTrackingArea == nil else { return }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            hoverTrackingArea = area
        }

        // MARK: Hover reconciliation
        //
        // Enter and exit events alone are not reliable. AppKit sends no mouseExited when a row scrolls
        // under a still cursor, when the app deactivates, while an ellipsis menu tracks the mouse, or
        // when the proxy is removed mid-hover. So hover belongs to one row at a time, and each of these
        // moments re-derives it from the actual cursor position.

        /// The one row currently reporting hover. Entering another row clears it.
        private static weak var hoveredProxy: RowDragProxyView?
        private static var observersInstalled = false

        // MARK: Live scroll
        //
        // Rows report no hover while the sidebar live-scrolls, as Finder's do. Otherwise each row that
        // passes under a still cursor would build and tear down its ellipsis button. Hover is re-derived
        // once the scroll ends.

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
                    // The row under the cursor now is not the one it was over when the
                    // scroll began, so every row serving one is asked; only the one the
                    // cursor is in reports hover.
                    for proxy in activeProxies.allObjects { proxy.reconcileHover() }
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Self.installObserversIfNeeded()
            if let scrollView = enclosingScrollView { Self.sidebarScrollView = scrollView }
            if unsafe window == nil { setHovered(false) }
        }

        override func removeFromSuperview() {
            setHovered(false)
            super.removeFromSuperview()
        }

        override func mouseEntered(with event: NSEvent) {
            setHovered(true)
        }

        override func mouseExited(with event: NSEvent) {
            setHovered(false)
        }

        // MARK: - NSDraggingDestination

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard sender.draggingPasteboard.availableType(from: [.filmIDs]) != nil else {
                return []
            }
            onTargetChanged?(true)
            return .copy
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            return .copy
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            onTargetChanged?(false)
        }

        override func draggingEnded(_ sender: any NSDraggingInfo) {
            onTargetChanged?(false)
        }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            return sender.draggingPasteboard.availableType(from: [.filmIDs]) != nil
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            // Decodes through the shared FilmDragDecoder, which adds the JSON-pasteboard fallback and logging.
            guard let filmIDs = FilmDragDecoder.decode(from: sender),
                  !filmIDs.isEmpty else {
                return false
            }
            guard let coordinator = dataCoordinator else { return false }

            // "Up Next" holds at most eight films. A drop that would overflow is not added there. The
            // alert offers "Soon" instead. The drop is still accepted, so the preview does not fly back.
            if listID == FilmQueueSection.upNext.listID,
               FilmQueue.upNextOverflow(adding: filmIDs, coordinator: coordinator) > 0 {
                log("Drop of \(filmIDs.count) film(s) on '\(listName)' would overflow it — offering 'Soon'")
                // Only the films not already in "Up Next": the rest are where the user
                // dropped them, and adding them to "Soon" would move them out of it.
                AppEventBus.shared.sendAlert(.offerSoonForFullUpNextDrop(
                    filmIDs: filmIDs.subtracting(FilmQueue.upNextFilmIDs(coordinator: coordinator)),
                    message: FilmQueue.upNextFullDropMessage(filmIDs, coordinator: coordinator)))
                return true
            }

            // Special-sorting confirmation gate, using the same rule as the Add to Queue menus and the
            // FilmSheet picker. It applies only to the three internal Film Queue lists. If a dropped film has
            // a specialSorting value, the add waits for AlertHostView's confirmation. Canceling drops the
            // whole drop, and confirming adds the full set.
            if FilmQueue.isInternalList(listID),
               FilmQueue.addNeedsConfirmation(filmIDs, coordinator: coordinator) {
                log("Deferring add of \(filmIDs.count) film(s) to list '\(listName)' pending special-sorting confirmation")
                // Sent synchronously, on the same call stack as the drop. AlertHostView stashes the payload and
                // freezes the message at drop time. It presents the alert only when the .dragSessionDidEnd notice
                // arrives. AppKit defers that callback past its drag-completion pass, so the alert animates without
                // contention. Presenting here would drop frames, and sending now ensures the stash exists in time.
                AppEventBus.shared.sendAlert(.confirmFilmQueueAddOnDrop(filmIDs: filmIDs, listID: listID))
                return true
            }

            log("Adding \(filmIDs.count) film(s) to list '\(listName)'")

            // Called synchronously, not in Task { ... }. performDragOperation runs inside the drag session's
            // event-tracking loop, which defers main-actor continuations until the session ends. A Task would
            // run only after AppKit's completion pass, roughly a second later. A synchronous call lets the
            // membership change and its events post before teardown begins.
            FilmManager.addFilmsToList(filmIDs, listID: listID, coordinator: coordinator)
            return true
        }

        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
            onTargetChanged?(false)
            // Dismisses the drag-preview flyback window in step with the highlight clearing. AppKit defers
            // the endedAt callback past its completion pass, which would leave a visible lag. GalleryDragEngine
            // observes this notification and calls dismissFlybackImmediately().
            NotificationCenter.default.post(name: .dismissDragPreviewImmediately, object: nil)
        }
    }
}

// MARK: - Event Setup Extension
// With isolated binding, no special transaction handling needed
@MainActor
private extension View {
    func setupEvents(appState: AppState,
        importsGlyphState: Binding<ImportsGlyphState>) -> some View {
        self
            .onReceive(AppEventBus.shared.listEvents) { event in
                // Rows track cachedLists through syncListsCache() at each mutation, with the List's @Observable
                // subscription and .animation driving the updates. Per-row feedback comes from ListRow. The one
                // event needing explicit handling is deletion of the list being viewed, which moves the selection off it.
                if case .deleted(let deletedListID) = event,
                    case .list(let selectedListID) = appState.selectedSidebarItem,
                    selectedListID == deletedListID {
                    appState.navigate(to: .libraryItem(.allFilms))
                }
            }
            // ImportProgress is @Observable, so .onChange(of:) delivers its changes.
            .onChange(of: ImportProgress.shared.isImporting) { _, isImporting in
                // Only the rising edge matters. It clears a lingering .completed checkmark so a new import is not
                // masked. The falling edge is ignored, because the completionStatus handler below sets .completed
                // at the same moment and must win.
                if isImporting {
                    importsGlyphState.wrappedValue = .importing
                }
            }
            .onChange(of: ImportProgress.shared.completionStatus) { _, status in
                guard status == .success || status == .successWithErrors else { return }

                // Sets the matching completed state. `.successWithErrors` shows the warning glyph, since some
                // items failed. The session card holds the details.
                importsGlyphState.wrappedValue =
                    status == .successWithErrors ? .completedWithErrors : .completed

                // If already on Imports view, auto-clear after 2 seconds
                if case .libraryItem(.imports) = appState.selectedSidebarItem {
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        // Re-reads wrappedValue after the delay, since a new import may have started and set .importing.
                        // If so, do not revert to .normal.
                        if importsGlyphState.wrappedValue.isFinished {
                            importsGlyphState.wrappedValue = .normal
                        }
                    }
                }
            }
    }
}
