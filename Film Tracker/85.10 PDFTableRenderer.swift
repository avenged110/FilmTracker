// MARK: - PDFTableRenderer.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The shared paginated-table renderer every PDF report in the app is drawn with.
//
// Layer two of the PDF stack described at the top of PDFCore.swift (88.00). This file owns
// table LAYOUT — column geometry, the one- or two-row header band, row measurement, page
// breaks, per-page titles and footers — and nothing about what any particular table means.
//
// Everything renders through `PDFTableRenderer.render`: the report sheets built in
// ReportExporter.swift (27.50), which mostly pass plain string rows, and the
// complete-library table built in LibraryPDFReport.swift (88.20), which passes styled
// cells and a grouped header. Those are the only two axes the callers differ on, and both
// are expressed as data on `PDFTableSection` rather than as a second renderer.

import AppKit
import Foundation

// MARK: - Column

/// One column of a table: what its header says, how wide it is, and how its text aligns.
///
/// `width` is a RELATIVE weight, not a promise. `PDFTableRenderer` normalizes the column
/// set to exactly the page's content width before drawing, so a caller can express widths
/// in whatever units read most clearly at the call site — points, percentages of the
/// content width, or plain ratios — and tweaking one of them cannot silently push the last
/// column off the page.
struct PDFTableColumn {
    var title: String
    var width: CGFloat
    var alignment: NSTextAlignment
    /// Alignment for the HEADER cell, when it should differ from the column's values.
    ///
    /// A column of right-aligned values does not necessarily want a right-aligned label:
    /// a short header pinned to the right edge of a wide column reads as though it belongs
    /// to the column beside it, while the values below it still need to line up on their
    /// last digit. `nil` means the header follows the values, which is the common case.
    var headerAlignment: NSTextAlignment?

    /// Which edges of this column's HEADER cell are ruled. `.all` closes it on every side,
    /// as every header always has. Dropping an edge merges the cell with its neighbor, for
    /// a header whose span differs from the column grid beneath it.
    var headerBorders: PDFCellBorders = .all

    /// The header title laid out as a balanced pair — see `PDFPairedText`. When set, it is
    /// drawn instead of `title`, which stays the column's name for every other purpose.
    var pairedTitle: PDFPairedText?

    init(_ title: String,
         width: CGFloat,
         alignment: NSTextAlignment = .left,
         headerAlignment: NSTextAlignment? = nil) {
        self.title = title
        self.width = width
        self.alignment = alignment
        self.headerAlignment = headerAlignment
    }

    /// The alignment the header cell is drawn with.
    var resolvedHeaderAlignment: NSTextAlignment { headerAlignment ?? alignment }
}

// MARK: - Header Group

/// A banner spanning two or more adjacent columns in a second, upper header row.
///
/// This is what lets the complete-library table nest an audio sub-column inside each of its
/// two purchased-disc columns: the group names the pair, and each member column keeps its
/// own header underneath. A table declaring no groups draws a single header row and is
/// laid out exactly as it always was.
struct PDFHeaderGroup {
    var title: String
    /// The half-open range of column indices the banner spans.
    var columns: Range<Int>

    /// Optional widths for the SUB-HEADER cells only, in the group's column order.
    ///
    /// A sub-column can legitimately be narrower than the word naming it — "Audio" is
    /// wider than the "5.1" it labels, and widening the data column to fit its own header
    /// would waste the space on every row of the table to serve one cell at the top.
    /// Supplying weights here lets the header row divide the group's span differently from
    /// the body rows beneath it: the label takes the width it needs, and the neighboring
    /// header cell gives it up. The group's total span is unchanged either way, so the
    /// banner above and the data below both stay aligned to the real column edges.
    ///
    /// Scaled to the group's span exactly as `PDFTableColumn.width` is scaled to the page,
    /// so these are weights too. `nil` divides the span by the body columns' own widths.
    var headerWeights: [CGFloat]?

    /// How the banner's own title sits in its span. Centered by default, which is what a
    /// banner over several columns wants; a banner over ONE column is really that column's
    /// upper label and reads better aligned the way its values are.
    var alignment: NSTextAlignment = .center

    init(_ title: String, columns: Range<Int>, headerWeights: [CGFloat]? = nil) {
        self.title = title
        self.columns = columns
        self.headerWeights = headerWeights
    }
}

// MARK: - Cell

/// One table cell: its text, and optionally a background fill and an alignment that
/// overrides its column's.
///
/// The fill is drawn through `PDFDrawing.fillCell`, which applies the palette's shared
/// opacity — a cell hands over a swatch from `PDFPalette` and does not decide how strongly
/// it lands. `nil` means no fill, which is not the same as a white fill: an unfilled cell
/// is the table's neutral state.
struct PDFCell {
    var text: String
    var fill: NSColor?
    var alignment: NSTextAlignment?
    /// Draw this cell in the fixed-width face. For columns of bare numerals, where
    /// proportional digits leave the column ragged — see `PDFFonts.monospacedFont`.
    var monospaced: Bool
    /// Clip overlong text to one line with a trailing ellipsis instead of wrapping it.
    ///
    /// A wrapping cell grows the height of its whole row, so one long value costs every
    /// other column on that row the vertical space too. Where the column is wide enough
    /// that a truncated value is still unambiguous, truncating is the better trade.
    var truncates: Bool

    /// Which of the cell's four edges are ruled. `.all` — the default, and what every
    /// table drew before this existed — closes the cell on every side.
    ///
    /// Dropping the horizontal edges from a run of cells in one column merges that run
    /// visually: the column reads as a single tall cell spanning the rows, which is how a
    /// row-group's index number is made to cover the group it labels. Unlike `rowSpan`
    /// below, this costs nothing at layout time and so places no keep-together demand on
    /// the run — the rules simply stop, wherever the rows happen to fall.
    var borders: PDFCellBorders

    /// How many rows this cell occupies, counted from its own. `1` is an ordinary cell.
    ///
    /// A spanning cell is drawn once, at the combined height of the rows it covers, and
    /// vertically centered in it; the same column in each covered row draws nothing at all.
    /// The rows it spans become an ATOMIC BLOCK — the renderer will not break a page or a
    /// pane inside one, because half a merged cell on each side of a break is not a thing
    /// a reader can interpret. Keep spans short for that reason.
    var rowSpan: Int

    /// How many columns this cell occupies, counted from its own. `1` is an ordinary cell.
    ///
    /// The horizontal counterpart of `rowSpan`, and it exists for the same reason: a value
    /// that describes a whole group of sub-columns — one studio above a Provenance/Region
    /// Lock pair, one Notes field above the three columns that split its width — belongs to
    /// all of them, and putting it in the first while leaving the rest blank reads as a
    /// record somebody failed to fill in.
    ///
    /// Unlike `rowSpan`, this costs nothing at layout time: columns do not paginate, so a
    /// column span places no keep-together demand on anything.
    var columnSpan: Int

    /// The color the text is drawn in. `nil` takes `PDFPalette.text`.
    ///
    /// Exists for cells that invert — an opaque dark fill with white type. Pair it with
    /// `fillIsOpaque`; white text over a washed fill is unreadable.
    var textColor: NSColor?

    /// A color for the cell's TOP rule alone, drawn over the shared border color.
    ///
    /// For the per-film sections, where the table's rules carry three weights: black across
    /// the top of a film's band, a darker gray across the top of each release beneath it,
    /// and the ordinary border everywhere else. Only the top edge can be re-colored because
    /// only the top edge is ever a boundary a reader needs to rank — every other rule is
    /// between two cells of one record.
    ///
    /// Drawn AFTER the cell's ordinary rules, so it overdraws both this cell's own top and
    /// the bottom edge of whatever was drawn above it, which is the same line.
    var topRuleColor: NSColor?

