// MARK: - ReportsHelpers.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Reusable view components and configuration types shared across ReportsView tabs.

import SwiftUI
import AppKit

// MARK: - Gallery Title Order

/// A film's place in the gallery's Title sort, as one Comparable value, so report lists order titles as the gallery does. The rules follow
/// `MetadataCache.compareTitles`: letter-led titles before digit-led ones, then `englishStandardCompare` on the article-stripped sort name
/// (or name), then release year, then film id. The id makes the order total, so equal titles stay put between loads.
struct GalleryTitleKey: Comparable, Sendable {
    let startsWithNumber: Bool
    let key: String
    let year: Int
    let filmID: UUID

    init(name: String, sortName: String, year: Int, filmID: UUID) {
        let key = FilmMetadata.stripArticles(sortName.isEmpty ? name : sortName)
        self.key = key
        self.startsWithNumber = key.first?.isNumber ?? false
        self.year = year
        self.filmID = filmID
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.startsWithNumber != rhs.startsWithNumber { return !lhs.startsWithNumber }
        switch lhs.key.englishStandardCompare(rhs.key) {
        case .orderedAscending:  return true
        case .orderedDescending: return false
        case .orderedSame:       break
        }
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        return lhs.filmID.uuidString < rhs.filmID.uuidString
    }

    /// Equal exactly when neither sorts first, as `<` defines it.
    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

// MARK: - Empty State Configuration

/// Describes the two placeholder states for data-backed report tabs: one when the library is empty, and one when the library has films
/// but the tab's dataset is empty.
struct EmptyStateConfig {
    let glyph: String
    let noFilmsMessage: String
    let noDataMessage: String
}

// MARK: - Reports Empty State Wrapper

/// Wraps a report tab's content in the standard two-stage empty-state guard. With no films, the first placeholder shows. With an empty
/// tab dataset, the second shows. Otherwise `content` is shown.
///
/// Usage:
/// ```swift
/// ReportsEmptyStateWrapper(
///     totalFilmCount: dataCoordinator.totalFilmCount,
///     isEmpty: films.isEmpty,
///     config: emptyStateConfig
/// ) {
///     // active content
/// }
/// ```
struct ReportsEmptyStateWrapper<Content: View>: View {
    let totalFilmCount: Int
    let isEmpty: Bool
    let config: EmptyStateConfig
    @ViewBuilder let content: () -> Content

