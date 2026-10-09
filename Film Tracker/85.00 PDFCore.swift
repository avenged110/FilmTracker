// MARK: - PDFCore.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Shared, content-agnostic PDF machinery: page geometry, fonts, the cell fill palette,
// and the low-level drawing primitives every PDF report in the app is built from.
//
// This file knows nothing about films, releases, or reports. It is the bottom layer of a
// three-file stack:
//
//     88.00 PDFCore.swift            ← geometry, fonts, colors, drawing primitives
//     88.10 PDFTableRenderer.swift   ← paginated table layout built on those primitives
//     88.20 LibraryPDFReport.swift   ← the complete-library table's content and rules
//
// Both PDF-producing features draw from this stack: the per-tab report sheets in
// ReportExporter.swift (27.50) and the whole-library export in PDFExporter.swift
// (43.10), which assembles those sheets after the library table. Anything either of them
// would otherwise restate belongs here.

import AppKit
import Foundation

// MARK: - PDF Export Error

/// The failure modes a PDF export raises.
///
/// Lives here rather than beside the exporter so any future PDF-producing feature raises
/// the same set, and a caller catching them does not have to know which one it came from.
/// Write failures are NOT among them: the file is produced by a CoreGraphics PDF context,
/// which reports nothing back — `pdfCreationFailed` covers the one point where a failure
/// to open the destination is actually visible.
enum PDFExportError: LocalizedError {
    case noDataToExport
    case pdfCreationFailed

    var errorDescription: String? {
        switch self {
        case .noDataToExport:
            return "No data available to export"
        case .pdfCreationFailed:
            return "Failed to create PDF document"
        }
    }
}

// MARK: - Page Geometry

/// Every measurement that governs how a page is laid out, in one value.
///
/// These were once `private static let`s on `ReportsPDFExporter`, which pinned every
/// report in the app to a single portrait page at a single font size. Passing the set
/// around as a value is what lets the complete-library table use a LANDSCAPE page (it has
/// sixteen columns; portrait cannot hold them legibly) inside the same document as the
/// report sections that follow it.
///
/// A PDF document may mix page sizes freely as long as each page declares its own media
/// box — see `PDFTableRenderer.beginPage`, which does exactly that from this struct.
struct PDFPageGeometry: Sendable {
    /// The page's media box, in points (72 points to the inch).
    var pageSize: CGSize
    /// Uniform page margin. Content is laid out inside `pageSize` inset by this.
    var margin: CGFloat
    /// Body text size for table cells.
    var fontSize: CGFloat
    /// Text size for column header cells.
    var headerFontSize: CGFloat
    /// Text size for the section title printed at the top of every page.
    var titleFontSize: CGFloat
    /// Text size for the "Page N of M" footer.
    var footerFontSize: CGFloat
    /// The floor on a data row's height. Rows with wrapping text grow past it.
    var minRowHeight: CGFloat
    /// The height of ONE header row. A section with grouped columns draws two of these.
    var headerRowHeight: CGFloat
    /// Vertical space reserved for the section title band.
    var titleHeight: CGFloat
    /// Vertical space reserved at the foot of the page for the page-number footer.
    var footerReserve: CGFloat
    /// Line spacing used for wrapped cell text.
    var lineSpacing: CGFloat
    /// Horizontal inset applied to a cell's text rect, per side.
    var cellPaddingX: CGFloat
    /// Vertical inset applied to a cell's text rect, per side.
    var cellPaddingY: CGFloat
    /// The blank channel between the panes of a MULTI-COLUMN section — see
    /// `PDFTableSection.columnsPerPage`. Unused by a single-pane section, which is why it
    /// carries a default and the presets below do not restate it.
    ///
    /// Wide enough that the two tables read as two, narrow enough that it costs less than
    /// the whitespace the split recovers. At the landscape geometry this is 14 points
    /// against a 720-point content width — under two percent, for roughly double the rows
    /// per page.
    var paneGutter: CGFloat = 14

    /// The horizontal space available to columns.
    var contentWidth: CGFloat { pageSize.width - (margin * 2) }

    // MARK: Presets

    /// US Letter portrait. No export draws on it today (every sheet goes into the landscape
    /// library document); the PDF harness renders a portrait probe on it to prove the
    /// renderer's per-page media box handles mixed orientations.
    static let portraitLetter = PDFPageGeometry(
        pageSize: CGSize(width: 612, height: 792), // 8.5" x 11" at 72 DPI
        margin: 54,                                // 0.75"
        fontSize: 6,
        headerFontSize: 6,
        titleFontSize: 9,
        footerFontSize: 6,
        minRowHeight: 10,
        headerRowHeight: 10,
        titleHeight: 12,
        footerReserve: 30,
        lineSpacing: 1.2,
        cellPaddingX: 4,
        cellPaddingY: 1
    )

