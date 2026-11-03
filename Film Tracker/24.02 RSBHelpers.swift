// MARK: - RSBHelpers.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Generic UI-forming components and formatting helpers for the right sidebar's modules. Also contains
// QueryHandoff, which normalizes film titles and opens external web queries, and the "Releases Tab:
// Shared Derivations" section. That section is the single definition of what the Releases summary
// table (24.21) and release cards (24.20) say about a release.

import SwiftUI
import AppKit

// MARK: - Conditional Text Selection
extension View {
    /// Enables or disables text selection at runtime. `nonisolated` lets static builders such as
    /// `RSBHelpers.textSection` call it. SwiftUI applies the modifiers on the main actor at draw time, so
    /// building the chain needs no main-actor isolation.
    @ViewBuilder
    nonisolated func conditionalTextSelection(enabled: Bool) -> some View {
        if enabled {
            self.textSelection(.enabled)
        } else {
            self.textSelection(.disabled)
        }
    }

    /// Applies the sidebar's standard value-row chrome: full width, leading-aligned, inset by the shared
    /// padding, on the rounded `controlBackgroundColor` plate used by every value row.
    ///
    /// Every sidebar value row uses this chain, so a change to the corner radius, inset, or fill is made once.
    ///
    /// Callers with wrapping text apply `.fixedSize(horizontal: false, vertical: true)` before this modifier,
    /// so the row grows vertically to fit. The proposed width is the same either way.
    ///
    /// `nonisolated`, like `conditionalTextSelection`: SwiftUI evaluates the chain on the main actor at draw time.
    /// - Parameters:
    ///   - glyph: An SF Symbol drawn in the row's leading margin, outside the content. The content is inset by
    ///     `RSBHelpers.glyphGutterWidth`, and the symbol is overlaid into that space, centered horizontally and
    ///     aligned to the first line of text (see `RSBHelpers.singleLineRowHeight`). `nil` insets nothing and
    ///     overlays nothing. See `RSBHelpers.glyphLeadingMargin`.
    ///   - glyphColor: Tint for the symbol. Callers usually pass their content's own color, so the glyph tracks
    ///     its row, including a placeholder row's tertiary gray. (`valueRow` and `textSection` take an optional
    ///     here, where `nil` means the row's own text color.)
    ///   - trailingInset: Space between the content and the plate's trailing edge. Defaults to
    ///     `RSBHelpers.rowHorizontalPadding`, matching the leading side. A caller tightens it only to fit a value
    ///     it would otherwise wrap. The fill spans the full column either way, so this is invisible on any value
    ///     that does not reach the edge.
    ///
    /// The inset is applied here, not by callers, because a caller that measures its own content must see the
    /// reduced width. `fittingValueRow` runs a `ViewThatFits` inside this, and an inset applied outside it would
    /// not narrow the proposal its candidates are measured against.
    nonisolated func sidebarRowContainer(glyph: String? = nil,
                                         glyphColor: Color = .secondary,
                                         trailingInset: CGFloat = RSBHelpers.rowHorizontalPadding) -> some View {
        self
            .padding(.leading, glyph == nil ? 0 : RSBHelpers.glyphGutterWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, RSBHelpers.rowFontBackgroundVerticalPadding)
            .padding(.leading, RSBHelpers.rowHorizontalPadding)
            .padding(.trailing, trailingInset)
            .fieldEdgeChrome()
            .overlay(alignment: .topLeading) {
                if let glyph {
                    RSBHelpers.glyphImage(glyph)
                        .font(.system(size: RSBHelpers.glyphPointSize(for: glyph),
                                      weight: RSBHelpers.glyphWeight(for: glyph)))
                        .foregroundStyle(glyphColor)
                        // Top-aligned in a box one single-line row tall. The glyph stays where it would on a
                        // one-line row when the text wraps, instead of drifting to the center of the taller plate.
                        .frame(width: RSBHelpers.glyphBoxWidth,
                               height: RSBHelpers.singleLineRowHeight)
                        .offset(x: RSBHelpers.glyphHorizontalOffset(for: glyph))
                        .padding(.leading, RSBHelpers.glyphLeadingPadding)
                }
            }
    }
}

struct RSBHelpers {
    // Appearance parameters.
    static let sectionSpacing: CGFloat = 10
    static let headerRowSpacing: CGFloat = 4
    static let headerFontSize: CGFloat = 10
    static let rowFontSize: CGFloat = 12
    static let rowFontBackgroundVerticalPadding: CGFloat = 4
    /// The plate's horizontal inset. Named because `annotationRow`'s glyph overlay has to
    /// reproduce it to line its gutter up with the text the plate insets.
    static let rowHorizontalPadding: CGFloat = 8

    // MARK: - UI Styling and Layout
    // Single-value text section (manual header + row so spacing is controllable).
    @ViewBuilder
    static func textSection(title: String, value: String?, glyph: String? = nil,
                            glyphColor: Color? = nil,
                            rowFontSize: CGFloat = RSBHelpers.rowFontSize) -> some View {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayValue = trimmedValue.isEmpty ? "None provided" : trimmedValue
        let isPlaceholder = trimmedValue.isEmpty

        textSection(title: title, displayValue: displayValue, isPlaceholder: isPlaceholder,
                    glyph: glyph, glyphColor: glyphColor, rowFontSize: rowFontSize)
    }

    /// Overload for callers that have already resolved the display text and its placeholder status, such as
    /// "Blacklisted" or "None recorded". Those values are non-empty but still styled as placeholders. It holds
    /// the header-and-row layout shared by the section builders (WatchDetails, RTabNotes, and others).
    @ViewBuilder
    static func textSection(
        title: String,
        displayValue: String,
        isPlaceholder: Bool,
        glyph: String? = nil,
        glyphColor: Color? = nil,
        trailingInset: CGFloat = RSBHelpers.rowHorizontalPadding,
        rowFontSize: CGFloat = RSBHelpers.rowFontSize
    ) -> some View {
        VStack(alignment: .leading, spacing: headerRowSpacing) {
            sectionHeader(title)
            valueRow(displayValue,
                     isPlaceholder: isPlaceholder,
                     glyph: glyph,
                     glyphColor: glyphColor,
                     trailingInset: trailingInset,
                     rowFontSize: rowFontSize)
        }
    }

    /// The standard value row: the rounded plate a sidebar field's content sits on, without a header.
    /// `textSection` is `sectionHeader` plus this row.
    ///
    /// Private. Callers use `fittingValueRow` for a primary value and `annotationRow` for notes.
    @ViewBuilder
    private static func valueRow(
        _ displayValue: String,
        isPlaceholder: Bool,
        glyph: String? = nil,
        glyphColor: Color? = nil,
        trailingInset: CGFloat = RSBHelpers.rowHorizontalPadding,
        rowFontSize: CGFloat = RSBHelpers.rowFontSize
    ) -> some View {
        // The glyph takes the row's resolved color, so a placeholder's tertiary gray reaches the symbol
        // without callers restating the rule.
        let color: Color = isPlaceholder ? Color(nsColor: .tertiaryLabelColor) : .primary
        Text(displayValue)
            .foregroundStyle(color)
            .font(.system(size: rowFontSize))
            .conditionalTextSelection(enabled: !isPlaceholder)
            .fixedSize(horizontal: false, vertical: true)
            .sidebarRowContainer(glyph: glyph,
                                 glyphColor: glyphColor ?? color,
                                 trailingInset: trailingInset)
    }

    // MARK: - Overflow-Driven Abbreviation

    /// A value row that shortens its own text, but only when the full spelling would wrap to a second line.
    ///
    /// The measurement uses `ViewThatFits`, not a width prediction. A prediction must mirror the resolved font,
    /// the full padding chain, and CoreText's line breaking, and each is a silent coupling. Change
    /// `sidebarRowContainer`'s inset, or pass a different `rowFontSize`, and a predictor starts abbreviating
    /// strings that would have fit, or leaves strings that wrap anyway. `ViewThatFits` measures the real
    /// candidates with the real font at the real width, so it cannot drift.
    ///
    /// Three candidates, in priority order:
    ///
    ///   1. The full text on one line. Preferred whenever it fits, since abbreviating costs information.
    ///   2. The abbreviated text on one line. Used only when 1 does not fit.
    ///   3. The full text, wrapping. `ViewThatFits` falls back to its last candidate when none fits. The full
    ///      spelling is used here on purpose. Once a second line is unavoidable, the abbreviation has bought
    ///      nothing, so the more informative text wins. This also means the row never truncates.
    ///
    /// `.lineLimit(1)` on the first two candidates is required. `ViewThatFits` measures ideal size, and a `Text`
    /// free to wrap reports an ideal size that always fits, so candidate 1 would win unconditionally. For the
    /// same reason the first two must NOT carry `.fixedSize(horizontal: false, vertical: true)`, which permits
    /// vertical growth and belongs only on the wrapping fallback.
    ///
    /// `sidebarRowContainer`'s `.frame(maxWidth: .infinity)` stays OUTSIDE the `ViewThatFits`. Applied inside,
    /// every candidate would claim the full width, and the first would always win.
    ///
    /// The number of ladder steps the row can offer. It is fixed because each step must be its own
    /// `ViewThatFits` child (see the body). Seven covers every ladder in the module: `sourceValueLadder`
    /// produces at most seven (three words, every combination), and `dateValueLadder` at most three. A longer
    /// array is not consulted past the seventh, which abbreviates less than it could but never produces a
    /// wrong or wrapped row.
    ///
    /// `fittingValueRow` reads this to bound the ladder it receives. The body cannot derive it, since each candidate
    /// must be a literal child. Adding a slot therefore means bumping this constant and writing the slot, and the
    /// read keeps the two in agreement.
    static let maxAbbreviationCandidates = 7