    var body: some View {
        /// A Group, since only one of the three arms is ever present.
        Group {
            if totalFilmCount == 0 {
                StandardPlaceholder(
                    glyph: config.glyph,
                    title: "No Films in Library",
                    message: config.noFilmsMessage
                )
            } else if isEmpty {
                StandardPlaceholder(
                    glyph: config.glyph,
                    title: "No Data",
                    message: config.noDataMessage
                )
            } else {
                content()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Reports Ranked List View

/// The ranked list used by Hall of Fame and Release Wishlist. It is a headerless `ReportTable` whose first two columns are always the
/// position ("12.") and the name. The caller supplies the rest. It handles status bar spacing and selection sync with `SelectionState`.
///
/// **Row anatomy:**
/// ```
/// [ position ]  [ name ………… ]  [ trailingColumns … ]
/// ```
///
/// The name is the only flexible column: it takes whatever the position and the fixed-width
/// trailing columns leave, and truncates.
struct ReportsRankedListView<Item: RankedItem & Equatable>: View where Item.ID == UUID {
    @Environment(SelectionState.self) private var selectionState

    let items: [Item]
    @Binding var selection: Set<UUID>
    let onSelectionChange: (Set<UUID>) -> Void
    /// Pass `nil` to disable drag-to-reorder.
    let onMove: ((IndexSet, Int) -> Void)?
    /// The primary display name for each row item.
    let primaryLabel: (Item) -> String
    /// The fixed-width columns to the right of the name.
    let trailingColumns: [ReportTableColumn<Item>]
    /// The narrowest the name column may get before the trailing columns give way.
    var primaryMinWidth: CGFloat = 80
    /// The film each row stands for, for the gallery contextual menu (ReportTable.menuFilmID).
    let menuFilmID: (Item) -> UUID

    /// Row pitch of the SwiftUI `List(.inset)` this replaced (12 pt text, 2 pt vertical padding).
    static var rowHeight: CGFloat { 27 }

    private var columns: [ReportTableColumn<Item>] {
        [ReportTableColumn(id: "position", width: 30, alignment: .right,
                           font: .systemFont(ofSize: 12, weight: .medium), isSecondary: true,
                           content: .text { "\($0.position)." }),
         ReportTableColumn(id: "name", width: primaryMinWidth, minWidth: primaryMinWidth,
                           maxWidth: .greatestFiniteMagnitude,
                           content: .text(primaryLabel))]
        + trailingColumns
    }

    var body: some View {
        ReportTable(rows: items, columns: columns, selection: $selection,
                    showsHeader: false, rowHeight: Self.rowHeight, onMove: onMove, topInset: 5,
                    menuFilmID: menuFilmID)
            .statusBarInset()
            .onChange(of: selection) { _, newSelection in
                onSelectionChange(newSelection)
            }
            .onChange(of: selectionState.selectedFilmIDs) { _, newSelectedFilmIDs in
                if newSelectedFilmIDs.isEmpty && !selection.isEmpty {
                    selection = []
                }
            }
    }
}

// MARK: - Ranked Item Protocol

/// An `Identifiable` type with an explicit 1-based sort position. `ReportsRankedListView` reads `position` directly. Both row types conform,
/// so the conformance is required rather than falling back to a search.
protocol RankedItem: Identifiable {
    var position: Int { get }
}

// MARK: - Report Table (AppKit)
///
/// The one table every Reports tab uses: a plain NSTableView driven directly, in place of
/// SwiftUI's `Table` (the two trackers) and `List` (the two ranked lists).
///
/// WHY. A sub-tab switch into a SwiftUI Table or
/// List blocked the main thread before its first frame, more than a gallery sub-tab did. Most of that time went to the per-cell SwiftUI
/// machinery. Each cell was its own NSHostingView, measured for automatic row heights and given fresh Auto Layout constraints. Here a
/// row has a fixed height, and a cell is one reused view or one that draws itself.
///
/// WHAT IS KEPT. The inset, alternating-row style. Header sorting maps onto the tabs' existing `KeyPathComparator` orders, so the saved sort
/// and PDF export are unchanged. Multi-selection uses the same `Set<UUID>` binding. Drag-to-reorder uses SwiftUI `onMove`'s (IndexSet,
/// destination) meaning, which matches NSTableView's "drop above row" index.

/// One column of a `ReportTable`.
struct ReportTableColumn<Row> {
    enum Content {
        /// A single truncating line of text.
        case text((Row) -> String)
        /// A single truncating line built from runs that may each carry their own font; a
        /// run without one uses the column's.
        case runs((Row) -> [ReportTextRun])
        /// A secondary SF Symbol and text after it, both in the column's muted style, or nothing for nil (the Hall of Fame's
        /// rotation column).
        case symbolText(symbol: String, (Row) -> String?)
        /// A lone secondary SF Symbol, drawn like `symbolText`'s glyph, or nothing for false. `label` is its accessibility value
        /// (the Hall of Fame's Queue column).
        case symbol(String, label: String, (Row) -> Bool)
        /// A format badge (Wishlist, Hall of Fame): lettering on a rounded, colored plate, or nothing for nil.
        case badge((Row) -> ReportBadge?)
        /// The Hall of Fame's rating: a star in its tier's tint (RatingStarTint) and the number, or nothing for 0.
        case rating((Row) -> Int)
    }

    let id: String
    var title: String = ""
    var width: CGFloat
    var minWidth: CGFloat? = nil
    var maxWidth: CGFloat? = nil
    var alignment: NSTextAlignment = .left
    var font: NSFont = .systemFont(ofSize: 12)
    var isSecondary = false
    /// Extra empty space kept at the column's trailing edge, for the ranked lists' wider gaps.
    var trailingPad: CGFloat = 0
    /// The sort key reported to `ReportTable.onSort`; nil makes the header unsortable.
    var sortKey: String? = nil
    let content: Content
}

/// One run of a `ReportTableColumn.Content.runs` cell.
struct ReportTextRun {
    let text: String
    var font: NSFont? = nil
}

/// A `ReportTableColumn.Content.badge` cell: its text and plate color. The lettering is the cell's secondary text color.
struct ReportBadge {
    let text: String
    let fill: NSColor

    /// A format's badge: the stored format string verbatim on its ReleaseCard band tint.
    static func format(_ format: String) -> ReportBadge {
        ReportBadge(text: format, fill: ReleaseFormatPalette.tint(for: format))
    }
}

/// The rating star's color: a muted yellow that steps down a ladder from 10, one rung per rating, so the bands read apart at a glance.
/// Each rung below 10 turns a little toward amber and fades a little. The Hall of Fame's rating column and its status bar chips share it.
enum RatingStarTint {
    /// The tint for a rating from 1 to 10; anything outside is clamped.
    static func color(for rating: Int) -> NSColor {
        let rung = CGFloat(10 - min(max(rating, 1), 10))
        return NSColor(hue: 0.135 - 0.008 * rung, saturation: 0.62, brightness: 1,
                       alpha: max(0.3, 0.8 - 0.06 * rung))
    }
}

struct ReportTable<Row: Identifiable & Equatable>: NSViewRepresentable where Row.ID == UUID {
    let rows: [Row]
    let columns: [ReportTableColumn<Row>]
    @Binding var selection: Set<UUID>
    var showsHeader = true
    /// Row pitch in points.
    var rowHeight: CGFloat = 24
    /// Header sort state as (key, ascending) pairs, primary first; empty for an unsorted table.
    var sort: [(key: String, ascending: Bool)] = []
    var onSort: (([(key: String, ascending: Bool)]) -> Void)? = nil
    /// Non-nil enables drag-to-reorder: (source rows, destination) exactly as SwiftUI's onMove.
    var onMove: ((IndexSet, Int) -> Void)? = nil
    /// Space above the first row. The headerless ranked lists use 5, which matches SwiftUI's `List(.inset)`.
    var topInset: CGFloat = 0
    /// Non-nil enables the gallery contextual menu (GalleryContextMenu). It maps a row to the film the menu acts on:
    /// the row's own ID for a film row, the release's film for a release row.
    var menuFilmID: ((Row) -> UUID)? = nil

    static var rowDragType: NSPasteboard.PasteboardType { .init("app.FilmTracker.reportTableRow") }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ReportNSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.rowSizeStyle = .custom
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 12, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .none
        if !showsHeader { table.headerView = nil }

        for column in columns {
            let tc = NSTableColumn(identifier: .init(column.id))
            tc.title = column.title
            tc.width = column.width
            if let min = column.minWidth { tc.minWidth = min }
            if let max = column.maxWidth { tc.maxWidth = max }
            if column.minWidth == nil && column.maxWidth == nil {
                tc.resizingMask = []
                tc.minWidth = column.width
                tc.maxWidth = column.width
            } else {
                tc.resizingMask = [.autoresizingMask, .userResizingMask]
            }
            /// Header titles stay leading-aligned, whatever the column's content alignment.
            if let key = column.sortKey {
                tc.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            }
            table.addTableColumn(tc)
        }

        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator
        table.getContextMenu = { [weak coordinator] in coordinator?.contextMenu(forRow: $0) }
        if onMove != nil {
            table.registerForDraggedTypes([Self.rowDragType])
            /// `.none`: the table draws no drop feedback. ReportNSTableView draws the sidebar-style indicator instead, since the built-in styles
            /// do not draw the circle in an `.inset` table. The source row stays put during the drag, and rows slide only on the drop (see `move`).
            /// `.gap` was tried and glitched, so it is not used.
            table.draggingDestinationFeedbackStyle = .none
            table.setDraggingSourceOperationMask(.move, forLocal: true)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        if topInset > 0 {
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        }
        /// NSTableView fits its columns only when its width changes, so the starting widths would overflow sideways if they sum to more than the view.
        /// Fit them once, when the table first has a real width.
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.clipFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: scroll.contentView)

        coordinator.apply(self, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(self, force: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ReportTable?
        weak var table: NSTableView?
        private var rows: [Row] = []
        private var columnsByID: [String: ReportTableColumn<Row>] = [:]
        private var hasFittedColumns = false

        /// Target/selector observer of the clip view's frame. NotificationCenter drops it when the coordinator deallocates, so no deinit is needed.
        @objc func clipFrameDidChange(_ notification: Notification) { fitColumnsOnce() }

        func fitColumnsOnce() {
            guard !hasFittedColumns, let table, let clip = table.enclosingScrollView?.contentView,
                  clip.bounds.width > 0 else { return }
            hasFittedColumns = true
            table.sizeToFit()
        }
        /// Set while the coordinator changes the table, so the delegate callbacks are not reported back as user actions.
        private var isApplying = false

        func apply(_ parent: ReportTable, force: Bool) {
            self.parent = parent
            guard let table else { return }
            isApplying = true
            defer { isApplying = false }

            columnsByID = Dictionary(uniqueKeysWithValues: parent.columns.map { ($0.id, $0) })
            if force {
                rows = parent.rows
                table.reloadData()
            } else if parent.rows != rows {
                if parent.rows.map(\.id) == rows.map(\.id) {
                    /// Same rows in the same order, typically renumbered ranks after a drop `move` has animated. Refresh the cells in place, since a
                    /// full reload would cut the slide short.
                    rows = parent.rows
                    table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count),
                                     columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                } else {
                    rows = parent.rows
                    table.reloadData()
                }
            }

            let descriptors = parent.sort.map { NSSortDescriptor(key: $0.key, ascending: $0.ascending) }
            if table.sortDescriptors != descriptors { table.sortDescriptors = descriptors }

            /// Reselect from the binding: after a reload row indexes may have moved.
            var wanted = IndexSet()
            if !parent.selection.isEmpty {
                for (index, row) in rows.enumerated() where parent.selection.contains(row.id) {
                    wanted.insert(index)
                }
            }
            if table.selectedRowIndexes != wanted {
                table.selectRowIndexes(wanted, byExtendingSelection: false)
            }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplying, let onSort = parent?.onSort else { return }
            onSort(tableView.sortDescriptors.compactMap { d in d.key.map { ($0, d.ascending) } })
        }

        // MARK: Cells

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, rows.indices.contains(row),
                  let column = columnsByID[tableColumn.identifier.rawValue] else { return nil }
            let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? ReportTableCellView)
                ?? ReportTableCellView(identifier: tableColumn.identifier)
            cell.configure(column: column, row: rows[row])
            return cell
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying, let table, let parent else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            if ids != parent.selection { parent.selection = ids }
        }

        // MARK: Contextual Menu

        /// The gallery contextual menu for a secondary click on `row`, or nil when the table has no `menuFilmID`.
        /// ReportNSTableView.menu(for:) has already confirmed the click landed on a row's cells.
        ///
        /// Selection rules match the gallery (DraggableListView.Coordinator.contextMenu(forRow:)). A click on a
        /// selected row leaves the selection alone and the menu acts on the group. A click on an unselected row
        /// selects it first. Several selected releases of one film count as that one film.
        ///
        /// The tab maps the binding into SelectionState through an onChange, which runs after the menu opens.
        /// Edit Metadata… and Edit Releases… read SelectionState, so it is written here at once. The tab's later
        /// `select` of the same films is then a no-op.
        func contextMenu(forRow row: Int) -> NSMenu? {
            guard let table, let menuFilmID = parent?.menuFilmID, rows.indices.contains(row) else { return nil }

            var targetRows = table.selectedRowIndexes
            if !targetRows.contains(row) {
                targetRows = IndexSet(integer: row)
                /// Not isApplying: tableViewSelectionDidChange forwards the change to the binding as a click would.
                table.selectRowIndexes(targetRows, byExtendingSelection: false)
            }

            let filmIDs = Set(targetRows.compactMap { rows.indices.contains($0) ? menuFilmID(rows[$0]) : nil })
            SelectionState.shared.selectImmediate(filmIDs, inputKind: .fromCurrentAppKitEvent())
            return GalleryContextMenu.makeMenu(for: filmIDs)
        }

        // MARK: Reordering

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard parent?.onMove != nil else { return nil }
            let item = NSPasteboardItem()
            item.setString(String(row), forType: ReportTable.rowDragType)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            guard parent?.onMove != nil, (info.draggingSource as? NSTableView) === tableView else {
                (tableView as? ReportNSTableView)?.hideDropIndicator()
                return []
            }
            if op == .on { tableView.setDropRow(row, dropOperation: .above) }
            (tableView as? ReportNSTableView)?.showDropIndicator(aboveRow: row)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard parent?.onMove != nil else { return false }
            var source = IndexSet()
            /// The dragged rows' pasteboard items, read directly. This avoids the unsafe stop pointer of enumerateDraggingItems.
            for item in info.draggingPasteboard.pasteboardItems ?? [] {
                if let string = item.string(forType: ReportTable.rowDragType),
                   let index = Int(string) { source.insert(index) }
            }
            return move(source, to: row)
        }

        /// The drop's effect, with SwiftUI `onMove` semantics: (source rows, destination in the pre-move index space). It is separate from
        /// the drag plumbing so the harness can drive it. The rows slide to their places first, animated, before `onMove` reports the new order.
        /// The next update then only refreshes cells, rather than reloading and snapping the rows into place.
        @discardableResult
        func move(_ source: IndexSet, to row: Int) -> Bool {
            guard let onMove = parent?.onMove, !source.isEmpty, row >= 0, row <= rows.count,
                  source.allSatisfy({ rows.indices.contains($0) }) else { return false }
            if let table {
                isApplying = true
                table.beginUpdates()
                /// Each moveRow shifts later indexes, and the offsets track that. Rows from above the destination land just above it, in order.
                /// Rows from below land just after the previous one.
                var aboveOffset = 0
                var belowOffset = 0
                for index in source {
                    if index < row {
                        table.moveRow(at: index + aboveOffset, to: row - 1)
                        aboveOffset -= 1
                    } else {
                        table.moveRow(at: index, to: row + belowOffset)
                        belowOffset += 1
                    }
                }
                rows.move(fromOffsets: source, toOffset: row)
                table.endUpdates()
                isApplying = false
            } else {
                rows.move(fromOffsets: source, toOffset: row)
            }
            onMove(source, row)
            return true
        }

        #if DEBUG
        /// The row order the table is showing, for the harness.
        var rowIDs: [UUID] { rows.map(\.id) }
        #endif
    }
}

/// ReportTable's NSTableView. It adds only the gallery list's side-padding deselect (DraggableListTableView.mouseDown, 23.30 GalleryListView.swift).
///
/// With `.inset`, the margins beside each row's highlight belong to a row but to no column. A click there clears the selection and is absorbed,
/// as a click on empty space below the last row is.
final class ReportNSTableView: NSTableView {
    private(set) var dropIndicator: ReportDropIndicatorView?