    /// US Letter landscape with tighter margins — the complete-library table's geometry.
    /// The wider page buys the sixteen columns room; the 0.5" margin buys another 72 points
    /// on top of that.
    ///
    /// The body font is deliberately SMALL. This table's job is density: it carries every
    /// film in the library across sixteen columns, and two points of type traded away buys
    /// roughly a third of the page's width back for the columns that actually wrap.
    static let landscapeLetter = PDFPageGeometry(
        pageSize: CGSize(width: 792, height: 612), // 11" x 8.5" at 72 DPI
        margin: 36,                                // 0.5"
        fontSize: 5,
        headerFontSize: 4.5,
        titleFontSize: 8,
        footerFontSize: 4,
        minRowHeight: 8,
        headerRowHeight: 8,
        titleHeight: 12,
        footerReserve: 30,
        lineSpacing: 1.2,
        cellPaddingX: 3,
        cellPaddingY: 1
    )
}

// MARK: - Shared Column Widths

/// Column widths that must AGREE across sections, expressed once.
///
/// Every table in the library PDF writes its column widths as points against its own
/// content width and arranges for them to sum to exactly it — see `PDFTableColumn.width`,
/// which normalizes the set before drawing. That convention is what makes a bare point
/// value here mean the same on-page width in every section that uses it, and it is a
/// convention each section has to keep: a set that does not sum to its own width scales,
/// and a shared constant inside it stops being shared.
enum PDFColumnWidth {
    /// The leading index column, in every section that numbers its films.
    ///
    /// Sized against four fixed-width digits — a library that reaches four figures must not
    /// wrap its own index, and a wrapped index grows the height of every row it lands on.
    /// The three per-film sections all number the same films, so a reader moving between
    /// them meets the same column at the same width in the same place; three separately
    /// tuned values would have made that a coincidence.
    static let index: CGFloat = 19
}

// MARK: - Fonts

/// The font vendor for every PDF drawing site.
///
/// `NSFont` lookup is not free and the drawing loop asks for the same handful of faces
/// once per cell, so results are memoized. The cache is keyed by (size, weight) because
/// geometry is now a value: two sections in one document legitimately ask for the same
/// weight at different sizes.
@MainActor
enum PDFFonts {
    /// Preferred face, with a system-font fallback. SF Pro Text is requested by PostScript
    /// name so the PDF embeds the same face the app draws with on screen.
    static func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        resolve(CacheKey(size: size, weight: weight, monospaced: false))
    }

    /// The italic counterpart of a resolved face, AT THE SAME WEIGHT.
    ///
    /// Weight is the whole difficulty here. The obvious route —
    /// `fontDescriptor.withSymbolicTraits(.italic)` — REPLACES the descriptor's symbolic
    /// traits rather than adding to them, and weight above bold is not a symbolic trait at
    /// all: asked for an italic SFProText-Semibold that way, the matcher returns
    /// SFProText-RegularItalic. The italicized run then reads a whole weight lighter than
    /// the sentence around it, which looks like a rendering bug rather than emphasis.
    ///
    /// `NSFontManager.convert(_:toHaveTrait:)` adds the trait to the font's existing
    /// description instead of rebuilding it, and returns SFProText-SemiboldItalic — the
    /// same weight, italicized. It returns the font unchanged when no such face exists,
    /// which is also the fallback this wants: a family with no italic keeps the upright
    /// face rather than getting a synthesized oblique, which at five points is noticeably
    /// worse than no italic at all and no less legible.
    ///
    /// Memoized on the same grounds as everything else here — the draw loop asks per run.
    static func italic(of font: NSFont) -> NSFont {
        if let cached = italics[font] { return cached }
        let resolved = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        italics[font] = resolved
        return resolved
    }

    private static var italics: [NSFont: NSFont] = [:]

    /// The fixed-width face, for columns of pure numerals.
    ///
    /// Proportional digits make a column of numbers ragged — the same count of digits
    /// occupies a different width on every row, so the eye cannot use column position to
    /// compare magnitudes. At this table's type size that is the difference between a
    /// scannable index and a smear.
    static func monospacedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        resolve(CacheKey(size: size, weight: weight, monospaced: true))
    }

    private static func resolve(_ key: CacheKey) -> NSFont {
        if let cached = cache[key] { return cached }

        let resolved: NSFont
        if key.monospaced {
            resolved = NSFont.monospacedSystemFont(ofSize: key.size, weight: key.weight)
        } else {
            resolved = NSFont(name: "SFProText-\(weightName(key.weight))", size: key.size)
                ?? NSFont.systemFont(ofSize: key.size, weight: key.weight)
        }
        cache[key] = resolved
        return resolved
    }

    private struct CacheKey: Hashable {
        let size: CGFloat
        let weight: NSFont.Weight
        let monospaced: Bool
    }

    private static var cache: [CacheKey: NSFont] = [:]

    private static func weightName(_ weight: NSFont.Weight) -> String {
        if weight == .bold { return "Bold" }
        if weight == .semibold { return "Semibold" }
        if weight == .medium { return "Medium" }
        return "Regular"
    }
}

// MARK: - Paragraph Styles