    /// Leading inset applied to the TEXT only — the fill, the rules and the column's own
    /// edges are untouched.
    ///
    /// For a value that is subordinate to the one above it in the same column: a release's
    /// format sits under its film's title, and stepping it in says so without spending a
    /// column on the hierarchy.
    var indent: CGFloat

    /// Runs inside `text` drawn in their own color. See `PDFTextHighlight`.
    var highlights: [PDFTextHighlight]

    /// The cell's content laid out as a balanced pair — see `PDFPairedText`. When set, it
    /// is drawn instead of `text`; `text` still carries the same content as one run, so
    /// measurement and PDF text extraction are unaffected.
    var paired: PDFPairedText?

    /// Draw `fill` at its own alpha rather than at the palette's shared wash.
    ///
    /// The wash exists so black text reads through a fill (see `PDFPalette.fillAlpha`). A
    /// cell that inverts wants the opposite and must say so.
    var fillIsOpaque: Bool

    init(_ text: String,
         fill: NSColor? = nil,
         alignment: NSTextAlignment? = nil,
         monospaced: Bool = false,
         truncates: Bool = false,
         borders: PDFCellBorders = .all,
         rowSpan: Int = 1,
         columnSpan: Int = 1,
         indent: CGFloat = 0,
         topRuleColor: NSColor? = nil,
         highlights: [PDFTextHighlight] = [],
         paired: PDFPairedText? = nil,
         textColor: NSColor? = nil,
         fillIsOpaque: Bool = false) {
        self.text = text
        self.fill = fill
        self.alignment = alignment
        self.monospaced = monospaced
        self.truncates = truncates
        self.borders = borders
        self.rowSpan = rowSpan
        self.columnSpan = columnSpan
        self.indent = indent
        self.topRuleColor = topRuleColor
        self.highlights = highlights
        self.paired = paired
        self.textColor = textColor
        self.fillIsOpaque = fillIsOpaque
    }

    /// A cell whose content is a balanced pair. `text` is derived from the pair rather than
    /// passed alongside it, so the searchable string and the drawn one cannot disagree.
    init(paired: PDFPairedText,
         fill: NSColor? = nil,
         textColor: NSColor? = nil) {
        self.init(paired.plain, fill: fill, paired: paired, textColor: textColor)
    }
}

// MARK: - Cell Borders

/// Which edges of a cell are ruled. See `PDFCell.borders`.
struct PDFCellBorders: OptionSet, Hashable, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let top    = PDFCellBorders(rawValue: 1 << 0)
    static let bottom = PDFCellBorders(rawValue: 1 << 1)
    static let left   = PDFCellBorders(rawValue: 1 << 2)
    static let right  = PDFCellBorders(rawValue: 1 << 3)

    static let all: PDFCellBorders = [.top, .bottom, .left, .right]
    /// The two vertical rules only — a cell that continues into its neighbors above and
    /// below rather than closing against them.
    static let sides: PDFCellBorders = [.left, .right]
}

// MARK: - Section

/// A titled table: one heading, one column set, and the rows beneath it.
///
/// A "section" rather than a "document" because one PDF may hold several — the complete
/// library export writes its own section and then appends one per ReportsView tab into the
/// same file, each starting on a fresh page with its own geometry.
struct PDFTableSection {
    var title: String
    var columns: [PDFTableColumn]
    var headerGroups: [PDFHeaderGroup]
    var rows: [[PDFCell]]

    /// How many side-by-side copies of the table one page carries. `1` is an ordinary
    /// full-width table.
    ///
    /// # What this buys
    ///
    /// A table whose columns are all measured — no elastic Notes field to soak up the
    /// surplus — leaves the rest of the page blank. The Viewing History section is exactly
    /// that: a date, a gap, and a version code, none of which grows. Splitting the page
    /// into two panes and flowing rows down the first before starting the second roughly
    /// doubles the rows per page at no cost in legibility, because each pane is still the
    /// full table at the full type size.
    ///
    /// # How the flow reads
    ///
    /// Down, then across, then over: a page's left pane fills before its right one begins,
    /// and only when the right pane fills does a new page start. That is the order a reader
    /// of a newspaper column or a phone book already has, and it is the only order in which
    /// a numbered index stays monotonic down each pane.
    ///
    /// Every pane draws its own header band, and draws it only when a row actually lands in
    /// it — so a section that ends halfway down a page's first pane does not print an empty
    /// table beside itself.
    var columnsPerPage: Int

    /// Runs of rows the renderer should avoid breaking across a pane or a page.
    ///
    /// # Advisory, not a guarantee
    ///
    /// A run is moved to the next pane when it does not fit in what is left of this one
    /// AND it would fit in an empty one. A run too tall for any pane is placed row by row
    /// and split as it always was — the alternative is a section that can never place it.
    /// That is the difference between this and `PDFCell.rowSpan`, which is a HARD block: a
    /// merged cell has no meaning either side of a break, so it is never split, while a
    /// group of related rows is merely nicer unbroken.
    ///
    /// # Why the detail sections need it
    ///
    /// Both per-film sections print a banded film row followed by that film's own rows, and
    /// the band is the only thing that says whose rows those are. A break between the two
    /// leaves a pane opening with unattributed detail — which the two-up Viewing History
    /// layout makes twice as likely, since it has twice as many boundaries to fall on.
    ///
    /// Ranges are expected to be disjoint and to start on a row that is not already inside
    /// a `rowSpan` block. A range that fails either is ignored rather than honored halfway.
    var keepTogether: [Range<Int>]

    init(title: String,
         columns: [PDFTableColumn],
         headerGroups: [PDFHeaderGroup] = [],
         columnsPerPage: Int = 1,
         keepTogether: [Range<Int>] = [],
         rows: [[PDFCell]]) {
        self.title = title
        self.columns = columns
        self.headerGroups = headerGroups
        self.columnsPerPage = max(1, columnsPerPage)
        self.keepTogether = keepTogether
        self.rows = rows
    }

    /// Convenience for the plain-text tables the ReportsView tab exports build: every cell
    /// unfilled, taking its column's alignment.
    init(title: String, columns: [PDFTableColumn], textRows: [[String]]) {
        self.init(title: title,
                  columns: columns,
                  rows: textRows.map { $0.map { PDFCell($0) } })
    }
}

// MARK: - Footer

/// What a page's footer says about where the page sits.
///
/// A single-section document has one answer — "Page 3 of 8" — and centers it. A document
/// assembled from several sections has two, and they disagree: page 3 of the statistics
/// SHEET may be page 22 of the DOCUMENT. Printing only the first strands a reader who has
/// the paper in their hands; printing only the second loses the section they were reading.
/// So the assembled form prints both, labeled, at opposite corners.
enum PDFFooter {
    /// One centered "Page N of M" — a document that is only its one section.
    case single(page: Int, total: Int)
    /// Section position at bottom-left, production timestamp in the middle, document
    /// position at bottom-right.
    ///
    /// The timestamp is stamped on EVERY page, not just the first: a report of this kind is
    /// printed, filed, and compared against a later one, and a loose page with no date on it
    /// is a page nobody can place.
    case sectioned(sectionPage: Int, sectionTotal: Int,
                   documentPage: Int, documentTotal: Int,
                   producedOn: String)
}

// MARK: - Section Metrics

/// A table section laid out but not drawn: every row's height, and the page count those
/// heights produce.
///
/// Measuring is the expensive half of rendering, and the document builder has to measure
/// every section before it can draw the first one (page one's footer names a total that
/// depends on the last page). Carrying the result forward into the draw is what stops that
/// from costing two full layouts of every table in the document.
struct PDFSectionMetrics {
    var rowHeights: [CGFloat]
    var pageCount: Int
    /// Where every row landed: its page within the section, its pane on that page, and the
    /// distance from the page's top edge to the row's top.
    ///
    /// Carried on the metrics rather than recomputed by `render` because the flow is now
    /// more than "add heights until the page is full" — it honors panes and refuses to
    /// break inside a `rowSpan` block — and a page COUNT that disagreed with where the rows
    /// were actually drawn would put a wrong total in every footer of the document. One
    /// simulation, used both to count and to draw, cannot disagree with itself.
    var placements: [PDFRowPlacement]
}