    /// Places the drop indicator on the boundary above `row`. `numberOfRows` means below the last row.
    func showDropIndicator(aboveRow row: Int) {
        guard numberOfRows > 0, numberOfColumns > 0 else { hideDropIndicator(); return }
        let y = row < numberOfRows ? rect(ofRow: row).minY : rect(ofRow: numberOfRows - 1).maxY
        /// Spans the row content, from the first cell's leading edge to the last cell's trailing edge, where the inset highlight sits.
        let reference = min(row, numberOfRows - 1)
        let minX = frameOfCell(atColumn: 0, row: reference).minX
        let maxX = frameOfCell(atColumn: numberOfColumns - 1, row: reference).maxX
        let height = ReportDropIndicatorView.height
        let frame = NSRect(x: minX - ReportDropIndicatorView.circleDiameter / 2, y: y - height / 2,
                           width: maxX - minX + ReportDropIndicatorView.circleDiameter / 2, height: height)
        let indicator = dropIndicator ?? {
            let view = ReportDropIndicatorView(frame: frame)
            addSubview(view)
            dropIndicator = view
            return view
        }()
        if indicator.frame != frame { indicator.frame = frame }
        /// Row views added while scrolling would otherwise cover it.
        if subviews.last !== indicator { addSubview(indicator, positioned: .above, relativeTo: nil) }
        indicator.isHidden = false
    }