    /// Costs one extra measurement pass per row, which is negligible since the sidebar shows one film.
    ///
    /// - Parameters:
    ///   - full: The complete text, with its own font-independent styling (color, any image attachment).
    ///     Callers build it as `Text`, so composed rows such as the source row's disc glyph plus value can
    ///     use this path too.
    ///   - abbreviations: Shortened spellings, in the order to try, each a further step from `full`. An empty
    ///     array skips `ViewThatFits` and renders exactly what `valueRow` would, so a value with nothing to
    ///     shorten costs nothing. At most `maxAbbreviationCandidates` are offered.
    ///   - glyph: An SF Symbol for the leading margin, drawn by `sidebarRowContainer`. The gutter narrows what
    ///     the candidates are measured against. That is correct, since a glyphed row has less room and should
    ///     abbreviate sooner.
    ///   - glyphColor: Tint for that symbol, normally whatever `full` is already using.
    @ViewBuilder
    static func fittingValueRow(
        full: Text,
        abbreviations: [Text],
        isPlaceholder: Bool,
        glyph: String? = nil,
        glyphColor: Color = .primary,
        rowFontSize: CGFloat = RSBHelpers.rowFontSize
    ) -> some View {
        // Bounded here, so the body and `maxAbbreviationCandidates` cannot disagree on how many steps are
        // offered. Surplus candidates are ignored, which is the documented degradation.
        let offered = Array(abbreviations.prefix(Self.maxAbbreviationCandidates))
        Group {
            if offered.isEmpty {
                full.font(.system(size: rowFontSize))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Each candidate is its own direct child of ViewThatFits, on purpose. A ForEach would be one child
                // containing many views, so ViewThatFits would accept or reject the whole ladder as one unit. Hence
                // the fixed slots, and hence `maxAbbreviationCandidates`.
                ViewThatFits(in: .horizontal) {
                    full.font(.system(size: rowFontSize)).lineLimit(1)
                    if offered.count > 0 {
                        offered[0].font(.system(size: rowFontSize)).lineLimit(1)
                    }
                    if offered.count > 1 {
                        offered[1].font(.system(size: rowFontSize)).lineLimit(1)
                    }
                    if offered.count > 2 {
                        offered[2].font(.system(size: rowFontSize)).lineLimit(1)
                    }
                    if offered.count > 3 {
                        offered[3].font(.system(size: rowFontSize)).lineLimit(1)
                    }
                    if offered.count > 4 {
                        offered[4].font(.system(size: rowFontSize)).lineLimit(1)
                    }
                    if offered.count > 5 {
                        offered[5].font(.system(size: rowFontSize)).lineLimit(1)
                    }
                    if offered.count > 6 {
                        offered[6].font(.system(size: rowFontSize)).lineLimit(1)
                    }
                    full.font(.system(size: rowFontSize))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .conditionalTextSelection(enabled: !isPlaceholder)
        .sidebarRowContainer(glyph: glyph, glyphColor: glyphColor)
    }

    /// A subordinate note about the value above it, with the same plate chrome as `valueRow`. It is always
    /// stacked directly beneath its parent row, inside the parent's section, under the parent's header.
    ///
    /// Defaults to `.secondary`, overridable for the one note that is not subordinate in
    /// emphasis — "Region B locked" describes a hard playback restriction on the disc
    /// named above it and stays `.primary`.
    ///
    /// Not italicized: on their own plate the notes are already distinct, and italics cost legibility at this size.
    ///
    /// An optional `glyph` sits in a fixed-width gutter at the leading edge, outside the text. The text is
    /// inset by the gutter's width, and the symbol is overlaid into that space.
    ///
    /// Not an inline `Text(Image(...))` attachment. An attachment is part of the text run: its width moves where
    /// the text starts, and its height can raise the line's ascent, so symbols of different sizes would give rows
    /// different text offsets and heights. The gutter avoids that. The inset is constant, so text starts in the same
    /// place whatever the glyph, and the overlay is sized by the row, so no glyph can make a row taller.
    ///
    /// The symbol is centered horizontally in the whole leading margin (from the plate's fill edge to where the
    /// text starts, `glyphLeadingMargin`). Vertically it is centered on the first line of text, so on a wrapped
    /// note it stays where a one-line note would put it. `color` tints the glyph and the text together.
    ///
    /// Centering on the whole margin, not the gutter alone, makes glyphs of different widths look placed the same.
    /// A frame centers its content regardless of that content's width, so a narrow symbol and a wide one share one
    /// center point. Insetting the overlay by the plate's padding first (as if the glyph were text) would move the
    /// center to the middle of the gutter, which is off-center for the space the glyph occupies: it crowds the text
    /// on a wide symbol and strands a narrow one.
    ///
    /// See `glyphLeadingMargin` for how the margin is sized so that centering also leaves
    /// every symbol clear of both the fill's edge and the text.
    ///
    /// A wrapped second line aligns under the first line's text, not under the glyph: a hanging indent, which these
    /// rows want.
    ///
    /// Passing `nil` applies no inset and no overlay.
    @ViewBuilder
    static func annotationRow(
        _ text: String,
        glyph: String? = nil,
        color: Color = .secondary,
        rowFontSize: CGFloat = RSBHelpers.rowFontSize
    ) -> some View {
        Text(text)
            .foregroundStyle(color)
            .font(.system(size: rowFontSize))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .sidebarRowContainer(glyph: glyph, glyphColor: color)
    }

    /// Point size for a row's glyph, a little smaller than the row's text. That leaves the symbols room inside
    /// `glyphBoxWidth`. SF Symbols quantize to whole points, so changes to this value apply in steps.
    static let glyphPointSize: CGFloat = 10.5

    /// Per-symbol point sizes for symbols the standard size does not suit. The box is sized for the widest
    /// symbol at `glyphPointSize`. Any symbol that fits `glyphBoxWidth` at its chosen size may differ, since the
    /// constraint is width, not uniform scale.
    ///
    /// `scissors` is 17pt wide at 10.5 against a 16pt box, the only symbol in use that overflows. At 9.5 it is
    /// 15pt. Shrinking it is cheaper than widening the box, which would push the text inset out on every row.
    ///
    /// The rest go the other way, up to `rowFontSize`.
    ///
    /// `opticaldisc.fill` is pinned to `rowFontSize`, which keeps the Source row's disc at its established size.
    ///
    /// The two hourglasses are a judgment call. Both are naturally narrow for their point size (10pt and 12pt at
    /// 12, against a 16pt box), so at the standard size they read smaller than their neighbors. Sizing them up
    /// restores the match. They are listed individually, not matched by prefix. A future `hourglass.*` variant
    /// should be reviewed rather than inherit this one.
    ///
    /// Every entry here is still bounded by the box: at 12pt `opticaldisc.fill` is 14pt wide,
    /// `hourglass.and.lock` 12, and `hourglass` 10 — all inside 16.
    private static let glyphPointSizeOverrides: [String: CGFloat] = [
        "scissors": 9.5,
        "eye": 9.5,
        "calendar": rowFontSize,
        "hourglass": rowFontSize,
        "hourglass.and.lock": rowFontSize,
        ContentGlyphs.disc: rowFontSize
    ]

    /// The point size a given symbol renders at: its override if it has one, else the standard.
    static func glyphPointSize(for systemName: String) -> CGFloat {
        glyphPointSizeOverrides[systemName] ?? glyphPointSize
    }

    /// Per-symbol stroke weights. `.regular` unless listed.
    ///
    /// `checkmark` and `xmark` are bare strokes, with no enclosing shape or fill. At the standard weight they
    /// carry less ink than the filled and circled symbols beside them and read as fainter. Thickening them
    /// evens out the apparent density.
    ///
    /// A weight change alters width, so entries are bounded by `glyphBoxWidth` as point sizes are. At
    /// `glyphPointSize` semibold, `checkmark` is 13pt wide and `xmark` 11, against a 16pt box.
    private static let glyphWeightOverrides: [String: Font.Weight] = [
        "questionmark": .semibold,
        "checkmark": .semibold,
        "xmark": .semibold,
        "deskclock": .semibold,
        "timer": .semibold,
        "forward.frame": .semibold
    ]

    /// Glyphs from Apple's private symbol set. `privateGlyph(_:fallback:)` returns the private name only when
    /// it resolves on this system. Access lives in `PrivateSymbol` (GlobalUtilities). This file only styles the
    /// result for the gutter.
    private static let privateGlyphNames: Set<String> = ["music.circle"]

    /// `name` when it resolves as a private symbol, else the public `fallback`.
    nonisolated static func privateGlyph(_ name: String, fallback: String) -> String {
        PrivateSymbol.exists(name) ? name : fallback
    }

    /// The gutter's image for a glyph name. A private symbol gets the gutter's point size
    /// and weight baked in, because the `.font` the gutter applies does not reach an
    /// NSImage; `PrivateSymbol` hands it back as a template, so `foregroundStyle` tints it.
    nonisolated static func glyphImage(_ name: String) -> Image {
        guard privateGlyphNames.contains(name),
              let base = PrivateSymbol.nsImage(named: name)
        else { return Image(systemName: name) }
        let config = NSImage.SymbolConfiguration(
            pointSize: glyphPointSize(for: name),
            weight: glyphWeight(for: name) == .semibold ? .semibold : .regular)
        return Image(nsImage: base.withSymbolConfiguration(config) ?? base)
    }

    /// The stroke weight a given symbol is drawn at; `.regular` for anything unlisted.
    static func glyphWeight(for systemName: String) -> Font.Weight {
        glyphWeightOverrides[systemName] ?? .regular
    }

    /// Per-symbol horizontal nudges, applied after centering. They are optical corrections. A symbol whose
    /// visual weight sits off its geometric center looks misaligned even when centered exactly, because the
    /// eye centers on mass. `cart.fill.badge.questionmark` carries its badge up and to the right, which pulls
    /// its apparent center that way, so a point to the left settles it against its neighbors. The nudge uses
    /// `.offset`, so it moves the drawn symbol without moving the box, gutter, or text. It cannot affect
    /// layout, but a large value could push a symbol outside its box, so keep it small.
    private static let glyphHorizontalOffsets: [String: CGFloat] = [
        "cart.fill.badge.questionmark": -1
    ]

    /// The horizontal nudge a given symbol is drawn with; zero for anything unlisted.
    static func glyphHorizontalOffset(for systemName: String) -> CGFloat {
        glyphHorizontalOffsets[systemName] ?? 0
    }

    /// The symbol marking Film Queue membership, wherever the sidebar shows it. WatchDetails' "In the <Section>
    /// Queue" annotation and ListTable's queue rows use the same mark. ListTable's inline attachment renders at
    /// `glyphPointSize(for:)`, the size the gutter uses. Naming the symbol once here keeps the two surfaces in
    /// step. It lives in this file because neither module owns the other, and this file is where both share
    /// their row vocabulary.
    static let queueMembershipGlyph = "text.line.first.and.arrowtriangle.forward"

    /// The fixed box every glyph is centered in, sized for the widest symbol in use at `glyphPointSize` (16pt,
    /// from `cart.fill.badge.questionmark` and the queue arrow; the rest run 9 to 15). Centering happens inside
    /// this box, not the whole margin, so the space on either side can be set separately below. A wider symbol
    /// would push its row's text, which `glyphPointSizeOverrides` prevents.
    static let glyphBoxWidth: CGFloat = 16

    /// Space between the plate's fill edge and the glyph box.
    static let glyphLeadingPadding: CGFloat = 8

    /// The height of a value row whose text fits on one line: the row font's line height plus the plate's
    /// vertical padding on both sides. The glyph overlay is boxed to this height and top-aligned, which pins it
    /// to the first line of a wrapped row. Without a height, it would center on the whole plate and drift down
    /// as the text grew.
    ///
    /// Uses `NSLayoutManager.defaultLineHeight(for:)`, not the font's raw ascender, descender, and leading sum.
    /// That is the rounded line height the text system lays out with, and it matches SwiftUI's single-line
    /// `Text` height at this size (15pt at the 12pt system size, where the raw sum is 14.13). Rows drawn at
    /// another font size do not carry a glyph.
    static let singleLineRowHeight: CGFloat =
        NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: rowFontSize))
        + rowFontBackgroundVerticalPadding * 2

    /// Space between the glyph box and the text. It is set apart from the leading padding, because a glyph
    /// reads as part of the text beside it. A little less room on that side groups the two without crowding
    /// them.
    static let glyphTrailingPadding: CGFloat = 6

    /// The distance from the plate's fill edge to the text's leading edge on a glyphed row: the leading padding,
    /// the glyph box, and the trailing padding, in that order.
    ///
    /// Derived, not set, so the three parts always compose to exactly the text's inset, and no glyph placement
    /// can disagree with where the text starts. Tune the three constants above, and this follows.
    ///
    /// Symbols of different widths still share one center, because they center within `glyphBoxWidth`. The
    /// space around that box need not be symmetrical. A symbol narrower than the box gains the difference
    /// equally on both sides.
    static var glyphLeadingMargin: CGFloat {
        glyphLeadingPadding + glyphBoxWidth + glyphTrailingPadding
    }

    /// The text's own inset on a glyphed row — the margin less the inset the plate already
    /// applies, so the two compose to exactly `glyphLeadingMargin`.
    static var glyphGutterWidth: CGFloat { glyphLeadingMargin - rowHorizontalPadding }

    /// A glyph inlined ahead of `text` as a `Text` attachment, so it participates in the
    /// text's own layout flow rather than sitting in a separate `HStack` column. When the
    /// value wraps, subsequent lines return to the text's left edge — directly beneath the
    /// glyph — instead of indenting past it.
    ///
    /// The kerned space is the separator, approximating a 5pt gap at 12pt. Returns `Text`
    /// rather than `some View` because concatenation is what makes the glyph part of the run,
    /// and because the caller composes further before rendering.
    ///
    /// The inline alternative to the gutter. ListTable is its only caller, since its glyph sits in a table cell
    /// rather than on a sidebar plate. The sidebar uses the gutter instead, since an attachment's width and height
    /// move the text and change row heights.
    /// - Parameter pointSize: Size for the attachment alone. `nil` inherits the font of the text it renders
    ///   with, which is the default for inline attachments. A size holds the glyph to a fixed scale.
    ///   `RSBHelpers.glyphPointSize(for:)` gives the scale the gutter uses for that symbol, so an inline glyph
    ///   can match its gutter twin elsewhere in the sidebar.
    ///
    ///   The size applies only to the attachment's run. The label beside it keeps its own font.
    static func glyphPrefixedText(_ systemName: String,
                                  _ text: String,
                                  pointSize: CGFloat? = nil) -> Text {
        let glyph = Text(Image(systemName: systemName))
        let sized = pointSize.map { glyph.font(.system(size: $0)) } ?? glyph
        return sized + Text(" ").kerning(2) + Text(text)
    }

    /// The title that names a whole sidebar MODULE, centered across the full content
    /// width — "Viewing History", "List Membership", "Synopsis", "Metadata",
    /// "All Releases", "Disc-based Releases".
    ///
    /// Distinct from `sectionHeader` below, which labels a single FIELD inside a module
    /// (leading-aligned, secondary, rounded). The two are different sizes of heading and
    /// deliberately stay separate builders.
    ///
    /// The font and layout are defined only here, so every module header matches.
    ///
    /// Callers apply their own surrounding spacing: the Details modules sit in stacks
    /// that already supply it, while `allReleasesHeader` adds explicit padding at its use
    /// site. Nothing about that changes here — this styles the label and nothing else.
    @ViewBuilder
    static func moduleHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// The sidebar's standard field-header label. Renders nothing for an empty title. Callers such as `Synopsis`
    /// pass `""` when the module header is enough. Shared by `textSection`, `searchableItemSection`,
    /// WatchDetails' custom rows, and RTabNotes' frames and legend blocks.
    @ViewBuilder
    static func sectionHeader(_ title: String) -> some View {
        if !title.isEmpty {
            Text(title)
                .foregroundStyle(.secondary)
                .font(.system(size: headerFontSize, weight: .semibold, design: .rounded))
                .textCase(nil)
                .padding(.bottom, 0)
        }
    }

    // List-based text section (joins values into a single row string).
    @ViewBuilder
    static func textSectionList(title: String, values: [String]?, glyph: String? = nil,
                                glyphColor: Color? = nil) -> some View {
        textSection(title: title, value: values?.joined(separator: ", ") ?? "",
                    glyph: glyph, glyphColor: glyphColor)
    }

    // MARK: - Searchable Item Section
    // Multi-row section where each item gets its own text row with an inline
    // "Search" button on the trailing edge. Clicking the button fires an
    // .activateTokenSearch UICommand for the specified SearchField and item value.
    // Used for Studio, Cast, Directors, Producers, Executive Producers,
    // Screenwriters, and Composers in the Details tab's Metadata module.
    //
    // An optional `glyph` goes on EVERY row, not just the first: the gutter it reserves
    // insets the text, so a glyph on one row alone would stagger the names under it.
    @ViewBuilder
    static func searchableItemSection(title: String, items: [String]?, field: SearchField,
                                      glyph: String? = nil,
                                      glyphColor: Color = .secondary) -> some View {
        let trimmedItems = (items ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        VStack(alignment: .leading, spacing: headerRowSpacing) {
            sectionHeader(title)

            if trimmedItems.isEmpty {
                // Placeholder row — no search button since there's nothing to search.
                Text("None provided")
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .font(.system(size: rowFontSize))
                    .sidebarRowContainer(glyph: glyph,
                                         glyphColor: Color(nsColor: .tertiaryLabelColor))
            } else if RSBProfileFlags.swiftUICrewRows {
                ForEach(Array(trimmedItems.enumerated()), id: \.offset) { _, item in
                    SearchableItemRow(item: item, field: field,
                                      glyph: glyph, glyphColor: glyphColor)
                }
            } else {
                // The same rows in AppKit, re-pointed rather than rebuilt per film. See
                // CrewRowList.
                CrewRowList(items: trimmedItems, field: field, glyph: glyph, glyphColor: glyphColor)
            }
        }
    }

    // MARK: - Data Formatting and Conversion
    // Convert a duration in milliseconds (stored as a string) into a user-friendly
    // format like "2 hours 15 minutes".
    static func formattedDuration(from millisecondsString: String?) -> String {
        guard let parts = hoursAndMinutes(from: millisecondsString) else { return "" }
        let hours = parts.hours
        let minutes = parts.minutes

        switch (hours, minutes) {
        case (0, 0): return "0 minutes"
        case (0, _): return "\(minutes) minute" + (minutes == 1 ? "" : "s")
        case (_, 0): return "\(hours) hour" + (hours == 1 ? "" : "s")
        default: return "\(hours) hour" + (hours == 1 ? "" : "s") +
            " \(minutes) minute" + (minutes == 1 ? "" : "s")
        }
    }

    // Abbreviated duration such as "2 hr. 15 min.", for when two durations share one line (for example,
    // edited and original).
    static func formattedDurationAbbreviated(from millisecondsString: String?) -> String {
        guard let parts = hoursAndMinutes(from: millisecondsString) else { return "" }
        let hours = parts.hours
        let minutes = parts.minutes

        switch (hours, minutes) {
        case (0, 0): return "0 min."
        case (0, _): return "\(minutes) min."
        case (_, 0): return "\(hours) hr."
        default:     return "\(hours) hr. \(minutes) min."
        }
    }

    // MARK: - ISO8601 Timestamp Formatting (for stored string timestamps)
    // Parsers for full timestamps (such as lastModified). Both are private, since they exist only for
    // formatFullTimestamp(_:) in this file.
    @MainActor
    private static let isoTimestampParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        // Support full internet date-time with fractional seconds, in UTC ("Z").
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    // Fallback parser for timestamps without fractional seconds.
    @MainActor
    private static let isoTimestampFallbackParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    // "Month Day, Year, at HH:MM AM/PM" for full timestamps. Private and @MainActor, like the parsers above. It is
    // read only by formatFullTimestamp(_:). Nonisolated would expose this mutable, non-Sendable formatter to every
    // isolation domain.
    @MainActor
    private static let fullTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.calendar = AppCalendar.gregorian  // .current alone carries the system calendar
        formatter.timeZone = .current
        formatter.dateFormat = "MMMM d, yyyy, 'at' h:mm a"
        return formatter
    }()

    // Formats a full ISO8601 timestamp as "Month Day, Year, HH:MM AM/PM" in the user's locale and time zone.
    // If parsing fails, it tries the non-fractional parser, then YYYY.MM.DD via formatDateString. If all of
    // those fail, it returns the raw string so a real value shows rather than a placeholder.
    @MainActor
    static func formatFullTimestamp(_ raw: String?) -> String {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else { return "" }

        // Primary attempt: Fractional seconds-capable parser.
        if let date = isoTimestampParser.date(from: value) {
            return fullTimestampFormatter.string(from: date)
        }

        // Secondary attempt: Try again without fractional seconds.
        if let date = isoTimestampFallbackParser.date(from: value) {
            return fullTimestampFormatter.string(from: date)
        }

        // Tertiary attempt: Try YYYY.MM.DD format.
        let formattedDate = formatDateString(value)
        if formattedDate != "Unknown date" {
            return formattedDate
        }

        // As a last resort, show the raw string instead of an empty value.
        return value
    }

    // Splits a millisecond duration (stored as a string) into whole hours and minutes. Returns nil for a
    // missing, unparseable, or non-positive value. That nil is the single "no duration" signal both duration
    // formatters translate into an empty string. Sharing this keeps the parse rule in one place.
    //
    // Internal, not private: GalleryListView's duration column draws hours and minutes as two aligned items,
    // so it needs the components rather than a formatted string. A second copy of the rule there could
    // disagree with the formatters about what counts as "no duration."
    static func hoursAndMinutes(from millisecondsString: String?) -> (hours: Int, minutes: Int)? {
        guard let totalMinutes = DurationHelpers.storedMinutes(millisecondsString) else { return nil }
        return (totalMinutes / 60, totalMinutes % 60)
    }

    // MARK: - Other Field Formatting
    // Formats an integer so that nil or 0 becomes "no value" (empty string). The UI layer then shows the
    // tertiary "None provided" placeholder.
    static func formatNumericalValue(_ value: Int?) -> String {
        guard let value = value, value != 0 else { return "" }
        return String(value)
    }

    static func formatNumericalValue(_ value: Double?) -> String {
        guard let value = value, value != 0, value.isFinite else { return "" }
        // Display as integer if no decimal part.
        let display = value.truncatingRemainder(dividingBy: 1) == 0 && abs(value) < 1e15
            ? String(Int(value))
            : String(value)
        return display
    }

    // MARK: - Source-Field Logic
    // Computes the "Source for Viewing" display string for a film snapshot.
    //
    // Selection rules:
    //   • Edited films: a purchased Blu-ray, otherwise the digital source. 4K releases are skipped.
    //   • Non-edited films: 4K preferred, then Blu-ray, then DVD, then digitalSource.
    //   • A purchased disc always gets its own tier ("4K disc", "Blu-ray disc", "DVD") and never a " rip"
    //     suffix. "Rip" is reserved for the digitalSource fallback, used when no purchased disc of that format exists.
    //   • The best-scored purchased release (ReleaseSnapshot.qualityScore) is shown. Year, studio, remastered,
    //     and origin all come from that one release, so they are never mixed across releases.
    //   • Prefix rules check ALL releases of the format, purchased or not, so any release, wishlist or owned,
    //     can add a disambiguating prefix:
    //       – Year: another same-format release shares the best release's studio and has a different effective
    //         base year (baseReleaseYear, or releaseYear when that is empty). Same-studio releases with one
    //         effective base year are variants of one release (for example, a 2014 disc and a 2016 repackaging
    //         with baseReleaseYear "2014"), so no year is shown. When a year is shown, it is the best release's
    //         effective base year, not its releaseYear. A 2020 purchase of a disc with baseReleaseYear "2014"
    //         reads "2014".
    //       – Studio: at least one same-format release, of any purchase status, has a different studio from the
    //         best purchased release.
    //       – Origin: sits between year and studio ("2022 AU Imprint remastered Blu-ray disc"). It is shown for
    //         ANY import, meaning a release with an origin set that is not domestic, since a foreign disc is
    //         non-standard. A domestic release names its origin only to disambiguate: when all same-studio
    //         colliders share the best release's year but differ in origin.
    //       All three can apply together, giving "YEAR ORIGIN STUDIO ...". With one domestic release of the
    //       format, no prefix appears.
    //   • "remastered" goes before the format label, not in a parenthetical suffix. It is lowercase internally,
    //     and the final string is sentence-capitalized, so it is capitalized only when it is the first word.
    //   • An edited film using a Blu-ray digital fallback (no purchased Blu-ray) always gets "rip". Its remastered
    //     flag comes from any Blu-ray release in the pool, purchased or wishlist.
    //   • The three companion outputs (disc glyph, "available for purchase" suffix, "Region B locked" suffix) are
    //     returned with the string, not recomputed elsewhere. Each describes which branch was taken, so deriving
    //     them elsewhere would duplicate this structure and could drift (see `isPurchasedDiscSource`).
    struct SourceDisplay: Equatable {
        /// Sentence-capitalized display string; empty when the film has no source at all.
        var value: String = ""
        /// `value` with the origin's short form ("AU") in place of its demonym ("Australian"). Nil when the two are
        /// identical, or when the origin has no short form. It is offered to `fittingValueRow` only as an
        /// abbreviation step, and it appears only when it keeps the value on one line, as "rem." does for
        /// "remastered". It is built here rather than by text substitution, because a demonym can also occur
        /// elsewhere in the string. A studio named "American Zoetrope" must not become "U.S. Zoetrope".
        var originAbbreviatedValue: String? = nil
        /// `value` with the studio's abbreviation ("Uni") in place of the shorthand ("Universal") the value carries.
        /// Nil when the two are identical. As with the origin, this is an overflow-only fallback. The shorthand is
        /// the standard spelling (`ReleaseStudio` explains the three tiers). It is built here, where the studio
        /// token's position is known, so no substitution has to guess where it is.
        var studioAbbreviatedValue: String? = nil
        /// `value` with both the origin and the studio compacted. Nil when identical to `value`. It is the last
        /// ladder step, offered only after each single step.
        var originAndStudioAbbreviatedValue: String? = nil
        /// True when the displayed value is a disc the user owns, which is when the "opticaldisc.fill" glyph shows.
        /// This is not "the film owns any disc". The two differ when the value falls through to the digital source
        /// while a purchased disc of another format exists. For example, an edited film owning a purchased 4K but no
        /// purchased Blu-ray shows "Edited Blu-ray disc rip", which is a rip, not an owned disc. Keying the glyph off
        /// `film.purchasedReleases.isEmpty` would wrongly put a disc glyph on that rip.
        var isPurchasedDiscSource: Bool = false
        /// "Available for purchase on <format>", or empty. A complete, sentence-capitalized phrase, rendered as its
        /// own annotation row under the value row (see `WatchDetails.sourceSection`). It appears only for a format
        /// the film owns no purchased disc of, and names one format, never a list. The 4K and Blu-ray notes can
        /// appear beside a displayed purchased disc of a different format, such as a purchased Blu-ray with an
        /// unpurchased 4K. The 4K note is suppressed for edited films. The DVD note still requires that the displayed
        /// value is not a purchased disc. If the backing release is not out on `today`, the note reads "Upcoming
        /// <format> release on <date>" (or "… release in <year>" for a year-only date), since it cannot be bought yet.
        var availableForPurchaseNote: String = ""
        /// `availableForPurchaseNote` with the release date's month abbreviated, or nil
        /// when the two would be identical — every note but the upcoming form, and an
        /// upcoming release in May or with a year-only date. Offered to `fittingValueRow`
        /// as the one step of the note's ladder, the same overflow-only contract as the
        /// module's other date rows.
        var availableForPurchaseNoteAbbreviated: String? = nil
        /// "Region B locked" — empty unless the displayed value is a purchased Blu-ray
        /// reached via the non-edited path AND that release's regionLock is exactly
        /// "Region B". "Region B (Loosely-locked)" is excluded: it plays back like
        /// Region A on region-free hardware and so is not a practical restriction.
        /// Scoped to non-edited films by design. Rendered as its own annotation row.
        var regionBLockNote: String = ""
        /// "Releases on <date>" (or "… in <year>") — empty unless the displayed value is a
        /// purchased disc whose release date is still to come on `today`: a paid pre-order.
        /// Keyed off the very release the value row names, so owning some other purchased
        /// release, or having an unpurchased upcoming one, never triggers it. Rendered as
        /// its own annotation row.
        var preorderReleaseNote: String = ""
        /// `preorderReleaseNote` with the month abbreviated, or nil when identical. The
        /// same overflow-only contract as `availableForPurchaseNoteAbbreviated`.
        var preorderReleaseNoteAbbreviated: String? = nil
    }

    /// `today` decides whether the release behind the purchase note is upcoming; views
    /// pass `CurrentDay.shared.today` so the note changes wording on the release day.
    static func sourceDisplay(
        for film: FilmSnapshot,
        today: Date = StorageDateFormatters.calendar.startOfDay(for: Date())
    ) -> SourceDisplay {
        let isEdited = film.edited

        // All releases per format — used for prefix disambiguation rules.
        let all4K  = film.releases.filter { $0.format == ReleaseFormat.uhd4K.rawValue }
        let all2K  = film.releases.filter { $0.format == ReleaseFormat.bluRay.rawValue }
        let allDVD = film.releases.filter { $0.format == ReleaseFormat.dvd.rawValue }

        // Purchased-only pools — used for selecting the best release to display.
        let purchased4K  = all4K.filter  { $0.purchased }
        let purchased2K  = all2K.filter  { $0.purchased }
        let purchasedDVD = allDVD.filter { $0.purchased }

        // Best-scored purchased releases — all prefix/flag values always come
        // from the same release so they cannot be mixed across releases.
        let best4K  = ReleaseSnapshot.best(from: purchased4K)
        let best2K  = ReleaseSnapshot.best(from: purchased2K)
        let bestDVD = ReleaseSnapshot.best(from: purchasedDVD)

        // film.digitalSource stores the remastered flag as a "Remastered " prefix (the FSTabMetadata.computedDigitalSource
        // encoding). Strip it before any format comparison, so "Remastered Blu-ray disc" branches like "Blu-ray disc",
        // and the remastered state is carried separately as a boolean.
        let rawDigitalSource = film.digitalSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let (digitalSource, digitalSourceIsRemastered) = FilmDigitalSource.decompose(rawDigitalSource)
        let hasDigitalSource = !digitalSource.isEmpty

        // The value in every spelling the ladder can offer: the full form and the three with the origin, the studio,
        // or both compacted. Every branch fills all four; branches with no prefix fill them identically. See
        // SourceDisplay.originAbbreviatedValue and its siblings.
        let raw: SourceValueForms

        // Set by whichever branch wins. `isPurchasedDisc` answers "is the value displayed a disc the user owns?", which
        // differs from "does the film own any disc?" (see SourceDisplay.isPurchasedDiscSource). `displayedBluRay` is
        // non-nil only on the branch the Region B suffix is scoped to (non-edited, purchased Blu-ray), so the suffix
        // cannot drift from the branch it describes.
        var isPurchasedDisc = false
        var displayedBluRay: ReleaseSnapshot?
        // The purchased release the value row names, if any. It drives the pre-order note.
        var displayedPurchased: ReleaseSnapshot?

        if isEdited {
            // Edited films: Blu-ray only.
            if !purchased2K.isEmpty {
                let prefix = sourcePrefix(best: best2K, allOfFormat: all2K)
                let label  = formatLabel("Blu-ray disc", remastered: best2K?.remastered ?? false)
                raw = SourceValueForms(lead: "Edited ", prefix: prefix, label: label)
                isPurchasedDisc = true
                displayedPurchased = best2K
                // Deliberately no displayedBluRay: the Region B suffix is scoped to
                // non-edited films only.
            } else if hasDigitalSource {
                // No purchased Blu-ray. "rip" is appended for "Blu-ray disc" and "DVD" digital sources (the disc
                // itself was not purchased). A purchased DVD is the exception: the disc was bought, so "rip" is omitted,
                // mirroring the purchased-disc paths. Remastered comes from the digitalSource prefix flag for a Blu-ray
                // source, with the release-pool flag as a fallback in case no release object exists.
                let base: String
                if digitalSource == FilmDigitalSource.dvd && !purchasedDVD.isEmpty {
                    base = "DVD"
                    displayedPurchased = bestDVD
                    // The disc was bought, which is why "rip" is omitted, so this branch displays a purchased disc.
                    isPurchasedDisc = true
                } else if digitalSource == FilmDigitalSource.blurayDisc {
                    // Remastered: the stored digitalSource prefix flag first, then any Blu-ray release in the pool
                    // (purchased or wishlist).
                    let anyBlurayRemastered = digitalSourceIsRemastered
                        || (ReleaseSnapshot.best(from: all2K)?.remastered ?? false)
                    base = anyBlurayRemastered ? "remastered Blu-ray disc rip" : "Blu-ray disc rip"
                } else if digitalSource == FilmDigitalSource.dvd {
                    base = "DVD rip"
                } else {
                    base = digitalSource
                }
                raw = SourceValueForms(uniform: "Edited \(base)")
            } else {
                raw = SourceValueForms(uniform: "")
            }
        } else {
            // Non-edited: 4K → Blu-ray → DVD → digital.
            if !purchased4K.isEmpty {
                let prefix = sourcePrefix(best: best4K, allOfFormat: all4K, requiresNotableDifference: true)
                let label  = formatLabel("4K disc", remastered: best4K?.remastered ?? false)
                raw = SourceValueForms(lead: "", prefix: prefix, label: label)
                isPurchasedDisc = true
                displayedPurchased = best4K
            } else if !purchased2K.isEmpty {
                let prefix = sourcePrefix(best: best2K, allOfFormat: all2K)
                let label  = formatLabel("Blu-ray disc", remastered: best2K?.remastered ?? false)
                raw = SourceValueForms(lead: "", prefix: prefix, label: label)
                isPurchasedDisc = true
                displayedPurchased = best2K
                // The one branch the Region B suffix applies to.
                displayedBluRay = best2K
            } else if !purchasedDVD.isEmpty {
                // Purchased DVD release — display as "DVD" (with optional prefix),
                // never as "DVD rip", mirroring the Blu-ray and 4K purchased paths.
                let prefix = sourcePrefix(best: bestDVD, allOfFormat: allDVD)
                let label  = formatLabel("DVD", remastered: bestDVD?.remastered ?? false)
                raw = SourceValueForms(lead: "", prefix: prefix, label: label)
                isPurchasedDisc = true
                displayedPurchased = bestDVD
            } else if hasDigitalSource {
                // No purchased disc of any format. "Blu-ray disc" and "DVD" digital
                // sources represent rips from unpurchased discs, so append " rip".
                let base = (digitalSource == FilmDigitalSource.blurayDisc
                            || digitalSource == FilmDigitalSource.dvd)
                    ? "\(digitalSource) rip" : digitalSource
                // Remastered flag: honor the digitalSource prefix flag and any disc
                // pool's best release (none purchased, but flags may still be set).
                let anyRemastered = digitalSourceIsRemastered
                    || (best4K?.remastered ?? false)
                    || (best2K?.remastered ?? false)
                    || (bestDVD?.remastered ?? false)
                raw = SourceValueForms(uniform: anyRemastered ? "remastered \(base)" : base)
            } else {
                raw = SourceValueForms(uniform: "")
            }
        }

        // Sentence-capitalize: "remastered" is always written lowercase internally
        // so it is only capitalized here when it happens to be the first word.
        func sentenceCapitalized(_ s: String) -> String {
            s.isEmpty ? s : s.prefix(1).uppercased() + s.dropFirst()
        }
        let value = sentenceCapitalized(raw.full)
        // Each alternate is offered only when it actually differs from the value; a nil
        // here is what lets the ladder skip a step that would change nothing.
        func alternate(_ form: String) -> String? {
            let capitalized = sentenceCapitalized(form)
            return capitalized == value ? nil : capitalized
        }

        // ── Companion notes, each derived from the branch taken above ──
        // Each is a standalone phrase on its own row beneath the value, not spliced onto `value`.
        // The 4K and Blu-ray clauses are not gated on `!isPurchasedDisc`: a purchased Blu-ray still advertises
        // an unpurchased 4K. Each format is advertised only when no purchased disc of that format is owned.
        //
        //   • 4K UHD: not edited, no purchased 4K, and a 4K release is buyable. Covers both "no purchased 4K or
        //     Blu-ray" and "purchased Blu-ray plus an unpurchased 4K".
        //   • Blu-ray: the 4K note did not fire, an unpurchased Blu-ray exists, and no purchased Blu-ray is owned.
        //     A purchased 4K does not suppress it. Owning the 4K says nothing about the Blu-ray, and an edited film
        //     (Blu-ray only) has no 4K source.
        //   • DVD: shown only when the value is not a purchased disc, nothing on Blu-ray is buyable, and nothing on
        //     4K is either. The 4K condition is waived for edited films, where 4K never applies, as the Blu-ray rule
        //     waives it.
        let has4KToBuy  = all4K.contains  { !$0.purchased }
        let has2KToBuy  = all2K.contains  { !$0.purchased }
        let hasDVDToBuy = allDVD.contains { !$0.purchased }

        // The backing release is the best unpurchased one of that format. A foreign origin makes the note say
        // "foreign". If the release is still to come, the note names its date instead ("Upcoming Blu-ray release
        // on November 3, 2026").
        func buyPhrase(_ format: String, _ pool: [ReleaseSnapshot]) -> String {
            let backing = ReleaseSnapshot.best(from: pool.filter { !$0.purchased })
            let foreign = backing.map { ReleaseOrigin.isImport($0.nationalOrigin) } ?? false
            let label = "\(foreign ? "foreign " : "")\(format)"
            if let backing,
               let date = ReleaseDateValue(backing.releaseDate, format: backing.format),
               date.isUpcoming(today: today) {
                return date.isYearOnly
                    ? "Upcoming \(label) release in \(date.displayText)"
                    : "Upcoming \(label) release on \(date.displayText)"
            }
            return "Available for purchase on \(label)"
        }

        var availableForPurchase = ""
        if !isEdited && has4KToBuy && purchased4K.isEmpty {
            availableForPurchase = buyPhrase(ReleaseFormat.uhd4K.rawValue, all4K)
        } else if has2KToBuy && purchased2K.isEmpty {
            availableForPurchase = buyPhrase(ReleaseFormat.bluRay.rawValue, all2K)
        } else if !isPurchasedDisc && (isEdited || !has4KToBuy) && !has2KToBuy && hasDVDToBuy {
            availableForPurchase = buyPhrase(ReleaseFormat.dvd.rawValue, allDVD)
        }

        let regionBLock = (displayedBluRay?.regionLock == ReleaseRegionRules.regionB)
            ? "Region B locked"
            : ""

        // A purchased disc that has not come out yet: a paid pre-order.
        var preorderNote = ""
        if let displayedPurchased,
           let date = ReleaseDateValue(displayedPurchased.releaseDate, format: displayedPurchased.format),
           date.isUpcoming(today: today) {
            preorderNote = date.isYearOnly
                ? "Releases in \(date.displayText)"
                : "Releases on \(date.displayText)"
        }

        return SourceDisplay(
            value: value,
            originAbbreviatedValue: alternate(raw.originAbbreviated),
            studioAbbreviatedValue: alternate(raw.studioAbbreviated),
            originAndStudioAbbreviatedValue: alternate(raw.originAndStudioAbbreviated),
            isPurchasedDiscSource: isPurchasedDisc,
            availableForPurchaseNote: availableForPurchase,
            availableForPurchaseNoteAbbreviated: SidebarTextAbbreviation.abbreviatingMonthNames(in: availableForPurchase),
            regionBLockNote: regionBLock,
            preorderReleaseNote: preorderNote,
            preorderReleaseNoteAbbreviated: SidebarTextAbbreviation.abbreviatingMonthNames(in: preorderNote)
        )
    }

    /// The format label: "remastered" when set, then the format — "remastered Blu-ray
    /// disc". The four purchased-disc branches each build this, so the remastered/plain pair is spelled once.
    private static func formatLabel(_ format: String, remastered: Bool) -> String {
        "\(remastered ? "remastered " : "")\(format)"
    }

    /// One source value in the four spellings `sourceDisplay` hands back: full, and with
    /// the origin, the studio, or both in compact form. Assembled from a leading word
    /// ("Edited " or nothing), a `SourcePrefix` in the matching spelling, and the format
    /// label, so the four differ ONLY in the prefix — which is what makes them measurable
    /// against one another as steps of a single ladder. `uniform` is for the branches
    /// that show no prefix at all, where every spelling is the same string.
    private struct SourceValueForms {
        let full: String
        let originAbbreviated: String
        let studioAbbreviated: String
        let originAndStudioAbbreviated: String

        init(lead: String, prefix: SourcePrefix, label: String) {
            full                       = "\(lead)\(prefix.full)\(label)"
            originAbbreviated          = "\(lead)\(prefix.originAbbreviated)\(label)"
            studioAbbreviated          = "\(lead)\(prefix.studioAbbreviated)\(label)"
            originAndStudioAbbreviated = "\(lead)\(prefix.originAndStudioAbbreviated)\(label)"
        }

        init(uniform value: String) {
            full = value
            originAbbreviated = value
            studioAbbreviated = value
            originAndStudioAbbreviated = value
        }
    }

    // The studio spelling for the Source for Viewing field, in two tiers (see ReleaseStudio for the three-tier
    // scheme). Both are gated by Preferences.abbreviateSourceStudio. When that is off, every tier returns the
    // original name, so the ladder has nothing to retreat to.
    //
    //   • shorthandStudioName: the default spelling ("Universal").
    //   • abbreviatedStudioName: the retreat when the shorthand would wrap ("Uni"). It falls back to the shorthand
    //     when no tighter form exists, so that ladder step equals the default and is dropped.
    //
    // Studios not in the table display at full length at both tiers.
    //
    // Free-text "Other" entries (not matching a known studio) are not looked up. They are truncated to 30
    // characters plus an ellipsis, whatever the preference, so arbitrary user input cannot grow the layout.
    private static func shorthandStudioName(_ studio: String) -> String {
        guard Preferences.abbreviateSourceStudio else { return studio }
        return ReleaseStudio.shorthand(studio)
    }

    private static func abbreviatedStudioName(_ studio: String) -> String {
        guard Preferences.abbreviateSourceStudio else { return studio }
        return ReleaseStudio.abbreviated(studio)
    }

    // The 30-character truncation for free-text studios. Known names never reach this length, but the guard
    // is unconditional, so a future long name is handled safely.
    private static func truncatedStudioDisplayName(_ studio: String) -> String {
        let maxLength = 30
        guard studio.count > maxLength else { return studio }
        let truncated = studio.prefix(maxLength)
        return "\(truncated)…"
    }

    // Display string for a studio: shortened to the tier when enabled, then truncated as a final safety net.
    private static func displayStudioName(_ studio: String) -> String {
        return truncatedStudioDisplayName(shorthandStudioName(studio))
    }

    private static func displayStudioAbbreviation(_ studio: String) -> String {
        return truncatedStudioDisplayName(abbreviatedStudioName(studio))
    }

    // Builds the disambiguation prefix for a disc-format pool.
    //
    // `best`        — the best-scored purchased release (the one displayed).
    // `allOfFormat` — every release of the format, purchased or not. Prefix rules use this full set, so
    //                 wishlist releases disambiguate as owned ones do.
    //
    // Rules (applied only when allOfFormat has 2+ releases):
    //   showYear:   another release in allOfFormat shares the best release's studio, and that collider's
    //               effective base year (baseReleaseYear, or its releaseYear when that is empty) differs from the
    //               best's. Colliders with the same effective base year are variants of one release, so a year
    //               would not disambiguate and is suppressed. When shown, the year is the best release's effective
    //               base year, not its releaseYear.
    //   showStudio: at least one release in allOfFormat has a different studio from the best. The studio name
    //               identifies the release shown.
    //   showOrigin: same-studio colliders that share the best's effective base year differ in national origin.
    //               This is evaluated INDEPENDENTLY of showYear. The same-year group is exactly what a year cannot
    //               separate, so origin is needed when no different-year collider exists. Do not derive it from
    //               showYear: the "ORIGIN " form would then be unreachable, since showYear needs a different-year
    //               collider and origin needs a same-year one.
    //               The two tokens then compose naturally: a different-year collider
    //               contributes the year, a same-year origin difference contributes
    //               the origin, and a pool containing both contributes both — the
    //               year narrowing to the correct same-year sub-group first, then
    //               origin discriminating within it.
    //
    //   import:     INDEPENDENT of the collision rules above and of the 2+ gate: a
    //               release whose national origin is anything other than the domestic
    //               one (`ReleaseOrigin.domestic`) always names it. A foreign disc is
    //               inherently non-standard for this library, so the origin is part of
    //               what the disc IS rather than a disambiguator, and is stated even
    //               when there is nothing to tell it apart from. An empty origin is
    //               unset, not foreign, and stays silent.
    //
    // The three tokens are independent, so each combination is emitted in YEAR ORIGIN STUDIO order. The origin
    // precedes the studio whenever it appears, since it describes the disc's provenance. "English Criterion
    // Blu-ray disc" reads as the nation's edition of that studio's disc, which is what it is.
    //   ""                       — single domestic release; or 2+ releases sharing
    //                              studio, effective base year, and origin
    //   "YEAR "                  — 2+ releases, all same studio, years differ
    //   "ORIGIN "                — an import; or 2+ same-studio same-year releases whose
    //                              origins differ
    //   "YEAR ORIGIN "           — either origin trigger plus a different-year collider
    //   "STUDIO "                — 2+ releases, all different studios
    //   "YEAR STUDIO "           — mixed studios with a same-studio/different-year collision
    //   "ORIGIN STUDIO "         — mixed studios plus either origin trigger
    //   "YEAR ORIGIN STUDIO "    — all three
    //
    // Four spellings differ only in their proper-name tokens. `full` uses the origin's demonym ("Australian")
    // and the studio's shorthand ("Universal"). `originAbbreviated` uses the origin's short form ("AU",
    // `ReleaseOrigin.shortForm`). `studioAbbreviated` uses the studio's abbreviation ("Uni",
    // `ReleaseStudio.abbreviated`), and `originAndStudioAbbreviated` uses both. The compact forms are
    // overflow-only fallbacks, like "rem." for "remastered". A spelling equals `full` when its token is not
    // shown or has no compact form. Each ends with a space, so the format label can be concatenated directly.
    struct SourcePrefix {
        var full: String = ""
        var originAbbreviated: String = ""
        var studioAbbreviated: String = ""
        var originAndStudioAbbreviated: String = ""
    }

    private static func sourcePrefix(
        best: ReleaseSnapshot?,
        allOfFormat: [ReleaseSnapshot],
        requiresNotableDifference: Bool = false
    ) -> SourcePrefix {
        guard let best = best else { return SourcePrefix() }

        let bestStudio = best.studio
        let bestOrigin = best.nationalOrigin
        let originToken      = bestOrigin.isEmpty ? "" : "\(ReleaseOrigin.demonym(for: bestOrigin)) "
        let originShortToken = bestOrigin.isEmpty ? "" : "\(ReleaseOrigin.shortForm(for: bestOrigin)) "
        let isImport = ReleaseOrigin.isImport(bestOrigin)

        // One release of the format: nothing to disambiguate, so no year or studio. Only the import rule
        // applies. All four spellings are filled, since no studio is shown. Left empty, they would read as
        // ladder steps that drop the origin ("Blu-ray disc" for an Australian disc), which the row could pick
        // on overflow.
        guard allOfFormat.count >= 2 else {
            return isImport ? SourcePrefix(full: originToken,
                                           originAbbreviated: originShortToken,
                                           studioAbbreviated: originToken,
                                           originAndStudioAbbreviated: originShortToken)
                            : SourcePrefix()
        }

        // Same-studio colliders: other releases that share the best release's studio.
        let sameStudioOthers = allOfFormat.filter { $0.id != best.id && $0.studio == bestStudio }

        // The effective base year identifies which original release a disc is a variant of. It is baseReleaseYear
        // when set (a re-issue or repack of an earlier release), otherwise the year of the release's own date.
        // Releases sharing one effective base year are variants of one release (for example, a 2014 Blu-ray and
        // its 2016 repackaging with baseReleaseYear "2014"), so a year would mislead rather than help.
        //
        // Years only, never the full date. The base year has no month or day.
        func effectiveBaseYear(_ release: ReleaseSnapshot) -> String {
            release.baseReleaseYear.isEmpty
                ? ReleaseDateValue.yearText(of: release.releaseDate, format: release.format)
                : release.baseReleaseYear
        }
        let bestEffectiveBaseYear = effectiveBaseYear(best)

        // showYear needs a same-studio collider to tell apart, unless all share the year (then showOrigin applies).
        //
        // For requiresNotableDifference formats (currently 4K), the year is shown only if a same-studio collider
        // differs notably from the best: remastered, videoFormat, audioFormat, audioChannels, hasSubtitles, or
        // releaseAspectRatio. Otherwise, such as the same disc bought twice, the year adds nothing.
        //
        // The year is also suppressed when every same-studio collider shares the best's effective base year. Those
        // are variants of one release, so a year would only create a false distinction.
        let hasSameStudioColliders = !sameStudioOthers.isEmpty
        let hasNotableCollider: Bool = {
            guard requiresNotableDifference else { return true }
            return sameStudioOthers.contains { other in
                other.remastered          != best.remastered          ||
                other.videoFormat         != best.videoFormat         ||
                other.audioFormat         != best.audioFormat         ||
                other.audioChannels       != best.audioChannels       ||
                other.hasSubtitles        != best.hasSubtitles        ||
                other.releaseAspectRatio  != best.releaseAspectRatio
            }
        }()
        let hasDistinctBaseYearCollider = sameStudioOthers.contains { other in
            effectiveBaseYear(other) != bestEffectiveBaseYear
        }
        let showYear = hasSameStudioColliders && hasNotableCollider && hasDistinctBaseYearCollider

        // showStudio fires when at least one release carries a different studio.
        let showStudio = allOfFormat.contains { $0.studio != bestStudio }

        // showOrigin fires when a same-studio collider shares the best's effective base year (a re-issue counts as
        // its original, as above) and differs in national origin. That covers two cases: all same-year (origin
        // replaces the year token) and mixed years (origin narrows within the effective-year group).
        //
        // Not predicated on showYear: that would make the all-same-year case unreachable, since showYear needs a
        // different-year collider. The notable-difference gate still applies, since it separates distinct discs from copies.
        let sameStudioSameYearOthers = sameStudioOthers.filter { effectiveBaseYear($0) == bestEffectiveBaseYear }
        let originDiffersAmongSameYearGroup = sameStudioSameYearOthers.contains { $0.nationalOrigin != bestOrigin }
        let showOrigin = hasNotableCollider && !sameStudioSameYearOthers.isEmpty && originDiffersAmongSameYearGroup

        // Build the tokens. Each is emitted independently by the flags above. The year token is the best release's
        // effective base year, not its releaseYear. A 2020 purchase of a disc with baseReleaseYear "2014" is
        // effectively a 2014 release, so it reads "2014".
        let yearToken        = bestEffectiveBaseYear.isEmpty  ? "" : "\(bestEffectiveBaseYear) "
        let studioToken      = bestStudio.isEmpty ? "" : "\(displayStudioName(bestStudio)) "
        let studioShortToken = bestStudio.isEmpty ? "" : "\(displayStudioAbbreviation(bestStudio)) "

        // The tokens are independent and always appear in this order, so the prefix is their concatenation. This
        // covers every documented form with no unreachable states.
        let showOriginToken = showOrigin || isImport
        func compose(_ origin: String, _ studio: String) -> String {
            "\(showYear ? yearToken : "")\(showOriginToken ? origin : "")\(showStudio ? studio : "")"
        }
        return SourcePrefix(full:                       compose(originToken,      studioToken),
                            originAbbreviated:          compose(originShortToken, studioToken),
                            studioAbbreviated:          compose(originToken,      studioShortToken),
                            originAndStudioAbbreviated: compose(originShortToken, studioShortToken))
    }

    // MARK: - Shared Utilities
    // Returns singular or plural form of a title based on count.
    static func pluralizedTitle(_ singular: String, _ plural: String, count: Int) -> String {
        return count == 1 ? singular : plural
    }
    
    /// Applies a state change with `.animation(_:value:)` modifiers suppressed, for state a
    /// tab animates on that must also follow a new selection in one step (the Details tab's
    /// table expansion, the Releases tab's purchase filter).
    static func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    // Standard section divider used throughout sidebar modules.
    static var sectionDivider: some View {
        Divider()
            .padding(.vertical, 8)
    }
}

// MARK: - Releases Tab: Shared Derivations
// ═══════════════════════════════════════════════════════════════════════════════════════
// The Releases tab shows each release twice: as a row in the summary table (DiscReleasesTable, 24.21) and as a
// card (RTabReleases, 24.20). A row and its card describe the same disc, so the derivations that define what
// they say must match: the region mark and its color, the video line, and the release order.
//
// Every derivation lives here only, so the table and the cards cannot drift apart.
//
// Chrome and geometry are not shared. They differ by context on purpose: the cards draw into a fixed slot on an
// opaque gray pill, and the table draws into a column on the row background.
// ═══════════════════════════════════════════════════════════════════════════════════════

// MARK: Region Lock Badging

/// The mark a region lock resolves to: a lettered/numbered disc, the Region Free globe, or
/// an unrecognized stored value passed through verbatim.
enum RSBRegionIndicator: Equatable {
    /// A filled disc carrying one character. `playable` is whether the disc runs on this
    /// library's hardware, which is what selects the fill.
    case character(String, playable: Bool)
    /// The Region Free globe. It carries no symbol name, since it is the only glyph in this vocabulary.
    case globe
    /// A stored value outside the vocabulary, shown as-is. This happens only with hand-edited or legacy data,
    /// since the FilmSheet's region pickers are closed lists.
    case raw(String)