/// One row's position in the flow. See `PDFSectionMetrics.placements`.
struct PDFRowPlacement: Equatable {
    /// 1-based, within the section.
    var page: Int
    /// 0-based, left to right across the page's panes.
    var pane: Int
    /// Distance from the page's TOP edge down to the row's top edge. (Page geometry is
    /// expressed downward from the top throughout the renderer; CoreGraphics' upward y is
    /// derived at the drawing site.)
    var y: CGFloat
}

// MARK: - Renderer

@MainActor
enum PDFTableRenderer {
    // MARK: Public entry point

    /// Draws `section` into `context`, starting a new page and paginating as needed.
    ///
    /// The caller owns the `CGContext` and is responsible for `closePDF()`. Calling this
    /// more than once on the same context appends sections to the same document, which is
    /// how the library export assembles the library table and the report sheets into a
    /// single file.
    static func render(
        _ section: PDFTableSection,
        into context: CGContext,
        geometry: PDFPageGeometry
    ) async throws {
        try await render(section, into: context, geometry: geometry) { page, total in
            .single(page: page, total: total)
        }
    }

    /// The general form. `footer` is handed each page's position WITHIN THIS SECTION and
    /// returns what its footer should say — which is how `PDFDocumentBuilder` folds in a
    /// document-wide position this call has no way to know.
    ///
    /// # Why this is async
    ///
    /// The whole PDF stack runs on the MainActor, and a library-sized section is a hundred
    /// pages of a few hundred cells each. Drawn in one call that is several seconds during
    /// which the run loop never turns — no progress bar movement, no Cancel button, and
    /// past a couple of seconds the system's spinning cursor. So the loop SUSPENDS after
    /// every page: `afterPage` is awaited, then the task yields, and the run loop gets a
    /// turn between every page of every section. The drawing itself is no faster; it is
    /// merely no longer one indivisible stretch.
    ///
    /// Suspending between pages is safe because nothing is open then — the page has been
    /// ended and the next not begun — and because `NSGraphicsContext.current`, which is
    /// process-wide state, is re-pointed at this context at the start of every page rather
    /// than trusted to have survived whatever ran during the suspension.
    ///
    /// Cancellation is checked at the same point, so a Cancel mid-document stops the draw
    /// at the next page boundary rather than after the last one.
    static func render(
        _ section: PDFTableSection,
        into context: CGContext,
        geometry: PDFPageGeometry,
        metrics: PDFSectionMetrics? = nil,
        footer: (_ sectionPage: Int, _ sectionTotal: Int) -> PDFFooter,
        afterPage: ((_ sectionPage: Int, _ sectionTotal: Int) -> Void)? = nil
    ) async throws {
        let panes = paneLayout(section, geometry: geometry)

        let fonts = BodyFonts(geometry: geometry)
        let headerFont = PDFFonts.font(size: geometry.headerFontSize, weight: .bold)

        // Every row's real height and where it lands. Page breaks are decided against these,
        // which is also what makes the "Page N of M" footer correct on page one — a flat
        // estimate under-counts any table with wrapping cells (a long Notes field is the
        // usual culprit) and mislabels every footer in the document.
        //
        // Measuring is the expensive half of rendering — one `boundingRect` per cell — so
        // a caller that has already measured this section hands the result back rather
        // than paying for it twice. `PDFDocumentBuilder` does exactly that: it must count
        // every section's pages before drawing any of them, and that count IS this
        // measurement.
        let measured = metrics ?? self.metrics(of: section, geometry: geometry)
        let rowHeights = measured.rowHeights
        let placements = measured.placements
        let totalPages = measured.pageCount

        // Which column of which row is drawn by an EARLIER row's spanning cell, and at what
        // height that spanning cell is drawn. Derived from the same row heights the flow
        // was simulated against, so a span's rect always closes exactly on the bottom edge
        // of the last row it covers.
        let spans = spanLayout(section, rowHeights: rowHeights,
                               columns: panes[0].columns)

        // AppKit's text drawing path reads NSGraphicsContext.current, and beginPDFPage
        // installs a fresh graphics state — so this is re-pointed at the context after
        // every page break as well as here.
        //
        // The previous current context is restored on the way out: this is process-wide
        // state, and leaving it aimed at a PDF context that `closePDF()` has finished with
        // would hand the next unrelated AppKit draw a dead destination.
        let priorContext = NSGraphicsContext.current
        defer { NSGraphicsContext.current = priorContext }
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext

        guard !placements.isEmpty else {
            beginPage(context, geometry: geometry)
            NSGraphicsContext.current = nsContext
            drawPageHeading(section.title, context: context, geometry: geometry)
            drawFooter(footer(1, max(1, totalPages)), context: context, geometry: geometry)
            context.endPDFPage()
            return
        }

        var currentPage = 0
        // The panes whose header band has already been drawn ON THIS PAGE. A band is drawn
        // lazily, immediately before the first row that lands in its pane, so a section
        // that runs out halfway through a page does not leave an empty table header beside
        // its last rows.
        var bandedPanes = Set<Int>()

        for (index, placement) in placements.enumerated() {
            if placement.page != currentPage {
                if currentPage > 0 {
                    drawFooter(footer(currentPage, totalPages), context: context, geometry: geometry)
                    context.endPDFPage()
                    afterPage?(currentPage, totalPages)
                    try Task.checkCancellation()
                    await Task.yield()
                }
                beginPage(context, geometry: geometry)
                NSGraphicsContext.current = nsContext
                drawPageHeading(section.title, context: context, geometry: geometry)
                currentPage = placement.page
                bandedPanes.removeAll()
            }

            let pane = panes[min(placement.pane, panes.count - 1)]

            if bandedPanes.insert(placement.pane).inserted {
                drawHeaderBand(section, columns: pane.columns, xPositions: pane.origins,
                               yPosition: geometry.margin + geometry.titleHeight,
                               font: headerFont, context: context, geometry: geometry)
            }

            drawRow(section.rows[index], columns: pane.columns, xPositions: pane.origins,
                    yPosition: placement.y, height: rowHeights[index],
                    spanSizes: spans.sizes[index] ?? [:],
                    covered: spans.covered[index] ?? [],
                    fonts: fonts, context: context, geometry: geometry)
        }

        drawFooter(footer(max(1, currentPage), totalPages), context: context, geometry: geometry)
        context.endPDFPage()
        afterPage?(max(1, currentPage), totalPages)
    }

    // MARK: Pane geometry

    /// One pane of a page: the column set normalized to the pane's own width, and the
    /// x origins that follow from it.
    private struct Pane {
        let columns: [PDFTableColumn]
        let origins: [CGFloat]
    }

    /// The panes a page is divided into — one for an ordinary table, `columnsPerPage` of
    /// them for a multi-column section.
    ///
    /// Every pane carries the SAME columns at the SAME width; only the x origin differs.
    /// That is what makes a two-up section still be one table rather than two: a row lands
    /// in whichever pane the flow reached, and looks identical either way.
    private static func paneLayout(_ section: PDFTableSection,
                                   geometry: PDFPageGeometry) -> [Pane] {
        let count = max(1, section.columnsPerPage)
        let gutters = geometry.paneGutter * CGFloat(count - 1)
        let paneWidth = (geometry.contentWidth - gutters) / CGFloat(count)
        let columns = normalizedColumns(section.columns, to: paneWidth)

        return (0..<count).map { index in
            Pane(columns: columns,
                 origins: columnOrigins(
                    columns,
                    startingAt: geometry.margin + CGFloat(index) * (paneWidth + geometry.paneGutter)))
        }
    }

    // MARK: Row spans