/// Cached paragraph styles, one per (alignment, lineSpacing) pair.
///
/// `NSMutableParagraphStyle` init is not free and a paragraph style is needed for every
/// cell drawn and every cell measured, so the small set actually in use is memoized.
@MainActor
enum PDFParagraphStyles {
    static func style(alignment: NSTextAlignment,
                      lineSpacing: CGFloat,
                      lineBreak: NSLineBreakMode = .byWordWrapping) -> NSParagraphStyle {
        let key = CacheKey(alignment: alignment, lineSpacing: lineSpacing, lineBreak: lineBreak)
        if let cached = cache[key] { return cached }

        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = lineBreak
        style.lineSpacing = lineSpacing
        cache[key] = style
        return style
    }

    /// The style used when MEASURING text. Alignment cannot change a bounding height, so
    /// measurement deliberately does not vary by it — one style serves every column.
    static func measurementStyle(lineSpacing: CGFloat) -> NSParagraphStyle {
        style(alignment: .natural, lineSpacing: lineSpacing)
    }

    private struct CacheKey: Hashable {
        let alignment: NSTextAlignment
        let lineSpacing: CGFloat
        let lineBreak: NSLineBreakMode
    }

    private static var cache: [CacheKey: NSParagraphStyle] = [:]
}

// MARK: - Cell Fill Palette

/// The canonical cell-fill colors, and the one opacity every fill is drawn at.
///
/// # Why one place
///
/// The complete-library table asks for the same conceptual color from several different
/// columns — "green" means the same green whether it is a Blu-ray digital source, a
/// purchased Blu-ray, an affirmative subtitles cell, or a non-object-based audio track.
/// Naming each shade once here is what makes that true; a column that reached for its own
/// `NSColor(...)` would drift the moment either site was tweaked.
///
/// The ONE deliberate exception is the aspect-ratio column, whose four "very dark" shades
/// are its own family and are used nowhere else. They live here anyway, under their own
/// heading, because the alternative is a color literal buried in a switch.
///
/// # Why the opacity
///
/// Fills exist to make a column scannable at a glance, not to be read for their own sake.
/// Every fill is composited at `fillAlpha` over white, which keeps the hues distinct from
/// one another while leaving black body text at full contrast on top of them. Tweak the
/// one constant to restyle every cell in the document.
@MainActor
enum PDFPalette {
    /// The opacity every fill below is drawn at. The single knob for "more/less vibrant".
    ///
    /// Raised from 0.38 once the tables had been seen on paper: at this type size the fills
    /// were deferring to the text more than they needed to, and a tenth more opacity
    /// separates the shades from one another without touching the contrast of the black
    /// text sitting on them.
    static let fillAlpha: CGFloat = 0.42

    // MARK: Shared shades

    /// The affirmative green. Blu-ray source, purchased Blu-ray, subtitles present,
    /// a non-object-based audio configuration on a purchased disc.
    static let green = NSColor(calibratedRed: 0.16, green: 0.68, blue: 0.29, alpha: 1)

    /// The paler, grayer green that qualifies an affirmative state rather than negating it:
    /// a REMASTERED Blu-ray, and an OBJECT-BASED audio configuration.
    static let paleGreen = NSColor(calibratedRed: 0.52, green: 0.71, blue: 0.55, alpha: 1)

    /// The darker green reserved for a high-quality DOWNLOAD source (720p / 1080p).
    static let darkGreen = NSColor(calibratedRed: 0.09, green: 0.40, blue: 0.19, alpha: 1)

    /// The negative fill: unpurchased, absent, or a source below the quality bar.
    static let red = NSColor(calibratedRed: 0.85, green: 0.20, blue: 0.18, alpha: 1)

    /// The neutral fill: DVD-tier purchases, and black-and-white chroma.
    static let lightGray = NSColor(calibratedWhite: 0.70, alpha: 1)

    /// A purchased NATIVE 4K release.
    static let lightBlue = NSColor(calibratedRed: 0.33, green: 0.66, blue: 0.92, alpha: 1)

    /// A purchased UPSCALED 4K release.
    static let purple = NSColor(calibratedRed: 0.57, green: 0.34, blue: 0.80, alpha: 1)

    /// Subtitles that exist only on the disc.
    static let darkGold = NSColor(calibratedRed: 0.68, green: 0.50, blue: 0.04, alpha: 1)

    /// Color (as opposed to black-and-white) chroma.
    static let seafoam = NSColor(calibratedRed: 0.38, green: 0.85, blue: 0.71, alpha: 1)

    /// A film carrying a custom edit. Its own shade — an edit is neither a quality
    /// judgment nor a purchase state, so it borrows from neither family.
    static let brown = NSColor(calibratedRed: 0.52, green: 0.34, blue: 0.16, alpha: 1)

    // MARK: Aspect-ratio shades
    // The one column whose fills are its own family. Four bands, deliberately darker than
    // the shared shades so the column reads as a distinct axis rather than as more of the
    // same purchase/quality signaling to its left.

