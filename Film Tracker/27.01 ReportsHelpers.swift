// MARK: - ReportsHelpers.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Reusable view components and configuration types shared across ReportsView tabs.

import SwiftUI
import AppKit

// MARK: - Gallery Title Order

/// A film's place in the gallery's Title sort, as one Comparable value, so a report list or
/// table column orders titles exactly as the gallery does: `MetadataCache.compareTitles`'
/// rules, in its order — titles starting with a letter before those starting with a digit,
/// then `localizedStandardCompare` on the article-stripped sort name (or name), then
/// release year, then film id. The id makes it a total order, so equal titles cannot trade
/// places between loads; descending is the exact reverse, as the gallery's swap is.
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
        switch lhs.key.localizedStandardCompare(rhs.key) {
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

/// Describes the two placeholder states common to data-backed report tabs:
/// one for when the library is completely empty, and one for when the library
/// has films but the tab's specific dataset is empty.
struct EmptyStateConfig {
    let glyph: String
    let noFilmsMessage: String
    let noDataMessage: String
}

// MARK: - Reports Empty State Wrapper

/// A generic container that wraps a report tab's content behind the standard
/// two-stage empty-state guard used across all data-backed tabs. When the
/// library has no films the first placeholder is shown; when the tab-specific
/// dataset is empty the second placeholder is shown; otherwise `content` is
/// presented.
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
        // A Group, not a ZStack: exactly one of the three arms is ever present, so the
        // stack was a layout container with nothing to stack.
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

// MARK: - Reports Status Bar Inset Modifier

/// Applies the standard `.safeAreaInset(edge: .bottom)` spacer used by all
/// report tab views to prevent their content from scrolling under the
/// StatusBar when it is visible.
struct ReportsStatusBarInset: ViewModifier {
    @AppStorage(preference: Preferences.showStatusBarKey) private var showStatusBar: Bool

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showStatusBar {
                    Color.clear.frame(height: 29)
                }
            }
    }
}

extension View {
    /// Reserves space at the bottom of a report tab view for the StatusBar
    /// when it is visible, preventing content from scrolling beneath it.
    func reportsStatusBarInset() -> some View {
        modifier(ReportsStatusBarInset())
    }
}

// MARK: - Reports Ranked List View