    /// The region a release displays as, with 4K UHD's default: a 4K disc with nothing recorded is Region Free,
    /// since the format has no region coding. It is separate from `resolve` because the card also needs the
    /// string for its tooltip.
    static func displayValue(_ stored: String, format: String) -> String {
        format == ReleaseFormat.uhd4K.rawValue && stored.isEmpty
            ? ReleaseRegionRules.regionFree : stored
    }

    /// Resolves a region lock for a given format, or nil when nothing is recorded.
    ///
    /// Playability is this library's hardware: Region A, a loosely-locked Region B (a
    /// bypass exists, so it effectively plays), and DVD Region 1. Everything else that
    /// names a real region does not play.
    ///
    /// Pass the value through `displayValue(_:format:)` first, or pass a raw field and get
    /// no 4K default — both call sites use the former.
    static func resolve(_ regionLock: String, format: String) -> RSBRegionIndicator? {
        let trimmed = regionLock.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed == ReleaseRegionRules.regionFree { return .globe }

        // DVD numbers its regions; 4K UHD and Blu-ray letter them.
        if format == ReleaseFormat.dvd.rawValue {
            guard let digit = dvdRegionDigit(trimmed) else { return .raw(trimmed) }
            return .character(String(digit), playable: digit == 1)
        }

        switch trimmed {
        case ReleaseRegionRules.regionA:          return .character("A", playable: true)
        case ReleaseRegionRules.regionB:          return .character("B", playable: false)
        case ReleaseRegionRules.looselyLockedTag: return .character("B", playable: true)
        default:                                  return .raw(trimmed)
        }
    }