    /// Narrower than 1.60:1.
    static let veryDarkGold = NSColor(calibratedRed: 0.45, green: 0.33, blue: 0.02, alpha: 1)
    /// 1.60:1 up to (but not including) 2.00:1.
    static let veryDarkGreen = NSColor(calibratedRed: 0.05, green: 0.27, blue: 0.12, alpha: 1)
    /// 2.00:1 and wider.
    static let veryDarkBlue = NSColor(calibratedRed: 0.06, green: 0.20, blue: 0.45, alpha: 1)
    /// The "Hybrid" tag, which has no single ratio to band.
    static let veryDarkPurple = NSColor(calibratedRed: 0.30, green: 0.13, blue: 0.45, alpha: 1)

    // MARK: Inverted fill

    /// The one shade meant to be drawn OPAQUE, with white text on it — the 4K UHD format
    /// badge in the Disc-based Releases section.
    ///
    /// Every other entry above is a wash: composited at `fillAlpha` so black body text
    /// reads through it. This one is the opposite, and deliberately so — it marks the top
    /// of a three-format hierarchy, and an inverted cell is the only thing on these pages
    /// that reads as a rank rather than as a category. It is dark enough that white text
    /// on it clears the contrast bar with room to spare, which a washed fill cannot be:
    /// at `fillAlpha` over white, no color is darker than roughly 58% luminance.
    ///
    /// Callers must pass it through `PDFDrawing.fillOpaque` (or `PDFCell.fillIsOpaque`).
    /// Handing it to `fillCell` would wash it to a mid gray and leave the white text on it
    /// unreadable.
    static let veryDarkGray = NSColor(calibratedWhite: 0.20, alpha: 1)

    /// Body text drawn ON an opaque fill.
    static let invertedText = NSColor.white

    // MARK: Batch hues
    //
    // A cycle of distinct hues for banding a ranked list into groups — the Hall of Fame's
    // position column, which colors each block of twenty-five. These are NOT semantic: a
    // reader is meant to see "this is a different block from the one above", not to read
    // any meaning into which color a block got. That is why they are their own set rather
    // than reuse of the shades above, every one of which does carry a meaning.

    /// The hue cycle, in the order blocks consume it. Eight entries against blocks of
    /// twenty-five covers the two hundred positions the Hall of Fame holds without a color
    /// repeating.
    ///
    /// The order is deliberately NOT spectral. Walking the rainbow puts neighboring blocks
    /// on neighboring hues, which is the one arrangement where two adjacent blocks are hard
    /// to tell apart — exactly what the banding exists to prevent. This sequence steps
    /// across the wheel instead, so no block sits beside its own neighbor.
    static let bandHues: [NSColor] = [
        NSColor(calibratedRed: 0.26, green: 0.55, blue: 0.88, alpha: 1), // blue
        NSColor(calibratedRed: 0.90, green: 0.55, blue: 0.16, alpha: 1), // orange
        NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.84, alpha: 1), // violet
        NSColor(calibratedRed: 0.30, green: 0.72, blue: 0.33, alpha: 1), // green
        NSColor(calibratedRed: 0.85, green: 0.40, blue: 0.66, alpha: 1), // magenta
        NSColor(calibratedRed: 0.85, green: 0.78, blue: 0.20, alpha: 1), // yellow
        NSColor(calibratedRed: 0.24, green: 0.74, blue: 0.70, alpha: 1), // teal
        NSColor(calibratedRed: 0.85, green: 0.26, blue: 0.24, alpha: 1), // red
    ]

    /// The hue for a block index, wrapping if a list ever outgrows the cycle.
    static func bandHue(_ block: Int) -> NSColor {
        bandHues[((block % bandHues.count) + bandHues.count) % bandHues.count]
    }

    // MARK: Table chrome
    // Not cell fills — these are drawn at full opacity and are not subject to `fillAlpha`.

    /// A qualified warning: a region-locked disc that this library's hardware cannot play
    /// without qualification. Light enough to stay a wash under black text, and warm enough
    /// to catch the eye in a column of otherwise unfilled cells.
    static let lightOrange = NSColor(calibratedRed: 0.95, green: 0.64, blue: 0.28, alpha: 1)

    // MARK: Text

    /// Text that is present but subordinate — a figure or a date that describes something
    /// the user does not own, or money reported on another row.
    ///
    /// A de-emphasized value is NOT the same as an absent one: the placeholder dash says a
    /// field was never filled in, while this says the field is filled in and secondary. Gray
    /// rather than a smaller size, because a column of mixed type sizes is harder to scan
    /// than a column of mixed weights.
    static let secondaryText = NSColor(calibratedWhite: 0.45, alpha: 1)

    /// The background behind a column header cell.
    static let headerBackground = NSColor(calibratedWhite: 0.95, alpha: 1)
    /// Every cell border in every table.
    static let border = NSColor(calibratedWhite: 0.70, alpha: 1)

    /// The rule across the top of a FILM's band in the per-film sections — black, so the
    /// boundary between one film and the next is the strongest line on the page.
    static let filmRule = NSColor.black

    /// The rule across the top of each RELEASE within a film — as far from both the film
    /// rule and the ordinary cell border as one gray can be, so the three read as three
    /// distinct weights: film, then release, then everything else.
    ///
    /// Perceptually, not arithmetically, between them. Black and the 0.70 border are
    /// 0.35 apart on the gray scale, but the eye is far more sensitive to the dark end, and
    /// the midpoint (0.35) reads as nearly black at half a point wide. 0.45 is where it
    /// stops looking like a lighter black and starts looking like a darker gray.
    static let releaseRule = NSColor(calibratedWhite: 0.45, alpha: 1)
    /// Body text.
    static let text = NSColor.black
    /// The page-number footer.
    static let footerText = NSColor.darkGray
}

