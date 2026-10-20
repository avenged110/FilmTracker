// MARK: - LeftSidebar.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Navigation sidebar showing Library sections and user-created Lists.

import SwiftUI
import AppKit

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
                selectedSidebarItem: appState.selectedSidebarItem,
                dataCoordinator: dataCoordinator,
                onAction: performListAction,
                onMove: moveItems
            )
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
        // Animate sidebar list insertions, deletions, and reorders.
        // Keying on cachedLists ensures the animation fires exactly when the data changes —
        // which is now synchronous in DataCoordinator — rather than relying on AppEventBus events.
        .animation(.default, value: dataCoordinator.cachedLists)
        // Sync AppState -> LocalSelection (programmatic changes flow DOWN)
        .onChange(of: displayedSelection) { _, newValue in
            if localSelection != newValue {
                localSelection = newValue
            }
        }
        // Sync LocalSelection -> AppState (user clicks flow UP)
        .onChange(of: localSelection) { oldValue, newValue in
            if displayedSelection != newValue {
                Self.log("User selection: \(String(describing: oldValue)) → \(String(describing: newValue))")
                if case .smartList(let type) = newValue {
                    selectSmartList(type)
                } else {
                    appState.navigate(to: newValue)
                }
                handleSelectionChange(newValue: newValue)
            }
        }
        .onChange(of: smartListsEnabled) { _, isEnabled in
            // If smart lists are disabled and we're viewing one, switch to All Films
            if !isEnabled, case .smartList = appState.selectedSidebarItem {
                appState.navigate(to: .libraryItem(.allFilms))
            }
        }
        .onAppear {
            // Initialize local selection to match app state
            localSelection = displayedSelection
        }
        // No initialization task is needed here: cachedLists is populated synchronously
        // inside finalizeInitialization() alongside films, so the rows appear in the same
        // frame as the gallery grid via the @Observable subscription above.
        .setupEvents(appState: appState,
            importsGlyphState: $importsGlyphState)
    }

    // MARK: - Smart List Rows

    /// The row the sidebar highlights. AppState only ever holds a smart list family's
    /// PARENT (`.smartList(.purchased)` while "Purchased 4K" is on screen — every
    /// navigation path relies on that), so the variant actually displayed is read from
    /// the family's SmartListVariantState and the variant's own row is selected. Inside a
    /// collapsed family that row is hidden, so nothing is highlighted, the same as while
    /// Search (which has no row) is showing; expanding the family reveals it already
    /// selected.
    private var displayedSelection: SidebarItem {
        if case .smartList(let parent) = appState.selectedSidebarItem {
            return .smartList(SmartListVariantState.shared(for: parent).selected)
        }
        return appState.selectedSidebarItem
    }

    /// A click on a smart list row: a family's parent or one of its variants.
    ///
    /// - Within the family on screen it is exactly the title-bar picker's selection
    ///   (SmartListVariantState.select), so the two controls cannot disagree. That covers
    ///   a click on the parent row while a variant is showing, which returns to the parent.
    /// - A variant from anywhere else takes ShowInListNavigation's order: resolve the
    ///   family to the variant, load it, then flip the sidebar to the parent. Flipping
    ///   first would reset the family to its parent (GalleryView.prepareSidebarTransition
    ///   honors only a variant that is already loaded).
    /// - A parent from anywhere else is an ordinary navigation, as before.
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

    /// Side effects that must accompany a user-driven selection change. The transition
    /// itself is already logged by the .onChange handler above, so nothing here repeats
    /// that; only the two cases that genuinely need to *do* something appear.
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

    /// Single entry point for every ListRow contextual-menu action. Replaces the five
    /// separate closures that used to be threaded down through ListsSection into ListRow.
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
        // Pre-fetch film IDs synchronously — getFilmIDsForListDeletion reads MemoryStore
        // directly and requires no async hop. Doing this on the calling actor avoids
        // wrapping synchronous logic in Task {} unnecessarily.
        let filmIDs = ListManager.getFilmIDsForListDeletion(listID, coordinator: dataCoordinator)

        guard !filmIDs.isEmpty else {
            // List became empty between the menu gesture and this call
            // (e.g., user confirmed a prior deletion while this one was pending).
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
        // DataCoordinator.batchUpdateListOrders applies an optimistic MemoryStore update
        // synchronously and calls syncListsCache(), so cachedLists (and therefore the
        // sidebar) updates immediately via @Observable — no local state or rollback needed.
        Task {
            ListManager.reorderLists(from: source, to: destination,
                coordinator: dataCoordinator)
        }
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
// Shows a transient confirmation glyph for a fixed interval, then hides it again.
// Used identically by the "Queue" library row and by every ListRow, so the
// cancel-then-restart discipline and the display duration live in exactly one place:
// a rapid second completion restarts the full interval rather than inheriting the
// remainder of the first, and the caller's stored handle keeps onDisappear able to
// cancel a still-pending hide.
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
// Installs the AppKit drop/hover proxy for a sidebar row and paints the native-style
// drop highlight behind it. Both the "Queue" library row and every user ListRow need
// exactly this pair of modifiers, so they are defined once here.
//
// The proxy is always wrapped in the same conditional shape regardless of `isEnabled`,
// so a row whose enablement never changes (ListRow, which passes `true`) keeps a stable
// view identity and its RowDragProxyView is never torn down and reinstalled.
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

    // Drag-and-drop state for the "Film Queue" row, mirroring ListRow's
    // isDropTargeted/isHovered pattern. isHovered is unused for display here (the
    // row has no hover-driven accessory) but is required by ListRowDropTarget's API.
    @State private var isQueueDropTargeted = false
    @State private var isQueueHovered = false

    // Momentary completion glyph, mirroring ListRow's showCompletionGlyph. Driven by
    // AppEventBus's .queueAdditionCompleted event, which fires only on successful
    // additions to one of the three internal Film Queue lists (drag-and-drop onto this
    // row, an "Add to Queue" menu selection, or an explicit Film Queue assignment saved
    // from the FilmSheet) — never on removals.
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
                // DRAG-AND-DROP: the shared row modifier points the same proxy machinery
                // ListRow uses at whichever internal Film Queue list is currently selected
                // via Preferences.queueSectionOnDrop. Passing isEnabled: false when
                // queueIsDropTarget is off installs no proxy and paints no highlight.
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
                    // Mirrors ListRow's identical isSelected guard.
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
    // SmartListType.sidebarCases is a static source of truth. DataCoordinator was
    // previously passed here but was never read in this view's body; removing it
    // eliminates a spurious @Observable subscription on every body evaluation.

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
    let selectedSidebarItem: SidebarItem
    let dataCoordinator: DataCoordinator
    let onAction: (ListRowAction, UUID) -> Void
    let onMove: (IndexSet, Int) -> Void

    var body: some View {
        Section("Lists") {
            ForEach(lists) { listInfo in
                ListRow(
                    listInfo: listInfo,
                    isSelected: selectedSidebarItem == .list(listInfo.listID),
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
    let isSelected: Bool
    let dataCoordinator: DataCoordinator
    let onAction: (ListRowAction) -> Void

    @State private var isOperationInProgress = false
    @State private var showProgressIndicator = false
    @State private var showCompletionGlyph = false
    @State private var progressDelayTask: Task<Void, Never>?
    @State private var completionTask: Task<Void, Never>?

    // Hover / ellipsis button state
    @State private var isHovered = false
    @State private var isEllipsisPressed = false

    // Drag-and-drop state
    @State private var isDropTargeted = false

    /// The trailing accessory slot shows at most one item at a time:
    ///   • spinner  — while an operation is in progress (takes priority)
    ///   • ellipsis — while the cursor hovers and no operation is running
    ///
    /// Both are excluded when neither condition applies so the row is clean. Rendered as an
    /// overlay on the title rather than a sibling of it — see `body` for why that matters.
    /// Both occupy the same fixed slot, so switching between them shifts nothing either.
    @ViewBuilder
    private var trailingAccessory: some View {
        if showProgressIndicator {
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
                // Dims the glyph on mouse-down; restores on release.
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
    private var isAccessoryShowing: Bool { showProgressIndicator || isHovered }

    var body: some View {
        Label {
            // The title is JUST the text, laid out as though no accessory existed; the
            // accessory is layered over it and reserved for by a constant trailing inset.
            //
            // Previously the accessory was a sibling in an HStack alongside this text,
            // joining and leaving that stack with hover. Label aligns its icon against the
            // title's baseline, and a view entering or leaving a stack changes that stack's
            // baseline as well as its intrinsic height — so the icon tracked the change and
            // moved a fraction of a point on every hover. That is the jiggle. Pinning the
            // stack's height was not enough, because the height was only one of the metrics
            // that moved. An overlay sits outside the layout entirely, so its presence
            // cannot alter any metric the icon is aligned against.
            //
            // The trailing inset that makes room for the accessory is applied only while one
            // is showing. Toggling horizontal padding on a single-line Text changes only the
            // width it may fill — never its height or baseline — so the icon stays put while
            // the title gets the whole row back the moment the accessory leaves. The change
            // is deliberately unanimated: the title snaps between its two truncation points.
            Text(listInfo.listName)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, isAccessoryShowing ? Self.accessorySlotWidth + 4 : 0)
                .animation(nil, value: isAccessoryShowing)
                .overlay(alignment: .trailing) { trailingAccessory }
        } icon: {
            Image(systemName: showCompletionGlyph ? ViewGlyphs.rowCompletion.outline : ViewGlyphs.userList.outline)
                .contentTransition(.symbolEffect(.replace))
        }
        .tag(SidebarItem.list(listInfo.listID))
        // Secondary-click anywhere on the row opens the same menu as the ellipsis button.
        .contextMenu {
            contextMenuItems()
        }
        // Clear stale press state when the cursor leaves the row (e.g., mouse dragged
        // off the glyph before being released), preventing the glyph from staying dim.
        .onChange(of: isHovered) { _, hovering in
            if !hovering, isEllipsisPressed { isEllipsisPressed = false }
        }
        // DRAG-AND-DROP + HOVER: ListRowDropTarget is a zero-size anchor view embedded in
        // the SwiftUI cell. Its DropTargetAnchorView walks up to NSTableRowView at
        // attachment time and installs a RowDragProxyView there, giving full-row coverage
        // that exactly matches the highlight for both drag targets and hover tracking.
        // SwiftUI .onHover and NSHostingView layout both only cover the inset content area,
        // so the proxy — which fills the entire NSTableRowView — is the authoritative
        // source for hover state as well as drag-destination callbacks. User list rows are
        // always drop targets, hence isEnabled: true.
        .modifier(ListRowDropHighlight(
            listID: listInfo.listID,
            listName: listInfo.listName,
            dataCoordinator: dataCoordinator,
            isEnabled: true,
            isDropTargeted: $isDropTargeted,
            isHovered: $isHovered
        ))
        .onReceive(AppEventBus.shared.listEvents) { event in
            switch event {
            case .operationStarted(let listID):
                guard listID == listInfo.listID else { return }
                
                isOperationInProgress = true

                progressDelayTask?.cancel()
                progressDelayTask = Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }

                    if isOperationInProgress {
                        withAnimation(.easeIn(duration: 0.2)) {
                            showProgressIndicator = true
                        }
                    }
                }
                
            case .operationCompleted(let listID):
                guard listID == listInfo.listID else { return }

                isOperationInProgress = false

                progressDelayTask?.cancel()

                if showProgressIndicator {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showProgressIndicator = false
                    }
                }

                // Only show the completion glyph when the user is NOT currently
                // viewing this list — if they are, the change is self-evident.
                guard !isSelected else { return }

                MomentaryGlyph.show($showCompletionGlyph, task: $completionTask)
                
            default:
                break
            }
        }
        .onDisappear {
            progressDelayTask?.cancel()
            completionTask?.cancel()
        }
    }

    // MARK: - Context Menu Items
    // Shared between the secondary-click .contextMenu and the ellipsis button Menu overlay,
    // so the two surfaces always stay identical without duplication.
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

// MARK: - AppKit Drop Target
// An NSViewRepresentable used purely as a lifecycle anchor embedded in the SwiftUI cell.
// On attachment it walks up to NSTableRowView — the AppKit view that owns the full
// row highlight — and installs a RowDragProxyView there. The proxy covers the entire
// NSTableRowView, matching the highlight exactly, and handles all drag protocol calls.
// SwiftUI layout (NSHostingView) is always inset from NSTableRowView, so a proxy
// attached at the NSTableRowView level is the only way to cover the full highlight area.
private struct ListRowDropTarget: NSViewRepresentable, Loggable {
    nonisolated static let logTag = "[LeftSidebar]"

    let listID: UUID
    let listName: String
    let dataCoordinator: DataCoordinator
    @Binding var isDropTargeted: Bool
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> DropTargetAnchorView {
        let view = DropTargetAnchorView()
        // Seed initial values; updateNSView also runs immediately after makeNSView.
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
        // Also update proxy directly for the rename / reuse case where proxy exists.
        nsView.proxy?.listID = listID
        nsView.proxy?.listName = listName
        nsView.proxy?.dataCoordinator = dataCoordinator
        // onHoverChanged closure captures a Binding; re-seat it so identity stays
        // consistent if SwiftUI re-evaluates the parent view with new binding storage.
        nsView.proxy?.onHoverChanged = nsView.onHoverChanged
    }
    
    // MARK: - Anchor View
    // Zero-size; its sole purpose is lifecycle management of the RowDragProxyView.
    // Caches listID/listName/dataCoordinator so viewDidMoveToWindow can seed the proxy,
    // since updateNSView (which carries the real values) runs before the proxy exists.
    @MainActor
    final class DropTargetAnchorView: NSView, Loggable {
        nonisolated static let logTag = "[LeftSidebar]"

        var listID: UUID = UUID()
        var listName: String = ""
        weak var dataCoordinator: DataCoordinator?
        var onTargetChanged: ((Bool) -> Void)?
        var onHoverChanged: ((Bool) -> Void)?
        // Weak reference so the proxy's own removal from NSTableRowView releases it.
        weak var proxy: RowDragProxyView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // viewDidMoveToWindow fires after the full NSView hierarchy is established:
            // anchor → NSHostingView → NSTableRowView → NSOutlineView → window.
            // viewDidMoveToSuperview fired too early — at that point NSHostingView had
            // no superview yet, so the NSTableRowView ancestor walk returned nil and
            // the proxy was never created.
            guard unsafe window != nil else { return }
            guard proxy == nil,
                  let rowView = findAncestor(ofType: NSTableRowView.self) else { return }
            let p = RowDragProxyView()
            p.listID = listID
            p.listName = listName
            p.dataCoordinator = dataCoordinator
            p.onTargetChanged = onTargetChanged
            p.onHoverChanged = onHoverChanged
            rowView.addSubview(p, positioned: .below, relativeTo: nil)
            p.frame = rowView.bounds
            proxy = p
            Self.noteProxy(installed: true)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // Clean up when the view leaves its window (e.g., app close / sidebar teardown).
            if newWindow == nil, let p = proxy {
                p.removeFromSuperview()
                proxy = nil
                Self.noteProxy(installed: false)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewWillMove(toSuperview newSuperview: NSView?) {
            // Clean up when SwiftUI removes the anchor from NSHostingView
            // (cell recycled for a different row or list item deleted).
            if newSuperview == nil, let p = proxy {
                p.removeFromSuperview()
                proxy = nil
                Self.noteProxy(installed: false)
            }
            super.viewWillMove(toSuperview: newSuperview)
        }

        // MARK: Proxy digest
        // Every sidebar row installs a proxy, all at once on each mount and again on each
        // reload, so a line per install filled the log. Installs and removals are counted
        // instead, and one digest line is written per burst.
        private static var liveProxies = 0
        private static var installedSinceDigest = 0
        private static var removedSinceDigest = 0
        private static var isDigestScheduled = false
        /// How long a burst may run before its digest is written.
        private static let digestDelay: TimeInterval = 0.5

        private static func noteProxy(installed: Bool) {
            if installed {
                liveProxies += 1
                installedSinceDigest += 1
            } else {
                liveProxies -= 1
                removedSinceDigest += 1
            }
            guard !isDigestScheduled else { return }
            isDigestScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + digestDelay) {
                isDigestScheduled = false
                log("RowDragProxyViews: \(liveProxies) installed "
                    + "(+\(installedSinceDigest) / -\(removedSinceDigest) since last digest)")
                installedSinceDigest = 0
                removedSinceDigest = 0
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
    // Attached directly to NSTableRowView; always sized to fill it.
    // Handles the full NSDraggingDestination protocol for this list row.
    // Because NSHostingView does NOT register for filmIDs drag types, AppKit's
    // drag hit-test falls through the hosting view to this proxy for the content
    // area, and the proxy is the only registered view in the padding areas.
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

        // Installs the tracking area once. `.inVisibleRect` makes AppKit keep its rect
        // equal to the visible bounds itself, so it is never torn down and replaced
        // while the cursor is inside it — a replacement delivers no mouseExited for the
        // area it removed, which was one way a row's hover state got stuck on.
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
        // Enter/exit events alone are not reliable: AppKit sends no mouseExited when the
        // row scrolls out from under a still cursor, when the app deactivates (the area
        // is .activeInActiveApp), while a menu opened from the ellipsis button is
        // tracking the mouse, or when the proxy is removed mid-hover. Each of those left
        // the ellipsis showing. So hover is owned by one row at a time, and every one of
        // those moments re-derives it from where the cursor actually is.

        /// The one row currently reporting hover. Entering another row clears it.
        private static weak var hoveredProxy: RowDragProxyView?
        private static var observersInstalled = false

        private var isHoverReported = false

        private func setHovered(_ hovering: Bool) {
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

        private static func installObserversIfNeeded() {
            guard !observersInstalled else { return }
            observersInstalled = true
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSApplication.didResignActiveNotification,
                NSApplication.didBecomeActiveNotification,
                NSMenu.didEndTrackingNotification,
                NSScrollView.didLiveScrollNotification,
                NSScrollView.didEndLiveScrollNotification,
                NSWindow.didResignKeyNotification,
            ]
            for name in names {
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { reconcileCurrent() }
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Self.installObserversIfNeeded()
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
            // Routed through the shared FilmDragDecoder utility (rather than
            // decoding the .filmIDs pasteboard type by hand) so this drop handler
            // gets the same JSON-pasteboard-type fallback and diagnostic logging
            // as any other consumer, with no change to the happy-path decode.
            guard let filmIDs = FilmDragDecoder.decode(from: sender),
                  !filmIDs.isEmpty else {
                return false
            }
            guard let coordinator = dataCoordinator else { return false }

            // "Up Next" is capped at eight. A drop that would not fit is not added there;
            // its alert (waiting for the drag session to end, as the confirmation below
            // does) offers "Soon" instead. The drop is accepted, so the drag preview does
            // not fly back as if it had failed — the alert carries the decision.
            if listID == FilmQueueSection.upNext.listID,
               FilmQueue.upNextOverflow(adding: filmIDs, coordinator: coordinator) > 0 {
                log("Drop of \(filmIDs.count) film(s) on '\(listName)' would overflow it — offering 'Soon'")
                AppEventBus.shared.sendAlert(.offerSoonForFullUpNextDrop(
                    filmIDs: filmIDs,
                    message: FilmQueue.upNextFullDropMessage(filmIDs, coordinator: coordinator)))
                return true
            }

            // Special-sorting confirmation gate — `FilmQueue.addNeedsConfirmation`, the
            // rule the "Add to Queue" menus and FilmSheet picker also apply. Only applies when the
            // drop target is one of the three internal Film Queue lists — ordinary
            // user lists are unaffected. When enabled and at least one dropped film
            // carries a non-empty specialSorting value, the add is deferred to
            // AlertHostView's confirmation alert instead of proceeding immediately.
            // Canceling that alert cancels the entire drop; confirming adds the full
            // set exactly as the unconfirmed path below does.
            if FilmQueue.isInternalList(listID),
               FilmQueue.addNeedsConfirmation(filmIDs, coordinator: coordinator) {
                log("Deferring add of \(filmIDs.count) film(s) to list '\(listName)' pending special-sorting confirmation")
                // Sent synchronously and directly, on the same call stack as the
                // drop — like the unconfirmed add path below. AlertHostView does
                // NOT present the alert on receipt of this event: it stashes the
                // payload (and composes the alert message, freezing it to the
                // films' state at drop time) and waits for the .dragSessionDidEnd
                // notification posted by GalleryDragEngine when AppKit delivers
                // its session-end callback. That callback is deferred by AppKit
                // until after its own drag-completion rendering pass, so anchoring
                // presentation there guarantees Core Animation drives the alert's
                // appear animation with no drag-teardown work contending for the
                // main thread. (Presenting from here — even deferred one run-loop
                // turn via DispatchQueue.main.async — lands mid-rendering-pass and
                // the appear animation's frames are dropped.) Sending synchronously
                // guarantees the stash exists before the session-end notification
                // for this drag can possibly fire.
                AppEventBus.shared.sendAlert(.confirmFilmQueueAddOnDrop(filmIDs: filmIDs, listID: listID))
                return true
            }

            log("Adding \(filmIDs.count) film(s) to list '\(listName)'")

            // Called synchronously and directly — NOT wrapped in Task { ... }.
            // performDragOperation arrives on the main thread from inside
            // NSDraggingSession's internal event-tracking run loop. That mode defers
            // Swift Concurrency's main-actor continuations until the tracking session
            // unwinds, so a Task spawned here would not actually start running until
            // after concludeDragOperation and AppKit's own drag-completion rendering
            // pass — which is precisely the ~1 second delay this works around.
            // Calling the synchronous, non-suspending path here instead means the
            // membership change and its event posts happen on the same call stack,
            // before AppKit even begins its completion teardown.
            FilmManager.addFilmsToList(filmIDs, listID: listID, coordinator: coordinator)
            return true
        }

        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
            onTargetChanged?(false)
            // Dismiss the drag-preview flyback window immediately, in lockstep with
            // the sidebar highlight clearing and the cursor reverting. AppKit defers
            // the NSDraggingSource `endedAt` callback until after its own drag-
            // completion rendering pass, which introduces a visible multi-frame lag.
            // Posting this notification fires at the exact moment the other UI changes
            // apply, and GalleryDragEngine observes it to call dismissFlybackImmediately().
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
                // The sidebar's list rows track cachedLists automatically: it is refreshed
                // synchronously at every mutation site (createList / updateList / deleteList /
                // add- and removeFilmsFromList) via syncListsCache(), and the List's
                // @Observable subscription plus the .animation(.default, value: cachedLists)
                // modifier drive insertions, deletions, reorders, and film-count changes.
                // Per-row feedback for content operations is handled by ListRow itself via
                // operationStarted/operationCompleted. The only event needing explicit
                // handling here is deletion of the list the user is currently viewing —
                // in which case the selection must move off the now-gone list.
                if case .deleted(let deletedListID) = event,
                    case .list(let selectedListID) = appState.selectedSidebarItem,
                    selectedListID == deletedListID {
                    appState.navigate(to: .libraryItem(.allFilms))
                }
            }
            // ImportProgress is now @Observable; $-publisher projections are unavailable.
            // .onChange(of:) uses the observation graph to deliver the same notifications.
            .onChange(of: ImportProgress.shared.isImporting) { _, isImporting in
                // Only the rising edge matters: it displaces a lingering .completed
                // checkmark so a newly started import isn't masked by the previous one's
                // confirmation. The falling edge is deliberately ignored — .completed is
                // set by the completionStatus handler below, which fires around the same
                // moment and must win. (Writing the value back to itself on the falling
                // edge, as this once did, was a no-op that still invalidated the view.)
                if isImporting {
                    importsGlyphState.wrappedValue = .importing
                }
            }
            .onChange(of: ImportProgress.shared.completionStatus) { _, status in
                guard status == .success || status == .successWithErrors else { return }

                // Set to the matching completed state. `.successWithErrors` earns the
                // warning glyph rather than the checkmark: the import finished, but not
                // everything in it landed, and the session card carries the detail.
                importsGlyphState.wrappedValue =
                    status == .successWithErrors ? .completedWithErrors : .completed

                // If already on Imports view, auto-clear after 2 seconds
                if case .libraryItem(.imports) = appState.selectedSidebarItem {
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        // Re-read wrappedValue after the delay rather than capturing it up front.
                        // This intentionally checks the live state: a new import may have started
                        // during the delay and set .importing, in which case we must not revert to
                        // .normal and lose that indicator.
                        if importsGlyphState.wrappedValue.isFinished {
                            importsGlyphState.wrappedValue = .normal
                        }
                    }
                }
            }
    }
}