    /// The region number 1 to 8 in `value`, or nil unless `value` is exactly "Region N". It is read from
    /// `ReleaseRegionRules`, which also composes the tag, so the two directions cannot drift. It is wider than the
    /// DVD picker's 1 to 5 on purpose; see `ReleaseRegionRules.regionNumber(in:)`.
    private static func dvdRegionDigit(_ value: String) -> Int? {
        ReleaseRegionRules.regionNumber(in: value)
    }
}

/// How a region disc is painted, given whether it plays.
///
/// A playable lock takes white with black lettering rather than green: green competed with
/// the purchase state shown alongside it, and a playable region is the unremarkable case —
/// it should read as neutral.
///
/// That leaves the locked fill as the only color here that means anything, and it is
/// `Preferences.orange` rather than red. Red and green are the purchase state's pair, the card's header band and
/// the table's "Pur." column, and a red region disc beside them would read as a second purchase remark. Orange
/// belongs to neither end of that scale and is the most saturated mark in view, so a disc that will not play stands out.
enum RSBRegionBadge {
    static func fill(playable: Bool) -> Color { playable ? .white : Preferences.orange }

    /// Lettering, at whatever contrasts with `fill`.
    static func ink(playable: Bool) -> Color { playable ? .black : .white }

    /// Whether the lettering needs a drop shadow to hold its edges against the fill. White
    /// on saturated orange does; black on white does not — the contrast there is already
    /// maximal and a shadow would only muddy the letter.
    static func inkNeedsShadow(playable: Bool) -> Bool { !playable }