    func hideDropIndicator() { dropIndicator?.isHidden = true }

    /// Modifier keys must not narrow the reorder drag's .move-only mask. AppKit would otherwise cut it to .copy
    /// under Option, .generic under ⌘ and .link under Control. None of those includes .move, the only operation
    /// validateDrop offers, so the reorder would be refused. Only reorderable tables start drags at all.
    override func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        hideDropIndicator()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        super.draggingEnded(sender)
        hideDropIndicator()
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        super.concludeDragOperation(sender)
        hideDropIndicator()
    }

    #if DEBUG
    /// Full reloads so far, for the harness. A drop must animate, not reload.
    private(set) var fullReloadCount = 0
    override func reloadData() {
        fullReloadCount += 1
        super.reloadData()
    }
    #endif

    /// Supplies the contextual menu for a row. Wired to ReportTable.Coordinator.contextMenu(forRow:).
    var getContextMenu: ((Int) -> NSMenu?)?

    /// The hit test matches mouseDown: a row and a column. The inset margins beside a row belong to no column, and a
    /// click there counts as clicking nothing. It does not call super, so no menu appears away from a row.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0, column(at: point) >= 0 else { return nil }
        return getContextMenu?(clickedRow)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if row(at: point) >= 0, column(at: point) < 0 {
            if !selectedRowIndexes.isEmpty { deselectAll(nil) }
            return
        }
        super.mouseDown(with: event)
    }
}