// MARK: - Text Decoration

/// A run inside a cell's text that is drawn in its own color.
///
/// Exists because a cell is one string but not always one statement: the complete-library
/// table's Notes column is a comma-joined list of derived facts, and one of them — an
/// unplayable disc — matters more than the rest of the sentence it sits in. Coloring the
/// whole cell would claim that everything in it is urgent; coloring the phrase says which
/// part is.
///
/// Matching is case-insensitive, because the list convention lowercases an item's initial
/// wherever it does not lead (see `PDFNoteList`), so the phrase a caller asks for is not
/// necessarily the casing the cell ended up with. EVERY occurrence is colored — a rule that
/// needs no tie-break and cannot depend on where in the list an item happened to land.
struct PDFTextHighlight {
    let text: String
    /// The run's color, or `nil` to leave it in the cell's own.
    let color: NSColor?
    /// Draw the run in the italic face of whatever font the cell is using.
    ///
    /// For a run that is a NAME rather than a statement — a studio inside a note about
    /// which copies were bought. Italics say "this is a proper noun, not part of the
    /// sentence" without spending a color, which in this document already means something
    /// else. See `PDFFonts.italic(of:)` for what happens when no italic face exists.
    let italic: Bool

    init(_ text: String, color: NSColor? = nil, italic: Bool = false) {
        self.text = text
        self.color = color
        self.italic = italic
    }
}

/// Two values and the relation between them, laid out on the relation.
///
/// A cost and the price actually paid are one comparison, and the comparison is only
/// readable if the eye can make it without re-reading: the separator is pinned to the
/// center of the cell and each value is centered in its own half, so the figures line up
/// column-wise down the page and the slash forms an unbroken vertical rule between them.
/// Written as one run — "$34.99 / $29.99" — the pair drifts left and right with the width
/// of the figures and the comparison has to be found before it can be made.
///
/// `plain` is the same content as a single string. It is what the cell reports for
/// measurement and for PDF text extraction, so a paired cell is still searchable and still
/// sizes like the text it draws.
struct PDFPairedText {
    var leading: String
    var separator: String
    var trailing: String

    init(_ leading: String, separator: String = "/", _ trailing: String) {
        self.leading = leading
        self.separator = separator
        self.trailing = trailing
    }

    var plain: String { "\(leading) \(separator) \(trailing)" }
}

// MARK: - Drawing Primitives

/// The low-level draw and measure calls shared by every table renderer.
///
/// Every method assumes `NSGraphicsContext.current` has already been pointed at `context`
/// — which `PDFTableRenderer` does once per page, because `CGContext.beginPDFPage`
/// establishes a fresh graphics state that would otherwise leave the AppKit text drawing
/// path aimed at whatever was current before.
@MainActor
enum PDFDrawing {
    /// Fills `rect` with `color` at the palette's shared opacity.
    ///
    /// Takes the alpha from the palette rather than from the color so a caller cannot
    /// accidentally hand in an opaque swatch and black out its own text.
    static func fillCell(_ rect: CGRect,
                         color: NSColor,
                         opaque: Bool = false,
                         context: CGContext) {
        fill(rect, color: color, alpha: opaque ? nil : PDFPalette.fillAlpha, context: context)
    }

    /// Fills `rect` with `color` at that color's OWN alpha — for table chrome (header
    /// bands), which is not a data fill and must not be washed out by `fillAlpha`.
    static func fillOpaque(_ rect: CGRect, color: NSColor, context: CGContext) {
        fill(rect, color: color, alpha: nil, context: context)
    }