    /// One size and weight for every region disc. Both renderers draw into a 14 pt circle, and even a one-point
    /// difference would make one disc look large or off-center beside the other.
    static let characterFont = Font.system(size: 10, weight: .semibold)
}

// MARK: Video Line

/// The release's video codec with its qualifier, as both presentations state it:
///
///   • 4K UHD → "CODEC (Master Type)", or the codec alone when the stored master type is
///     not one the picker offers. The codec itself defaults to HEVC, which is the only
///     codec 4K UHD ships with, so an unset field is filled rather than left blank.
///   • Blu-ray → "CODEC (Interlaced)" when interlaced, otherwise the codec alone. Nothing
///     is substituted for an unset codec here: unlike 4K, Blu-ray carries several and the
///     format does not imply one.
///   • DVD → always "MPEG2 (Interlaced)", which the format fixes.
///
/// Only the two known master types are appended. Any other stored value (an empty string, a legacy placeholder,
/// or a corrupt import) is ignored, so the codec shows alone rather than with a broken fragment in parentheses.
func releaseVideoDisplay(for release: ReleaseSnapshot) -> String {
    switch ReleaseFormat(rawValue: release.format) {
    case .uhd4K:
        let codec = release.videoFormat.isEmpty ? ReleaseVideoFormat.hevc : release.videoFormat
        return ReleaseMasterType.isKnown(release.masterType)
            ? "\(codec) (\(release.masterType))"
            : codec
    case .dvd:
        return "\(ReleaseVideoFormat.mpeg2) (\(ReleaseScanningMethod.interlaced))"
    default: // Blu-ray, and any format this build does not recognize.
        return ReleaseScanningMethod.isInterlaced(release.scanningMethod)
            ? "\(release.videoFormat) (\(ReleaseScanningMethod.interlaced))"
            : release.videoFormat
    }
}

// MARK: Ordering

/// The four sort keys for visible ordering: format group (4K UHD, Blu-ray, DVD, read from `ReleaseFormat` so
/// every list agrees), then descending release date, then descending purchase date, then studio. Returns nil when
/// all four tie. Each caller decides the tiebreak. The table's flat `.standard` sort treats a tie as `false`,
/// and the grouped ordering below falls back to a unique ID so its result is total.
func releaseSortKeysPrecede(_ lhs: ReleaseSnapshot, _ rhs: ReleaseSnapshot) -> Bool? {
    // Primary: format group (4K → Blu-ray → DVD)
    let lhsOrder = ReleaseFormat.displayRank(for: lhs.format)
    let rhsOrder = ReleaseFormat.displayRank(for: rhs.format)
    if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }

