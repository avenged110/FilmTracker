// MARK: - RecentsSummary.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// The Recents summary tab (RecentsCategory.summary): one section per Recents category, each a band like the
/// gallery's section dividers over a single, horizontally scrolling row of gallery cells. The band's trailing
/// "Show All" button opens that category's own tab. All six sections are always present and equally tall. One
/// with no films shows a line of text where its row would be.
///
/// The cells are the gallery's own (GalleryItem in a GalleryCollectionView), sized by the grid's column math, so
/// a row here matches a row of any other view at the same window width. Selection lives in SelectionState, by
/// film ID, as everywhere else. A film in several categories is therefore selected in each row it appears in.

import SwiftUI
import AppKit
import Combine

/// Reusable cell identifier for a summary row's GalleryItem.
private let kSummaryItemID = NSUserInterfaceItemIdentifier("RecentsSummaryItem")

/// Clear space above and below a row's cells, inside the row's own scroll view, so the selection ring and the
/// poster shadow are not clipped at the cell's edge.
private let kRowPadding: CGFloat = 4

// MARK: - RecentsSummaryView

struct RecentsSummaryView: NSViewRepresentable, Loggable {
    nonisolated static let logTag = "[RecentsSummary]"

    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SelectionState.self) private var selectionState
    /// The StatusBar's height, 0 when hidden (StatusBarLayout.height, from GalleryView), for the bottom inset.
    let statusBarHeight: CGFloat
    /// Observes the large grid preference, for the column maximum the cells are sized from.
    @AppStorage(preference: Preferences.largeGalleryGridKey) private var largeGalleryGrid: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(selectionState: selectionState)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SummaryScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .allowed
        /// Overlay scrollers, as the grid uses: the rows take their width from the scroll view's bounds.
        scrollView.scrollerStyle = .overlay

        let document = SummaryDocumentView()
        scrollView.documentView = document

        let coordinator = context.coordinator
        coordinator.attach(scrollView: scrollView, document: document)
        scrollView.onLayout = { [weak coordinator] in coordinator?.layoutSections() }
        document.onBackgroundMouseDown = { [weak coordinator] in coordinator?.trackMarquee(from: $0) }

        /// The handoffs a gallery consumes as it mounts (see GallerySubview.makeNSView), so neither is left
        /// armed for a later visit: a film to bring into view, and keyboard focus after a search exit.
        coordinator.pendingRevealFilmID = GalleryScrollIntent.shared.consume(ifTargeting: .recents(.summary))
        coordinator.pendingKeyboardFocus = GalleryFocusIntent.shared.consume(ifTargeting: .recents(.summary))
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if scrollView.scrollerInsets.bottom != statusBarHeight {
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: statusBarHeight, right: 0)
        }
        coordinator.bottomInset = statusBarHeight
        coordinator.maxColumns = largeGalleryGrid ? Preferences.galleryMaxColumnsLargeGrid
                                                  : Preferences.galleryMaxColumns

        /// Stale-pass guard, as in GallerySubview: until the loaded films are this tab's, nothing is owed.
        let films = dataCoordinator.films
        guard ViewStateManager.shared.activeView == .recents(.summary),
              dataCoordinator.loadedRecentsCategory == .summary else { return }

        if PosterCache.shared.needsLaunchWarm, !films.isEmpty {
            PosterCache.shared.registerLaunchDisplayOrder(films.map(\.posterUID))
        }
        if !films.isEmpty { LaunchReveal.shared.galleryWillAppear(scrollView) }

        coordinator.update(films: films)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, Loggable {
        nonisolated static let logTag = "[RecentsSummary]"

        /// One film's place in the summary: its row, and its index in that row.
        private struct Position: Equatable {
            let category: RecentsCategory
            var item: Int
        }

        /// The scroll offsets of the last summary on screen this session, so that returning to the tab (from a
        /// Show All, say) returns to the same place. Row offsets are in cells, since the cell width follows
        /// the window's. Applied only under Preferences.maintainScrollPositionOnViewSwitch.
        private struct SavedScroll {
            var vertical: CGFloat = 0
            var rowCells: [RecentsCategory: CGFloat] = [:]
        }
        private static var savedScroll: SavedScroll?

        private let selectionState: SelectionState
        private weak var scrollView: NSScrollView?
        private weak var document: SummaryDocumentView?
        /// Every category's row, in display order.
        private var rows: [SummaryRow] = []
        /// The rubber band of a marquee drag, and whether one is being tracked.
        private let marqueeView = SummaryMarqueeView()
        private var isTrackingMarquee = false

        /// One-shot arrivals from makeNSView, acted on by the first layout that has films.
        fileprivate var pendingRevealFilmID: UUID?
        fileprivate var pendingKeyboardFocus = false

        var bottomInset: CGFloat = 0 { didSet { if bottomInset != oldValue { layoutSections() } } }
        var maxColumns: Int = Preferences.galleryMaxColumns {
            didSet { if maxColumns != oldValue { layoutSections() } }
        }

        /// The fixed end of a Shift range, and the moving end the arrow keys step from.
        private var anchor: Position?
        private var cursor: Position?

        /// What the last layout pass was computed from. A pass with the same inputs is skipped.
        private struct LayoutInputs: Equatable {
            let width: CGFloat
            let scale: CGFloat
            let maxColumns: Int
            let bottomInset: CGFloat
            /// The rows showing their placeholder line in place of cells.
            let empty: [RecentsCategory]
        }
        private var lastLayoutInputs: LayoutInputs?
        private var hasRestoredScroll = false
        /// True until the first layout that places films. That layout attaches only the rows on screen (see
        /// deferOffscreenRows); the rest follow after the first frame.
        private var isFirstMount = true
        /// Bumped by tearDown, so a deferred attach scheduled for this summary does nothing after it is gone.
        private var mountGeneration = 0
        private var clipObserver: (any NSObjectProtocol)?

        private var cancellables = Set<AnyCancellable>()
        private var observationTask: Task<Void, Never>?
        /// Sends mostly vertical scrolls over a row to the summary's own scroll view (installScrollRouter).
        private var scrollMonitor: Any?
        /// The current gesture's axis, decided by its first event that moves: true sends it to the summary's
        /// scroll view, false leaves it to the row, nil is still undecided. Kept through the momentum phase.
        private var routesGestureVertically: Bool?

        init(selectionState: SelectionState) {
            self.selectionState = selectionState
            super.init()
        }

        fileprivate func attach(scrollView: NSScrollView, document: SummaryDocumentView) {
            self.scrollView = scrollView
            self.document = document
            rows = RecentsCategory.sections.map { SummaryRow(category: $0, owner: self) }
            observeSelectionState()
            subscribeToCommands()
            installScrollRouter()
        }

        /// A row's scroll view takes every gesture that starts over it, vertical ones included, which left the
        /// page scrollable only from the bands between rows. Overriding the row's scrollWheel(with:) would fix
        /// that but turns off responsive scrolling (see SummaryRowScrollView), so this monitor routes instead:
        /// a gesture over a row whose first movement is mostly vertical goes to the summary's scroll view whole,
        /// momentum included. Horizontal and diagonal-leaning-horizontal gestures are left untouched.
        private func installScrollRouter() {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.route(event) ?? event
            }
        }

        private func route(_ event: NSEvent) -> NSEvent? {
            guard let scrollView, let window = unsafe scrollView.window, event.window === window else { return event }
            let dx = abs(event.scrollingDeltaX), dy = abs(event.scrollingDeltaY)

            /// A mouse wheel has no phases: each click is decided on its own.
            if event.phase.isEmpty && event.momentumPhase.isEmpty {
                guard dy > dx, isOverRow(event) else { return event }
                scrollView.scrollWheel(with: event)
                return nil
            }

            if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
                routesGestureVertically = isOverRow(event) ? nil : false
            }
            if routesGestureVertically == nil, dx > 0 || dy > 0 {
                routesGestureVertically = dy > dx
            }
            guard routesGestureVertically == true else { return event }
            scrollView.scrollWheel(with: event)
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                routesGestureVertically = nil
            }
            return nil
        }

        private func isOverRow(_ event: NSEvent) -> Bool {
            rows.contains { row in
                guard !row.scrollView.isHidden, unsafe row.scrollView.window != nil else { return false }
                return row.scrollView.bounds.contains(row.scrollView.convert(event.locationInWindow, from: nil))
            }
        }

        func tearDown() {
            saveScroll()
            cancellables.removeAll()
            observationTask?.cancel()
            observationTask = nil
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
            if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
            clipObserver = nil
            mountGeneration += 1
        }

        // MARK: - Films

        /// Fills each row with its category's first `summaryRowLimit` films, in the category's own order, less
        /// any the view did not load (those the active filters exclude).
        func update(films: [FilmSnapshot]) {
            let loaded = Dictionary(films.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var membershipChanged = false
            for row in rows {
                let ordered = row.category.orderedFilmIDs()
                let rowFilms = ordered.prefix(RecentsCategory.summaryRowLimit).compactMap { loaded[$0] }
                if row.setFilms(rowFilms, categoryIsEmpty: ordered.isEmpty) { membershipChanged = true }
            }
            layoutSections()
            /// A reloaded row has lost its highlight, a film may have left every row, and an index the arrow keys
            /// were tracking may now hold another film.
            if membershipChanged {
                anchor = nil
                cursor = nil
                syncSelectionFromState(deferringPrune: true)
            }
        }

        /// The rows with films, which are the ones the keyboard and the marquee can reach.
        private var shownRows: [SummaryRow] { rows.filter { !$0.films.isEmpty } }

        private func row(for category: RecentsCategory) -> SummaryRow? {
            rows.first { $0.category == category }
        }

        // MARK: - Layout

        /// Places every row's band and cells down the document, in the grid's geometry: the same insets, band
        /// height, spacing, and cell size as a gallery showing section dividers at this width. Cells stop growing
        /// where the grid's do, at the maximum grid width. The rows themselves are not capped: they always reach
        /// both edges of the window, so a wider window shows more of each row rather than larger posters.
        func layoutSections() {
            guard let scrollView, let document else { return }
            let width = scrollView.bounds.width
            guard width > 0 else { return }
            let scale = unsafe scrollView.window?.backingScaleFactor ?? 2.0
            let inputs = LayoutInputs(width: width, scale: scale, maxColumns: maxColumns,
                                      bottomInset: bottomInset,
                                      empty: rows.filter { $0.films.isEmpty }.map(\.category))
            guard inputs != lastLayoutInputs else { return }
            lastLayoutInputs = inputs

            let metrics = SmoothResizingGridLayout.columnMetrics(scrollWidth: width, scale: scale,
                                                                 maxColumns: maxColumns)
            let edge = SmoothResizingGridLayout.edgeInset
            let spacing = SmoothResizingGridLayout.lineSpacing
            let bandHeight = SmoothResizingGridLayout.dividerHeight
            /// Every row has a date subtitle. Snapped to a backing pixel, since each row is its own view.
            let itemHeight = (metrics.itemHeight(hasSubtitles: true) * scale).rounded() / scale
            let itemSize = NSSize(width: metrics.baseItemWidth, height: itemHeight)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            /// A fresh summary places every row's band and geometry, but holds back the cells of rows off screen.
            let deferring = isFirstMount && rows.contains { !$0.films.isEmpty }
            if deferring {
                isFirstMount = false
                for row in rows { row.cellsDeferred = true }
            }

            var y = edge
            for (index, row) in rows.enumerated() {
                if index > 0 { y += spacing }
                row.header.frame = NSRect(x: edge, y: y, width: max(0, width - 2 * edge), height: bandHeight)
                y += bandHeight + spacing
                /// The same rect whether the row has cells or its placeholder line, so every section is as tall.
                row.place(in: document,
                          contentFrame: NSRect(x: 0, y: y - kRowPadding, width: width,
                                               height: itemHeight + 2 * kRowPadding),
                          itemSize: itemSize)
                y += itemHeight
            }
            document.frame = NSRect(x: 0, y: 0, width: width, height: y + edge + bottomInset)

            /// A shorter document, after the window widened, must not leave the viewport past its end.
            let clip = scrollView.contentView
            let maxY = max(0, document.frame.height - clip.bounds.height)
            if clip.bounds.origin.y > maxY {
                clip.setBoundsOrigin(NSPoint(x: 0, y: maxY))
                scrollView.reflectScrolledClipView(clip)
            }

            applyArrivalIfNeeded()
            if deferring { deferOffscreenRows() }
        }

        // MARK: - Lazy Rows

        /// Attaches the cells of the rows on screen (with a row's margin) and of the first row with films, which
        /// keyboard focus lands on; the others attach one per run-loop turn once the first frame is up. Building
        /// every row's cells before that frame cost the whole summary's cells (about seven rows' worth) up front,
        /// when two or three rows are visible. The deferred rows are already placed, so nothing moves when they
        /// attach, and their selection is applied as for any row. Scrolling attaches any row it brings near.
        private func deferOffscreenRows() {
            guard let scrollView, let document else { return }
            shownRows.first?.attachCells(in: document)
            attachRowsNearViewport()
            #if DEBUG
            SummaryLazyProbe.attachedAtMount = rows.filter { !$0.cellsDeferred && !$0.films.isEmpty }.map(\.category)
            #endif

            scrollView.contentView.postsBoundsChangedNotifications = true
            clipObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.attachRowsNearViewport() }
            }

            /// Two hops: the first lands before this turn's display commit, the second after it.
            let generation = mountGeneration
            DispatchQueue.main.async {
                DispatchQueue.main.async { [weak self] in
                    #if DEBUG
                    SummaryLazyProbe.cellsAtFirstFrame = SummaryLazyProbe.cellsMade
                    #endif
                    self?.attachNextDeferredRow(generation: generation)
                }
            }
        }

        private func attachNextDeferredRow(generation: Int) {
            guard generation == mountGeneration, let document,
                  let row = rows.first(where: { $0.cellsDeferred }) else {
                if generation == mountGeneration { stopObservingClip() }
                return
            }
            row.attachCells(in: document)
            DispatchQueue.main.async { [weak self] in self?.attachNextDeferredRow(generation: generation) }
        }

        private func attachRowsNearViewport() {
            guard let scrollView, let document else { return }
            let visible = scrollView.documentVisibleRect
            let margin = rows.first.map { $0.contentFrame.height + SmoothResizingGridLayout.dividerHeight } ?? 0
            let near = visible.insetBy(dx: 0, dy: -margin)
            for row in rows where row.cellsDeferred && row.contentFrame.intersects(near) {
                row.attachCells(in: document)
            }
            if !rows.contains(where: { $0.cellsDeferred }) { stopObservingClip() }
        }

        private func stopObservingClip() {
            if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
            clipObserver = nil
        }

        // MARK: - Scroll Position

        private func saveScroll() {
            guard let scrollView, hasRestoredScroll else { return }
            var saved = SavedScroll(vertical: scrollView.contentView.bounds.origin.y)
            for row in shownRows { saved.rowCells[row.category] = row.scrollOffsetInCells }
            Self.savedScroll = saved
        }

        /// Runs once, on the first layout that has films to place. A film handed off by the previous view outranks
        /// the saved offsets, as it does in the grid.
        private func applyArrivalIfNeeded() {
            guard !hasRestoredScroll, let scrollView, let document, let firstRow = shownRows.first else { return }
            hasRestoredScroll = true

            if pendingKeyboardFocus {
                pendingKeyboardFocus = false
                /// A turn later, once this layout pass is over.
                DispatchQueue.main.async { [weak self] in
                    if let document = self?.document { firstRow.attachCells(in: document) }
                    unsafe firstRow.collectionView.window?.makeFirstResponder(firstRow.collectionView)
                }
            }

            if let filmID = pendingRevealFilmID {
                pendingRevealFilmID = nil
                for row in shownRows {
                    if let item = row.films.firstIndex(where: { $0.id == filmID }) {
                        reveal(Position(category: row.category, item: item))
                        return
                    }
                }
            }

            guard Preferences.maintainScrollPositionOnViewSwitch, let saved = Self.savedScroll else { return }
            for row in shownRows {
                if let cells = saved.rowCells[row.category], cells > 0 { row.scrollOffsetInCells = cells }
            }
            let maxY = max(0, document.frame.height - scrollView.contentView.bounds.height)
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: min(max(0, saved.vertical), maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // MARK: - Selection

        /// The films highlighted right now. Read from the collection views, not SelectionState, whose deferred
        /// write can lag a click by a run-loop turn.
        private func currentSelectionIDs() -> Set<UUID> {
            rows.reduce(into: Set<UUID>()) { $0.formUnion($1.selectedFilmIDs) }
        }

        /// Highlights `ids` in every row at once, then publishes them.
        private func applySelection(_ ids: Set<UUID>, immediate: Bool, inputKind: SelectionInputKind) {
            for row in rows { row.showSelection(ids) }
            if immediate {
                selectionState.selectImmediate(ids, inputKind: inputKind)
            } else {
                selectionState.select(ids, inputKind: inputKind)
            }
        }

        /// Brings the rows' highlight in line with SelectionState, and drops any selected film that no row
        /// shows. From an update pass the prune is deferred, since it must not publish during a view update.
        private func syncSelectionFromState(deferringPrune: Bool) {
            /// A deferred selection is about to land and will sync again. A marquee in progress owns the highlight
            /// until it ends and publishes.
            guard !selectionState.hasPendingSelection, !isTrackingMarquee else { return }
            let selected = selectionState.untrackedSelectedFilmIDs
            let shownIDs = rows.reduce(into: Set<UUID>()) { $0.formUnion($1.filmIDs) }
            let valid = selected.intersection(shownIDs)
            for row in rows { row.showSelection(valid) }
            if valid.isEmpty {
                anchor = nil
                cursor = nil
            }
            guard valid.count != selected.count else { return }
            if deferringPrune {
                selectionState.select(valid)
            } else {
                selectionState.selectImmediate(valid)
            }
        }

        /// Watches SelectionState for changes made elsewhere, with the same one-shot observation loop as
        /// GallerySubview.Coordinator.observeSelectionState (see there for the priority).
        private func observeSelectionState() {
            /// The wait holds only the selection state, so a dismantled summary is not kept alive by its loop.
            let selectionState = selectionState
            observationTask = Task(priority: .userInitiated) { @MainActor [weak self] in
                while !Task.isCancelled {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        withObservationTracking {
                            _ = selectionState.selectedFilmIDs
                        } onChange: {
                            continuation.resume()
                        }
                    }
                    guard !Task.isCancelled, let self else { break }
                    self.syncSelectionFromState(deferringPrune: false)
                }
            }
        }

        private func subscribeToCommands() {
            AppEventBus.shared.selectionEvents
                .receive(on: RunLoop.main)
                .sink { [weak self] event in
                    guard let self else { return }
                    switch event {
                    case .selectAllFilms: self.selectAll()
                    case .clearFocusRings:
                        for row in self.rows { row.showSelection([]) }
                        self.anchor = nil
                        self.cursor = nil
                    }
                }
                .store(in: &cancellables)

            /// Cmd+L: brings the first selected film into view.
            AppEventBus.shared.uiCommands
                .receive(on: RunLoop.main)
                .sink { [weak self] command in
                    guard let self, command == .scrollToSelection else { return }
                    for row in self.shownRows {
                        if let item = row.collectionView.selectionIndexPaths.map(\.item).min() {
                            self.reveal(Position(category: row.category, item: item))
                            return
                        }
                    }
                }
                .store(in: &cancellables)
        }

        func selectAll() {
            let ids = rows.reduce(into: Set<UUID>()) { $0.formUnion($1.filmIDs) }
            anchor = nil
            cursor = nil
            applySelection(ids, immediate: true, inputKind: .unspecified)
        }

        // MARK: - Clicks

        /// Resolves a click on a cell. GalleryCollectionView calls the row's delegate at mouse-down for a click
        /// that changes the selection, and at mouse-up for a plain click on a selected cell that did not
        /// become a drag. It has already toggled a Cmd-click in the row's own selection.
        fileprivate func handleClick(in row: SummaryRow, at indexPath: IndexPath) {
            guard let clickedID = row.filmID(at: indexPath.item) else { return }
            let flags = NSEvent.modifierFlags
            let clicked = Position(category: row.category, item: indexPath.item)
            let ids: Set<UUID>

            if flags.contains(.shift), let anchor, anchor.category == row.category {
                /// A range within the row the anchor is in. Rows are separate lines, so a range never spans two.
                let range = min(anchor.item, clicked.item)...max(anchor.item, clicked.item)
                ids = Set(range.compactMap { row.filmID(at: $0) })
                cursor = clicked
            } else if flags.contains(.command) {
                var toggled = currentSelectionIDs()
                if row.collectionView.selectionIndexPaths.contains(indexPath) {
                    toggled.insert(clickedID)
                } else {
                    /// Removed by ID, so the film's copies in other rows are deselected with it.
                    toggled.remove(clickedID)
                }
                ids = toggled
                anchor = clicked
                cursor = clicked
            } else {
                ids = [clickedID]
                anchor = clicked
                cursor = clicked
            }
            applySelection(ids, immediate: false, inputKind: .fromCurrentAppKitEvent())
        }

        /// The films a drag that starts on `indexPath` carries: the whole selection when the cell is in it,
        /// otherwise that film alone.
        fileprivate func filmIDsForDrag(in row: SummaryRow, clickedAt indexPath: IndexPath?) -> Set<UUID> {
            guard let indexPath, let clickedID = row.filmID(at: indexPath.item) else { return [] }
            let selection = currentSelectionIDs()
            return selection.contains(clickedID) ? selection : [clickedID]
        }

        /// The contextual menu for a secondary click on a cell. A click outside the selection selects that
        /// film first, as in the grid (GallerySubview.Coordinator.contextMenu).
        fileprivate func contextMenu(in row: SummaryRow, forItemAt indexPath: IndexPath) -> NSMenu? {
            guard let clickedID = row.filmID(at: indexPath.item) else { return nil }
            var targetIDs = currentSelectionIDs()
            if !targetIDs.contains(clickedID) {
                let clicked = Position(category: row.category, item: indexPath.item)
                anchor = clicked
                cursor = clicked
                targetIDs = [clickedID]
                applySelection(targetIDs, immediate: true, inputKind: .fromCurrentAppKitEvent())
            }
            return GalleryContextMenu.makeMenu(for: targetIDs)
        }

        // MARK: - Marquee

        /// The row whose section is nearest a point in the document, among the rows with films.
        private func nearestRow(toY y: CGFloat) -> SummaryRow? {
            shownRows.min { distance(from: y, to: $0) < distance(from: y, to: $1) }
        }

        private func distance(from y: CGFloat, to row: SummaryRow) -> CGFloat {
            let section = row.header.frame.union(row.contentFrame)
            return y < section.minY ? section.minY - y : max(0, y - section.maxY)
        }

        /// Runs a marquee drag that began on empty space: a band, the gap between sections, or the space around
        /// a row's cells. The whole drag selects in one section only, the one nearest where it began, however
        /// far the pointer then travels. Shift or Command keeps the existing selection and adds to it, as in
        /// the grid. A press that never becomes a drag clears the selection.
        ///
        /// The drag is tracked here, in a loop over the window's events, since it starts in any of several
        /// views. The highlight follows the drag, and the selection is published once, when it ends.
        fileprivate func trackMarquee(from event: NSEvent) {
            guard let document, let scrollView, let window = unsafe document.window, !isTrackingMarquee else { return }
            let start = document.convert(event.locationInWindow, from: nil)
            let extending = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
            let base = extending ? currentSelectionIDs() : []
            let row = nearestRow(toY: start.y)
            row?.attachCells(in: document)
            if let row { window.makeFirstResponder(row.collectionView) }

            isTrackingMarquee = true
            document.addSubview(marqueeView, positioned: .above, relativeTo: nil)
            marqueeView.isHidden = true
            var selected = base

            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let point = document.convert(next.locationInWindow, from: nil)
                let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                  width: abs(point.x - start.x), height: abs(point.y - start.y))
                /// The grid's threshold: a smaller movement is still a click.
                if rect.width > 5 || rect.height > 5 {
                    marqueeView.frame = rect.intersection(document.bounds)
                    marqueeView.isHidden = false
                    selected = base.union(row?.filmIDs(inDocumentRect: rect, of: document) ?? [])
                } else {
                    marqueeView.isHidden = true
                    selected = base
                }
                for row in rows { row.showSelection(selected) }
                if next.type == .leftMouseUp { break }
                /// Scrolls the summary while the pointer is dragged past its top or bottom edge.
                scrollView.contentView.autoscroll(with: next)
            }

            marqueeView.removeFromSuperview()
            isTrackingMarquee = false
            anchor = nil
            cursor = nil
            applySelection(selected, immediate: false, inputKind: .unspecified)
        }

        // MARK: - Keyboard

        /// Keyboard focus arrived with nothing selected: selects the first film, so the arrow keys have a
        /// place to start.
        fileprivate func seedInitialCursor() {
            guard currentSelectionIDs().isEmpty, !selectionState.hasPendingSelection,
                  let first = shownRows.first else { return }
            moveSelection(to: Position(category: first.category, item: 0), inputKind: .unspecified)
        }

        /// Left and Right step along the row, and Shift extends the range there. Up and Down move to the cell
        /// directly above or below in the neighboring row, as the rows are scrolled right now.
        fileprivate func handleArrowKey(_ direction: ArrowDirection, withShift: Bool, isRepeat: Bool) {
            let shown = shownRows
            guard let firstRow = shown.first else { return }
            let inputKind: SelectionInputKind = isRepeat ? .keyRepeat : .discrete

            guard let start = resolvedCursor(in: shown), let startRow = row(for: start.category) else {
                moveSelection(to: Position(category: firstRow.category, item: 0), inputKind: inputKind)
                return
            }

            switch direction {
            case .left, .right:
                let target = min(max(0, start.item + (direction == .right ? 1 : -1)), startRow.films.count - 1)
                guard target != start.item else { return }
                let destination = Position(category: start.category, item: target)
                if withShift, let anchor, anchor.category == start.category {
                    let range = min(anchor.item, target)...max(anchor.item, target)
                    cursor = destination
                    applySelection(Set(range.compactMap { startRow.filmID(at: $0) }),
                                   immediate: true, inputKind: inputKind)
                    reveal(destination)
                } else {
                    moveSelection(to: destination, inputKind: inputKind)
                }

            case .up, .down:
                guard let index = shown.firstIndex(where: { $0.category == start.category }) else { return }
                let targetIndex = index + (direction == .down ? 1 : -1)
                guard shown.indices.contains(targetIndex) else { return }
                let targetRow = shown[targetIndex]
                /// Its cells must be in the window to map the column across (see deferOffscreenRows).
                if let document { targetRow.attachCells(in: document) }
                let item = targetRow.itemNearest(windowX: startRow.windowMidX(ofItem: start.item))
                moveSelection(to: Position(category: targetRow.category, item: item), inputKind: inputKind)
                unsafe targetRow.collectionView.window?.makeFirstResponder(targetRow.collectionView)
            }
        }

        /// Where the arrow keys step from: the tracked cursor while its film is still highlighted, otherwise the
        /// first highlighted film, top row first.
        private func resolvedCursor(in shown: [SummaryRow]) -> Position? {
            if let cursor, let row = row(for: cursor.category),
               row.collectionView.selectionIndexPaths.contains(IndexPath(item: cursor.item, section: 0)) {
                return cursor
            }
            for row in shown {
                if let item = row.collectionView.selectionIndexPaths.map(\.item).min() {
                    return Position(category: row.category, item: item)
                }
            }
            return nil
        }

        /// Selects the one film at `position` and brings it into view.
        private func moveSelection(to position: Position, inputKind: SelectionInputKind) {
            guard let id = row(for: position.category)?.filmID(at: position.item) else { return }
            anchor = position
            cursor = position
            applySelection([id], immediate: true, inputKind: inputKind)
            reveal(position)
        }

        /// Scrolls the row sideways to the cell, and the summary up or down to the row's whole section.
        private func reveal(_ position: Position) {
            guard let row = row(for: position.category), let document else { return }
            appViewportMove {
                row.scrollItemToVisible(position.item)
                let section = row.header.frame.union(row.contentFrame)
                    .insetBy(dx: 0, dy: -SmoothResizingGridLayout.edgeInset)
                document.scrollToVisible(section)
            }
        }
    }
}