/// The sidebar-style drop indicator that ReportNSTableView shows between rows: a hollow circle at the leading end, with a line in the accent color.
final class ReportDropIndicatorView: NSView {
    static let circleDiameter: CGFloat = 6
    static let lineWidth: CGFloat = 2
    static let height: CGFloat = circleDiameter + lineWidth

    override var isFlipped: Bool { true }
    /// Never takes clicks or drags: it only marks the drop.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let midY = bounds.midY
        let circle = NSRect(x: Self.lineWidth / 2, y: midY - Self.circleDiameter / 2,
                            width: Self.circleDiameter, height: Self.circleDiameter)
        let ring = NSBezierPath(ovalIn: circle)
        ring.lineWidth = Self.lineWidth
        ring.stroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: circle.maxX + Self.lineWidth / 2, y: midY))
        line.line(to: NSPoint(x: bounds.maxX, y: midY))
        line.lineWidth = Self.lineWidth
        line.lineCapStyle = .round
        line.stroke()
    }
}

/// A report table cell. It draws its own text, badge, or rating, rather than hosting an NSTextField. A Reports tab switch builds every visible
/// cell at once, and per-cell text fields cost a large share of that (measured with a profiler). Cells never edit or take focus, and the text is exposed as a static text element.
final class ReportTableCellView: NSTableCellView {
    private enum Drawn {
        case text(String), runs([ReportTextRun]), symbolText(symbol: String, String), symbol(String), badge(ReportBadge), rating(Int)
    }
    private var drawn: Drawn = .text("")
    private var font: NSFont = .systemFont(ofSize: 12)
    private var alignment: NSTextAlignment = .left
    private var isSecondary = false
    private var trailingPad: CGFloat = 0