    // Secondary: release date (descending). A year-only date sorts after the full dates
    // in its year (ReleaseDateValue.sortKey); no date at all sorts last, as 0 always has.
    let lhsReleased = ReleaseDateValue(lhs.releaseDate, format: lhs.format)?.sortKey ?? 0
    let rhsReleased = ReleaseDateValue(rhs.releaseDate, format: rhs.format)?.sortKey ?? 0
    if lhsReleased != rhsReleased { return lhsReleased > rhsReleased }

    // Tertiary: purchase date (descending)
    let lhsDate = parseDate(from: lhs.purchaseDate)
    let rhsDate = parseDate(from: rhs.purchaseDate)
    if let l = lhsDate, let r = rhsDate, l != r { return l > r }
    if lhsDate != nil && rhsDate == nil { return true }
    if lhsDate == nil && rhsDate != nil { return false }

    // Quaternary: studio (ascending)
    let studioOrder = lhs.studio.englishStandardCompare(rhs.studio)
    if studioOrder != .orderedSame { return studioOrder == .orderedAscending }

    return nil
}

/// Groups a release set by acquisition — a combo-pack parent followed by its attached
/// children — and orders both the members within each group and the groups themselves.
///
/// Groups are keyed on `parentReleaseID ?? id`, which pairs a child with its parent from
/// the child's side alone — so the pairing holds regardless of whether the parent's
/// `childReleaseIDs` agrees. Group order is decided entirely by each group's primary
/// release, using `releaseSortKeysPrecede` — so the top-level entries appear in exactly
/// the order the table's flat `.standard` sort would place them.
///
/// GROUP SHAPE: index 0 of each group is its top-level parent, and later indices are its children. The member
/// sort puts `isTopLevel` first. The cards read index 0 as the plate's parent half and treat later indices as
/// attached children. The table reads `isChild` as "the row above continues my stack".
///
/// This holds because a child cannot name an absent parent, which would form a parentless group.
/// `Release.parentRelease` is an object reference with a `.nullify` delete rule, so deleting a parent makes its
/// children top-level instead of dangling. Both writers that resolve a raw `parentReleaseID` refuse unresolvable
/// links. DataManager's hierarchy step (Step 6) looks the parent up in `film.releases` alone and clears the pointer
/// otherwise, and DBRestorer's hierarchy pass drops any link whose parent is missing, is on another film, or is itself a child.
///
/// One residual case is deliberately not defended against. Both callers filter to recognized `ReleaseFormat`
/// values, so a parent with an unknown format string is removed while its child stays, leaving the child alone in
/// a group. No UI path can produce such a format. Only a hand-edited or corrupt backup can. The effect fails safe.
/// The card treats the release as standalone and shows its acquisition figures, and the table draws one
/// open-topped badge that meets nothing. Defending against it would need per-row adjacency bookkeeping, which this shape avoids.
///
/// The table flattens the result into rows; the cards map each group onto one plate.
///
/// Both tiebreaks are needed. `sortOrder` orders a dual-BD pack's two children, which tie on every visible key,
/// in the order the FilmSheet creates and displays them. The final ID key makes the order total. A dictionary's
/// value order is unspecified and `sorted(by:)` is not stable, so two groups that tie on all four keys could swap
/// on any rebuild, even one triggered by editing a field no sort key reads.
///
/// Every group is non-empty by construction (each is created by `default: []` immediately
/// followed by an `append`), which is what lets both sorts read `[0]` directly.
func releasesGroupedByHierarchy(_ source: [ReleaseSnapshot]) -> [[ReleaseSnapshot]] {
    var grouped: [UUID: [ReleaseSnapshot]] = [:]
    for release in source {
        grouped[release.parentReleaseID ?? release.id, default: []].append(release)
    }

    return grouped.values
        .map { members in
            // Parent first, then children in format order, then descending release date.
            members.sorted { lhs, rhs in
                if lhs.isTopLevel != rhs.isTopLevel { return lhs.isTopLevel }
                let lhsOrder = ReleaseFormat.displayRank(for: lhs.format)
                let rhsOrder = ReleaseFormat.displayRank(for: rhs.format)
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                let lhsReleased = ReleaseDateValue(lhs.releaseDate, format: lhs.format)?.sortKey ?? 0
                let rhsReleased = ReleaseDateValue(rhs.releaseDate, format: rhs.format)?.sortKey ?? 0
                if lhsReleased != rhsReleased { return lhsReleased > rhsReleased }
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
        .sorted { lhs, rhs in
            releaseSortKeysPrecede(lhs[0], rhs[0])
                ?? (lhs[0].id.uuidString < rhs[0].id.uuidString)
        }
}

// MARK: - QueryTarget
/// Enumerates the supported external query destinations.
enum QueryTarget {
    case imdb
    case bluray

    /// The index into 'FilmSnapshot.externalIdentifiers' for this target.
    var identifierIndex: Int {
        switch self {
        case .imdb:   return 0
        case .bluray: return 1
        }
    }

    /// The site's origin; every URL below is built on it.
    private var baseURL: String {
        switch self {
        case .imdb:   return "https://www.imdb.com"
        case .bluray: return "https://www.blu-ray.com"
        }
    }

    /// Builds a direct URL using the stored numeric identifier for this site.
    /// 'identifier' must be a non-empty digit string.
    /// 'dashedName' is used only by the Blu-ray target (the slug component).
    func directURL(identifier: String, dashedName: String) -> URL? {
        switch self {
        case .imdb:
            // Direct title reference page: /title/tt<id>/reference/
            return URL(string: "\(baseURL)/title/tt\(identifier)/reference/")

        case .bluray:
            // Direct title page: /<dashed-name>/<id>/
            // dashedName is already lowercased, punctuation-stripped, and hyphen-joined.
            return URL(string: "\(baseURL)/\(dashedName)/\(identifier)/")
        }
    }

    /// Builds a fallback search URL for the given normalized title string.
    /// `normalizedTitle` must already have had dash variants collapsed and must
    /// be plain Unicode text — percent-encoding is applied internally.
    func searchURL(for normalizedTitle: String) -> URL? {
        // A value inside a query string. `.urlQueryAllowed` leaves `&`, `=`, `+` and `?` literal, which would cut a
        // title such as "Fast & Furious" at the ampersand and read a `+` as a space.
        var valueAllowed = CharacterSet.urlQueryAllowed
        valueAllowed.remove(charactersIn: "&=+?")
        switch self {
        case .imdb:
            // IMDb find: restrict to feature films, exact-title search.
            guard let encoded = normalizedTitle.addingPercentEncoding(
                withAllowedCharacters: valueAllowed
            ) else { return nil }
            return URL(string: "\(baseURL)/find/?q=\(encoded)&s=tt&ttype=ft&exact=true")

        case .bluray:
            // Blu-ray.com quick-search, US theatrical section.
            // The keyword parameter uses "+" as a word separator on this site,
            // so we percent-encode the name and then swap encoded spaces for "+".
            guard let encoded = normalizedTitle
                .addingPercentEncoding(withAllowedCharacters: valueAllowed)?
                .replacingOccurrences(of: "%20", with: "+")
            else { return nil }
            return URL(string: "\(baseURL)/search/?quicksearch=1&quicksearch_country=US&quicksearch_keyword=\(encoded)&section=theatrical")
        }
    }
}

// MARK: - QueryHandoff
/// Stateless helper that normalizes a film title and opens an external query
/// in the user's default browser. All methods are static — no instance needed.
enum QueryHandoff {

    // MARK: - Private: Normalization

    /// Characters considered "dashes" that must be collapsed to a plain
    /// hyphen-minus (U+002D) before URL encoding so they don't produce
    /// unexpected percent-encoded sequences.
    private static let dashVariants: [(Unicode.Scalar, Unicode.Scalar)] = [
        ("\u{2014}", "\u{002D}"),  // em dash        →  -
        ("\u{2013}", "\u{002D}"),  // en dash        →  -
        ("\u{2012}", "\u{002D}"),  // figure dash    →  -
        ("\u{2011}", "\u{002D}"),  // non-breaking hyphen → -
        ("\u{2010}", "\u{002D}"),  // hyphen         →  -
        ("\u{FE58}", "\u{002D}"),  // small em dash  →  -
        ("\u{FE63}", "\u{002D}"),  // small hyphen-minus → -
        ("\u{FF0D}", "\u{002D}"),  // fullwidth hyphen-minus → -
    ]

    /// Returns a copy of `title` with all recognized dash variants replaced by
    /// a plain ASCII hyphen-minus. Applied once, up front, before any encoding.
    private static func normalizeDashes(in title: String) -> String {
        var result = title
        for (variant, replacement) in dashVariants {
            result = result.replacingOccurrences(
                of: String(variant),
                with: String(replacement)
            )
        }
        return result
    }

    // Pre-built CharacterSets used by dashedSlug to avoid per-scalar allocation.
    private static let slugAllowedScalars: CharacterSet =
        .letters.union(.decimalDigits).union(.init(charactersIn: " -"))
    private static let slugSeparatorScalars: CharacterSet =
        .whitespaces.union(.init(charactersIn: "-"))

    /// Produces the Blu-ray.com URL slug from a raw film title:
    /// lowercased, all punctuation removed, words joined by hyphens.
    /// Example: "The Lord of the Rings: The Return of the King"
    ///        → "the-lord-of-the-rings-the-return-of-the-king"
    private static func dashedSlug(for filmName: String) -> String {
        // Normalize dash variants first so they don't survive as punctuation.
        let dashNormalized = normalizeDashes(in: filmName)
        // Lowercase, then strip every character that isn't a letter, digit,
        // space, or plain hyphen-minus, then collapse runs of whitespace/hyphens
        // into a single hyphen to form the final slug.
        let stripped = dashNormalized
            .lowercased()
            .unicodeScalars
            .filter { slugAllowedScalars.contains($0) }
        let result = String(stripped)
            // Replace one or more spaces or hyphens with a single hyphen.
            .components(separatedBy: slugSeparatorScalars)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return result
    }

    // MARK: - Public: Open

    /// Opens the best available URL for 'target' in the user's default browser.
    ///
    /// If 'externalIdentifiers' contains a non-empty value at the target's
    /// designated index, a direct title URL is constructed and opened.
    /// Otherwise the call falls back to a keyword search query.
    ///
    /// - Parameters:
    ///   - filmName:            The raw film title from the data model.
    ///   - externalIdentifiers: The film's stored identifier array (may be empty).
    ///   - target:              The external site to open.
    ///   - logHandler:          Optional closure that receives a log-ready string.
    static func open(
        filmName: String,
        externalIdentifiers: [String] = [],
        target: QueryTarget,
        logHandler: ((String) -> Void)? = nil
    ) {
        let normalized = normalizeDashes(in: filmName)

        // Resolve stored identifier for this target, if present.
        let storedID: String? = {
            let idx = target.identifierIndex
            guard idx < externalIdentifiers.count else { return nil }
            let value = externalIdentifiers[idx].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }()

        let url: URL?
        let mode: String

        if let id = storedID {
            // Direct URL path — use the stored numeric identifier.
            let slug = dashedSlug(for: filmName)
            url  = target.directURL(identifier: id, dashedName: slug)
            mode = "direct"
        } else {
            // Fallback — keyword search query.
            url  = target.searchURL(for: normalized)
            mode = "search"
        }

        guard let resolvedURL = url else {
            logHandler?("QueryHandoff: failed to build \(mode) URL for '\(filmName)' → \(target)")
            return
        }

        NSWorkspace.shared.open(resolvedURL)
        logHandler?("QueryHandoff: opened [\(target)] (\(mode)) for '\(filmName)' → \(resolvedURL.absoluteString)")
    }
}

// MARK: - SearchableItemRow
/// One crew name's row: the name, selectable, with its token-search button. Internal rather than private, so
/// Metadata's pooled crew block (24.17) draws exactly the same row.
///
/// The Search button fires `.activateTokenSearch`, which MainView handles as a single-token search. The result
/// appears at once, with no intermediate state.
@MainActor
struct SearchableItemRow: View {
    let item: String
    let field: SearchField
    let glyph: String?
    let glyphColor: Color

    var body: some View {
        HStack(spacing: 6) {
            // Item text — expands to fill available space, truncating before the button.
            Text(item)
                .foregroundStyle(.primary)
                .font(.system(size: RSBHelpers.rowFontSize))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Search button — standard macOS bordered style.
            Button {
                AppEventBus.shared.sendCommand(.activateTokenSearch(field: field, value: item))
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help("Perform a token-based search for this name")
        }
        .sidebarRowContainer(glyph: glyph, glyphColor: glyphColor)
    }
}

// MARK: - Crew Row List
//
// The rows of one Metadata crew section (Cast, Directors, …), built from AppKit views rather
// than as a ForEach of SearchableItemRow. Each row is a plate (fill, shadow and fading
// outline), an optional glyph, the name as a selectable label, and the token-search button
// — the same parts SearchableItemRow draws, to the point. A film change re-points the rows:
// a name is a string assignment, and a longer list adds rows to a pool that a shorter one
// leaves intact. The section header above stays SwiftUI.
//
// SwiftUI rows re-render even when nothing in them changes, and a film's crew lists run to 20 or 30 rows. The
// `rsb-crew-parity` harness scenario compares these rows with SearchableItemRow pixel for pixel, in light and dark.
struct CrewRowList: NSViewRepresentable {
    let items: [String]
    let field: SearchField
    let glyph: String?
    let glyphColor: Color

    func makeNSView(context: Context) -> CrewRowListView { CrewRowListView() }

    func updateNSView(_ view: CrewRowListView, context: Context) {
        let tint = NSColor(Color(glyphColor.resolve(in: context.environment)))
        view.update(items: items, field: field, glyph: glyph, glyphTint: tint)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CrewRowListView,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.bounds.width, height: nsView.totalHeight)
    }
}

/// CrewRowList's AppKit side: the row pool, laid out top to bottom.
final class CrewRowListView: NSView {
    private var rows: [CrewRowView] = []
    private var count = 0

    override var isFlipped: Bool { true }

    var totalHeight: CGFloat {
        count == 0 ? 0 : CGFloat(count) * CrewRowView.height + CGFloat(count - 1) * RSBHelpers.headerRowSpacing
    }

    func update(items: [String], field: SearchField, glyph: String?, glyphTint: NSColor) {
        while rows.count < items.count {
            let row = CrewRowView()
            rows.append(row)
            addSubview(row)
        }
        for (i, row) in rows.enumerated() {
            row.isHidden = i >= items.count
            guard i < items.count else { continue }
            row.configure(item: items[i], field: field, glyph: glyph, glyphTint: glyphTint)
        }
        if count != items.count {
            count = items.count
            invalidateIntrinsicContentSize()
        }
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: totalHeight) }

    /// The rows round their labels to the window's pixels, so a display of another scale needs
    /// them placed again.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        for row in rows { row.needsLayout = true }
    }

    override func layout() {
        super.layout()
        for (i, row) in rows.prefix(count).enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(i) * (CrewRowView.height + RSBHelpers.headerRowSpacing),
                               width: bounds.width, height: CrewRowView.height)
        }
    }
}