// MARK: - Summary Row

/// One category's section: its band, and the scroll view and collection view of its single row of cells.
@MainActor
private final class SummaryRow: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let category: RecentsCategory
    let header: SummaryHeaderView
    let scrollView = SummaryRowScrollView()
    let collectionView = GalleryCollectionView()
    /// Shown in place of the cells while the row has no films.
    private let emptyLabel = NSTextField(labelWithString: "")
    /// Where the row's cells, or its placeholder line, sit in the document.
    private(set) var contentFrame: NSRect = .zero
    private let flowLayout = SummaryRowLayout()
    /// The category's date, shown under each poster, as on its own tab.
    private let subtitleProvider: GallerySubtitleProvider?
    private weak var owner: RecentsSummaryView.Coordinator?

    private(set) var films: [FilmSnapshot] = []
    private(set) var filmIDs: Set<UUID> = []

    /// While true, the row's band and geometry are placed but its cells stay out of the document
    /// (Coordinator.deferOffscreenRows).
    var cellsDeferred = false

    init(category: RecentsCategory, owner: RecentsSummaryView.Coordinator) {
        self.category = category
        self.owner = owner
        header = SummaryHeaderView(category: category)
        subtitleProvider = category.dateType.map { dateType in
            GallerySubtitleProvider(kind: dateType.rawValue) { filmID in
                MetadataCache.shared.getFormattedDate(for: filmID, type: dateType)
            }
        }
        super.init()

        flowLayout.scrollDirection = .horizontal
        /// In a horizontal flow, the line spacing is the gap between one cell and the next.
        flowLayout.minimumLineSpacing = SmoothResizingGridLayout.itemSpacing
        flowLayout.minimumInteritemSpacing = 0
        flowLayout.sectionInset = NSEdgeInsets(top: kRowPadding, left: SmoothResizingGridLayout.edgeInset,
                                               bottom: kRowPadding, right: SmoothResizingGridLayout.edgeInset)

        collectionView.collectionViewLayout = flowLayout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        /// Layer-backed like the grid, so a sideways scroll moves layers and redraws nothing.
        collectionView.wantsLayer = true
        collectionView.layerContentsRedrawPolicy = .onSetNeedsDisplay

        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byTruncatingTail
        collectionView.register(GalleryItem.self, forItemWithIdentifier: kSummaryItemID)
        collectionView.dataSource = self
        collectionView.delegate = self
        scrollView.documentView = collectionView
        scrollView.onMoveToWindow = { [weak self] in self?.applyPendingOffset() }

        /// A press on the row's empty space starts the summary's own marquee.
        collectionView.onEmptySpaceMouseDown = { [weak owner] event in
            guard let owner else { return false }
            owner.trackMarquee(from: event)
            return true
        }
        collectionView.onArrowNavigation = { [weak owner] in
            owner?.handleArrowKey($0, withShift: $1, isRepeat: $2)
        }
        collectionView.onSelectAll = { [weak owner] in
            guard let owner else { return false }
            owner.selectAll()
            return true
        }
        collectionView.onKeyboardFocusWithNoSelection = { [weak owner] in owner?.seedInitialCursor() }
        collectionView.getFilmID = { [weak self] in self?.filmID(at: $0.item) }
        collectionView.getDragFilmIDs = { [weak self] indexPath in
            guard let self else { return [] }
            return self.owner?.filmIDsForDrag(in: self, clickedAt: indexPath) ?? []
        }
        collectionView.getPosterImage = { [weak self] filmID in
            guard let film = self?.films.first(where: { $0.id == filmID }) else { return nil }
            return PosterCache.shared.dragPreviewImage(for: film.posterUID)
        }
        collectionView.getContextMenu = { [weak self] indexPath in
            guard let self else { return nil }
            return self.owner?.contextMenu(in: self, forItemAt: indexPath)
        }
    }

    // MARK: Films

    func filmID(at item: Int) -> UUID? {
        films.indices.contains(item) ? films[item].id : nil
    }

    /// Installs the row's films, and returns whether the films themselves changed. The same films in the same
    /// order only reconfigure the cells on screen, which keeps the row's scroll offset and highlight. That pass
    /// runs even for equal snapshots, since a cell's date line comes from MetadataCache and not the snapshot. Each
    /// cell compares what it shows, so an unchanged one does no work.
    ///
    /// - Parameter categoryIsEmpty: Whether the category has no films at all, as opposed to none that pass the
    ///   active filters. It chooses the placeholder line, and whether Show All has anywhere to go.
    func setFilms(_ newFilms: [FilmSnapshot], categoryIsEmpty: Bool) -> Bool {
        header.setShowAllEnabled(!categoryIsEmpty)
        if newFilms.isEmpty {
            let text = categoryIsEmpty ? category.summaryEmptyText : category.summaryFilteredText
            if emptyLabel.stringValue != text { emptyLabel.stringValue = text }
        }

        let sameFilms = newFilms.count == films.count
            && zip(newFilms, films).allSatisfy { $0.id == $1.id }
        films = newFilms
        guard !sameFilms else {
            for indexPath in collectionView.indexPathsForVisibleItems() {
                guard let item = collectionView.item(at: indexPath) as? GalleryItem,
                      films.indices.contains(indexPath.item) else { continue }
                item.configure(with: films[indexPath.item], subtitleProvider: subtitleProvider)
            }
            return false
        }
        filmIDs = Set(newFilms.map(\.id))
        collectionView.reloadData()
        return true
    }

    /// The row's films whose cells a marquee touches, where those cells are on screen. `rect` is in the
    /// document's coordinates.
    func filmIDs(inDocumentRect rect: NSRect, of document: NSView) -> Set<UUID> {
        let visible = rect.intersection(contentFrame)
        guard !visible.isEmpty else { return [] }
        let local = collectionView.convert(visible, from: document)
        var ids = Set<UUID>()
        for (index, film) in films.enumerated() where frame(ofItem: index).intersects(local) {
            ids.insert(film.id)
        }
        return ids
    }

    // MARK: Selection

    var selectedFilmIDs: Set<UUID> {
        Set(collectionView.selectionIndexPaths.compactMap { filmID(at: $0.item) })
    }

    /// Highlights exactly the row's films that are in `ids`.
    func showSelection(_ ids: Set<UUID>) {
        var paths = Set<IndexPath>()
        if !ids.isEmpty, !ids.isDisjoint(with: filmIDs) {
            for (index, film) in films.enumerated() where ids.contains(film.id) {
                paths.insert(IndexPath(item: index, section: 0))
            }
        }
        if collectionView.selectionIndexPaths != paths { collectionView.selectionIndexPaths = paths }
    }

    // MARK: Geometry

    /// Puts the row's band in the document, with its cells at `contentFrame`, or its placeholder line centered
    /// there while it has no films. An empty row's collection view leaves the document, so keyboard focus
    /// (KeyboardManager.focusGalleryGrid) never lands on a row with nothing in it.
    func place(in document: NSView, contentFrame: NSRect, itemSize: NSSize) {
        self.contentFrame = contentFrame
        if !header.isDescendant(of: document) { document.addSubview(header) }

        guard !films.isEmpty else {
            scrollView.removeFromSuperview()
            let inset = SmoothResizingGridLayout.edgeInset
            let height = emptyLabel.intrinsicContentSize.height
            emptyLabel.frame = NSRect(x: contentFrame.minX + inset,
                                      y: (contentFrame.midY - height / 2).rounded(),
                                      width: max(0, contentFrame.width - 2 * inset), height: height)
            if !emptyLabel.isDescendant(of: document) { document.addSubview(emptyLabel) }
            return
        }

        emptyLabel.removeFromSuperview()
        scrollView.frame = contentFrame
        if cellsDeferred {
            setItemSize(itemSize)
            return
        }
        insertScrollView(in: document)
        setItemSize(itemSize)
    }

    /// Ends the row's deferral and puts its cells in the document, if it has films.
    func attachCells(in document: NSView) {
        guard cellsDeferred else { return }
        cellsDeferred = false
        guard !films.isEmpty else { return }
        insertScrollView(in: document)
    }

    /// Scrolls to an offset set while the row was out of a window, now that it is in one. Called by the row's
    /// scroll view as it joins a window, whether the row attached late or the whole summary just mounted.
    private func applyPendingOffset() {
        guard let offset = pendingOffsetInCells, unsafe scrollView.window != nil else { return }
        scrollOffsetInCells = offset
    }

    /// Directly above the row's band, so the document's subviews keep the rows' order (keyboard focus takes the
    /// first collection view it finds).
    private func insertScrollView(in document: NSView) {
        guard !scrollView.isDescendant(of: document) else { return }
        if header.isDescendant(of: document) {
            document.addSubview(scrollView, positioned: .above, relativeTo: header)
        } else {
            document.addSubview(scrollView)
        }
    }

    /// The distance from one cell's leading edge to the next's.
    private var stride: CGFloat { flowLayout.itemSize.width + flowLayout.minimumLineSpacing }

    private var maxScrollX: CGFloat {
        let count = CGFloat(films.count)
        let contentWidth = flowLayout.sectionInset.left + flowLayout.sectionInset.right
            + count * flowLayout.itemSize.width + max(0, count - 1) * flowLayout.minimumLineSpacing
        return max(0, contentWidth - scrollView.contentView.bounds.width)
    }

    /// An offset set while the row was out of a window. The clip view clamps a scroll there to zero (its
    /// collection view has no width yet), so the offset waits for the row to join one (applyPendingOffset).
    private var pendingOffsetInCells: CGFloat?

    /// The row's horizontal scroll offset in cells, which survives a change of cell width.
    var scrollOffsetInCells: CGFloat {
        get {
            if let pendingOffsetInCells { return pendingOffsetInCells }
            return stride > 0 ? scrollView.contentView.bounds.origin.x / stride : 0
        }
        set {
            guard unsafe scrollView.window != nil else {
                pendingOffsetInCells = newValue
                return
            }
            pendingOffsetInCells = nil
            collectionView.layoutSubtreeIfNeeded()
            let x = min(max(0, newValue * stride), maxScrollX)
            scrollView.contentView.setBoundsOrigin(NSPoint(x: x, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Resizes the cells, keeping the same cell at the row's leading edge.
    private func setItemSize(_ size: NSSize) {
        guard flowLayout.itemSize != size else { return }
        let offset = scrollOffsetInCells
        flowLayout.itemSize = size
        flowLayout.invalidateLayout()
        /// A row at its start stays there, with no layout pass forced to place it.
        if offset > 0 { scrollOffsetInCells = offset }
    }

    private func frame(ofItem item: Int) -> NSRect {
        NSRect(x: flowLayout.sectionInset.left + CGFloat(item) * stride, y: flowLayout.sectionInset.top,
               width: flowLayout.itemSize.width, height: flowLayout.itemSize.height)
    }

    /// The horizontal center of a cell, in window coordinates.
    func windowMidX(ofItem item: Int) -> CGFloat {
        let cell = frame(ofItem: item)
        return collectionView.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil).x
    }

    /// The cell under a window X coordinate, or the nearest one at either end.
    func itemNearest(windowX: CGFloat) -> Int {
        guard stride > 0, !films.isEmpty else { return 0 }
        let x = collectionView.convert(NSPoint(x: windowX, y: 0), from: nil).x
        let item = Int(((x - flowLayout.sectionInset.left) / stride).rounded(.down))
        return min(max(0, item), films.count - 1)
    }

    /// Scrolls sideways just far enough to show the whole cell with the row's inset beside it.
    func scrollItemToVisible(_ item: Int) {
        guard films.indices.contains(item) else { return }
        let clip = scrollView.contentView
        let cell = frame(ofItem: item).insetBy(dx: -flowLayout.sectionInset.left, dy: 0)
        var x = clip.bounds.origin.x
        if cell.minX < x {
            x = cell.minX
        } else if cell.maxX > x + clip.bounds.width {
            x = cell.maxX - clip.bounds.width
        } else {
            return
        }
        clip.setBoundsOrigin(NSPoint(x: min(max(0, x), maxScrollX), y: 0))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Data Source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        films.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let item = collectionView.makeItem(withIdentifier: kSummaryItemID, for: indexPath) as? GalleryItem,
              films.indices.contains(indexPath.item) else { return NSCollectionViewItem() }
        #if DEBUG
        SummaryLazyProbe.cellsMade += 1
        #endif
        item.configure(with: films[indexPath.item], subtitleProvider: subtitleProvider)
        return item
    }

    // MARK: Delegate

    /// Called by GalleryCollectionView itself, with the one clicked cell (see its SELECTION TIMING note).
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let clicked = indexPaths.first else { return }
        owner?.handleClick(in: self, at: clicked)
    }
}

// MARK: - Summary Header

/// A row's band: the category's name above a hairline, in the gallery's section-divider style
/// (SectionDividerDecorationView), with a "Show All" button where a divider shows its film count.
private final class SummaryHeaderView: NSView {
    private let category: RecentsCategory
    private let titleLabel = NSTextField(labelWithString: "")
    private let showAllButton = NSButton(title: "Show All", target: nil, action: nil)
    private let separatorLine = NSView()

    init(category: RecentsCategory) {
        self.category = category
        super.init(frame: .zero)
        wantsLayer = true

        titleLabel.stringValue = category.displayName
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        /// The standard push button, at the small size that fits the band.
        showAllButton.bezelStyle = .push
        showAllButton.controlSize = .small
        showAllButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        showAllButton.target = self
        showAllButton.action = #selector(showAll)
        showAllButton.toolTip = "Show all of \(category.displayName)"
        showAllButton.setAccessibilityLabel("Show All, \(category.displayName)")
        showAllButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(showAllButton)

        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separatorLine)

        NSLayoutConstraint.activate([
            separatorLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorLine.heightAnchor.constraint(equalToConstant: 2),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: separatorLine.topAnchor, constant: -6),

            showAllButton.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            showAllButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            showAllButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Off for a category with no films, whose tab would only show its own placeholder.
    func setShowAllEnabled(_ enabled: Bool) {
        if showAllButton.isEnabled != enabled { showAllButton.isEnabled = enabled }
    }

    /// A sidebar-style switch: a click has no menu fade to wait out, so the tab changes in this turn.
    @objc private func showAll() {
        RecentsState.shared.selectCategory(category, immediate: true)
    }

    /// A CALayer color does not follow appearance changes, so it is re-resolved when the appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        separatorLine.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

// MARK: - Scroll Views

/// The summary's vertical scroll view. It reports each layout pass, so the rows follow the window's width.
private final class SummaryScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}

/// The summary's document: a top-down stack of bands and rows, placed by the Coordinator.
private final class SummaryDocumentView: NSView {
    var onBackgroundMouseDown: ((NSEvent) -> Void)?

    override var isFlipped: Bool { true }

    /// A press on a band, a placeholder line, or the space between rows starts a marquee. One that never
    /// becomes a drag clears the selection, as a click on the grid's padding does.
    override func mouseDown(with event: NSEvent) {
        onBackgroundMouseDown?(event)
    }
}

/// The marquee's rubber band. It takes no clicks.
private final class SummaryMarqueeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        applyColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.35).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A row's horizontal scroll view.
///
/// It must not override scrollWheel(with:). AppKit turns off responsive scrolling for a scroll view whose class
/// does (NSScrollView.isCompatibleWithResponsiveScrolling), and every sideways scroll then runs on the main
/// thread with no overdraw prepared ahead of it, so any main-thread hitch shows as a jolt. The summary's own
/// vertical scroll view never had that override, which is why vertical scrolling stayed smooth.
///
/// A mostly vertical gesture over a row reaches the summary's vertical scroll view through the coordinator's
/// event monitor (Coordinator.installScrollRouter), not through this class.
private final class SummaryRowScrollView: NSScrollView {
    /// Called once the row is in a window (SummaryRow.applyPendingOffset).
    var onMoveToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if unsafe window != nil { onMoveToWindow?() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        borderType = .noBorder
        drawsBackground = false
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        usesPredominantAxisScrolling = true
        /// Layer-backed with the grid's redraw policy (GallerySubview.configureScrollView), so a sideways scroll
        /// moves layers and asks nothing to redraw.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        contentView.wantsLayer = true
        contentView.layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A row's flow layout. Scrolling sideways moves only the visible rect, which changes no cell's frame, so it
/// never invalidates the layout. A new cell size invalidates it explicitly (SummaryRow.setItemSize), and a
/// change of row height still does here.
private final class SummaryRowLayout: NSCollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView else { return false }
        return newBounds.height != collectionView.visibleRect.height
    }
}

// MARK: - Placeholder Text

private extension RecentsCategory {
    /// The line an empty section of the summary shows in place of its row.
    var summaryEmptyText: String {
        switch self {
        case .summary: return ""
        case .recentlyViewed: return "No films were recently viewed."
        case .recentlyRotated: return "No films recently came up for rotation."
        case .recentlyAdded: return "No films were recently added."
        case .recentlyUpdated: return "No films were recently updated."
        case .recentlyPurchased: return "No films were recently purchased."
        case .recentDiscRelease: return "No films had a disc release in the past 180 days."
        }
    }

    /// The line for a section whose films are all hidden by the active filters.
    var summaryFilteredText: String {
        switch self {
        case .summary: return ""
        case .recentlyViewed: return "No recently viewed films match the filters."
        case .recentlyRotated: return "No films that recently came up for rotation match the filters."
        case .recentlyAdded: return "No recently added films match the filters."
        case .recentlyUpdated: return "No recently updated films match the filters."
        case .recentlyPurchased: return "No recently purchased films match the filters."
        case .recentDiscRelease: return "No films with a recent disc release match the filters."
        }
    }
}

// MARK: - Lazy Rows Probe (DEBUG)

#if DEBUG
/// DEBUG view of the summary's lazy rows (Coordinator.deferOffscreenRows), for `summary-lazy-rows`.
@MainActor
enum SummaryLazyProbe {
    /// The rows with films whose cells were in the document when the first layout finished.
    static var attachedAtMount: [RecentsCategory] = []
    /// Cells made by the rows' data sources, counted from SummaryRow.
    static var cellsMade = 0
    /// `cellsMade` when the deferred rows began to attach, after the first frame.
    static var cellsAtFirstFrame = 0
}
#endif