    /// The one fill. `alpha` of `nil` means the color's own — see `fillOpaque`.
    ///
    /// The sRGB conversion is what the component-wise `setFillColor` needs, and a color
    /// with no sRGB representation is skipped rather than drawn wrong.
    private static func fill(_ rect: CGRect,
                             color: NSColor,
                             alpha: CGFloat?,
                             context: CGContext) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        context.saveGState()
        context.setFillColor(red: rgb.redComponent,
                             green: rgb.greenComponent,
                             blue: rgb.blueComponent,
                             alpha: alpha ?? rgb.alphaComponent)
        context.fill(rect)
        context.restoreGState()
    }

    /// Strokes `rect`'s border with the shared table border color.
    static func strokeBorder(_ rect: CGRect, context: CGContext, lineWidth: CGFloat = 0.5) {
        withBorderStroke(context: context, lineWidth: lineWidth) { $0.stroke(rect) }
    }

    /// Strokes only SOME of `rect`'s edges, for a cell that continues into the row below
    /// (or above) it rather than closing against it.
    ///
    /// A column of cells that all omit their horizontal edges reads as one tall,
    /// uninterrupted cell — which is the point: it says "everything between these two rules
    /// belongs to the same thing" without the renderer needing a merged-cell concept, and
    /// without the block having to fit on one page the way a real merged cell would.
    static func strokeEdges(_ rect: CGRect,
                            edges: PDFCellBorders,
                            color: NSColor = PDFPalette.border,
                            context: CGContext,
                            lineWidth: CGFloat = 0.5) {
        guard !edges.isEmpty else { return }
        // The complete set in the shared color is the overwhelmingly common case and is
        // drawn as a rectangle rather than as four segments — identical output, a quarter
        // of the path work, and byte-for-byte the same as every table produced before this
        // existed.
        if edges == .all && color == PDFPalette.border {
            return strokeBorder(rect, context: context, lineWidth: lineWidth)
        }

        withBorderStroke(color: color, context: context, lineWidth: lineWidth) { ctx in
            var segments: [(CGPoint, CGPoint)] = []
            if edges.contains(.top) {
                segments.append((CGPoint(x: rect.minX, y: rect.maxY),
                                 CGPoint(x: rect.maxX, y: rect.maxY)))
            }
            if edges.contains(.bottom) {
                segments.append((CGPoint(x: rect.minX, y: rect.minY),
                                 CGPoint(x: rect.maxX, y: rect.minY)))
            }
            if edges.contains(.left) {
                segments.append((CGPoint(x: rect.minX, y: rect.minY),
                                 CGPoint(x: rect.minX, y: rect.maxY)))
            }
            if edges.contains(.right) {
                segments.append((CGPoint(x: rect.maxX, y: rect.minY),
                                 CGPoint(x: rect.maxX, y: rect.maxY)))
            }
            for (from, to) in segments {
                ctx.move(to: from)
                ctx.addLine(to: to)
            }
            ctx.strokePath()
        }
    }

    /// Runs `draw` with the shared border color and width installed, and the graphics state
    /// restored afterwards.
    private static func withBorderStroke(color: NSColor = PDFPalette.border,
                                         context: CGContext,
                                         lineWidth: CGFloat,
                                         _ draw: (CGContext) -> Void) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        context.saveGState()
        context.setStrokeColor(red: rgb.redComponent,
                               green: rgb.greenComponent,
                               blue: rgb.blueComponent,
                               alpha: rgb.alphaComponent)
        context.setLineWidth(lineWidth)
        draw(context)
        context.restoreGState()
    }

    /// Draws `text` inside `rect`, wrapping at word boundaries.
    ///
    /// The graphics state is saved and restored around the draw so any clip or fill
    /// established by the surrounding cell chrome survives it.
    static func drawText(
        _ text: String,
        in rect: CGRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment,
        lineSpacing: CGFloat,
        lineBreak: NSLineBreakMode = .byWordWrapping,
        highlights: [PDFTextHighlight] = [],
        context: CGContext
    ) {
        guard !text.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: PDFParagraphStyles.style(alignment: alignment,
                                                      lineSpacing: lineSpacing,
                                                      lineBreak: lineBreak)
        ]

        let attributed = NSMutableAttributedString(string: text, attributes: attributes)
        for highlight in highlights {
            for range in ranges(of: highlight.text, in: text) {
                if let color = highlight.color {
                    attributed.addAttribute(.foregroundColor, value: color, range: range)
                }
                if highlight.italic {
                    attributed.addAttribute(.font, value: PDFFonts.italic(of: font), range: range)
                }
            }
        }

        context.saveGState()
        attributed.draw(in: rect)
        context.restoreGState()
    }

    /// Every case-insensitive occurrence of `needle` in `haystack`, as `NSRange`s.
    ///
    /// Searched over the whole string rather than stopping at the first hit — see
    /// `PDFTextHighlight`. An empty needle matches nothing, which is what stops a caller
    /// that built its phrase from an empty field from coloring the entire cell.
    private static func ranges(of needle: String, in haystack: String) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        let text = haystack as NSString
        var found: [NSRange] = []
        var searched = NSRange(location: 0, length: text.length)
        while searched.length > 0 {
            let hit = text.range(of: needle, options: .caseInsensitive, range: searched)
            guard hit.location != NSNotFound else { break }
            found.append(hit)
            let next = hit.location + max(1, hit.length)
            guard next < text.length else { break }
            searched = NSRange(location: next, length: text.length - next)
        }
        return found
    }

    /// Draws a `PDFPairedText`: the separator centered in `rect`, and each value centered in
    /// its own half of it. See `PDFPairedText` for why.
    ///
    /// The three runs are drawn independently and may in principle collide, which happens
    /// only when a value is wider than half the cell — at which point a single-run layout
    /// would have overflowed too. The column is sized for the widest pair it can hold.
    static func drawPaired(
        _ pair: PDFPairedText,
        in rect: CGRect,
        font: NSFont,
        color: NSColor,
        lineSpacing: CGFloat,
        context: CGContext
    ) {
        let half = rect.width / 2
        let left = CGRect(x: rect.minX, y: rect.minY, width: half, height: rect.height)
        let right = CGRect(x: rect.midX, y: rect.minY, width: half, height: rect.height)

        drawText(pair.leading, in: left, font: font, color: color, alignment: .center,
                 lineSpacing: lineSpacing, lineBreak: .byClipping, context: context)
        drawText(pair.trailing, in: right, font: font, color: color, alignment: .center,
                 lineSpacing: lineSpacing, lineBreak: .byClipping, context: context)
        drawText(pair.separator, in: rect, font: font, color: color, alignment: .center,
                 lineSpacing: lineSpacing, lineBreak: .byClipping, context: context)
    }

    /// Draws `image` to fill `rect`, preserving its aspect ratio and centering it.
    static func drawImage(_ image: NSImage, in rect: CGRect, context: CGContext) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }

        let scale = min(rect.width / size.width, rect.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let target = CGRect(x: rect.midX - drawn.width / 2,
                            y: rect.midY - drawn.height / 2,
                            width: drawn.width,
                            height: drawn.height)

        context.saveGState()
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        context.restoreGState()
    }

    /// The height `text` needs when wrapped to `width`.
    ///
    /// Used by the pre-pass that sizes every row before any drawing happens, so that a
    /// page break is decided against the row's real height and the "Page N of M" footer
    /// can be correct on the first page.
    static func textHeight(
        _ text: String,
        width: CGFloat,
        font: NSFont,
        lineSpacing: CGFloat
    ) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: PDFParagraphStyles.measurementStyle(lineSpacing: lineSpacing)
        ]
        let bounds = NSAttributedString(string: text, attributes: attributes).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(bounds.height)
    }

    /// The width ONE line of `text` occupies, unwrapped.
    ///
    /// Used where a caller must reserve exact horizontal room for a fixed label — the
    /// "Film Tracker" wordmark beside the brand-mark icon — rather than measuring a column
    /// that is free to wrap.
    static func singleLineWidth(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let bounds = NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(bounds.width)
    }

    /// The height ONE line of `text` occupies, whatever its width.
    ///
    /// For cells that truncate rather than wrap: their height is a property of the font,
    /// not of the string, and measuring them against the column width would report the
    /// several lines they would have needed had they been allowed to wrap.
    static func singleLineHeight(
        _ text: String,
        font: NSFont,
        lineSpacing: CGFloat
    ) -> CGFloat {
        textHeight(text, width: .greatestFiniteMagnitude, font: font, lineSpacing: lineSpacing)
    }
}

