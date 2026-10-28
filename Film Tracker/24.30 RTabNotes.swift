// MARK: - RTabNotes.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Displays film notes in the right sidebar's "Notes" tab.

import SwiftUI
import AppKit

struct RTabNotes: View {
    @Environment(\.sidebarFilm) private var film: FilmSnapshot?

    var body: some View {
        SidebarScrollView {
            VStack(alignment: .leading, spacing: 0) {
                notesContent
            }
            .padding(.horizontal, 16)
        }
    }
    
    // MARK: - Notes Content
    
    @ViewBuilder
    private var notesContent: some View {
        if let film = film {
            VStack(alignment: .leading, spacing: RSBHelpers.sectionSpacing) {
                RSBHelpers.textSection(
                    title: "Release", value: film.releaseUsed)
                RSBHelpers.textSectionList(
                    title: RSBHelpers.pluralizedTitle("Software Tool", "Software Tools", count: film.tools.count),
                    values: film.tools)
                // Two-column section: "HandBrake RF Value" and "Edit Date".
                HStack(spacing: 12) {
                    RSBHelpers.textSection(
                        title: "HandBrake RF Value",
                        value: RSBHelpers.formatNumericalValue(film.editedHBRFValue))
                    editDateSection(editDateString: film.editDate)
                }
                
                repeatedTextSection("Warning", plural: "Warnings", values: film.warning)

                RSBHelpers.textSection(
                    title: "Description", value: film.descriptionNotes)

                repeatedTextSection("Notes On Audio Timing", values: film.notesOnAudioTiming)
                repeatedTextSection("Special Audio Note", plural: "Special Audio Notes",
                                    values: film.specialAudioNotes, showsWhenEmpty: false)
                repeatedTextSection("Note", plural: "Notes", values: film.notesArray)

                if !RSBProfileFlags.noNotesFrames {
                    framesSection(title: "HandBrake Frames", values: film.handbrakeFrames)
                    // Only this table gets the aligned range layout. Its values are
                    // time codes, which are uniform in character count and therefore
                    // ragged only because the face is proportional — exactly what
                    // the sub-columns correct. Frame numbers vary in length for real
                    // reasons, so pinning them to fixed sub-columns would impose a
                    // regularity the data does not have.
                    framesSection(title: "Associated Time Codes",
                                  values: film.correspondingTimecodes,
                                  alignsRanges: true)
                }
                
                // Legend — shown only when at least one entry in either table actually
                // carries one of the glyphs it explains, not merely when a table is
                // non-empty. A list of plain frame numbers displays no marks and no fade
                // indicators, so a key to those symbols has nothing to key.
                if FramesEntryParser.containsLegendGlyphs(film.handbrakeFrames)
                    || FramesEntryParser.containsLegendGlyphs(film.correspondingTimecodes) {
                    legendSection
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Custom Sections

    /// One text section per value, titled only on the first, so a field holding several
    /// entries reads as one titled list. The title is `plural` when given and there is
    /// more than one value, otherwise `singular`. With no values it is a single
    /// "None provided" section under `singular`, or nothing when `showsWhenEmpty` is false.
    @ViewBuilder
    private func repeatedTextSection(_ singular: String, plural: String? = nil,
                                     values: [String], showsWhenEmpty: Bool = true) -> some View {
        if values.isEmpty {
            if showsWhenEmpty {
                RSBHelpers.textSection(title: singular, value: "")
            }
        } else {
            let title = plural.map { RSBHelpers.pluralizedTitle(singular, $0, count: values.count) } ?? singular
            ForEach(values.indices, id: \.self) { index in
                RSBHelpers.textSection(title: index == 0 ? title : "", value: values[index])
            }
        }
    }
    
    /// Renders the Edit Date section from the stored String value in FilmSnapshot.
    /// FilmSnapshot.editDate is a "yyyy-MM-dd" string (empty string = no date set),
    /// matching the format used by FSTabNotes when saving.
    @ViewBuilder
    private func editDateSection(editDateString: String) -> some View {
        let formattedDate = formatDateString(editDateString)
        let isPlaceholder = (formattedDate == "Unknown date") || editDateString.isEmpty
        let displayValue = isPlaceholder ? "None provided" : formattedDate

        RSBHelpers.textSection(
            title: "Edit Date",
            displayValue: displayValue,
            isPlaceholder: isPlaceholder
        )
    }
    
    // MARK: - Frames Section Display
    
    @ViewBuilder
    private func framesSection(title: String,
                               values: [String],
                               alignsRanges: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: RSBHelpers.headerRowSpacing) {
            RSBHelpers.sectionHeader(title)
            
            // Content
            if values.isEmpty {
                Text("None provided")
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .font(.system(size: RSBHelpers.rowFontSize))
                    .textSelection(.disabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .sidebarRowContainer()
            } else {
                Group {
                    if RSBProfileFlags.swiftUIFramesRows {
                        VStack(alignment: .leading, spacing: FrameEntryRow.spacing) {
                            ForEach(values.indices, id: \.self) { index in
                                FrameEntryRow(index: index + 1,
                                              entry: values[index],
                                              alignsRanges: alignsRanges)
                            }
                        }
                    } else {
                        FramesRowList(entries: values, alignsRanges: alignsRanges)
                    }
                }
                .sidebarRowContainer()
            }
        }
    }
    
    // MARK: - Legend Section Display
    
    @ViewBuilder
    private var legendSection: some View {
        VStack(alignment: .leading, spacing: RSBHelpers.headerRowSpacing) {
            RSBHelpers.sectionHeader("Legend")
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                legendRow(glyph: "asterisk", text: "See notes")
                legendRow(glyph: "chevron.up", text: "See notes")
                legendRow(glyph: "number", text: "See notes")
                legendRow(glyph: "arrow.up.right.circle.fill", text: "Audio fade-in for this section")
                legendRow(glyph: "arrow.down.right.circle.fill", text: "Audio fade-out for this section")
                
                Text("Final Cut Pro audio fade effects:")
                    .font(.system(size: RSBHelpers.rowFontSize))
                    .padding(.top, 8)
                
                legendRow(glyph: "line.diagonal", text: "Linear")
                legendRow(glyph: "point.bottomleft.forward.to.point.topright.scurvepath", text: "S-curve")
                legendRow(glyph: "wave.3.up", text: "+3dB")
                legendRow(glyph: "wave.3.down", text: "-3dB")
            }
            .sidebarRowContainer()
        }
    }
    
    @ViewBuilder
    private func legendRow(glyph: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: glyph)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 17, alignment: .leading)
            Text(text)
                .font(.system(size: RSBHelpers.rowFontSize))
        }
    }
}