/// The ranked list both ordered report tabs use (Hall of Fame, Release Wishlist): a headerless
/// `ReportTable` whose first two columns are always the position ("12.") and the name, and whose
/// remaining columns the caller supplies. Handles status bar spacing and selection
/// synchronization with `SelectionState`.
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

    /// Row pitch of the SwiftUI `List(.inset)` this replaced (12 pt text, 2 pt vertical padding).
    static var rowHeight: CGFloat { 27 }

    private var columns: [ReportTableColumn<Item>] {
        [ReportTableColumn(id: "position", width: 30, alignment: .right,
                           font: .systemFont(ofSize: 12, weight: .medium), isSecondary: true,
                           content: .text { "\($0.position)." }),
         ReportTableColumn(id: "name", width: 80, minWidth: 80, maxWidth: .greatestFiniteMagnitude,
                           content: .text(primaryLabel))]
        + trailingColumns
    }

    var body: some View {
        ReportTable(rows: items, columns: columns, selection: $selection,
                    showsHeader: false, rowHeight: Self.rowHeight, onMove: onMove, topInset: 5)
            .reportsStatusBarInset()
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

/// An `Identifiable` type that carries an explicit 1-based sort position.
///
/// Required by `ReportsRankedListView`, which reads `position` directly. It used to be
/// optional — the list took any `Identifiable` and fell back to a `firstIndex` search when
/// the item did not conform — but both row types (`HallOfFameFilm`, `WishlistRelease`)
/// have always conformed, so that path was a linear scan per row, behind a per-row
/// existential cast, that nothing ever reached. Requiring the conformance deletes both and
/// makes the position a compile-time guarantee rather than a runtime fallback.
protocol RankedItem: Identifiable {
    var position: Int { get }
}

// MARK: - Report Table (AppKit)
//
// The one table every Reports tab uses: a plain NSTableView driven directly, in place of
// SwiftUI's `Table` (the two trackers) and `List` (the two ranked lists).
//
// WHY. Measured with the `reports-hitch` / `reports-loop` harness scenarios (99.50) on a
// library-shaped corpus, a sub-tab switch into a SwiftUI Table or List held the main thread
// for ~185 ms before its first frame, against 30–60 ms for a gallery sub-tab — the "hitch"
// every Reports tab had. The profile put nearly all of it in the per-cell SwiftUI machinery:
// every cell is its own NSHostingView, measured through `sizeThatFits` for NSTableView's
// automatic row heights (`_uncachedAutomaticRowHeight`, ~16% of main-thread samples) and given
// fresh Auto Layout constraints (`NSHostingView._willUpdateConstraintsForSubtree`, ~20%). Here a
// row is a fixed height and a cell is one reused NSTextField or a view that draws itself.
//
// WHAT IS KEPT. The inset, alternating-row style both SwiftUI controls rendered with; native
// header sorting mapped onto the tabs' existing `KeyPathComparator` orders (so ReportsState's
// saved sort and the PDF export are untouched); multi-selection through the same
// `Set<UUID>` binding; drag-to-reorder with SwiftUI `onMove`'s (IndexSet, destination)
// meaning, which is also NSTableView's "drop above row" index.

/// One column of a `ReportTable`.
struct ReportTableColumn<Row> {
    enum Content {
        /// A single truncating line of text.
        case text((Row) -> String)
        /// The Wishlist's format badge: text knocked out of a rounded label-colored plate.
        case badge((Row) -> String)
        /// The Hall of Fame's rating: a star and the number, or nothing for 0.
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
    /// Space above the first row. The headerless ranked lists use 5, the gap SwiftUI's
    /// `List(.inset)` left there.
    var topInset: CGFloat = 0

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
            // Header titles stay leading-aligned whatever the column's content alignment,
            // as SwiftUI's Table drew them.
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
        if onMove != nil {
            table.registerForDraggedTypes([Self.rowDragType])
            table.draggingDestinationFeedbackStyle = .gap
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
        // NSTableView fits its columns to its width only when that width CHANGES, so the
        // columns' starting widths would otherwise stand on the first layout — overflowing
        // sideways when they add up to more than the view. Fit them once, when the table
        // first has a real width.
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

        /// Target/selector observer of the clip view's frame: NotificationCenter drops it
        /// when the coordinator deallocates, so no token or deinit is needed.
        @objc func clipFrameDidChange(_ notification: Notification) { fitColumnsOnce() }

        func fitColumnsOnce() {
            guard !hasFittedColumns, let table, let clip = table.enclosingScrollView?.contentView,
                  clip.bounds.width > 0 else { return }
            hasFittedColumns = true
            table.sizeToFit()
        }
        /// Set while the coordinator itself changes the table, so the delegate callbacks
        /// those changes raise are not reported back as user actions.
        private var isApplying = false

        func apply(_ parent: ReportTable, force: Bool) {
            self.parent = parent
            guard let table else { return }
            isApplying = true
            defer { isApplying = false }

            columnsByID = Dictionary(uniqueKeysWithValues: parent.columns.map { ($0.id, $0) })
            if force || parent.rows != rows {
                rows = parent.rows
                table.reloadData()
            }

            let descriptors = parent.sort.map { NSSortDescriptor(key: $0.key, ascending: $0.ascending) }
            if table.sortDescriptors != descriptors { table.sortDescriptors = descriptors }

            // Reselect from the binding: after a reload row indexes may have moved.
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

        // MARK: Reordering

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard parent?.onMove != nil else { return nil }
            let item = NSPasteboardItem()
            item.setString(String(row), forType: ReportTable.rowDragType)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            guard parent?.onMove != nil, (info.draggingSource as? NSTableView) === tableView else { return [] }
            if op == .on { tableView.setDropRow(row, dropOperation: .above) }
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard parent?.onMove != nil else { return false }
            var source = IndexSet()
            unsafe info.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self],
                                        searchOptions: [:]) { item, _, _ in
                if let string = (item.item as? NSPasteboardItem)?.string(forType: ReportTable.rowDragType),
                   let index = Int(string) { source.insert(index) }
            }
            return move(source, to: row)
        }

        /// The drop's effect: SwiftUI `onMove` semantics, (source rows, destination row in the
        /// pre-move index space). Separate from the drag plumbing so the harness can drive it.
        @discardableResult
        func move(_ source: IndexSet, to row: Int) -> Bool {
            guard let onMove = parent?.onMove, !source.isEmpty, row >= 0, row <= rows.count else { return false }
            onMove(source, row)
            return true
        }
    }
}