// MARK: - Brand Mark

/// The application icon, as it appears in the corner of every exported page.
///
/// Read from the running application rather than from an asset name so the mark is always
/// whatever the app is actually shipping — there is no second copy to fall out of step when
/// the icon changes.
///
/// Resolved once and cached: `applicationIconImage` is cheap, but it is asked for on every
/// page of every section, and a nil result should be decided once rather than re-tested a
/// hundred times. `nil` is a normal outcome (a process with no icon), and every caller
/// simply draws no mark.
@MainActor
enum PDFBrandMark {
    static let image: NSImage? = NSApplication.shared.applicationIconImage

    /// The mark's square footprint on a page: the LEADING half of the banner block, with
    /// the wordmark to its right and the pair together right-aligned to the page margin, so
    /// the two read as one banner across the top beside the section title.
    ///
    /// The `+ 10` matches the same nudge the title's own text rect carries — without it the
    /// mark hangs a title's height below the words it is supposed to sit beside.
    static func rect(in geometry: PDFPageGeometry) -> CGRect {
        let side = geometry.titleHeight
        // The banner is right-aligned to the page margin and the icon is its LEADING half,
        // so the icon's left edge is the margin less the whole banner's span. Derived from
        // `reservedWidth` rather than re-adding its terms, so the two cannot drift.
        return CGRect(x: geometry.pageSize.width - geometry.margin - reservedWidth(in: geometry),
                      y: geometry.pageSize.height - geometry.margin - geometry.titleHeight + 10,
                      width: side,
                      height: side)
    }

    // MARK: Wordmark

    /// The app name printed immediately to the right of the icon, so the banner reads
    /// "[icon] Film Tracker" rather than the icon standing unlabeled.
    static let wordmark = "Film Tracker"

    /// The gap left between the icon's right edge and the wordmark's text.
    static let wordmarkPadding: CGFloat = 1.5

    /// The wordmark's font: a few points smaller than the section title, so the two read as
    /// a heading and a subordinate label rather than as two titles competing for attention.
    static func wordmarkFont(in geometry: PDFPageGeometry) -> NSFont {
        PDFFonts.font(size: max(1, geometry.titleFontSize - 2), weight: .semibold)
    }

    /// The wordmark's own single-line width, memoized per title size.
    ///
    /// The string never changes, but `drawPageHeading` asks for it three times on every
    /// page of every section — once to place the icon, once to reserve room for the title,
    /// and once to frame the text — and each ask was a fresh `boundingRect` over the same
    /// constant. Keyed by the geometry's title size because that is the only input the
    /// font resolves from.
    private static var wordmarkWidths: [CGFloat: CGFloat] = [:]