/// One crew row. Every measure is SearchableItemRow's, through `sidebarRowContainer` and
/// `fieldEdgeChrome()`; the constants come from RSBHelpers, the edge from `FieldEdgeLayers`.
final class CrewRowView: NSView {
    /// The taller of the label's line and the button, plus the plate's vertical padding —
    /// SearchableItemRow's HStack. The button counts at its alignment rectangle, as SwiftUI
    /// lays it out; its frame overhangs that for the bezel's shadow and focus ring.
    static let height: CGFloat = max(labelHeight, buttonAlignmentSize.height)
        + RSBHelpers.rowFontBackgroundVerticalPadding * 2

    /// One line of the row font: what SwiftUI's selectable Text is, as a text field.
    private static let labelHeight: CGFloat = {
        let field = NSTextField(labelWithString: "Xg")
        field.font = .systemFont(ofSize: RSBHelpers.rowFontSize)
        return field.intrinsicContentSize.height
    }()

    /// The cell's own size, unrounded: `fittingSize` rounds up to whole points (37 pt where
    /// SwiftUI's button is 36.5).
    private static let buttonFrameSize: NSSize = {
        let button = makeButton()
        return button.cell?.cellSize ?? button.fittingSize
    }()

    private static let buttonAlignmentSize: NSSize = {
        let button = makeButton()
        return button.alignmentRect(forFrame: NSRect(origin: .zero, size: buttonFrameSize)).size
    }()

    /// The magnifying glass at the small control font, cut to the width SwiftUI gives a
    /// symbol label: its alignment rectangle's (12.5 pt, against an image 13 pt wide), at
    /// the image's full height. Drawn from the left edge, where the alignment rectangle
    /// starts; nothing of the symbol lies in the half point this leaves off.
    private static let searchImage: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize(for: .small), weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")?
            .withSymbolConfiguration(config) else { return NSImage() }
        let size = NSSize(width: symbol.alignmentRect.width, height: symbol.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Search"
        return image
    }()

    /// SwiftUI's `.bordered` small button, as SwiftUI builds it: bezel style 28 (no public
    /// name in the SDK; `rsb-crew-parity` logs the style SwiftUI's own button carries) with
    /// the symbol at the small control font.
    private static func makeButton() -> NSButton {
        let button = NSButton(image: searchImage, target: nil, action: nil)
        button.title = ""
        button.imagePosition = .imageOnly
        button.bezelStyle = NSButton.BezelStyle(rawValue: 28) ?? .push
        button.controlSize = .small
        button.toolTip = "Perform a token-based search for this name"
        return button
    }

    private let edge = FieldEdgeLayers()
    private let glyphView = CrewGlyphView()
    private let label = NSTextField(labelWithString: "")
    private let button = CrewRowView.makeButton()

    private var item = ""
    private var field: SearchField = .cast
    private var glyph: String?
    private var glyphTint: NSColor = .secondaryLabelColor

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        if let layer { edge.install(in: layer) }

        addSubview(glyphView)

        label.font = .systemFont(ofSize: RSBHelpers.rowFontSize)
        label.textColor = .labelColor
        label.isSelectable = true
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)

        button.target = self
        button.action = #selector(search)
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(item: String, field: SearchField, glyph: String?, glyphTint: NSColor) {
        self.item = item
        self.field = field
        if label.stringValue != item {
            label.stringValue = item
            // The label is as wide as its text, so a new name needs a new frame.
            needsLayout = true
        }
        if glyph != self.glyph {
            self.glyph = glyph
            glyphView.image = glyph.flatMap(Self.glyphImage)
            glyphView.isHidden = glyph == nil
            needsLayout = true
        }
        if glyphTint != self.glyphTint {
            self.glyphTint = glyphTint
            glyphView.tint = glyphTint
        }
    }

    private static func glyphImage(_ name: String) -> NSImage? {
        let weight: NSFont.Weight = RSBHelpers.glyphWeight(for: name) == .semibold ? .semibold : .regular
        let config = NSImage.SymbolConfiguration(pointSize: RSBHelpers.glyphPointSize(for: name), weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    @objc private func search() {
        AppEventBus.shared.sendCommand(.activateTokenSearch(field: field, value: item))
    }

    override func layout() {
        super.layout()
        let b = bounds
        edge.layout(in: b)

        let pad = RSBHelpers.rowHorizontalPadding
        if let glyph {
            glyphView.frame = NSRect(x: RSBHelpers.glyphLeadingPadding + RSBHelpers.glyphHorizontalOffset(for: glyph),
                                     y: 0, width: RSBHelpers.glyphBoxWidth, height: RSBHelpers.singleLineRowHeight)
        }
        let leading = pad + (glyph == nil ? 0 : RSBHelpers.glyphGutterWidth)
        // The button's alignment rectangle ends at the plate's trailing padding, centered
        // vertically; its frame is placed around that.
        let align = Self.buttonAlignmentSize
        let alignRect = NSRect(x: b.width - pad - align.width, y: (b.height - align.height) / 2,
                               width: align.width, height: align.height)
        var buttonFrame = button.frame(forAlignmentRect: alignRect)
        buttonFrame.size = Self.buttonFrameSize
        button.frame = buttonFrame
        // SwiftUI's selectable Text is a text field 2 pt wider on each side than the text
        // (the field's own intrinsic width is the text's alone),
        // centered on the row and, as SwiftUI places it, on the window's pixels (the 15 pt line
        // in the 24 pt row centers on a half point, between two pixels at 1x); a truncated name
        // runs to the HStack's 6 pt gap.
        let available = max(0, alignRect.minX - 6 - leading)
        let height = Self.labelHeight
        let scale = unsafe window?.backingScaleFactor ?? 2
        let labelY = ((b.height - height) / 2 * scale).rounded(.toNearestOrAwayFromZero) / scale
        label.frame = NSRect(x: leading - 2, y: labelY,
                             width: min(label.intrinsicContentSize.width, available) + 4, height: height)
    }

    override func updateLayer() {
        super.updateLayer()
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        edge.applyColors(appearance: effectiveAppearance)
    }
}

/// A crew row's glyph, placed in its box exactly as SwiftUI places the Image in
/// SearchableItemRow. NSImageView centers differently and misplaces some symbols by half a pixel or more.
final class CrewGlyphView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var tint: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        // SwiftUI's placement, read off `rsb-crew-parity` captures of all seven crew symbols:
        // horizontally the alignment rectangle's width is centered, vertically the image's
        // full height, and the origin is rounded to the nearest device pixel.
        let size = image.size
        let align = image.alignmentRect
        let scale = unsafe window?.backingScaleFactor ?? 2
        func pixel(_ v: CGFloat) -> CGFloat { (v * scale).rounded(.toNearestOrAwayFromZero) / scale }
        let rect = NSRect(x: pixel((bounds.width - align.width) / 2) - align.minX,
                          y: pixel((bounds.height - size.height) / 2),
                          width: size.width, height: size.height)
        image.draw(in: rect)
        // The symbol is a template: replace what it drew with the tint, keeping its coverage.
        // (.sourceAtop would blend a translucent tint, such as .secondary, over the black.)
        tint.set()
        rect.fill(using: .sourceIn)
    }
}