    /// Where the merges are: per row, the size each spanning cell is drawn at, and which
    /// cells draw nothing because a span covers them.
    private struct SpanLayout {
        /// row index → (column index → the merged size to draw that cell at). Only cells
        /// that actually span appear; everything else takes its row's height and its
        /// column's width.
        var sizes: [Int: [Int: CGSize]] = [:]
        /// row index → the columns that draw nothing at all, because a span from above or
        /// from the left already owns their space.
        var covered: [Int: Set<Int>] = [:]
    }

    private static func spanLayout(_ section: PDFTableSection,
                                   rowHeights: [CGFloat],
                                   columns: [PDFTableColumn]) -> SpanLayout {
        var layout = SpanLayout()
        for (index, row) in section.rows.enumerated() {
            for (column, cell) in row.enumerated()
            where cell.rowSpan > 1 || cell.columnSpan > 1 {
                let lastRow = min(index + max(1, cell.rowSpan), rowHeights.count)
                let lastColumn = min(column + max(1, cell.columnSpan), columns.count)
                guard lastRow > index, lastColumn > column else { continue }

                layout.sizes[index, default: [:]][column] = CGSize(
                    width: columns[column..<lastColumn].reduce(0) { $0 + $1.width },
                    height: rowHeights[index..<lastRow].reduce(0, +))

                // Every cell in the merged rectangle except the one that owns it.
                for coveredRow in index..<lastRow {
                    for coveredColumn in column..<lastColumn
                    where !(coveredRow == index && coveredColumn == column) {
                        layout.covered[coveredRow, default: []].insert(coveredColumn)
                    }
                }
            }
        }
        return layout
    }

    /// The rows grouped into blocks that must not be split across a pane or page boundary.
    ///
    /// A block is a run opened by a `rowSpan` and closed when every span inside it has
    /// ended — spans are allowed to overlap and to nest, and the run simply extends to the
    /// furthest one. Every other row is a block of its own, which is what keeps an ordinary
    /// table's pagination byte-for-byte what it always was.
    private static func atomicBlocks(_ section: PDFTableSection) -> [Range<Int>] {
        var blocks: [Range<Int>] = []
        var index = 0
        while index < section.rows.count {
            var end = index + 1
            var scan = index
            while scan < end {
                for cell in section.rows[scan] where cell.rowSpan > 1 {
                    end = max(end, min(scan + cell.rowSpan, section.rows.count))
                }
                scan += 1
            }
            blocks.append(index..<end)
            index = end
        }
        return blocks
    }

    /// The runs the flow actually places, which is the hard blocks with each honored
    /// `keepTogether` range folded into one.
    ///
    /// A range is honored only when it begins on a hard block boundary — folding a merged
    /// cell's rows apart would defeat the guarantee `rowSpan` makes — and only when the
    /// whole of it fits in an empty pane. Everything else falls through to the hard blocks,
    /// which is the placement this renderer has always done.
    private static func placementUnits(_ section: PDFTableSection,
                                       rowHeights: [CGFloat],
                                       usable: CGFloat) -> [Range<Int>] {
        let hard = atomicBlocks(section)
        guard !section.keepTogether.isEmpty else { return hard }

        // Keyed by first row, so a block boundary can be tested against it in one lookup.
        var groups: [Int: Range<Int>] = [:]
        for range in section.keepTogether where !range.isEmpty
        && range.upperBound <= rowHeights.count {
            groups[range.lowerBound] = range
        }

        var units: [Range<Int>] = []
        var index = 0
        while index < hard.count {
            let start = hard[index].lowerBound
            if let group = groups[start], rowHeights[group].reduce(0, +) <= usable {
                units.append(group)
                while index < hard.count && hard[index].lowerBound < group.upperBound {
                    index += 1
                }
            } else {
                units.append(hard[index])
                index += 1
            }
        }
        return units
    }

    // MARK: Flow

    /// Walks the rows into panes and pages, and reports where each one landed.
    ///
    /// The one definition of the section's pagination: `metrics` counts pages from it and
    /// `render` draws from it, so the total in a footer and the page a row is actually on
    /// cannot disagree. Its rules, in order:
    ///
    ///   * A block that does not fit in what is left of the pane moves to the next pane;
    ///     when the panes run out, to the next page.
    ///   * A block that does not fit in a WHOLE empty pane is drawn anyway rather than
    ///     moved forever. It overflows the pane's foot, which is visible and fixable; the
    ///     alternative is a loop that never terminates.
    ///   * Blocks are never split, so a merged cell always has all of its rows around it.
    ///   * A `keepTogether` run that fits in an empty pane is placed as one such block —
    ///     see `placementUnits`.
    private static func flow(_ section: PDFTableSection,
                             rowHeights: [CGFloat],
                             geometry: PDFPageGeometry) -> [PDFRowPlacement] {
        let paneCount = max(1, section.columnsPerPage)
        let top = geometry.margin + geometry.titleHeight
            + headerBandHeight(section, geometry: geometry)
        let floor = geometry.pageSize.height - geometry.margin - geometry.footerReserve

        var placements = [PDFRowPlacement](
            repeating: PDFRowPlacement(page: 1, pane: 0, y: top), count: rowHeights.count)

        var page = 1
        var pane = 0
        var y = top

        for block in placementUnits(section, rowHeights: rowHeights,
                                    usable: max(0, floor - top)) {
            let height = rowHeights[block].reduce(0, +)
            if y + height > floor && y > top {
                pane += 1
                if pane >= paneCount {
                    page += 1
                    pane = 0
                }
                y = top
            }
            for index in block {
                placements[index] = PDFRowPlacement(page: page, pane: pane, y: y)
                y += rowHeights[index]
            }
        }

        return placements
    }

    /// Lays `section` out without drawing anything: every row's height, and the page count
    /// those heights produce.
    ///
    /// A document footer cannot name a total it has not counted, and the count is only
    /// knowable by laying every row out — so the builder measures every section first,
    /// then renders. Handing the result back to `render` is what keeps that from being a
    /// SECOND full measurement of the same table: on the complete-library section that is
    /// one `boundingRect` per cell across every film in the library.
    static func metrics(of section: PDFTableSection,
                        geometry: PDFPageGeometry) -> PDFSectionMetrics {
        // Measured against a PANE's columns, not the page's — a two-up section's cells wrap
        // inside a half-width table, and measuring them at full width would report row
        // heights roughly half of what the section actually draws.
        let columns = paneLayout(section, geometry: geometry)[0].columns
        let fonts = BodyFonts(geometry: geometry)
        let heights = section.rows.map {
            rowHeight($0, columns: columns, fonts: fonts, geometry: geometry)
        }
        let placements = flow(section, rowHeights: heights, geometry: geometry)
        return PDFSectionMetrics(
            rowHeights: heights,
            pageCount: max(1, placements.last?.page ?? 1),
            placements: placements)
    }