/// ReportTable's NSTableView: the gallery list's side-padding deselect
/// (DraggableListTableView.mouseDown, 23_30_GalleryListView.swift), nothing else.
///
/// With the `.inset` style the margins flanking each row's highlight resolve to a row but to
/// no column. A click there clears the selection and is absorbed, so NSTableView cannot read
/// it as a row gesture — the same "clicking on nothing" the empty space below the last row
/// already is.
final class ReportNSTableView: NSTableView {
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if row(at: point) >= 0, column(at: point) < 0 {
            if !selectedRowIndexes.isEmpty { deselectAll(nil) }
            return
        }
        super.mouseDown(with: event)
    }
}

/// A report table cell. It draws its own content — text, the badge, or the rating — rather
/// than hosting an NSTextField: a new table builds every visible cell at once (a Reports tab
/// switch mounts a fresh table), and per-cell text fields were about a fifth of that switch
/// in the `reports-loop` profile, between their construction, their text layers, and the row
/// key-view loop each one joins. Cells never edit or take focus, so nothing is lost; the text
/// is exposed to accessibility as a static text element.
final class ReportTableCellView: NSTableCellView {
    private enum Drawn { case text(String), badge(String), rating(Int) }
    private var drawn: Drawn = .text("")
    private var font: NSFont = .systemFont(ofSize: 12)
    private var alignment: NSTextAlignment = .left
    private var isSecondary = false
    private var trailingPad: CGFloat = 0

    /// The rating star at 10 pt in the given color. The size and the color go in as ONE
    /// configuration: a second `withSymbolConfiguration` call replaces the first rather than
    /// adding to it, which drew the star at the default size.
    private static func star(_ color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Rating")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
                .applying(.init(paletteColors: [color])))
    }
    private static let secondaryStar = star(.secondaryLabelColor)
    private static let emphasizedStar = star(.alternateSelectedControlTextColor)

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
        case .badge(let text):
            let value = text(row)
            drawn = .badge(value)
            setAccessibilityValue(value)
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
        case .badge(let text):
            // 10 pt heavy, centered on a 4 pt-radius continuous-corner plate one point taller than the text above
            // and below — the SwiftUI row's `.padding(.vertical, 1)` on a label-colored fill.
            let badgeFont = NSFont.systemFont(ofSize: 10, weight: .heavy)
            let attributes: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: NSColor.windowBackgroundColor]
            let size = (text as NSString).size(withAttributes: attributes)
            let plateHeight = ceil(size.height) + 2
            let plate = NSRect(x: 0, y: floor((bounds.height - plateHeight) / 2), width: width, height: plateHeight)
            NSColor.labelColor.setFill()
            NSBezierPath(cgPath: CGPath.continuousRoundedRect(plate, cornerRadius: 4)).fill()
            (text as NSString).draw(at: NSPoint(x: plate.midX - size.width / 2, y: plate.minY + 1),
                                    withAttributes: attributes)
        case .rating(let rating):
            guard rating > 0 else { return }
            let color = backgroundStyle == .emphasized ? NSColor.alternateSelectedControlTextColor : .secondaryLabelColor
            var x: CGFloat = 0
            if let tinted = backgroundStyle == .emphasized ? Self.emphasizedStar : Self.secondaryStar {
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