    private static func wordmarkWidth(in geometry: PDFPageGeometry) -> CGFloat {
        if let cached = wordmarkWidths[geometry.titleFontSize] { return cached }
        let measured = PDFDrawing.singleLineWidth(wordmark, font: wordmarkFont(in: geometry))
        wordmarkWidths[geometry.titleFontSize] = measured
        return measured
    }

    /// The total horizontal room the wordmark + padding + icon occupy, right-aligned to the
    /// page margin. The section title's available width must stop short of this exact span,
    /// or a long title would run underneath the wordmark instead of clipping before it.
    static func reservedWidth(in geometry: PDFPageGeometry) -> CGFloat {
        wordmarkWidth(in: geometry) + wordmarkPadding + geometry.titleHeight
    }

    /// The wordmark's frame: vertically centered on the ICON's own square (not the header
    /// row, and not the title's baseline), sitting `wordmarkPadding` to its right.
    static func wordmarkRect(in geometry: PDFPageGeometry) -> CGRect {
        let font = wordmarkFont(in: geometry)
        let textWidth = wordmarkWidth(in: geometry)
        let textHeight = PDFDrawing.singleLineHeight(wordmark, font: font, lineSpacing: geometry.lineSpacing)
        let iconRect = rect(in: geometry)
        return CGRect(
            x: iconRect.maxX + wordmarkPadding,
            y: iconRect.midY - textHeight / 2,
            width: textWidth,
            height: textHeight
        )
    }
}

// MARK: - Note Lists

/// The comma-separated list convention every Notes column in the app's PDFs prints in:
/// the first item's initial capitalized, every later item's lowercased, joined with ", ".
///
/// Two sections build such a list — the complete-library table's Notes column and the Hall
/// of Fame's — and their whole point is that the two read alike. The rule lived once in
/// each file, which made "alike" a comment rather than a fact.
///
/// An item may opt OUT of the case transform when its text is a proper noun or a brand —
/// "Steelbook", a studio name, an authored note — where re-casing would be wrong wherever
/// it lands.
///
/// Pure string work with no state, so unlike the rest of this file it is not actor-bound.
enum PDFNoteList {
    struct Item {
        let text: String
        let preservesCase: Bool

        init(_ text: String, preservesCase: Bool = false) {
            self.text = text
            self.preservesCase = preservesCase
        }
    }

    static func joined(_ items: [Item]) -> String {
        items.enumerated().map { position, item -> String in
            guard !item.preservesCase, let first = item.text.first else { return item.text }
            let rest = item.text.dropFirst()
            return position == 0
                ? String(first).uppercased() + rest
                : String(first).lowercased() + rest
        }
        .joined(separator: ", ")
    }
}

// MARK: - Cell Text

/// Cell text the report's tables share. The complete-library table and the film-detail
/// sections each carried their own copy of the placeholder and the abbreviated-date
/// formatter, with a comment asking the second to match the first; one definition makes
/// that a fact.
@MainActor
enum PDFCellText {
    /// The stand-in for a field with nothing in it, where a blank cell would read as an
    /// omission rather than as an answer. An EN dash, not a hyphen: it is punctuation
    /// standing for a missing value, not a minus sign or a word break.
    static let placeholder = "\u{2013}"

    /// A stored date as "Nov 23, 2024", or `placeholder` when it is blank or unparseable.
    ///
    /// Parsing goes through `parseDate(from:)` in GlobalUtilities — the app's one date
    /// reader — so a stored value carrying a viewing-version code ("2026.01.24.TH") is
    /// handled here exactly as it is everywhere else.
    static func abbreviatedDate(_ stored: String) -> String {
        guard let date = parseDate(from: stored) else { return placeholder }
        return abbreviatedDateFormatter.string(from: date)
    }

    /// Pinned to en_US_POSIX so the abbreviated month is always the English one the
    /// columns are sized for, regardless of the user's locale.
    private static let abbreviatedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
}

// MARK: - Filename Helpers

/// Shared filename construction for exported PDFs, so two exporters cannot disagree about
/// what a safe name or a sortable timestamp looks like.
@MainActor
enum PDFFilename {
    /// Locale- and time-zone-pinned so "yyyy-MM-dd_HHmmss" is always a Gregorian stamp,
    /// which is what keeps a folder of exports sorting chronologically by name.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    /// `<sanitized base>_<timestamp>.pdf`.
    static func timestamped(base: String, date: Date = Date()) -> String {
        "\(sanitize(base))_\(timestampFormatter.string(from: date)).pdf"
    }

    /// Replaces every character that is invalid in a filename with an underscore.
    static func sanitize(_ name: String) -> String {
        let invalid: Set<Character> = [":", "/", "\\", "?", "%", "*", "|", "\"", "<", ">"]
        return String(name.map { invalid.contains($0) ? "_" : $0 })
    }
}