    /// `metrics(of:geometry:)`, suspending every `stride` rows so the run loop can turn.
    ///
    /// Measuring is one `boundingRect` per cell, and a library-sized section is tens of
    /// thousands of cells — half a second or more in one stretch. The document builder
    /// measures every section before it can draw the first page, so without this the
    /// export would open with a stall as long as every section's measurement combined. The
    /// result is identical to the synchronous form; only the pacing differs.
    static func metrics(of section: PDFTableSection,
                        geometry: PDFPageGeometry,
                        yieldingEvery stride: Int) async throws -> PDFSectionMetrics {
        let columns = paneLayout(section, geometry: geometry)[0].columns
        let fonts = BodyFonts(geometry: geometry)
        var heights: [CGFloat] = []
        heights.reserveCapacity(section.rows.count)
        for (index, row) in section.rows.enumerated() {
            heights.append(rowHeight(row, columns: columns, fonts: fonts, geometry: geometry))
            if index % max(1, stride) == stride - 1 {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        let placements = flow(section, rowHeights: heights, geometry: geometry)
        return PDFSectionMetrics(
            rowHeights: heights,
            pageCount: max(1, placements.last?.page ?? 1),
            placements: placements)
    }

    /// How many pages `section` will occupy at `geometry`, without drawing anything.
    static func pageCount(of section: PDFTableSection, geometry: PDFPageGeometry) -> Int {
        metrics(of: section, geometry: geometry).pageCount
    }

    // MARK: Page lifecycle

    /// Begins a page that declares its OWN media box.
    ///
    /// Passing the box explicitly (rather than `beginPDFPage(nil)`, which inherits the box
    /// the context was created with) is what allows one document to hold both the landscape
    /// library table and the portrait report sheets that follow it.
    private static func beginPage(_ context: CGContext, geometry: PDFPageGeometry) {
        var box = CGRect(origin: .zero, size: geometry.pageSize)
        let boxData = unsafe Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
        context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
    }

    // MARK: Column geometry

    /// Scales the column set so its widths sum to exactly the page's content width.
    ///
    /// See `PDFTableColumn.width` — widths are weights. Normalizing here is what makes them
    /// safe to tweak individually.
    private static func normalizedColumns(
        _ columns: [PDFTableColumn],
        to width: CGFloat
    ) -> [PDFTableColumn] {
        let total = columns.reduce(0) { $0 + $1.width }
        guard total > 0 else { return columns }
        let scale = width / total
        guard abs(scale - 1) > 0.0001 else { return columns }
        return columns.map {
            var column = $0
            column.width *= scale
            return column
        }
    }

    /// The left edge of each column, plus a trailing entry for the table's right edge.
    private static func columnOrigins(
        _ columns: [PDFTableColumn],
        startingAt originX: CGFloat
    ) -> [CGFloat] {
        var origins: [CGFloat] = [originX]
        var x = originX
        for column in columns {
            x += column.width
            origins.append(x)
        }
        return origins
    }

    // MARK: Header

    /// One header row, or two when the section declares groups.
    private static func headerBandHeight(
        _ section: PDFTableSection,
        geometry: PDFPageGeometry
    ) -> CGFloat {
        section.headerGroups.isEmpty
            ? geometry.headerRowHeight
            : geometry.headerRowHeight * 2
    }

    private static func drawHeaderBand(
        _ section: PDFTableSection,
        columns: [PDFTableColumn],
        xPositions: [CGFloat],
        yPosition: CGFloat,
        font: NSFont,
        context: CGContext,
        geometry: PDFPageGeometry
    ) {
        let rowHeight = geometry.headerRowHeight
        let grouped = !section.headerGroups.isEmpty
        let bandHeight = grouped ? rowHeight * 2 : rowHeight

        // Which columns belong to a group, so the rest can be drawn as one merged cell
        // spanning both header rows rather than leaving a blank banner above them.
        var groupedColumns = Set<Int>()
        for group in section.headerGroups {
            for index in group.columns { groupedColumns.insert(index) }
        }

        for (index, column) in columns.enumerated() {
            guard !grouped || !groupedColumns.contains(index) else { continue }

            let rect = CGRect(x: xPositions[index],
                              y: geometry.pageSize.height - yPosition - bandHeight,
                              width: column.width,
                              height: bandHeight)
            drawHeaderCell(column.title, rect: rect,
                           alignment: column.resolvedHeaderAlignment, font: font,
                           borders: column.headerBorders, paired: column.pairedTitle,
                           context: context, geometry: geometry)
        }

        guard grouped else { return }

        // Upper row: one banner per group.
        for group in section.headerGroups {
            guard let first = group.columns.first,
                  first < columns.count,
                  group.columns.upperBound <= columns.count else { continue }
            let width = columns[group.columns].reduce(0) { $0 + $1.width }
            let rect = CGRect(x: xPositions[first],
                              y: geometry.pageSize.height - yPosition - rowHeight,
                              width: width,
                              height: rowHeight)
            drawHeaderCell(group.title, rect: rect,
                           alignment: group.alignment, font: font,
                           context: context, geometry: geometry)
        }

        // Lower row: each grouped column's own header, laid out on the group's OWN header
        // weights when it supplies them — see PDFHeaderGroup.headerWeights. The cells still
        // tile the group's exact span, so the banner above and the data below stay aligned.
        for group in section.headerGroups {
            guard let first = group.columns.first, first < columns.count else { continue }
            let members = Array(group.columns.filter { $0 < columns.count })
            let span = members.reduce(CGFloat(0)) { $0 + columns[$1].width }
            let widths = subHeaderWidths(group: group, members: members,
                                         columns: columns, span: span)

            var x = xPositions[first]
            for (offset, index) in members.enumerated() {
                let rect = CGRect(x: x,
                                  y: geometry.pageSize.height - yPosition - bandHeight,
                                  width: widths[offset],
                                  height: rowHeight)
                drawHeaderCell(columns[index].title, rect: rect,
                               alignment: columns[index].resolvedHeaderAlignment, font: font,
                               borders: columns[index].headerBorders,
                               paired: columns[index].pairedTitle,
                               context: context, geometry: geometry)
                x += widths[offset]
            }
        }
    }

    /// How a group's sub-header row divides the group's span.
    ///
    /// The declared weights are normalized to the span so they cannot drift away from the
    /// column edges the body rows use, however they are written. Absent weights — or a set
    /// that does not match the member count — fall back to the body columns' own widths,
    /// which is the layout this row always had.
    private static func subHeaderWidths(
        group: PDFHeaderGroup,
        members: [Int],
        columns: [PDFTableColumn],
        span: CGFloat
    ) -> [CGFloat] {
        let bodyWidths = members.map { columns[$0].width }
        guard let weights = group.headerWeights,
              weights.count == members.count,
              span > 0 else { return bodyWidths }

        let total = weights.reduce(0, +)
        guard total > 0 else { return bodyWidths }
        return weights.map { $0 / total * span }
    }

    /// Draws one header cell with its title vertically centered in the space available.
    ///
    /// Centering is MEASURED rather than assumed. A merged header spans two rows while its
    /// title may occupy one line or two — "Chr." against "Aspect Ratio" — and the previous
    /// fixed half-row nudge was only ever correct for the one-line case: a title that
    /// wrapped to two lines was pushed down until it sat on the floor of the cell. Asking
    /// for the text's real height at the cell's real width covers every combination,
    /// including the single-row banner and sub-header cells, with one rule.
    private static func drawHeaderCell(
        _ text: String,
        rect: CGRect,
        alignment: NSTextAlignment,
        font: NSFont,
        borders: PDFCellBorders = .all,
        paired: PDFPairedText? = nil,
        context: CGContext,
        geometry: PDFPageGeometry
    ) {
        PDFDrawing.fillOpaque(rect, color: PDFPalette.headerBackground, context: context)
        PDFDrawing.strokeEdges(rect, edges: borders, context: context)

        var textRect = rect.insetBy(dx: geometry.cellPaddingX, dy: geometry.cellPaddingY)
        let textHeight = PDFDrawing.textHeight(text, width: textRect.width, font: font,
                                               lineSpacing: geometry.lineSpacing)
        // Text draws from the top of its rect downward, and y grows upward, so shifting the
        // rect DOWN by half the slack centers the block within the cell.
        let slack = max(0, textRect.height - textHeight)
        textRect.origin.y -= slack / 2

        // A paired header sits on the same axis as the paired values below it, which is the
        // whole point of pairing them: the separator forms one vertical rule from the
        // header down through every row of the column.
        if let paired {
            PDFDrawing.drawPaired(paired, in: textRect, font: font, color: PDFPalette.text,
                                  lineSpacing: geometry.lineSpacing, context: context)
        } else {
            PDFDrawing.drawText(text, in: textRect, font: font, color: PDFPalette.text,
                                alignment: alignment, lineSpacing: geometry.lineSpacing,
                                context: context)
        }
    }

    // MARK: Rows

    /// The proportional and fixed-width faces at one geometry's body size, resolved once
    /// per section rather than per cell.
    private struct BodyFonts {
        let proportional: NSFont
        let monospaced: NSFont

        /// The pair a geometry's body size calls for. Resolved from the geometry rather
        /// than assembled at each of the three sites that need them (render, metrics, and
        /// the stack layout), which is what stops one of them drifting to a different
        /// weight from the other two and silently measuring against a face it never draws.
        @MainActor init(geometry: PDFPageGeometry) {
            self.proportional = PDFFonts.font(size: geometry.fontSize, weight: .semibold)
            self.monospaced = PDFFonts.monospacedFont(size: geometry.fontSize, weight: .semibold)
        }

        func face(for cell: PDFCell) -> NSFont { cell.monospaced ? monospaced : proportional }
    }

    private static func drawRow(
        _ row: [PDFCell],
        columns: [PDFTableColumn],
        xPositions: [CGFloat],
        yPosition: CGFloat,
        height: CGFloat,
        // Defaulted empty for the tile-stack renderer below, whose tiles are plain tables
        // with no merged cells — not because a merge there would be wrong, but because
        // nothing builds one.
        spanSizes: [Int: CGSize] = [:],
        covered: Set<Int> = [],
        fonts: BodyFonts,
        context: CGContext,
        geometry: PDFPageGeometry
    ) {
        for (index, column) in columns.enumerated() {
            // A column covered by a merge that began above draws NOTHING — not the fill,
            // not the rules, not an empty cell. The spanning cell already owns this space.
            guard !covered.contains(index) else { continue }

            // A spanning cell covers the rows and columns it names; everything else is its
            // own row's height at its own column's width.
            let size = spanSizes[index] ?? CGSize(width: column.width, height: height)
            let rect = CGRect(x: xPositions[index],
                              y: geometry.pageSize.height - yPosition - size.height,
                              width: size.width,
                              height: size.height)
            let cell = index < row.count ? row[index] : PDFCell("")

            if let fill = cell.fill {
                PDFDrawing.fillCell(rect, color: fill, opaque: cell.fillIsOpaque,
                                    context: context)
            }
            PDFDrawing.strokeEdges(rect, edges: cell.borders, context: context)
            if let topRule = cell.topRuleColor {
                PDFDrawing.strokeEdges(rect, edges: .top, color: topRule, context: context)
            }

            var textRect = rect.insetBy(dx: geometry.cellPaddingX, dy: geometry.cellPaddingY)
            if cell.indent > 0 {
                textRect.origin.x += cell.indent
                textRect.size.width = max(0, textRect.width - cell.indent)
            }

            // A cell merged DOWNWARD centers vertically in the space it owns; an ordinary
            // one keeps the top alignment every table in the app has always had. Centering
            // is the only reading of a cell that deliberately covers several rows — pinned
            // to the top it would look like it belonged to the first of them. A cell merged
            // only sideways has gained no vertical room and is left alone.
            if let merged = spanSizes[index], merged.height > height + 0.001 {
                let textHeight = PDFDrawing.textHeight(cell.text, width: textRect.width,
                                                       font: fonts.face(for: cell),
                                                       lineSpacing: geometry.lineSpacing)
                // Text draws downward from the top of its rect and y grows upward, so
                // lowering the rect by half the slack centers the block.
                textRect.origin.y -= max(0, textRect.height - textHeight) / 2
            }

            if let paired = cell.paired {
                PDFDrawing.drawPaired(paired, in: textRect, font: fonts.face(for: cell),
                                      color: cell.textColor ?? PDFPalette.text,
                                      lineSpacing: geometry.lineSpacing, context: context)
            } else {
                PDFDrawing.drawText(cell.text, in: textRect, font: fonts.face(for: cell),
                                    color: cell.textColor ?? PDFPalette.text,
                                    alignment: cell.alignment ?? column.alignment,
                                    lineSpacing: geometry.lineSpacing,
                                    lineBreak: cell.truncates ? .byTruncatingTail : .byWordWrapping,
                                    highlights: cell.highlights,
                                    context: context)
            }
        }
    }

    private static func rowHeight(
        _ row: [PDFCell],
        columns: [PDFTableColumn],
        fonts: BodyFonts,
        geometry: PDFPageGeometry
    ) -> CGFloat {
        var height = geometry.minRowHeight
        for index in columns.indices where index < row.count {
            let cell = row[index]
            // A cell that spans columns wraps inside the WHOLE span. Measuring it against
            // its first column alone would report several lines for text that in fact
            // fits on one, and grow the row to hold them.
            let span = min(index + max(1, cell.columnSpan), columns.count)
            let available = columns[index..<span].reduce(CGFloat(0)) { $0 + $1.width }
                - (geometry.cellPaddingX * 2)
            let needed = cell.truncates
                ? PDFDrawing.singleLineHeight(cell.text,
                                              font: fonts.face(for: cell),
                                              lineSpacing: geometry.lineSpacing)
                : PDFDrawing.textHeight(cell.text,
                                        width: available,
                                        font: fonts.face(for: cell),
                                        lineSpacing: geometry.lineSpacing)
            // A merged cell is drawn across `rowSpan` rows, so it only has to claim its
            // share of the height from each of them. Charging the whole of it to the first
            // row would make that row tall enough to hold the text twice over.
            height = max(height,
                         needed / CGFloat(max(1, cell.rowSpan)) + (geometry.cellPaddingY * 2))
        }
        return height
    }

    // MARK: Chrome

    /// The banner every page opens with: the section title at the left margin and the
    /// application mark at the right, sharing one horizontal band.
    static func drawPageHeading(
        _ title: String,
        context: CGContext,
        geometry: PDFPageGeometry
    ) {
        drawTitle(title, context: context, geometry: geometry)
        drawWordmark(context: context, geometry: geometry)
        if let mark = PDFBrandMark.image {
            PDFDrawing.drawImage(mark, in: PDFBrandMark.rect(in: geometry), context: context)
        }
    }

    private static func drawTitle(
        _ title: String,
        context: CGContext,
        geometry: PDFPageGeometry
    ) {
        let font = PDFFonts.font(size: geometry.titleFontSize, weight: .bold)
        let rect = CGRect(
            x: geometry.margin,
            y: geometry.pageSize.height - geometry.margin - geometry.titleHeight + 10,
            // Stops short of the "Film Tracker" wordmark + its padding + the brand mark's
            // square, so a long section title clips before the wordmark rather than running
            // underneath it.
            width: geometry.contentWidth - PDFBrandMark.reservedWidth(in: geometry) - 6,
            height: geometry.titleHeight
        )
        PDFDrawing.drawText(title, in: rect, font: font, color: PDFPalette.text,
                            alignment: .left, lineSpacing: geometry.lineSpacing,
                            context: context)
    }

    /// The "Film Tracker" wordmark, printed just right of the brand-mark icon.
    private static func drawWordmark(
        context: CGContext,
        geometry: PDFPageGeometry
    ) {
        PDFDrawing.drawText(PDFBrandMark.wordmark,
                            in: PDFBrandMark.wordmarkRect(in: geometry),
                            font: PDFBrandMark.wordmarkFont(in: geometry),
                            color: PDFPalette.text,
                            alignment: .left,
                            lineSpacing: geometry.lineSpacing,
                            lineBreak: .byClipping,
                            context: context)
    }

    private static func drawFooter(
        _ footer: PDFFooter,
        context: CGContext,
        geometry: PDFPageGeometry
    ) {
        let font = PDFFonts.font(size: geometry.footerFontSize, weight: .semibold)
        let baseline = geometry.margin - 20

        switch footer {
        case let .single(page, total):
            draw(footerText: "Page \(page) of \(total)", font: font,
                 alignedTo: .center, baseline: baseline, context: context, geometry: geometry)

        case let .sectioned(sectionPage, sectionTotal, documentPage, documentTotal, producedOn):
            // Labeled, because two bare numbers at opposite corners would be a puzzle.
            draw(footerText: "Section page \(sectionPage) of \(sectionTotal)", font: font,
                 alignedTo: .left, baseline: baseline, context: context, geometry: geometry)
            draw(footerText: producedOn, font: font,
                 alignedTo: .center, baseline: baseline, context: context, geometry: geometry)
            draw(footerText: "Document page \(documentPage) of \(documentTotal)", font: font,
                 alignedTo: .right, baseline: baseline, context: context, geometry: geometry)
        }
    }

    private static func draw(
        footerText: String,
        font: NSFont,
        alignedTo alignment: NSTextAlignment,
        baseline: CGFloat,
        context: CGContext,
        geometry: PDFPageGeometry
    ) {
        let attributed = NSAttributedString(string: footerText, attributes: [
            .font: font,
            .foregroundColor: PDFPalette.footerText
        ])
        let size = attributed.size()

        let x: CGFloat
        switch alignment {
        case .left:   x = geometry.margin
        case .right:  x = geometry.pageSize.width - geometry.margin - size.width
        default:      x = (geometry.pageSize.width - size.width) / 2
        }

        context.saveGState()
        attributed.draw(in: CGRect(x: x, y: baseline, width: size.width, height: size.height))
        context.restoreGState()
    }
}

// MARK: - Document Builder

/// Assembles several `PDFTableSection`s into one document with document-wide page numbering.
///
/// Sections are collected first and drawn only on `finish()`, because the footer of the very
/// first page has to name a total that depends on the last — so nothing can be drawn until
/// every section has been measured. Each section keeps its own geometry, which is what lets
/// one document mix page sizes.
@MainActor
final class PDFDocumentBuilder {
    private let context: CGContext
    private let producedOn: String
    private var pending: [(sheet: PDFSheet, geometry: PDFPageGeometry)] = []

    /// - Parameter producedAt: the moment the document is stamped with. Taken once and
    ///   reused on every page, so a long render cannot leave two pages claiming to have
    ///   been produced a minute apart.
    init(context: CGContext, producedAt: Date = Date()) {
        self.context = context
        self.producedOn = Self.stamp(producedAt)
    }

    /// "Report produced on September 4, 2026 at 3:05 PM".
    ///
    /// Pinned to en_US_POSIX so the month name and the AM/PM marker are stable regardless
    /// of the reader's locale — this string is part of the document's identity, not a piece
    /// of localized UI.
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        return f
    }()

    static func stamp(_ date: Date) -> String {
        "Report produced on \(stampFormatter.string(from: date))"
    }

    func add(_ section: PDFTableSection, geometry: PDFPageGeometry) {
        pending.append((.table(section), geometry))
    }

    /// Adds an already-resolved sheet, whichever shape it turned out to be.
    func add(_ sheet: PDFSheet, geometry: PDFPageGeometry) {
        pending.append((sheet, geometry))
    }

    /// How many rows a table is measured between suspensions. Two hundred rows is a few
    /// thousand `boundingRect`s — tens of milliseconds — which is short enough that the
    /// run loop is never starved and long enough that the yields themselves cost nothing
    /// measurable.
    static let measureStride = 200

    /// Renders every collected sheet and closes the document.
    ///
    /// - Parameter progress: called on the MainActor with 0…1 as the document advances —
    ///   through the measuring pass first (every sheet must be measured before the first
    ///   page can be drawn, because page one's footer names the document total), then
    ///   through the pages as each is finished. See `progressShare`.
    /// - Returns: the document's total page count.
    ///
    /// # Why this is async and throwing
    ///
    /// This is where a library-sized export spends nearly all of its time — a few hundred
    /// pages of a few hundred cells each — and it used to spend it in one synchronous call.
    /// The exporter yielded between BUILDING its sections and then handed everything to
    /// this method, which drew every page of every section before returning. Several
    /// seconds without a turn of the run loop: a progress bar stuck at ninety percent, a
    /// Cancel button that could not be pressed, and the system's spinning cursor. The
    /// sheets now suspend between pages (and, while measuring, every `measureStride` rows),
    /// which is what puts the run loop back in charge. Cancellation is honored at the same
    /// points, so a cancel lands within a page rather than after the last one; the caller
    /// is responsible for removing the partial file, exactly as before.
    ///
    /// The context is NOT closed when a cancellation or an error is thrown: closing would
    /// finalize a truncated document onto disk with nothing in the error saying so, and the
    /// caller's cleanup deletes the file either way.
    @discardableResult
    func finish(progress: ((Double) -> Void)? = nil) async throws -> Int {
        // Laid out once, up front: the document total appears in the footer of the FIRST
        // page, so it has to be known before anything is drawn. The layout is CARRIED into
        // the draw rather than thrown away — measuring is the expensive part of rendering,
        // and re-deriving it would lay every sheet in the document out twice.
        var layouts: [PDFSheet.Layout] = []
        layouts.reserveCapacity(pending.count)
        for (index, entry) in pending.enumerated() {
            layouts.append(try await entry.sheet.layout(geometry: entry.geometry))
            progress?(Self.progressShare.measuring * Double(index + 1) / Double(max(1, pending.count)))
        }
        let documentTotal = max(1, layouts.reduce(0) { $0 + $1.pageCount })

        var pagesSoFar = 0
        for (entry, layout) in zip(pending, layouts) {
            let base = pagesSoFar
            try await entry.sheet.render(into: context, geometry: entry.geometry, layout: layout) {
                sectionPage, sectionTotal in
                .sectioned(sectionPage: sectionPage, sectionTotal: sectionTotal,
                           documentPage: base + sectionPage, documentTotal: documentTotal,
                           producedOn: self.producedOn)
            } afterPage: { sectionPage, _ in
                progress?(Self.progressShare.measuring
                          + (1 - Self.progressShare.measuring)
                            * Double(base + sectionPage) / Double(documentTotal))
            }
            pagesSoFar += layout.pageCount
        }

        context.closePDF()
        progress?(1)
        return documentTotal
    }

    /// How `finish` divides its progress between its two passes. Measuring is roughly a
    /// fifth of the wall time on a library-sized document and drawing the rest, so the bar
    /// moves at about the rate the work is actually done.
    static let progressShare = (measuring: 0.2, drawing: 0.8)
}

// MARK: - Sheet

/// One unit of a document: either a single table or a stack of them.
///
/// The builder needs exactly two things from whatever it was handed — how many pages it
/// takes, and how to draw it — so the two shapes meet behind this rather than the builder
/// branching on which array an entry came from.
@MainActor
enum PDFSheet {
    case table(PDFTableSection)
    case stack(PDFSectionStack)