    /// The rating star at 10 pt in the given color. Size and color go in as one configuration, because a second `withSymbolConfiguration` replaces the first.
    private static func star(_ color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Rating")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
                .applying(.init(paletteColors: [color])))
    }
    /// The badge plate's and shadow's opacity: enough to keep each format's color, muted like the other detail columns.
    private static let badgePlateOpacity: CGFloat = 0.6
    /// Room left of the plate for the shadow's blur.
    private static let badgeOutsideAllowance: CGFloat = 3
    /// The badge's drop shadow, heavier than the release cards' badge shadow (RSBCardChrome), since this plate has no outline. NSShadow
    /// offsets use the y-up base space even in this flipped view, so a negative height drops the shadow downward.
    private static let badgeShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.75)
        shadow.shadowBlurRadius = 2.5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
    }()
    /// One tinted star per rating, index 0 unused.
    private static let ratingStars: [NSImage?] = (0...10).map { star(RatingStarTint.color(for: $0)) }
    private static let emphasizedStar = star(.alternateSelectedControlTextColor)
    /// A `symbolText` cell's glyph at the star's 10 pt, keyed by symbol name and whether the row is selected.
    private static var symbols: [String: NSImage] = [:]
    private static func symbol(_ name: String, emphasized: Bool) -> NSImage? {
        let key = "\(name)|\(emphasized)"
        if let cached = symbols[key] { return cached }
        let color: NSColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
                .applying(.init(paletteColors: [color]))) else { return nil }
        symbols[key] = image
        return image
    }

    private static let paragraphStyles: [NSTextAlignment: NSParagraphStyle] = {
        var styles: [NSTextAlignment: NSParagraphStyle] = [:]
        for alignment in [NSTextAlignment.left, .right, .center, .natural] {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            style.lineBreakMode = .byTruncatingTail
            styles[alignment] = style
        }
        return styles
    }()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func configure<Row>(column: ReportTableColumn<Row>, row: Row) {
        font = column.font
        alignment = column.alignment
        isSecondary = column.isSecondary
        trailingPad = column.trailingPad
        switch column.content {
        case .text(let text):
            let value = text(row)
            drawn = .text(value)
            setAccessibilityValue(value)
        case .runs(let runs):
            let value = runs(row)
            drawn = .runs(value)
            setAccessibilityValue(value.map(\.text).joined())
        case .symbolText(let symbol, let text):
            if let value = text(row) {
                drawn = .symbolText(symbol: symbol, value)
                setAccessibilityValue(value)
            } else {
                drawn = .text("")
                setAccessibilityValue("")
            }
        case .symbol(let name, let label, let isShown):
            if isShown(row) {
                drawn = .symbol(name)
                setAccessibilityValue(label)
            } else {
                drawn = .text("")
                setAccessibilityValue("")
            }
        case .badge(let badge):
            if let value = badge(row) {
                drawn = .badge(value)
                setAccessibilityValue(value.text)
            } else {
                drawn = .text("")
                setAccessibilityValue("")
            }
        case .rating(let value):
            let rating = value(row)
            drawn = .rating(rating)
            setAccessibilityValue(rating > 0 ? "Rating \(rating)" : "")
        }
        needsDisplay = true
    }

    private var foreground: NSColor {
        if backgroundStyle == .emphasized { return .alternateSelectedControlTextColor }
        return isSecondary ? .secondaryLabelColor : .labelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = max(0, bounds.width - trailingPad)
        switch drawn {
        case .text(let text):
            guard !text.isEmpty else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: foreground,
                .paragraphStyle: Self.paragraphStyles[alignment] ?? NSParagraphStyle.default]
            let height = ceil(font.ascender - font.descender + font.leading)
            (text as NSString).draw(with: NSRect(x: 0, y: floor((bounds.height - height) / 2), width: width, height: height),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: attributes)
        case .runs(let runs):
            guard !runs.isEmpty else { return }
            let text = NSMutableAttributedString()
            var height: CGFloat = 0
            for run in runs {
                let runFont = run.font ?? font
                height = max(height, ceil(runFont.ascender - runFont.descender + runFont.leading))
                text.append(NSAttributedString(string: run.text, attributes: [.font: runFont]))
            }
            let whole = NSRange(location: 0, length: text.length)
            text.addAttribute(.foregroundColor, value: foreground, range: whole)
            text.addAttribute(.paragraphStyle, value: Self.paragraphStyles[alignment] ?? NSParagraphStyle.default, range: whole)
            text.draw(with: NSRect(x: 0, y: floor((bounds.height - height) / 2), width: width, height: height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        case .symbolText(let symbol, let text):
            /// Laid out as the rating is: the glyph, 2 pt, then the text, both secondary.
            var x: CGFloat = 0
            if let glyph = Self.symbol(symbol, emphasized: backgroundStyle == .emphasized) {
                let size = glyph.size
                glyph.draw(in: NSRect(x: 0, y: floor((bounds.height - size.height) / 2), width: size.width, height: size.height))
                x = size.width + 2
            }
            let color = backgroundStyle == .emphasized ? NSColor.alternateSelectedControlTextColor : .secondaryLabelColor
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: x, y: floor((bounds.height - size.height) / 2)), withAttributes: attributes)
        case .symbol(let name):
            /// At the leading edge, vertically centered, as `symbolText` places its glyph.
            if let glyph = Self.symbol(name, emphasized: backgroundStyle == .emphasized) {
                let size = glyph.size
                glyph.draw(in: NSRect(x: 0, y: floor((bounds.height - size.height) / 2), width: size.width, height: size.height))
            }
        case .badge(let badge):
            /// 10 pt heavy, centered on a 4 pt-radius continuous-corner plate, 1 pt taller than the text above and below (the SwiftUI row's
            /// `.padding(.vertical, 1)`). Muted like the row's other detail columns: secondary lettering (selected-row text on a selected
            /// row), and the plate drawn at `badgePlateOpacity`, so each format keeps its color but sits behind the title.
            let badgeFont = NSFont.systemFont(ofSize: 10, weight: .heavy)
            let ink = backgroundStyle == .emphasized ? NSColor.alternateSelectedControlTextColor : .secondaryLabelColor
            let attributes: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: ink]
            let text = badge.text as NSString
            let size = text.size(withAttributes: attributes)
            /// The plate starts `badgeOutsideAllowance` in from the leading edge, so the cell does not clip its shadow. The trailing side spills
            /// into `trailingPad`, which is wider.
            let plateHeight = ceil(size.height) + 2
            let plate = NSRect(x: Self.badgeOutsideAllowance, y: floor((bounds.height - plateHeight) / 2),
                               width: width, height: plateHeight)
            /// Plate and shadow fade together in one transparency layer: a translucent fill drawn straight over its own shadow would
            /// show the shadow through it.
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext.current?.cgContext
            context?.setAlpha(Self.badgePlateOpacity)
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
            Self.badgeShadow.set()
            badge.fill.setFill()
            NSBezierPath(cgPath: CGPath.continuousRoundedRect(plate, cornerRadius: 4)).fill()
            context?.endTransparencyLayer()
            NSGraphicsContext.restoreGraphicsState()
            text.draw(at: NSPoint(x: plate.midX - size.width / 2, y: plate.minY + 1), withAttributes: attributes)
        case .rating(let rating):
            guard rating > 0 else { return }
            let color = backgroundStyle == .emphasized ? NSColor.alternateSelectedControlTextColor : .secondaryLabelColor
            var x: CGFloat = 0
            let star = backgroundStyle == .emphasized ? Self.emphasizedStar : Self.ratingStars[min(rating, 10)]
            if let tinted = star {
                let size = tinted.size
                tinted.draw(in: NSRect(x: 0, y: floor((bounds.height - size.height) / 2), width: size.width, height: size.height))
                x = size.width + 2
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let text = "\(rating)" as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: x, y: floor((bounds.height - size.height) / 2)), withAttributes: attributes)
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }
}