// MARK: - Frames Entry Row

/// One row of the Notes tab's two frames tables: the index, the value, and the mark and fade
/// indicators. The tab draws its rows with FramesRowList (below); this is the SwiftUI row it
/// replaced, kept for `-FTRSBSwiftUIFramesRows` and as the reference `rsb-frames-parity`
/// compares FramesRowList against.
struct FrameEntryRow: View {
    /// The gap between rows.
    static let spacing: CGFloat = 4

    let index: Int
    let entry: String
    var alignsRanges: Bool = false

    var body: some View {
        let parsed = FramesEntryParser.parse(entry)
        
        HStack(spacing: 8) {
            // Index number
            // Index number.
            //
            // Zero-padded and tinted to match the sheet's `ReorderableFramesList`
            // exactly: the two surfaces show the same rows of the same arrays, so
            // an index that reads one way while editing and another way in the
            // sidebar is a difference with nothing behind it. Padding also fills
            // the tens place on rows 1 through 9, which is what keeps the
            // trailing-aligned column reading as a column of numerals rather than
            // as one that starts ragged and squares up at row 10.
            //
            // `%02d` is a minimum width, not a cap, so an index that somehow ran
            // to three digits would widen rather than truncate.
            Text("\(Fmt.padded(index, 2)).")
                .font(.system(size: RSBHelpers.rowFontSize, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
            
            // Frame value.
            //
            // The aligned variant draws the same string; it only distributes it
            // across three fixed sub-columns, and falls back to the plain run
            // for any value it cannot measure as a time-code range — so the two
            // branches agree on what a non-range entry looks like. Font, line
            // limit, and truncation are set inside that view, which needs the
            // point size to derive its widths; `.textSelection` is an
            // environment modifier and reaches its `Text`s either way.
            Group {
                if alignsRanges {
                    TimeCodeRangeText(text: parsed.text, fontSize: RSBHelpers.rowFontSize)
                } else {
                    Text(parsed.text)
                        .font(.system(size: RSBHelpers.rowFontSize))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Indicators
            HStack(spacing: 5) {
                // Mark indicator (11pt wide)
                Group {
                    if parsed.mark != .none {
                        Image(systemName: parsed.mark.symbolName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 11, height: 11)
                
                // Fade-in indicator (27pt wide total: 11pt arrow + 2pt spacing + 14pt glyph)
                HStack(spacing: 2) {
                    Group {
                        if parsed.fadeIn != .none {
                            Image(systemName: "arrow.up.right.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 11, height: 11)
                    
                    Group {
                        if parsed.fadeIn != .none {
                            fadeGlyphForStyle(parsed.fadeIn)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 14, height: 11)
                }
                .frame(width: 27)
                
                // Fade-out indicator (27pt wide total: 11pt arrow + 2pt spacing + 14pt glyph)
                HStack(spacing: 2) {
                    Group {
                        if parsed.fadeOut != .none {
                            Image(systemName: "arrow.down.right.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 11, height: 11)
                    
                    Group {
                        if parsed.fadeOut != .none {
                            fadeGlyphForStyle(parsed.fadeOut)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 14, height: 11)
                }
                .frame(width: 27)
            }
            .frame(width: 75) // Total: 11 + 5 + 27 + 5 + 27
        }
    }
    
    private func fadeGlyphForStyle(_ style: AudioFadeStyle) -> some View {
        Image(systemName: style.glyph)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Frames Row List
//
// The rows of one frames table, built from AppKit views rather than as a ForEach of
// FrameEntryRow: the zero-padded index, the value as a selectable label (or, for an aligned
// time-code range, three, one per sub-column), and the five indicator slots. A film change
// re-points the rows, and a longer table adds rows to a pool that a shorter one leaves
// intact. The table's container and header stay SwiftUI.
//
// `rsb-modules` measured the two tables at about 18 ms of the tab's median 29 ms (Debug),
// growing by about 1.5 ms a row, to 155 ms for a film with 84 entries. `rsb-frames-parity`
// compares these rows with FrameEntryRow pixel for pixel, light and dark.
struct FramesRowList: NSViewRepresentable {
    let entries: [String]
    var alignsRanges: Bool = false

    func makeNSView(context: Context) -> FramesRowListView { FramesRowListView() }

    func updateNSView(_ view: FramesRowListView, context: Context) {
        view.update(entries: entries, alignsRanges: alignsRanges)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FramesRowListView,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.bounds.width, height: nsView.totalHeight)
    }
}

/// FramesRowList's AppKit side: the row pool, laid out top to bottom.
final class FramesRowListView: NSView {
    private var rows: [FramesRowView] = []
    private var count = 0
    /// What the rows were last configured from: parsing and aligning every entry is the costly
    /// part, and the tab updates this view for many changes that leave the table as it was.
    private var configured: (entries: [String], alignsRanges: Bool)?

    override var isFlipped: Bool { true }

    var totalHeight: CGFloat {
        count == 0 ? 0 : CGFloat(count) * FramesRowView.height + CGFloat(count - 1) * FrameEntryRow.spacing
    }

    func update(entries: [String], alignsRanges: Bool) {
        if let configured, configured.entries == entries, configured.alignsRanges == alignsRanges { return }
        configured = (entries, alignsRanges)
        while rows.count < entries.count {
            let row = FramesRowView()
            rows.append(row)
            addSubview(row)
        }
        for (i, row) in rows.enumerated() {
            row.isHidden = i >= entries.count
            guard i < entries.count else { continue }
            row.configure(index: i + 1, entry: entries[i], alignsRanges: alignsRanges)
        }
        if count != entries.count {
            count = entries.count
            invalidateIntrinsicContentSize()
        }
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: totalHeight) }

    /// The rows round to the window's pixels, so a display of another scale needs them placed again.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        for row in rows { row.needsLayout = true }
    }

    override func layout() {
        super.layout()
        for (i, row) in rows.prefix(count).enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(i) * (FramesRowView.height + FrameEntryRow.spacing),
                               width: bounds.width, height: FramesRowView.height)
        }
    }
}

/// One frames row. Every measure is FrameEntryRow's: an HStack of the 24 pt index column, the
/// flexible value column and the 75 pt indicator column, 8 pt apart, centered vertically.
final class FramesRowView: NSView {
    private static let fontSize = RSBHelpers.rowFontSize
    private static let valueFont = NSFont.systemFont(ofSize: fontSize)
    private static let indexFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        let field = NSTextField(labelWithString: "Xg")
        field.font = font
        return field.intrinsicContentSize.height
    }
    private static let valueHeight = lineHeight(valueFont)
    private static let indexHeight = lineHeight(indexFont)

    /// The tallest of the HStack's three columns.
    static let height: CGFloat = max(valueHeight, indexHeight, glyphBox)

    private static let indexWidth: CGFloat = 24
    private static let gap: CGFloat = 8
    private static let indicatorsWidth: CGFloat = 75
    private static let glyphBox: CGFloat = 11

    private let indexLabel = NSTextField(labelWithString: "")
    /// The plain value, or the leading half of an aligned range.
    private let valueLabel = NSTextField(labelWithString: "")
    /// The dash and trailing half of an aligned range, and the five indicator glyphs (mark,
    /// fade-in arrow, fade-in style, fade-out arrow, fade-out style), are made the first time
    /// a row needs them: most rows show a plain value and no indicators, and a frames table
    /// can run to eighty rows, all made at once when a tab is built.
    private var dashLabel: NSTextField?
    private var trailingLabel: NSTextField?
    private var glyphs: [FramesGlyphView?] = Array(repeating: nil, count: 5)

    private var halves: (leading: String, trailing: String)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        indexLabel.font = Self.indexFont
        indexLabel.textColor = .tertiaryLabelColor
        addSubview(indexLabel)
        addValueLabel(valueLabel)
    }

    private func addValueLabel(_ label: NSTextField) {
        label.font = Self.valueFont
        label.textColor = .labelColor
        label.isSelectable = true
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
    }

    private func makeValueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        addValueLabel(label)
        return label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(index: Int, entry: String, alignsRanges: Bool) {
        let parsed = FramesEntryParser.parse(entry)
        set(indexLabel, "\(Fmt.padded(index, 2)).")
        halves = alignsRanges
            ? TimeCodeRangeText.alignedHalves(of: parsed.text, fontSize: Self.fontSize,
                                              within: TimeCodeRangeText.metrics(fontSize: Self.fontSize))
            : nil
        set(valueLabel, halves?.leading ?? parsed.text)
        if let halves {
            let dash = dashLabel ?? makeValueLabel()
            let trailing = trailingLabel ?? makeValueLabel()
            dashLabel = dash
            trailingLabel = trailing
            set(dash, TimeCodeRangeText.dashGlyph)
            set(trailing, halves.trailing)
        }
        dashLabel?.isHidden = halves == nil
        trailingLabel?.isHidden = halves == nil
        let names: [String?] = [
            parsed.mark != .none ? parsed.mark.symbolName : nil,
            parsed.fadeIn != .none ? "arrow.up.right.circle.fill" : nil,
            parsed.fadeIn != .none ? parsed.fadeIn.glyph : nil,
            parsed.fadeOut != .none ? "arrow.down.right.circle.fill" : nil,
            parsed.fadeOut != .none ? parsed.fadeOut.glyph : nil]
        for (i, name) in names.enumerated() {
            guard let name else {
                glyphs[i]?.isHidden = true
                continue
            }
            let glyph = glyphs[i] ?? {
                let glyph = FramesGlyphView()
                glyph.clipsToBounds = false
                addSubview(glyph)
                glyphs[i] = glyph
                return glyph
            }()
            glyph.isHidden = false
            glyph.symbolName = name
        }
        needsLayout = true
    }

    private func set(_ label: NSTextField, _ text: String) {
        if label.stringValue != text { label.stringValue = text }
    }

    override func layout() {
        super.layout()
        let b = bounds
        let scale = unsafe window?.backingScaleFactor ?? 2
        func pixel(_ v: CGFloat) -> CGFloat { (v * scale).rounded(.toNearestOrAwayFromZero) / scale }
        func centeredY(_ h: CGFloat) -> CGFloat { pixel((b.height - h) / 2) }

        // Index: trailing in its 24 pt column.
        let indexWidth = indexLabel.intrinsicContentSize.width
        indexLabel.frame = NSRect(x: pixel(Self.indexWidth - indexWidth) - 2, y: centeredY(Self.indexHeight),
                                  width: indexWidth + 4, height: Self.indexHeight)

        // Value column. A selectable label is a text field 2 pt wider on each side than its
        // text (see CrewRowView).
        let valueX = Self.indexWidth + Self.gap
        let valueWidth = max(0, b.width - valueX - Self.gap - Self.indicatorsWidth)
        let y = centeredY(Self.valueHeight), h = Self.valueHeight
        func place(_ label: NSTextField, x: CGFloat, width: CGFloat, align: CGFloat) {
            let textWidth = min(label.intrinsicContentSize.width, width)
            label.frame = NSRect(x: x + pixel((width - textWidth) * align) - 2, y: y, width: textWidth + 4, height: h)
        }
        if halves != nil, let dashLabel, let trailingLabel {
            let metrics = TimeCodeRangeText.metrics(fontSize: Self.fontSize)
            place(valueLabel, x: valueX, width: metrics.half, align: 0)
            place(dashLabel, x: valueX + metrics.half, width: metrics.dash, align: 0.5)
            place(trailingLabel, x: valueX + metrics.half + metrics.dash, width: metrics.half, align: 1)
        } else {
            place(valueLabel, x: valueX, width: valueWidth, align: 0)
        }

        // Indicators: 11 (mark), 5, 11 + 2 + 14 (fade in), 5, 11 + 2 + 14 (fade out).
        let indicatorsX = b.width - Self.indicatorsWidth
        let slots: [(CGFloat, CGFloat)] = [(0, 11), (16, 11), (29, 14), (48, 11), (61, 14)]
        for (glyph, slot) in zip(glyphs, slots) {
            glyph?.frame = NSRect(x: indicatorsX + slot.0, y: centeredY(Self.glyphBox), width: slot.1, height: Self.glyphBox)
        }
    }
}

/// One indicator glyph, placed as SwiftUI places `Image(systemName:)` at an 11 pt font in its
/// 11 pt-tall slot: horizontally by the alignment rectangle's width, vertically by the
/// symbol's own vector bounds (which is neither the image's height nor its alignment
/// rectangle's), each centered in the slot and rounded to the device pixel with a half
/// rounding up. Found with `rsb-frames-parity`, against all nine indicator symbols: its view
/// tree shows the vertical bounds (SwiftUI draws each symbol in a view that size), and its
/// captures the horizontal rule. CrewGlyphView's rule differs, and is right for its symbols.
class FramesGlyphView: NSView {
    var symbolName: String? { didSet { if symbolName != oldValue { needsDisplay = true } } }
    /// The font the symbol is drawn at, as `.font(.system(size:weight:))` sets it on an Image.
    /// The frames tables use the default; the Releases tab's AppKit cards set their own.
    var pointSize: CGFloat = 11 { didSet { if pointSize != oldValue { needsDisplay = true } } }
    var weight: NSFont.Weight = .regular { didSet { if weight != oldValue { needsDisplay = true } } }
    var tint: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    /// Centers the symbol's vector bounds horizontally too, as SwiftUI does for an Image
    /// centered in a ZStack (the release cards' checkmark badge), rather than its alignment
    /// rectangle, as it does in a frame (the frames tables).
    var centersVectorBoundsHorizontally = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    private struct Symbol {
        let image: NSImage
        /// The symbol's vector bounds within `image`, top-left origin, in points.
        let bounds: CGRect
    }
    private struct Key: Hashable { let name: String; let pointSize: CGFloat; let weight: CGFloat }
    @MainActor private static var cache: [Key: Symbol] = [:]

    @MainActor private static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> Symbol? {
        let key = Key(name: name, pointSize: pointSize, weight: weight.rawValue)
        if let cached = cache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        // The vector bounds, from an 8x raster's coverage, rounded out to the half point.
        let scale: CGFloat = 8
        let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
        guard let context = unsafe CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let cg = unsafe image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = unsafe context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where unsafe data[y * w + x] > 64 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        // Rows are top-down in the context's memory.
        func down(_ v: Int) -> CGFloat { (CGFloat(v) / scale * 2).rounded(.down) / 2 }
        func up(_ v: Int) -> CGFloat { (CGFloat(v) / scale * 2).rounded(.up) / 2 }
        let bounds = CGRect(x: down(minX), y: down(minY), width: up(maxX + 1) - down(minX), height: up(maxY + 1) - down(minY))
        let symbol = Symbol(image: image, bounds: bounds)
        cache[key] = symbol
        return symbol
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let symbolName, let symbol = Self.symbol(symbolName, pointSize: pointSize, weight: weight) else { return }
        let scale = unsafe window?.backingScaleFactor ?? 2
        func pixel(_ v: CGFloat) -> CGFloat { (v * scale + 0.5).rounded(.down) / scale }
        let b = symbol.bounds
        let align = symbol.image.alignmentRect
        let x = centersVectorBoundsHorizontally
            ? pixel((bounds.width - b.width) / 2) - b.minX
            : pixel((bounds.width - align.width) / 2) - align.minX
        let origin = CGPoint(x: x, y: pixel((bounds.height - b.height) / 2) - b.minY)
        let rect = NSRect(origin: origin, size: symbol.image.size)
        // Replace the black with the tint, keeping its coverage, in an image of its own: a .sourceIn fill
        // on the view's backing, at a rect off the pixel grid, could leave a dark seam in the glyph.
        let image = symbol.image, tint = tint
        let tinted = NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            tint.set()
            r.fill(using: .sourceIn)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