    /// What a sheet costs and what it measured, so a caller that needs the page count
    /// before drawing does not pay for the layout twice. A table carries its row heights
    /// forward; a stack lays itself out from its tiles and only its page count survives.
    struct Layout {
        var pageCount: Int
        var sectionMetrics: PDFSectionMetrics?
    }

    /// Lays the sheet out, suspending periodically — see
    /// `PDFTableRenderer.metrics(of:geometry:yieldingEvery:)`. A stack is a page or two of
    /// small tiles and is measured in one go.
    func layout(geometry: PDFPageGeometry) async throws -> Layout {
        switch self {
        case let .table(section):
            let metrics = try await PDFTableRenderer.metrics(
                of: section, geometry: geometry, yieldingEvery: PDFDocumentBuilder.measureStride)
            return Layout(pageCount: metrics.pageCount, sectionMetrics: metrics)
        case let .stack(stack):
            return Layout(pageCount: PDFTableRenderer.pageCount(of: stack, geometry: geometry),
                          sectionMetrics: nil)
        }
    }

    /// Draws the sheet, suspending after every page — see `PDFTableRenderer.render`.
    /// `afterPage` is told each page's position within this sheet as it is finished.
    func render(into context: CGContext,
                geometry: PDFPageGeometry,
                layout: Layout? = nil,
                footer: (_ sectionPage: Int, _ sectionTotal: Int) -> PDFFooter,
                afterPage: ((_ sectionPage: Int, _ sectionTotal: Int) -> Void)? = nil)
    async throws {
        switch self {
        case let .table(section):
            try await PDFTableRenderer.render(section, into: context, geometry: geometry,
                                              metrics: layout?.sectionMetrics, footer: footer,
                                              afterPage: afterPage)
        case let .stack(stack):
            // A stack is a page or two; it is drawn in one go and reported as such.
            PDFTableRenderer.render(stack, into: context, geometry: geometry,
                                    pageCount: layout?.pageCount, footer: footer)
            let pages = layout?.pageCount ?? PDFTableRenderer.pageCount(of: stack, geometry: geometry)
            afterPage?(pages, pages)
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

// MARK: - Section Stack

/// A page of pre-drawn blocks stacked one under another — the Data Visualizations sheet,
/// whose sections are drawn by the tab's own canvas nodes (see `ReportsPDFExporter`).
struct PDFSectionStack {
    /// The heading printed at the top of every page, beside the brand mark.
    var title: String
    /// Vertical space between blocks.
    var gutter: CGFloat
    /// The content, one block under another, each scaled to the content width — see
    /// `PDFDrawnBlock`.
    var blocks: [PDFDrawnBlock]
    /// Filled behind each page's run of `blocks` as one rounded panel, the way the
    /// on-screen page they were drawn from sits on its window's background. Nil for none.
    var blockBackdrop: NSColor?

    init(title: String, gutter: CGFloat = 12,
         blocks: [PDFDrawnBlock] = [], blockBackdrop: NSColor? = nil) {
        self.title = title
        self.gutter = gutter
        self.blocks = blocks
        self.blockBackdrop = blockBackdrop
    }
}

/// A unit of vector content the stack does not lay out itself — the Data Visualizations
/// page's own sections, drawn by its canvas nodes (see `ReportsPDFExporter`). The stack only needs
/// its size to place it and a way to draw it; it never looks inside.
///
/// A block is never split across pages. One that would overrun the page it starts on
/// moves to the next; one taller than a whole page is scaled down further to fit one.
struct PDFDrawnBlock {
    /// The block's natural size, in its own points, before it is scaled onto the page.
    var size: CGSize
    /// Draws the block at its natural size into a context whose origin is the block's
    /// bottom-left corner, y up.
    var draw: @MainActor (CGContext) -> Void
}

extension PDFTableRenderer {
    // MARK: Stack rendering

    /// Draws `stack`, paginating as needed.
    ///
    /// - Parameter pageCount: the stack's page total, when the caller already knows it.
    ///   The footer has to name a total the drawing pass will actually reach, so absent
    ///   this the stack is laid out twice — once to count, once to draw. A caller that has
    ///   already counted (the document builder always has, to reach its own document-wide
    ///   total) passes that count in and the measuring pass is skipped entirely.
    static func render(
        _ stack: PDFSectionStack,
        into context: CGContext,
        geometry: PDFPageGeometry,
        pageCount: Int? = nil,
        footer: (_ sectionPage: Int, _ sectionTotal: Int) -> PDFFooter
    ) {
        // Measuring, when it is needed, is the SAME layout routine run with drawing off —
        // not a separate estimator, which would be a second implementation of the layout
        // free to disagree with it.
        let total = pageCount ?? layOut(stack, into: nil, geometry: geometry, draw: false,
                                        totalPages: 1, footer: footer)
        layOut(stack, into: context, geometry: geometry, draw: true, totalPages: total,
               footer: footer)
    }

    /// How many pages `stack` occupies, without drawing.
    static func pageCount(of stack: PDFSectionStack, geometry: PDFPageGeometry) -> Int {
        layOut(stack, into: nil, geometry: geometry, draw: false, totalPages: 1) { _, _ in
            .single(page: 1, total: 1)
        }
    }

    /// The single layout routine, run either to measure or to draw.
    ///
    /// - Returns: the number of pages the stack occupies.
    @discardableResult
    private static func layOut(
        _ stack: PDFSectionStack,
        into context: CGContext?,
        geometry: PDFPageGeometry,
        draw: Bool,
        totalPages: Int,
        footer: (_ sectionPage: Int, _ sectionTotal: Int) -> PDFFooter
    ) -> Int {

        let contentTop = geometry.margin + geometry.titleHeight
        let contentBottom = geometry.pageSize.height - geometry.margin - geometry.footerReserve

        // A drawing pass needs the AppKit text context pointed at the CGContext, and
        // re-pointed after every beginPDFPage. A measuring pass touches neither — which is
        // also why the restore below is conditional: a measuring pass must not clobber a
        // current context it never set.
        let nsContext = (draw && context != nil)
            ? NSGraphicsContext(cgContext: context!, flipped: false) : nil
        // Process-wide state. Restored on the way out so the next unrelated AppKit draw is
        // not left aimed at a PDF context this document has already finished with.
        let priorContext = NSGraphicsContext.current
        defer { if nsContext != nil { NSGraphicsContext.current = priorContext } }

        var page = 1

        func startPage() {
            guard draw, let context else { return }
            beginPage(context, geometry: geometry)
            NSGraphicsContext.current = nsContext
            drawPageHeading(stack.title, context: context, geometry: geometry)
        }

        func endPage() {
            guard draw, let context else { return }
            drawFooter(footer(page, totalPages), context: context, geometry: geometry)
            context.endPDFPage()
        }

        startPage()
        var y = contentTop

        // MARK: The drawn blocks, one under another
        //
        // Placed now and drawn when their page is finished, so the backdrop — which spans
        // every block on the page — goes down before any of them.
        let inset: CGFloat = stack.blockBackdrop == nil ? 0 : 8
        let blockWidth = geometry.contentWidth - inset * 2
        var placed: [(block: PDFDrawnBlock, rect: CGRect, scale: CGFloat)] = []

        func drawPlacedBlocks() {
            defer { placed.removeAll() }
            guard draw, let context, let first = placed.first, let last = placed.last else { return }
            let pageHeight = geometry.pageSize.height
            if let backdrop = stack.blockBackdrop {
                let top = first.rect.minY - inset, bottom = last.rect.maxY + inset
                let panel = CGRect(x: geometry.margin, y: pageHeight - bottom,
                                   width: geometry.contentWidth, height: bottom - top)
                context.saveGState()
                context.setFillColor(backdrop.cgColor)
                context.addPath(CGPath.continuousRoundedRect(panel, cornerRadius: 6))
                context.fillPath()
                context.restoreGState()
            }
            for entry in placed {
                context.saveGState()
                context.translateBy(x: entry.rect.minX, y: pageHeight - entry.rect.maxY)
                context.scaleBy(x: entry.scale, y: entry.scale)
                entry.block.draw(context)
                context.restoreGState()
            }
        }

        let blockRoom = contentBottom - contentTop - inset * 2
        for block in stack.blocks where block.size.width > 0 && block.size.height > 0 {
            var scale = blockWidth / block.size.width
            if block.size.height * scale > blockRoom { scale = blockRoom / block.size.height }
            let size = CGSize(width: block.size.width * scale, height: block.size.height * scale)

            // The first block on a page sits `inset` inside the top of the backdrop panel.
            let top = placed.isEmpty ? y + inset : y
            if top + size.height + inset > contentBottom, !(placed.isEmpty && y == contentTop) {
                drawPlacedBlocks()
                endPage(); page += 1
                startPage(); y = contentTop
            }
            let blockTop = placed.isEmpty ? y + inset : y
            // Centered: only a block scaled down to fit a page is narrower than the column.
            let x = geometry.margin + inset + (blockWidth - size.width) / 2
            placed.append((block, CGRect(x: x, y: blockTop, width: size.width, height: size.height), scale))
            y = blockTop + size.height + stack.gutter
        }
        drawPlacedBlocks()

        endPage()
        return page
    }
}