// MARK: - Sidebar Text Abbreviation
//
// The shortened spellings `RSBHelpers.fittingValueRow` falls back to when a value would
// otherwise wrap. Kept here, apart from the row builder, because they are pure string
// rules with no view involvement — testable on their own, and extensible without touching
// layout code.
//
// Every rule returns `nil` when it changed nothing. That is the signal `fittingValueRow`
// uses to skip its measurement entirely, so a value with no applicable abbreviation costs
// exactly what it always did. It also means a caller never has to compare the two strings
// itself to decide whether offering an alternative is meaningful.
enum SidebarTextAbbreviation {

    // MARK: Time Units

    /// Shortens the unit words inside a value's TRAILING PARENTHETICAL — the relative-time
    /// clause produced by `timeAgo(from:)` and `timeDistanceFromNow(to:)` — leaving the
    /// date that precedes it untouched:
    ///
    ///     "November 04, 2025 (4 years 4 months ago)"
    ///       → "November 04, 2025 (4 yr. 4 mo. ago)"
    ///     "September 2026 (1 year 11 months away)"
    ///       → "September 2026 (1 yr. 11 mo. away)"
    ///
    /// Scoped to the parenthetical rather than applied across the whole string so the rule
    /// can never reach into a value's own prose, and so a future value that happens to
    /// contain the word "month" outside its time clause is unaffected.
    ///
    /// Only a unit word IMMEDIATELY PRECEDED BY A NUMBER is rewritten. Both formatters also
    /// emit prose forms — "Last week", "Less than a week ago", "Less than a month ago",
    /// "Today", "Yesterday" — and shortening a word inside those reads as a typo rather
    /// than as an abbreviation ("Last wk."). Those forms are also short enough that they
    /// cannot be what pushed a row onto a second line, so nothing is lost by excluding them.
    ///
    /// Days are deliberately not abbreviated. "N days away" is only produced for N < 7, so
    /// it is never the cause of an overflow, and there is no abbreviation for "days" that
    /// is both shorter and still readable.
    static func abbreviatingTimeUnits(in value: String) -> String? {
        // The parenthetical is the LAST "(...)" run and closes at the very end of the
        // string, which is exactly the shape both formatters produce. Anything else — no
        // parenthetical at all ("Ready for viewing", "Blacklisted", "Unknown date"), or a
        // stray parenthesis mid-string — leaves the value alone.
        guard value.hasSuffix(")"), let openIndex = value.lastIndex(of: "(") else { return nil }

        let clauseStart = value.index(after: openIndex)
        let clauseEnd = value.index(before: value.endIndex)
        guard clauseStart < clauseEnd else { return nil }

        let clause = String(value[clauseStart..<clauseEnd])
        guard let shortened = Self.shorteningUnits(in: clause) else { return nil }

        return String(value[value.startIndex...openIndex]) + shortened + ")"
    }

    /// Rewrites every "<number> <unit>" pair in `clause`, or returns nil if there are none.
    ///
    /// Built by walking the matches forward and appending — the unmatched text before each
    /// match, then the rewritten pair — rather than by splicing into a copy. Splicing would
    /// mean carrying ranges from one String instance over to another, which is exactly the
    /// index-domain confusion this shape has no way to get wrong.
    private static func shorteningUnits(in clause: String) -> String? {
        guard let regex = unitPattern else { return nil }
        let matches = regex.matches(in: clause, range: NSRange(clause.startIndex..., in: clause))
        guard !matches.isEmpty else { return nil }

        var result = ""
        var cursor = clause.startIndex
        for match in matches {
            guard let fullRange = Range(match.range, in: clause),
                  let countRange = Range(match.range(at: 1), in: clause),
                  let unitRange = Range(match.range(at: 2), in: clause),
                  let abbreviation = unitAbbreviations[String(clause[unitRange])]
            else { continue }
            result += clause[cursor..<fullRange.lowerBound]
            result += "\(clause[countRange]) \(abbreviation)"
            cursor = fullRange.upperBound
        }
        result += clause[cursor...]

        return result == clause ? nil : result
    }

    /// The "<number> <unit>" pattern `shorteningUnits(in:)` rewrites, compiled once.
    ///
    /// Built once, not per call. The two call sites are view properties, so the function would otherwise run on
    /// every body pass. Compiling the pattern is the expensive part. `NSRegularExpression` is immutable and
    /// thread-safe once built, so one shared instance is safe.
    ///
    /// Optional because the initializer throws. The literal pattern always compiles, so this is never nil in
    /// practice. A nil would mean there is nothing to abbreviate.
    private static let unitPattern: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"(\d+)\s+(year|month|week)s?\b"#)

    /// The shortened spelling for each abbreviated unit. "day" is deliberately absent —
    /// see the note on `abbreviatingTimeUnits(in:)`.
    private static let unitAbbreviations: [String: String] = [
        "year": "yr.", "month": "mo.", "week": "wk."
    ]

    // MARK: Month Names

    /// Shortens a full month name that introduces a date:
    ///
    ///     "September 2, 2026 (Less than a week ago)"
    ///       → "Sep. 2, 2026 (Less than a week ago)"
    ///     "September 2029 (3 yr. 7 mo. away)"
    ///       → "Sep. 2029 (3 yr. 7 mo. away)"
    ///
    /// Matches only a month name FOLLOWED BY A SPACE AND A DIGIT, which is the shape both
    /// producers emit (`formatDateWithTimeAgo`'s "Month DD, YYYY" and `monthYearLabel`'s
    /// "Month YYYY"). That lookahead is what keeps the rule out of a value's prose: a film
    /// or studio named "March" is not followed by a number and is left alone.
    ///
    /// "May" is listed with itself so the table states all twelve months. A value whose only month is May
    /// rewrites to itself, and the `result == value` check below reports that as nothing to shorten.
    static func abbreviatingMonthNames(in value: String) -> String? {
        var result = value
        for (month, abbreviation) in monthAbbreviations {
            result = result.replacingOccurrences(of: "\\b\(month)\\b(?= \\d)",
                                                 with: abbreviation,
                                                 options: .regularExpression)
        }
        return result == value ? nil : result
    }

    private static let monthAbbreviations: [(String, String)] = [
        ("January", "Jan."), ("February", "Feb."), ("March", "Mar."), ("April", "Apr."),
        ("May", "May"), ("June", "Jun."), ("July", "Jul."), ("August", "Aug."),
        ("September", "Sep."), ("October", "Oct."), ("November", "Nov."), ("December", "Dec.")
    ]

    // MARK: Ladders

    /// The shortened spellings of a "date plus relative-time parenthetical" value, in the order `fittingValueRow`
    /// tries them. Each is a further step from the full spelling:
    ///
    ///   1. Units only. The parenthetical is the lesser half, so it gives ground first: "November 04, 2021 (4 yr. 4 mo. ago)".
    ///   2. Month only. Used when there were no units to shorten, such as the prose forms ("Less than a week ago",
    ///      "Today"), so the date gives instead.
    ///   3. Both.
    ///
    /// Steps that change nothing are omitted, and duplicates are dropped. A value with no applicable rule yields an
    /// empty array and costs no measurement. The order is by decreasing informativeness, not width. `ViewThatFits`
    /// takes the first candidate that fits, so the ladder is a preference list, and a wider step later in it never wins.
    static func dateValueLadder(for value: String) -> [String] {
        let units = abbreviatingTimeUnits(in: value)
        let month = abbreviatingMonthNames(in: value)
        let both = units.flatMap { abbreviatingMonthNames(in: $0) }

        var ladder: [String] = []
        for candidate in [units, month, both] {
            guard let candidate, candidate != value, !ladder.contains(candidate) else { continue }
            ladder.append(candidate)
        }
        return ladder
    }

    // MARK: Source for Viewing

    /// The abbreviation ladder for the Source for Viewing value, from the full value and
    /// the compacted spellings `RSBHelpers.sourceDisplay` supplies alongside it (each nil
    /// when there is none). Three words can be shortened, each independently of the
    /// others:
    ///
    ///   • "remastered" → "rem.",
    ///   • the origin demonym → its compact form ("Australian" → "AU"),
    ///   • the studio shorthand → its abbreviation ("Universal" → "Uni").
    ///
    /// The ladder is every combination of them, ordered by how much it gives up:
    /// the three single-word steps first, then the three pairs, then all three. That order
    /// is what makes `ViewThatFits` — which takes the first candidate that fits — give up
    /// the least it can: any one-word change is preferred to any two, and any two to all
    /// three. Within a tier the order is remastered, origin, studio, so the proper names
    /// are the last to go. Steps that would change nothing, or that duplicate an earlier
    /// step, are dropped, so a value with none of the three words offers no candidates at
    /// all and pays for no measurement. Caps at `RSBHelpers.maxAbbreviationCandidates`,
    /// which is sized to hold the whole ladder.
    static func sourceValueLadder(full value: String,
                                  originAbbreviated: String?,
                                  studioAbbreviated: String? = nil,
                                  originAndStudioAbbreviated: String? = nil) -> [String] {
        let remastered = abbreviatingRemastered(in: value)
        let remasteredOrigin = originAbbreviated.flatMap { abbreviatingRemastered(in: $0) }
        let remasteredStudio = studioAbbreviated.flatMap { abbreviatingRemastered(in: $0) }
        let all = originAndStudioAbbreviated.flatMap { abbreviatingRemastered(in: $0) }

        var ladder: [String] = []
        for candidate in [remastered, originAbbreviated, studioAbbreviated,
                          remasteredOrigin, remasteredStudio, originAndStudioAbbreviated,
                          all] {
            guard let candidate, candidate != value, !ladder.contains(candidate) else { continue }
            ladder.append(candidate)
        }
        return ladder
    }

    // MARK: Remastered

    /// Shortens the word "remastered" in a source value, preserving its capitalization:
    ///
    ///     "Purchased remastered Blu-ray disc" → "Purchased rem. Blu-ray disc"
    ///     "Remastered Blu-ray disc rip"       → "Rem. Blu-ray disc rip"
    ///
    /// Both cases are handled because `RSBHelpers.sourceDisplay` writes the word inline in
    /// lower case but capitalizes it when it lands first in the value (see the encoding
    /// notes above `sourceDisplay`). Returns `nil` for any value that does not contain the
    /// word, which is the common case and skips the measurement entirely.
    static func abbreviatingRemastered(in value: String) -> String? {
        // Both spellings sourceDisplay can produce, each rewritten to the matching
        // short form. The two replacements are case-SENSITIVE on purpose: which one
        // applies is exactly what decides whether the abbreviation comes back
        // capitalized, so a single case-insensitive pass could not preserve it.
        let shortened = value
            .replacingOccurrences(of: #"\bremastered\b"#, with: "rem.", options: .regularExpression)
            .replacingOccurrences(of: #"\bRemastered\b"#, with: "Rem.", options: .regularExpression)

        // Report "nothing to shorten" by comparing the result, not by testing for the word first. A case-insensitive
        // presence check with case-sensitive replacements would disagree on other spellings, such as an all-caps
        // "REMASTERED", which matches neither replacement and would come back as an identical "abbreviation".
        return shortened == value ? nil : shortened
    }
}

// MARK: - Top-Pinned Layout

/// Keeps the root of a sidebar tab's hosted tree the same size during an animated update
/// that changes the tab's height (the Releases tab's purchase filter, the Details tab's
/// table expansion). Wrap the tab's whole content in it, inside SidebarScrollView.
///
/// When content grows taller in an animated update and the root of the hosted tree takes the
/// new height in that same pass, the whole stack, picker included, starts partway down and
/// slides up over the animation. The animated cards are interpolated against the root's
/// center, which has moved by half the growth. A shrink does not, since the root keeps its
/// size through the animated pass and the hosting view shrinks in a later pass.
///
/// So the root reports exactly the height it is offered, and the content, placed at the
/// top at its own natural height, may overhang it briefly. Under the unspecified height
/// NSHostingView measures with, the natural height passes through, so the hosting view
/// still grows to fit — just in the following pass, without moving anything on screen.
/// Top placement also keeps a shorter stack at the top instead of centered.
struct RSBTopPinnedLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // A plain pass-through under the profile flag, to measure what pinning costs.
        if RSBProfileFlags.noTopPinnedLayout { return subviews.first?.sizeThatFits(proposal) ?? .zero }
        let ideal = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? ideal.height
        return CGSize(width: proposal.width ?? ideal.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if RSBProfileFlags.noTopPinnedLayout {
            subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
            return
        }
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
