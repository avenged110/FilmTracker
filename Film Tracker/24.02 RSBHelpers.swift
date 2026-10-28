// MARK: - RSBHelpers.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Collection of generic UI-forming components and formatting helpers for use
// throughout the right sidebar's modules. Also contains QueryHandoff, a
// stateless helper that normalizes film titles and opens external Web queries,
// and the "Releases Tab: Shared Derivations" section — the single definition of
// everything the Releases tab's summary table (24.21) and its release cards
// (24.20) must say identically about the same release.

import SwiftUI
import AppKit

// MARK: - Conditional Text Selection
extension View {
    /// Enables or disables text selection based on a runtime flag.
    /// Marked `nonisolated` so it can be invoked from non-actor-isolated
    /// contexts (e.g. static helper builders like `RSBHelpers.textSection`).
    /// The underlying `.textSelection(_:)` modifiers attach to a `View` and
    /// are exercised by SwiftUI's rendering pipeline on the main actor at
    /// draw time; the builder chain itself does not require main-actor
    /// isolation to construct.
    @ViewBuilder
    nonisolated func conditionalTextSelection(enabled: Bool) -> some View {
        if enabled {
            self.textSelection(.enabled)
        } else {
            self.textSelection(.disabled)
        }
    }

    /// Applies the sidebar's standard "value row" chrome: full available width,
    /// leading-aligned, inset by the shared vertical/horizontal padding, on the
    /// rounded `controlBackgroundColor` plate used by every value row in the
    /// right sidebar.
    ///
    /// This exact chain was previously written out by hand in eight places
    /// (`RSBHelpers.textSection`, `RSBHelpers.searchableItemSection`'s
    /// placeholder row, `SearchableItemRow`, WatchDetails' rotation / duration /
    /// source rows, and RTabNotes' frames and legend blocks). Centralizing it
    /// means a change to the plate's corner radius, inset, or fill is made once.
    ///
    /// Callers whose content is wrapping text apply
    /// `.fixedSize(horizontal: false, vertical: true)` *before* this modifier so
    /// the row grows vertically to fit — identical in effect to the previous
    /// frame-then-fixedSize ordering, since the width proposed to the text is the
    /// same either way.
    ///
    /// Marked `nonisolated` for the same reason as `conditionalTextSelection`
    /// above: the builder chain is constructed without needing main-actor
    /// isolation, and is exercised by SwiftUI on the main actor at draw time.
    /// - Parameters:
    ///   - glyph: An SF Symbol drawn in the row's leading margin, OUTSIDE the content: the
    ///     content is inset by `RSBHelpers.glyphGutterWidth` and the symbol is overlaid into
    ///     the space that opens up, centered in the margin horizontally and against the
    ///     FIRST line of text vertically — see `RSBHelpers.singleLineRowHeight`. `nil`
    ///     insets nothing and overlays nothing, rendering exactly what this
    ///     did before the parameter existed. See `RSBHelpers.glyphLeadingMargin`.
    ///   - glyphColor: Tint for the symbol. Callers pass whatever they want the glyph to
    ///     take — usually their content's own color, so the glyph tracks its row, including a
    ///     placeholder row's tertiary gray. (`valueRow` and `textSection` take it as an
    ///     optional, where `nil` means "use the row's own text color".)
    ///   - trailingInset: Space between the content and the plate's trailing fill edge.
    ///     Defaults to `RSBHelpers.rowHorizontalPadding`, matching the leading side; a caller
    ///     tightens it only to buy a specific value room it would otherwise wrap for. The
    ///     fill itself is unaffected — it spans the full column either way — so this is
    ///     invisible on any value that does not reach the edge.
    ///
    /// The inset is applied HERE rather than by callers because a caller that measures its
    /// own content must have that measurement see the reduced width: `fittingValueRow` runs
    /// a `ViewThatFits` inside this, and inset applied outside it is exactly what narrows the
    /// proposal its candidates are measured against.
    nonisolated func sidebarRowContainer(glyph: String? = nil,
                                         glyphColor: Color = .secondary,
                                         trailingInset: CGFloat = RSBHelpers.rowHorizontalPadding) -> some View {
        self
            .padding(.leading, glyph == nil ? 0 : RSBHelpers.glyphGutterWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, RSBHelpers.rowFontBackgroundVerticalPadding)
            .padding(.leading, RSBHelpers.rowHorizontalPadding)
            .padding(.trailing, trailingInset)
            .sidebarFieldEdgeChrome()
            .overlay(alignment: .topLeading) {
                if let glyph {
                    RSBHelpers.glyphImage(glyph)
                        .font(.system(size: RSBHelpers.glyphPointSize(for: glyph),
                                      weight: RSBHelpers.glyphWeight(for: glyph)))
                        .foregroundStyle(glyphColor)
                        // Top-aligned in a box exactly one single-line row tall, so the
                        // glyph sits where it would on a one-line row and stays there
                        // when the text wraps, rather than drifting down to the center
                        // of the taller plate.
                        .frame(width: RSBHelpers.glyphBoxWidth,
                               height: RSBHelpers.singleLineRowHeight)
                        .offset(x: RSBHelpers.glyphHorizontalOffset(for: glyph))
                        .padding(.leading, RSBHelpers.glyphLeadingPadding)
                }
            }
    }

    /// The plate fill, outline, and drop shadow the sheet's reorderable tables wear
    /// (`listContainerChrome`), drawn from the same `FieldEdgeTreatment` constants.
    ///
    /// The shadow is cast by the background SHAPE alone, not by the composited view. A
    /// `.shadow` on the whole view makes SwiftUI render the row's text into an offscreen
    /// layer and blur it every draw; a shadow on a solid rounded rect is a single-shape
    /// blur Core Animation handles cheaply, and the text on top is untouched. Because the
    /// fill is opaque the visible result is identical.
    nonisolated func sidebarFieldEdgeChrome(fill: Color = Color(NSColor.controlBackgroundColor)) -> some View {
        let shape = RoundedRectangle(cornerRadius: FieldEdgeTreatment.cornerRadius, style: .continuous)
        return self
            .background(
                shape
                    .fill(fill)
                    .shadow(color: .black.opacity(FieldEdgeTreatment.shadowOpacity),
                            radius: FieldEdgeTreatment.shadowRadius,
                            x: 0,
                            y: FieldEdgeTreatment.shadowOffsetY))
            .overlay(
                shape.strokeBorder(FieldEdgeTreatment.borderGradient,
                                   lineWidth: FieldEdgeTreatment.borderWidth)
                    .allowsHitTesting(false))
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

    /// Explicit-placeholder overload used when the caller has already resolved both
    /// the display string and its placeholder status (e.g. values like "Blacklisted"
    /// or "None recorded" that are non-empty yet should render with placeholder
    /// styling). Centralizes the shared VStack/Text/rounded-background layout that
    /// was previously duplicated across several per-section builders in WatchDetails,
    /// RTabNotes, etc.
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

    /// The standard value row — the rounded plate a sidebar field's content sits on,
    /// without a header above it. `textSection` is exactly `sectionHeader` + this.
    ///
    /// Private, because that is the only thing that uses it. It was previously exposed
    /// for "sections that stack SEVERAL rows under a single header" — WatchDetails'
    /// rotation and source fields — but those fields moved to `fittingValueRow` for
    /// their primary value and `annotationRow` for their subordinate notes, and neither
    /// they nor anything else has called this since. Narrowing the access level retires
    /// a sharing contract with no participants, and lets the compiler enforce that
    /// rather than leaving a doc comment to assert it.
    @ViewBuilder
    private static func valueRow(
        _ displayValue: String,
        isPlaceholder: Bool,
        glyph: String? = nil,
        glyphColor: Color? = nil,
        trailingInset: CGFloat = RSBHelpers.rowHorizontalPadding,
        rowFontSize: CGFloat = RSBHelpers.rowFontSize
    ) -> some View {
        // Row with adaptive, rounded background. The glyph takes the row's own resolved
        // color, so a placeholder's tertiary gray reaches the symbol without the caller
        // restating the rule.
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

    /// A value row that shortens its own text, but only when the full spelling would
    /// otherwise wrap to a second line.
    ///
    /// The measurement is `ViewThatFits`, deliberately, rather than a hand-rolled width
    /// prediction. Predicting the wrap means mirroring three things exactly — the font
    /// SwiftUI resolves for `.system(size:)`, the full padding chain down to the width
    /// actually proposed to the text, and CoreText's line-breaking behavior. Each is a
    /// silent coupling: change `sidebarRowContainer`'s inset or pass a different
    /// `rowFontSize` at one call site and a predictor does not fail loudly, it simply
    /// starts abbreviating strings that would have fit (or leaving strings that then wrap
    /// anyway, which is the worst of both). `ViewThatFits` measures the real candidate
    /// views with the real resolved font at the real proposed width, so it cannot drift.
    ///
    /// Three candidates, in priority order:
    ///
    ///   1. The full text on one line. Preferred whenever it fits — abbreviation is a cost,
    ///      paid only when it buys something.
    ///   2. The abbreviated text on one line. Reached only when 1 does not fit.
    ///   3. The FULL text, wrapping. `ViewThatFits` falls back to its last candidate when
    ///      none fit, so this is what renders when even the abbreviation needs two lines.
    ///      Full rather than abbreviated on purpose: the abbreviation exists to buy a
    ///      single line, so once a second line is unavoidable it has bought nothing and the
    ///      more informative spelling should win. It also guarantees the row never
    ///      truncates — the fallback wraps exactly as `valueRow` always has.
    ///
    /// `.lineLimit(1)` on the first two candidates is load-bearing: `ViewThatFits` measures
    /// each candidate's ideal size, and a `Text` that is free to wrap reports an ideal size
    /// that always "fits", so candidate 1 would win unconditionally without it. For the same
    /// reason the candidates must NOT carry `.fixedSize(horizontal: false, vertical: true)`
    /// — that is the modifier that permits vertical growth, and it belongs only on the
    /// wrapping fallback.
    ///
    /// `sidebarRowContainer`'s `.frame(maxWidth: .infinity)` stays OUTSIDE the
    /// `ViewThatFits`, which is what makes the measurement meaningful: applied inside, every
    /// candidate would claim the full width and the first would always be chosen.
    ///
    /// The number of ladder steps the row can offer. Fixed because each must be spelled out
    /// as its own `ViewThatFits` child (see the body). Seven covers every ladder in the module
    /// — `sourceValueLadder` produces at most seven (three words, every combination), and
    /// `dateValueLadder` at most three — and a longer array is simply not consulted past the
    /// seventh, which degrades to "abbreviates less than it could", never to a wrong or
    /// wrapped row.
    ///
    /// `fittingValueRow` reads this to bound the ladder it is handed, rather than leaving the
    /// number stated here and enforced only by how many slots happen to be written out below.
    /// Those two were previously independent: this constant had no reader at all, so it
    /// documented a limit that nothing consulted and could have disagreed with the body
    /// silently. It is still not a slot count the body can derive — each candidate must be a
    /// separate literal child — so adding a slot means bumping this and writing the slot;
    /// what the read buys is that the two can no longer say different things about how many
    /// candidates a caller's array may contribute.
    static let maxAbbreviationCandidates = 7

    /// Cost is one extra measurement pass per row. The sidebar renders one film at a time,
    /// so this is not a measurable expense.
    ///
    /// - Parameters:
    ///   - full: The complete text, already carrying its own font-independent styling
    ///     (color, any inline image attachment). Callers build this as `Text` so a composed
    ///     row — the source row's disc glyph plus its value — can use this path too.
    ///   - abbreviations: Shortened spellings, in the order they should be tried — each a
    ///     further step from `full`. An EMPTY array skips `ViewThatFits` entirely and renders
    ///     exactly what `valueRow` would, so a value with nothing to shorten pays nothing.
    ///     At most `maxAbbreviationCandidates` are offered; see that constant for why the
    ///     count is fixed rather than arbitrary.
    ///   - glyph: An SF Symbol for the row's leading margin, drawn outside the text by
    ///     `sidebarRowContainer` — see there, and note that the gutter narrows what the
    ///     candidates below are measured against, which is the correct behavior: a glyphed
    ///     row genuinely has less room for its value and should abbreviate sooner.
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
        // Bounded here so the body below and `maxAbbreviationCandidates` cannot disagree
        // about how many steps are actually offered. A caller passing more simply has the
        // surplus ignored — the documented degradation ("abbreviates less than it could"),
        // now stated once instead of being an emergent property of the slot count.
        let offered = Array(abbreviations.prefix(Self.maxAbbreviationCandidates))
        Group {
            if offered.isEmpty {
                full.font(.system(size: rowFontSize))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Each candidate is written out as its own direct child of the ViewThatFits
                // builder, deliberately. A ForEach over the array would read as the natural
                // spelling and be wrong: ViewThatFits measures its builder's CHILDREN, and a
                // ForEach is a single child containing many views — the whole ladder would be
                // measured, and chosen or rejected, as one unit. Hence the fixed slots, and
                // hence maxAbbreviationCandidates.
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

    /// A subordinate annotation row: identical plate chrome to `valueRow`, carrying a
    /// note ABOUT the value above it rather than a value of its own. Always stacked
    /// directly beneath its parent row, inside the parent's section and under the
    /// parent's header.
    ///
    /// Defaults to `.secondary`, overridable for the one note that is not subordinate in
    /// emphasis — "Region B locked" describes a hard playback restriction on the disc
    /// named above it and stays `.primary`.
    ///
    /// Not italicized. These notes were italic while they were still appended inline to
    /// their parent value, where the slant was what separated the note from the value it
    /// was spliced onto; sitting on its own plate, a note is already unmistakably
    /// separate, and the italics only cost legibility at this size.
    ///
    /// An optional `glyph` is drawn in a fixed-width gutter at the row's leading edge,
    /// OUTSIDE the text — the text is inset by exactly the gutter's width and the symbol is
    /// overlaid into the space that opens up.
    ///
    /// This is deliberately not the inline `Text(Image(...))` attachment the source row uses.
    /// An attachment is part of the text run, so its own width sets where the text starts and
    /// its own height can raise the line's ascent: symbols of different sizes gave these rows
    /// different text offsets and different heights, and normalizing that by compositing every
    /// symbol onto a common canvas moved the glyphs off their natural position. A gutter fixes
    /// both without touching the symbols: the inset is a constant, so the text starts in the
    /// same place whatever the glyph is, and the overlay is sized by the row rather than
    /// contributing to it, so no glyph can make a row taller.
    ///
    /// The symbol is centered in the whole leading MARGIN horizontally — the full run from
    /// the plate's fill edge to where the text starts, `glyphLeadingMargin` — and vertically
    /// against the first line of text, so on a wrapped note it stays exactly where a
    /// one-line note would put it rather than sliding down to the plate's center. `color`
    /// tints the glyph and the text together.
    ///
    /// Centering on the margin rather than on the gutter alone is the distinction that makes
    /// glyphs of different widths look placed the same. The frame is what centers them, and a
    /// frame centers whatever it contains regardless of that content's intrinsic width, so a
    /// narrow symbol and a wide one share one center point. Inset the overlay by the plate's
    /// padding first — as if the glyph were text — and the center moves to the middle of the
    /// gutter instead, which is off-center for the space the glyph actually occupies: it
    /// crowds the text on a wide symbol and strands a narrow one too far from it.
    ///
    /// See `glyphLeadingMargin` for how the margin is sized so that centering also leaves
    /// every symbol clear of both the fill's edge and the text.
    ///
    /// The one thing the gutter gives up relative to an attachment is that a wrapped second
    /// line now aligns under the first line's text rather than under the glyph. That is the
    /// hanging-indent shape these subordinate rows want anyway.
    ///
    /// Passing `nil` applies no inset and no overlay, rendering exactly what this did before
    /// the parameter existed.
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

    /// Point size for a row's glyph — a little smaller than the row's text, which is what buys
    /// the symbols room inside `glyphBoxWidth`. SF Symbols quantize to whole points, so nudging
    /// this changes the rendered widths in steps rather than smoothly.
    static let glyphPointSize: CGFloat = 10.5

    /// Per-symbol point sizes, for symbols the standard size does not suit. The box is sized
    /// to the widest symbol at `glyphPointSize`, so anything that fits within
    /// `glyphBoxWidth` at its chosen size is free to differ — the constraint is width, not
    /// uniform scale.
    ///
    /// `scissors` is 17pt wide at 10.5 against a 16pt box — the only symbol in use that
    /// overflows, and only by a point. At 9.5 it is 15. Shrinking the outlier is the cheaper
    /// correction: widening the box to admit it would push the text inset out on EVERY row,
    /// for one glyph's sake.
    ///
    /// The rest go the other way, up to `rowFontSize`.
    ///
    /// `opticaldisc.fill` is a restoration rather than a judgment. It is the one symbol here
    /// that predates the gutter: the "Source for Viewing" row drew it inline at the row's own
    /// font size long before the module had a glyph vocabulary, and moving that row into the
    /// gutter silently adopted the smaller standard size for it. Pinning it to `rowFontSize`
    /// keeps it at the size it has always rendered at. (The inline path itself is gone — that
    /// row now uses the gutter in every state of every preference.)
    ///
    /// The two hourglasses are a judgment: both are naturally narrow for their point size
    /// (10pt and 12pt at 12, against a 16pt box), so at the standard size they read as
    /// noticeably smaller than their neighbors rather than merely narrower. Sizing them up
    /// restores the subjective match. They are listed separately rather than matched by
    /// prefix — an override is a per-symbol decision, and a future `hourglass.*` variant
    /// should have to be looked at rather than inherit this one.
    ///
    /// Every entry here is still bounded by the box: at 12pt `opticaldisc.fill` is 14pt wide,
    /// `hourglass.and.lock` 12, and `hourglass` 10 — all inside 16.
    private static let glyphPointSizeOverrides: [String: CGFloat] = [
        "scissors": 9.5,
        "eye": 9.5,
        "calendar": rowFontSize,
        "hourglass": rowFontSize,
        "hourglass.and.lock": rowFontSize,
        "opticaldisc.fill": rowFontSize
    ]

    /// The point size a given symbol renders at: its override if it has one, else the standard.
    static func glyphPointSize(for systemName: String) -> CGFloat {
        glyphPointSizeOverrides[systemName] ?? glyphPointSize
    }

    /// Per-symbol stroke weights. `.regular` unless listed.
    ///
    /// `checkmark` and `xmark` are the two bare strokes in the vocabulary — no enclosing
    /// shape, no fill — so at the standard weight they carry visibly less ink than the filled
    /// and circled symbols they sit among and read as fainter rather than as lighter-weight.
    /// Thickening them evens out the apparent density.
    ///
    /// Weight changes width, so an entry here is bounded by `glyphBoxWidth` exactly as a point
    /// size is. Neither of these approaches it: at `glyphPointSize` semibold, `checkmark` is
    /// 13pt wide and `xmark` 11, against a 16pt box.
    private static let glyphWeightOverrides: [String: Font.Weight] = [
        "questionmark": .semibold,
        "checkmark": .semibold,
        "xmark": .semibold,
        "deskclock": .semibold,
        "timer": .semibold,
        "forward.frame": .semibold
    ]

    /// Glyphs resolved from Apple's private symbol set rather than the public one. A caller
    /// names one through `privateGlyph(_:fallback:)`, which only hands the private name back
    /// when it actually resolves on this system. Access lives in `PrivateSymbol`
    /// (GlobalUtilities); this file only styles the result for the gutter.
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

    /// Per-symbol horizontal nudges, applied after centering. Optical corrections only: a
    /// symbol whose visual weight sits off its geometric center reads as mis-aligned when it
    /// is in fact centered exactly, and no amount of measuring fixes that — the eye centers
    /// on mass, not on bounding box.
    ///
    /// `cart.fill.badge.questionmark` carries its badge up and to the right, which pulls its
    /// apparent center that way; a point to the left settles it against its neighbors.
    ///
    /// Applied with `.offset`, so this shifts the drawn symbol without moving the box, the
    /// gutter, or the text. A nudge here can therefore never affect layout — which is also
    /// why it is bounded by taste rather than by `glyphBoxWidth`: a large enough value would
    /// happily push a symbol outside its box.
    private static let glyphHorizontalOffsets: [String: CGFloat] = [
        "cart.fill.badge.questionmark": -1
    ]

    /// The horizontal nudge a given symbol is drawn with; zero for anything unlisted.
    static func glyphHorizontalOffset(for systemName: String) -> CGFloat {
        glyphHorizontalOffsets[systemName] ?? 0
    }

    /// The symbol marking a Film Queue membership, wherever the sidebar states one.
    ///
    /// Two modules say it, one tab apart: WatchDetails' "In the "<Section>" Queue"
    /// annotation row under the rotation countdown, and ListTable's queue rows in the List
    /// Membership table. They are the same mark meaning the same thing, and ListTable
    /// already reaches into `glyphPointSize(for:)` so its inline attachment renders at the
    /// size the gutter draws this symbol at — but the NAME itself was written out three
    /// times across the two files, with a comment on each asking that they be kept
    /// matched. Naming it once is what makes that structural: a change to the symbol
    /// cannot now move one surface without the other.
    ///
    /// It is deliberately here rather than on either module: neither owns the other, and
    /// this is the file both already share their row vocabulary through.
    static let queueMembershipGlyph = "text.line.first.and.arrowtriangle.forward"

    /// The fixed box every glyph is centered in, sized to the widest symbol in use at
    /// `glyphPointSize` — 16pt (`cart.fill.badge.questionmark` and the queue arrow; the rest
    /// run 9–15). Centering happens inside THIS, not inside the whole margin, which is what
    /// lets the space on either side of the box be set independently below.
    ///
    /// A symbol wider than this would push its own row's text; that is what
    /// `glyphPointSizeOverrides` exists to prevent.
    static let glyphBoxWidth: CGFloat = 16

    /// Space between the plate's fill edge and the glyph box.
    static let glyphLeadingPadding: CGFloat = 8

    /// The height of a value row whose text occupies one line: the row font's line height
    /// plus the plate's vertical padding on both sides. The glyph overlay is boxed to
    /// this height and top-aligned, which is what pins it against the first line of a
    /// wrapped row — with no height it would center on the whole plate and move down as
    /// the text grew.
    ///
    /// `NSLayoutManager.defaultLineHeight(for:)` is used rather than the font's own
    /// ascender/descender/leading sum because it is the rounded-up line height the text
    /// system actually lays out with, and it matches what SwiftUI's `Text` reports for a
    /// single line at this size (15pt at 12pt system, where the raw sum is 14.13). Rows
    /// drawn at a font size other than `rowFontSize` do not carry a glyph.
    static let singleLineRowHeight: CGFloat =
        NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: rowFontSize))
        + rowFontBackgroundVerticalPadding * 2

    /// Space between the glyph box and the text. Independent of the leading padding on
    /// purpose: a glyph reads as belonging to the text beside it, so a little less room on
    /// that side than against the plate's edge groups the two without crowding them.
    static let glyphTrailingPadding: CGFloat = 6

    /// The distance from the plate's fill edge to the text's leading edge on a glyphed row —
    /// the leading padding, the glyph box, and the trailing padding, in that order.
    ///
    /// Derived rather than set, so the three parts always compose to exactly the inset the
    /// text is given and no glyph placement can disagree with where the text starts. Tune the
    /// three constants above; this follows.
    ///
    /// Centering happens within `glyphBoxWidth`, so symbols of different widths still share
    /// one center — what changes here is that the space around that box need not be
    /// symmetrical. Every glyph therefore sits `glyphLeadingPadding` from the fill's edge and
    /// `glyphTrailingPadding` from the text, in the sense that the BOX does; a symbol narrower
    /// than the box gains the difference on both sides equally.
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
    /// This was the module's only glyph mechanism, shared by the "Source for Viewing" row and
    /// ListTable. The sidebar's own rows have since moved to the fixed-width gutter that
    /// `sidebarRowContainer(glyph:)` draws — an attachment's width and height vary with the
    /// symbol, which moved the text and changed row heights — leaving ListTable as the sole
    /// caller. It is kept because ListTable's glyph sits inside a table cell rather than on a
    /// sidebar plate, which is not a row `sidebarRowContainer` builds.
    /// - Parameter pointSize: Size for the attachment alone. `nil` lets it inherit the font
    ///   of whatever renders the returned `Text`, which is what an inline attachment does by
    ///   default and what this always did. Pass a size to hold the glyph to a fixed scale
    ///   independent of its surrounding text — `RSBHelpers.glyphPointSize(for:)` gives the
    ///   same scale the gutter draws that symbol at, so an inline glyph can be made to match
    ///   its gutter-drawn twin elsewhere in the sidebar.
    ///
    ///   The size lands on the attachment's own run only. Concatenated `Text` runs each keep
    ///   their own font, so the label beside it is untouched.
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
    /// deliberately stay separate builders; what they share is that neither should be
    /// spelled out by hand any more.
    ///
    /// This exact three-modifier chain was previously written out at six sites across
    /// five files — CalendarTable, ListTable, Synopsis, Metadata's own `moduleHeader`,
    /// RTabReleases' `allReleasesHeader`, and DiscReleasesTable's `.standard` layout —
    /// with the last of those carrying a comment naming the other four and asking that
    /// they be kept in step. Centralizing removes both the drift risk and the need for
    /// that pointer.
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

    /// The sidebar's standard section-header label. Renders nothing at all for an
    /// empty title, exactly as the inline `if !title.isEmpty` guards this replaces
    /// did — callers such as `Synopsis` deliberately pass `""` when the enclosing
    /// module header is sufficient. Shared by `textSection`,
    /// `searchableItemSection`, WatchDetails' custom rows, and RTabNotes' frames
    /// and legend blocks, all of which previously repeated this styling verbatim.
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

    // Convert a duration in milliseconds into an abbreviated format like "2 hr. 15 min."
    // Used when two duration values must share a single line (e.g. edited + original).
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
    // Primary ISO8601 parser for full timestamps (e.g., lastModified). Private, like
    // the fallback parser below it: both exist solely to serve formatFullTimestamp(_:)
    // in this file, and neither is read anywhere else in the project.
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

    // "Month Day, Year, at HH:MM AM/PM" for full timestamps (such as the "lastModified" field).
    //
    // Private and @MainActor for the same reason as the two parsers above, and stated the
    // same way: this formatter exists solely to serve formatFullTimestamp(_:) — itself
    // @MainActor — and is read nowhere else in the project. Leaving it internal and
    // nonisolated left a mutable, non-Sendable Foundation object reachable from any
    // isolation domain, an invariant that held only by convention while its two siblings
    // enforced theirs.
    @MainActor
    private static let fullTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.calendar = AppCalendar.gregorian  // .current alone carries the system calendar
        formatter.timeZone = .current
        formatter.dateFormat = "MMMM d, yyyy, 'at' h:mm a"
        return formatter
    }()

    // Formats a full ISO8601 timestamp string into "Month Day, Year, HH:MM AM/PM"
    // in the user's current locale/timezone. On parsing failure, fall back to trying
    // a non-fractional-seconds parser, then try YYYY.MM.DD format via formatDateString,
    // and if that still fails, return the raw string so a real value is shown instead
    // of the placeholder.
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

    // Decomposes a millisecond duration (stored as a string) into whole hours and
    // minutes. Returns nil for a missing, unparseable, or non-positive value — the
    // single "no duration" signal both duration formatters above translate into an
    // empty string. Shared so the parse/guard/divide logic exists in one place.
    //
    // Internal rather than private: GalleryListView's duration column renders the hour
    // and minute components as two separately aligned items rather than one string, so
    // it needs the decomposed values instead of a formatted result. Exposing this is
    // what keeps the parse/guard/divide rule in one place — a second copy over there
    // could silently disagree with the formatters above about, say, whether a
    // non-positive value counts as "no duration."
    static func hoursAndMinutes(from millisecondsString: String?) -> (hours: Int, minutes: Int)? {
        guard let totalMinutes = DurationHelpers.storedMinutes(millisecondsString) else { return nil }
        return (totalMinutes / 60, totalMinutes % 60)
    }

    // MARK: - Other Field Formatting
    // Formats a numerical value so that nil or 0 is treated as "no value" (empty string)
    // allowing the UI layer to show the tertiary "None provided" placeholder.
    // Supports both integer and double values.
    static func formatNumericalValue(_ value: Int?) -> String {
        guard let value = value, value != 0 else { return "" }
        return String(value)
    }

    static func formatNumericalValue(_ value: Double?) -> String {
        guard let value = value, value != 0 else { return "" }
        // Display as integer if no decimal part.
        let display = value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(value)
        return display
    }

    // MARK: - Source-Field Logic
    // Computes the "Source for Viewing" display string for a given film snapshot.
    //
    // Selection rules:
    //   • Edited films: Blu-ray only (4K and DVD releases are skipped entirely).
    //   • Non-edited films: 4K preferred, then Blu-ray, then DVD, then digitalSource.
    //   • A purchased disc of any format is always promoted to its own display tier
    //     ("4K disc", "Blu-ray disc", "DVD") and never shown with a " rip" suffix.
    //     "Rip" suffixes are reserved for the digitalSource fallback, where no
    //     purchased disc of the matching format exists.
    //   • The best-scored purchased release (see ReleaseSnapshot.qualityScore) is
    //     always selected for display; year, studio, remastered, and national origin
    //     are drawn from that same release so they are never mixed across releases.
    //   • Prefix rules evaluate ALL releases of the format (purchased or not),
    //     so that the presence of any release — wishlist or owned — influences
    //     whether a year, studio, or national origin is shown for disambiguation:
    //       – Year prefix:   another release of the same format shares the same
    //                        studio as the best purchased release AND that other
    //                        release's effective base year (its baseReleaseYear,
    //                        or its own releaseYear when baseReleaseYear is empty)
    //                        differs from the best release's effective base year.
    //                        Same-studio releases that share an effective base year
    //                        are treated as variants of one underlying release (e.g.
    //                        a 2014 Blu-ray and a 2016 repackaging of it with
    //                        baseReleaseYear == "2014"), so no year is shown to
    //                        distinguish them. When a year IS shown, it displays the
    //                        best release's effective base year rather than its
    //                        literal releaseYear, so a 2020 purchase of a disc whose
    //                        baseReleaseYear is "2014" reads as "2014" (the year it
    //                        was effectively released), not "2020" (the year it
    //                        happened to be bought).
    //       – Studio prefix: not all releases of the same format share the same
    //                        studio as the best purchased release (at least one
    //                        release, of any purchase status, differs).
    //       – Origin prefix: sits between the year and the studio ("2022 AU Imprint
    //                        remastered Blu-ray disc"). Shown for ANY import — a
    //                        release whose origin is set and is not the domestic one —
    //                        single release or not, since a foreign disc is inherently
    //                        non-standard and its origin is part of what it is. A
    //                        domestic release names it only for disambiguation: when
    //                        all same-studio colliders share the best release's release
    //                        year but differ in origin.
    //       All three can apply simultaneously, producing "YEAR ORIGIN STUDIO …". With
    //       a single domestic release of the format no prefix appears.
    //   • "remastered" is inserted inline before the format label rather than
    //     appended as a parenthetical suffix. It is always written in lowercase
    //     internally; the final string is sentence-capitalized before return so
    //     that "remastered" is only capitalized when it is the first word.
    //   • For edited films using a Blu-ray disc digital fallback (no purchased
    //     Blu-ray), "rip" is always appended and the remastered flag is honored
    //     from any Blu-ray release in the pool (purchased or wishlist).
    //   • The three companion outputs (disc glyph, "available for purchase" suffix,
    //     "Region B locked" suffix) are returned alongside the string rather than
    //     recomputed by separate functions. Each of them is a statement about *which
    //     branch below was taken*, so deriving them anywhere else means re-deriving
    //     this branch structure and keeping the copy in step by hand — which is
    //     exactly how the glyph came to disagree with the value it decorates (see
    //     `isPurchasedDiscSource`).
    struct SourceDisplay: Equatable {
        /// Sentence-capitalized display string; empty when the film has no source at all.
        var value: String = ""
        /// `value` with the origin's compact form ("AU") in place of its demonym
        /// ("Australian"), or nil when the two would be identical — no origin shown, or an
        /// origin with no short form. Offered to `fittingValueRow` as an abbreviation
        /// step, never displayed on its own account: the demonym is the standard spelling
        /// and the short form is used only when it keeps the value on one line, exactly
        /// as "rem." is for "remastered". Built here rather than by text substitution on
        /// `value` because a demonym can legitimately occur elsewhere in the string — a
        /// studio named "American Zoetrope" must not become "U.S. Zoetrope".
        var originAbbreviatedValue: String? = nil
        /// `value` with the studio's abbreviation ("Uni") in place of the shorthand
        /// ("Universal") the value itself carries, or nil when the two would be identical
        /// — no studio shown, or a studio with no tighter spelling. The same overflow-only
        /// contract as `originAbbreviatedValue`: the shorthand is the standard spelling
        /// for this field (`ReleaseStudio` explains the three tiers) and the abbreviation
        /// is a retreat, never the default. Built here for the same reason — the studio
        /// token is known by position, so no text substitution has to guess where it is.
        var studioAbbreviatedValue: String? = nil
        /// `value` with BOTH the origin and the studio compacted, or nil when identical
        /// to `value`. The last step of the ladder, offered only after each single step.
        var originAndStudioAbbreviatedValue: String? = nil
        /// True when the displayed value IS a disc the user owns, and therefore when the
        /// "opticaldisc.fill" glyph should be shown.
        ///
        /// This is deliberately NOT "the film owns any disc". Those two questions have
        /// different answers whenever the displayed value falls through to the digital
        /// source while a purchased disc of some *other* format exists — an edited film
        /// owning a purchased 4K but no purchased Blu-ray displays "Edited Blu-ray disc
        /// rip", which is a rip, not a disc the user owns. Keying the glyph off
        /// `film.purchasedReleases.isEmpty` put a disc glyph on that rip.
        var isPurchasedDiscSource: Bool = false
        /// "Available for purchase on <format>" — empty unless an unpurchased release
        /// exists in a format the film owns no purchased disc of. Names only one
        /// format, never a combined list. The 4K and Blu-ray notes can appear beside a
        /// displayed purchased disc of a *different* format (e.g. a purchased Blu-ray
        /// with an unpurchased 4K reads "Available for purchase on 4K UHD"); the 4K
        /// note is suppressed entirely for edited films. The DVD note still requires
        /// the displayed value not to be a purchased disc. See `sourceDisplay(for:)`.
        ///
        /// A complete, sentence-capitalized phrase rather than a fragment: it renders as
        /// its own annotation row beneath the value row, not as an inline continuation
        /// of the value. See `WatchDetails.sourceSection`.
        ///
        /// When the release backing the note has not come out yet on `today`, the note
        /// reads "Upcoming <format> release on <date>" instead (or "… release in <year>"
        /// for a year-only date), since it cannot be bought yet.
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

        // film.digitalSource stores the remastered flag as a "Remastered " prefix
        // (matching the FSTabMetadata.computedDigitalSource encoding). Strip that
        // prefix before any format comparisons so that "Remastered Blu-ray disc"
        // is treated identically to "Blu-ray disc" for branching purposes, and the
        // remastered state is carried separately as a boolean.
        let rawDigitalSource = film.digitalSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let (digitalSource, digitalSourceIsRemastered) = FilmDigitalSource.decompose(rawDigitalSource)
        let hasDigitalSource = !digitalSource.isEmpty

        // The value in every spelling the ladder can offer: the full form and the three
        // with the origin, the studio, or both compacted. Every branch below fills all
        // four; the ones that show no prefix fill them identically. See
        // SourceDisplay.originAbbreviatedValue and its siblings.
        let raw: SourceValueForms

        // Set by whichever branch below wins. `isPurchasedDisc` answers "is the value
        // being displayed a disc the user owns?", which is a different question from
        // "does the film own any disc?" — see SourceDisplay.isPurchasedDiscSource.
        // `displayedBluRay` is non-nil only on the one branch the Region B suffix is
        // scoped to (non-edited, purchased Blu-ray), so that suffix cannot drift out of
        // step with the branch it describes.
        var isPurchasedDisc = false
        var displayedBluRay: ReleaseSnapshot?
        // The purchased release the value row names, when it names one; drives the
        // pre-order note.
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
                // No purchased Blu-ray. "rip" is appended for both "Blu-ray disc"
                // and "DVD" digital sources (the disc itself was not purchased).
                // A purchased DVD is the one exception: the disc was bought, so
                // "rip" is omitted there, mirroring the purchased-disc paths above.
                // Remastered is honored from the digitalSource prefix flag when the
                // source is a Blu-ray disc; the release-pool flag is also checked as
                // a fallback in case no release object exists but the source is flagged.
                let base: String
                if digitalSource == FilmDigitalSource.dvd && !purchasedDVD.isEmpty {
                    base = "DVD"
                    displayedPurchased = bestDVD
                    // The disc itself was bought — that is precisely why "rip" is
                    // omitted here — so this branch does display a purchased disc.
                    isPurchasedDisc = true
                } else if digitalSource == FilmDigitalSource.blurayDisc {
                    // Remastered: honor the stored digitalSource prefix flag first;
                    // also check any Blu-ray release in the pool (purchased or wishlist).
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

        // ── Companion notes, both derived from the branch taken above ───────────────
        // Each is a standalone, sentence-capitalized phrase rendered on its own row
        // beneath the value row — not a fragment spliced onto the end of `value`.
        // The 4K and Blu-ray clauses are deliberately NOT gated on `!isPurchasedDisc`:
        // a non-edited film that owns a purchased Blu-ray (so a Blu-ray disc IS the
        // displayed source) still surfaces "Available for purchase on 4K UHD" when an
        // unpurchased 4K release exists. Each format is advertised only when no
        // purchased disc of that same format is already owned.
        //
        //   • 4K UHD  — film is not edited, owns no purchased 4K, and a 4K release is
        //               available to buy. Covers both "no purchased 4K or Blu-ray" and
        //               "purchased Blu-ray plus an unpurchased 4K".
        //   • Blu-ray — the 4K note did not fire, an unpurchased Blu-ray exists, and no
        //               purchased Blu-ray is owned. A purchased 4K does not suppress it:
        //               owning the 4K says nothing about owning the Blu-ray, and for an
        //               edited film (Blu-ray only) the 4K is not a source at all.
        //   • DVD     — shown only when the displayed value is not a purchased disc
        //               (so no DVD or better is owned), nothing on Blu-ray is to buy, and
        //               nothing on 4K is either — the 4K condition waived for edited films,
        //               where 4K never applies, exactly as the Blu-ray rule waives it.
        let has4KToBuy  = all4K.contains  { !$0.purchased }
        let has2KToBuy  = all2K.contains  { !$0.purchased }
        let hasDVDToBuy = allDVD.contains { !$0.purchased }

        // The release backing the claim is the best unpurchased one of that format; a foreign
        // origin makes it foreign ("Available for purchase on foreign Blu-ray"). When that
        // release is still to come it cannot be bought yet, so the note names its date
        // instead: "Upcoming Blu-ray release on November 3, 2026".
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
            availableForPurchase = buyPhrase("4K UHD", all4K)
        } else if has2KToBuy && purchased2K.isEmpty {
            availableForPurchase = buyPhrase("Blu-ray", all2K)
        } else if !isPurchasedDisc && (isEdited || !has4KToBuy) && !has2KToBuy && hasDVDToBuy {
            availableForPurchase = buyPhrase("DVD", allDVD)
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
    /// disc". The four purchased-disc branches each build this, and each used to spell
    /// the remastered/plain pair out by hand.
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

    // The studio's spelling for the Source for Viewing field, in the two tiers the field
    // uses (see ReleaseStudio for the three-tier scheme). Both are gated by
    // Preferences.abbreviateSourceStudio: when the preference is disabled, the original
    // studio string is returned unchanged at every tier, so the ladder finds nothing to
    // retreat to and the full name is what is shown.
    //
    //   • shorthandStudioName — what the field prints by default ("Universal").
    //   • abbreviatedStudioName — what it retreats to when the shorthand would wrap
    //     ("Uni"). Falls back to the shorthand for a studio with no tighter form, so the
    //     ladder step it feeds compares equal to the default and is dropped.
    //
    // Studios not present in the table are returned as-is at both tiers — only the
    // studios listed there have shorter forms; everything else displays at full length.
    //
    // Free-text "Other" entries (anything not matching a known studio name) are not
    // looked up in this table; instead they are truncated to a 30-character maximum
    // with a trailing ellipsis when they exceed that length, regardless of whether
    // abbreviateSourceStudio is enabled — truncation guards against unbounded layout
    // growth from arbitrary user input and is therefore independent of the preference.
    private static func shorthandStudioName(_ studio: String) -> String {
        guard Preferences.abbreviateSourceStudio else { return studio }
        return ReleaseStudio.shorthand(studio)
    }

    private static func abbreviatedStudioName(_ studio: String) -> String {
        guard Preferences.abbreviateSourceStudio else { return studio }
        return ReleaseStudio.abbreviated(studio)
    }

    // Applies the 30-character truncation rule used for free-text ("Other") studio
    // entries in the Source for Viewing field. Known studio names never reach this
    // length in practice, but the guard is unconditional so any future long studio
    // name (known or custom) is handled safely.
    private static func truncatedStudioDisplayName(_ studio: String) -> String {
        let maxLength = 30
        guard studio.count > maxLength else { return studio }
        let truncated = studio.prefix(maxLength)
        return "\(truncated)…"
    }

    // Resolves the display strings for a studio name in the Source for Viewing field:
    // known studios are shortened to the requested tier (when enabled), then the
    // 30-character truncation rule is applied as a final safety net for any remaining
    // long value.
    private static func displayStudioName(_ studio: String) -> String {
        return truncatedStudioDisplayName(shorthandStudioName(studio))
    }

    private static func displayStudioAbbreviation(_ studio: String) -> String {
        return truncatedStudioDisplayName(abbreviatedStudioName(studio))
    }

    // Builds the disambiguation prefix for a disc-format pool.
    //
    // `best`          — the best-scored *purchased* release (the one being displayed).
    // `allOfFormat`   — ALL releases of this format, regardless of purchase status.
    //                   Prefix rules are evaluated against this full set so that
    //                   wishlist releases influence disambiguation just as owned ones do.
    //
    // Rules (only applied when allOfFormat contains 2+ releases):
    //   showYear:   another release in allOfFormat shares the best release's studio
    //               exactly (same-studio collision requires a year to distinguish),
    //               AND that collider's effective base year (baseReleaseYear, or its
    //               own releaseYear when baseReleaseYear is empty) differs from the
    //               best release's effective base year. Colliders that share the
    //               same effective base year are variants of the same underlying
    //               release, so a year adds no genuine disambiguation and is
    //               suppressed. When shown, the year token itself is the best
    //               release's effective base year (not its literal releaseYear).
    //   showStudio: at least one release in allOfFormat has a different studio from
    //               the best release (studio name identifies which release is shown).
    //   showOrigin: fires when same-studio colliders that share the best release's
    //               effective base year also differ in national origin. Evaluated
    //               INDEPENDENTLY of showYear, which is the whole point of the rule:
    //               the same-year group is precisely the group a year token cannot
    //               separate, so origin is exactly what is needed when no
    //               different-year collider exists. (Deriving showOrigin from
    //               showYear — as this previously did — made the "ORIGIN " form
    //               below unreachable, since showYear requires a different-year
    //               collider and origin's own trigger requires a same-year one.)
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
    // Resulting prefix forms — the three tokens are independent, so this is simply
    // every combination of them, always emitted in YEAR ORIGIN STUDIO order. The origin
    // precedes the studio wherever it appears, whatever caused it to appear: it is a
    // fact about the disc's provenance, and "English Criterion Blu-ray disc" reads as
    // the nation's edition of that studio's disc, which is what it is.
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
    // The prefix comes in four spellings that differ only in their proper-name tokens.
    // `full` carries the origin's demonym ("Australian") and the studio's shorthand
    // ("Universal"); `originAbbreviated` compacts the origin ("AU",
    // `ReleaseOrigin.shortForm`), `studioAbbreviated` compacts the studio ("Uni",
    // `ReleaseStudio.abbreviated`), and `originAndStudioAbbreviated` compacts both. The
    // demonym and the shorthand are the standard spellings; the compact forms exist so
    // `fittingValueRow` can fall back to them when that is what keeps the value on one
    // line — the same overflow-only rule as "rem." for "remastered". A spelling is
    // identical to `full` whenever the token it compacts is not shown or has no compact
    // form. Each has a trailing space so the caller can concatenate the format label
    // directly.
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

        // Only one release of this format: nothing to disambiguate, so no year or
        // studio. The import rule is the one thing that does not depend on the pool.
        // Every spelling is filled: no studio is shown here, so the studio-compacted forms
        // are the full and origin-compacted ones. Left at their empty defaults, they read as
        // ladder steps with the origin dropped altogether ("Blu-ray disc" for an Australian
        // disc), which the row could pick whenever the full value overflowed.
        guard allOfFormat.count >= 2 else {
            return isImport ? SourcePrefix(full: originToken,
                                           originAbbreviated: originShortToken,
                                           studioAbbreviated: originToken,
                                           originAndStudioAbbreviated: originShortToken)
                            : SourcePrefix()
        }

        // Same-studio colliders: other releases that share the best release's studio.
        let sameStudioOthers = allOfFormat.filter { $0.id != best.id && $0.studio == bestStudio }

        // The "effective base year" identifies which original release a given disc is a
        // variant of: when baseReleaseYear is populated (the release is a re-issue/repack
        // of an earlier release), that value is used; otherwise the year of the release's
        // own releaseDate stands in as its own base. Two releases sharing the same effective
        // base year are variants of the same underlying release (e.g. a 2014 Blu-ray and
        // its 2016 repackaging, baseReleaseYear == "2014"), so distinguishing them by year
        // would be misleading rather than helpful.
        //
        // Years throughout, never the full release date: the base year has no month or
        // day, and the token built from this is a year.
        func effectiveBaseYear(_ release: ReleaseSnapshot) -> String {
            release.baseReleaseYear.isEmpty
                ? ReleaseDateValue.yearText(of: release.releaseDate, format: release.format)
                : release.baseReleaseYear
        }
        let bestEffectiveBaseYear = effectiveBaseYear(best)

        // showYear fires when any same-studio collider exists (requires year to
        // distinguish among them, unless all share the same year — see showOrigin).
        //
        // For formats where requiresNotableDifference is true (currently 4K), year is
        // additionally suppressed unless at least one same-studio collider differs
        // notably from the best release. "Notable" means any difference in: remastered,
        // videoFormat, audioFormat, audioChannels, hasSubtitles, or releaseAspectRatio.
        // Two releases that are otherwise identical (e.g., the same disc purchased
        // twice) carry no meaningful distinction, so the year adds no useful information.
        //
        // Additionally, year is suppressed entirely when every same-studio collider
        // shares the best release's effective base year — those releases are variants
        // of the same underlying release rather than genuinely distinct releases, so a
        // year would only manufacture a false disambiguation.
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

        // showOrigin fires when there are same-studio colliders that also share
        // the best release's *effective* year AND at least one of those same-year
        // entries carries a different national origin. Grouping uses effective base
        // year (not the raw releaseYear) so that a re-issue/repack — which is already
        // treated as a variant of its original release for the year-suppression rule
        // above — is likewise treated as belonging to the same year-group here, rather
        // than being misclassified into a spurious "different year" bucket. This
        // handles both the all-same-year case (origin fully replaces the year token)
        // and the mixed-year case (origin supplements the year token, narrowing
        // further within the same effective-year sub-group).
        //
        // Deliberately NOT predicated on showYear. It previously read
        // `showYear && …`, which made the all-same-year case — the very case origin
        // disambiguation exists for — impossible to reach: showYear requires
        // hasDistinctBaseYearCollider, and "all same-studio colliders share the best
        // release's year" is precisely that flag being false. Two same-studio,
        // same-year releases differing only in national origin therefore received no
        // prefix at all. The notable-difference gate is still applied (it answers the
        // separate question of whether the colliders are meaningfully distinct discs
        // rather than duplicate copies of one), but the year-specific term is not.
        let sameStudioSameYearOthers = sameStudioOthers.filter { effectiveBaseYear($0) == bestEffectiveBaseYear }
        let originDiffersAmongSameYearGroup = sameStudioSameYearOthers.contains { $0.nationalOrigin != bestOrigin }
        let showOrigin = hasNotableCollider && !sameStudioSameYearOthers.isEmpty && originDiffersAmongSameYearGroup

        // Build the three tokens. Each is emitted independently by the flags resolved
        // above. The year token displays the best release's
        // *effective* base year rather than its literal releaseYear: when the best
        // release is itself a re-issue/repack (baseReleaseYear populated), the
        // effective base year is the year that correctly describes when the release
        // was effectively made available (e.g. a disc purchased in 2020 with
        // baseReleaseYear "2014" is effectively a 2014 release, and should read
        // "2014" here, not "2020").
        let yearToken        = bestEffectiveBaseYear.isEmpty  ? "" : "\(bestEffectiveBaseYear) "
        let studioToken      = bestStudio.isEmpty ? "" : "\(displayStudioName(bestStudio)) "
        let studioShortToken = bestStudio.isEmpty ? "" : "\(displayStudioAbbreviation(bestStudio)) "

        // The tokens are independent and always appear in this order, so the prefix is
        // simply the concatenation of whichever ones fired. This replaces a four-way
        // switch that enumerated the combinations by hand; that switch had a dedicated
        // "year still needed alongside origin" discriminator which was provably
        // identical to showOrigin itself, leaving two of its arms unreachable, and it
        // documented one arm as "logically unreachable" that was in fact reached by
        // every all-same-studio/all-same-year pool. Composing the tokens directly
        // produces every documented form with no unreachable states to keep correct.
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
// The Releases tab draws the same release set twice: as rows in the optional summary table
// (DiscReleasesTable, 24.21) and as cards beneath it (RTabReleases, 24.20). A row and the
// card below it describe the same disc, so everything about *what they say* — which mark a
// region resolves to and how it is colored, how the video line is composed, and what order
// the releases come in — must be identical in both.
//
// EVERY such derivation lives in this section, and this section is the only place any of
// them lives. Each was previously written out in full in both files with a comment on each
// copy telling the reader to keep it in step with the other; the region badging had
// already drifted on character size and weight despite that.
//
// What is deliberately NOT here is chrome and geometry, which genuinely differ by context —
// the cards draw into a fixed slot on an opaque gray pill, the table into a column on the
// row background. Those differences are intentional, not drift, and stay at their sites.
// ═══════════════════════════════════════════════════════════════════════════════════════

// MARK: Region Lock Badging

/// The mark a region lock resolves to: a lettered/numbered disc, the Region Free globe, or
/// an unrecognized stored value passed through verbatim.
enum RSBRegionIndicator: Equatable {
    /// A filled disc carrying one character. `playable` is whether the disc runs on this
    /// library's hardware, which is what selects the fill.
    case character(String, playable: Bool)
    /// The Region Free globe. Carries no symbol name: this is the only glyph the
    /// vocabulary produces, so naming it at each site was a degree of freedom with exactly
    /// one legal value.
    case globe
    /// A stored value outside the recognized vocabulary, shown as itself rather than
    /// silently swallowed. Reachable only from hand-edited or legacy data — the FilmSheet's
    /// region pickers are closed vocabularies.
    case raw(String)

    /// The region a release displays as, applying 4K UHD's default: a 4K disc with nothing
    /// recorded is Region Free, since the format has no region coding at all.
    ///
    /// Exposed separately from `resolve` because the card needs the string as well as the
    /// mark — it spells the region out in the badge's tooltip — so returning only an
    /// indicator would have left the default to be reapplied there.
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

    /// The 1…8 region number in `value`, or nil when `value` is not exactly "Region N" for
    /// such an N. Read from `ReleaseRegionRules`, which also composes the tag, so the
    /// prefix cannot drift between the two directions. Wider than the DVD picker's 1…5 on
    /// purpose — see `ReleaseRegionRules.regionNumber(in:)`.
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
/// `Preferences.orange` rather than red for the same reason the playable case is not green.
/// Red and green are the purchase state's pair — the card's header band, the table's "Pur."
/// column — and a red region disc beside them read as a second remark about the purchase.
/// Orange belongs to neither end of that scale, so it separates cleanly while still being
/// the most saturated mark in view: a disc that will not play is the one thing here worth
/// interrupting a glance for.
enum RSBRegionBadge {
    static func fill(playable: Bool) -> Color { playable ? .white : Preferences.orange }

    /// Lettering, at whatever contrasts with `fill`.
    static func ink(playable: Bool) -> Color { playable ? .black : .white }

    /// Whether the lettering needs a drop shadow to hold its edges against the fill. White
    /// on saturated orange does; black on white does not — the contrast there is already
    /// maximal and a shadow would only muddy the letter.
    static func inkNeedsShadow(playable: Bool) -> Bool { !playable }

    /// The character's type. One size and one weight for every region disc in the sidebar:
    /// both renderers draw into a 14pt circle, so a difference of even a point here made
    /// one of them sit visibly large in its disc and read as off-center beside the other.
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
/// Only the two picker-valid master types are appended. Any other stored value — an empty
/// string, a legacy placeholder, a corrupt import artifact — is ignored so the codec
/// displays alone rather than trailing an parenthesized fragment of bad data.
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

/// The four visible sort keys — format group (4K UHD → Blu-ray → DVD, read from
/// `ReleaseFormat` so this list, the releases table and the FilmSheet carousel cannot drift
/// into different orders), then descending release date, then descending
/// purchase date, then studio — expressed once so every ordering uses exactly the same
/// rules. Returns `nil` when all four tie, letting each caller decide the tiebreak: the
/// table's flat `.standard` sort keeps its historical `false` (no further ordering), while
/// the grouped ordering below falls through to a unique ID so its result is total.
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
/// GROUP SHAPE — index 0 of every group is its top-level parent, and every later index is
/// one of that parent's children. The key pairs a child only with the release it names, and
/// the member sort below puts `isTopLevel` first. Both presentations depend on this: the
/// cards read index 0 as the plate's parent half and treat every later index as an attached
/// child, and the table reads `isChild` as "the row above continues my stack".
///
/// It holds because a child cannot name a parent that is absent from the film — which is
/// what would form a parentless group of one. `Release.parentRelease` is an object
/// reference under a `.nullify` delete rule (deleting a parent makes its children
/// top-level, never dangling), and the two writers that resolve a raw `parentReleaseID`
/// both refuse a link they cannot resolve: DataManager step 6.5 looks the parent up in
/// `film.releases` alone and clears the pointer otherwise, and DBRestorer's hierarchy pass
/// drops any link whose parent is missing, is on another film, or is itself a child.
///
/// ONE RESIDUAL, deliberately not defended against here. Both callers filter their input to
/// recognized `ReleaseFormat` values before calling this, so a parent carrying a format
/// string this build does not know is removed while its child survives — leaving that child
/// in a group of its own with nothing at index 0 but itself. No UI path can produce such a
/// format (every release is created from `ReleaseFormat.allCases` or an explicit case, and
/// the field is never edited afterward); only a hand-edited or corrupt backup can. The
/// consequence is bounded and fails safe: the card treats the release as standalone and
/// therefore shows its acquisition figures rather than hiding them, and the table draws one
/// open-topped badge meeting nothing — cosmetic. Defending it would mean reinstating the
/// per-row adjacency bookkeeping that this shape exists to make unnecessary.
///
/// The table flattens the result into rows; the cards map each group onto one plate.
///
/// Both tiebreaks are load-bearing. `sortOrder` orders a dual-BD pack's two children, which
/// tie on every key above it, in the order the FilmSheet created and displays them. The
/// final ID key makes the ordering *total*: a dictionary's value order is unspecified and
/// `sorted(by:)` is not stable, so without it two groups tying on all four visible keys
/// could swap places on any rebuild — including rebuilds triggered by editing a field no
/// sort key reads.
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

    /// Builds a direct URL using the stored numeric identifier for this site.
    /// 'identifier' must be a non-empty digit string.
    /// 'dashedName' is used only by the Blu-ray target (the slug component).
    func directURL(identifier: String, dashedName: String) -> URL? {
        switch self {
        case .imdb:
            // Direct title reference page: /title/tt<id>/reference/
            return URL(string: "https://www.imdb.com/title/tt\(identifier)/reference/")

        case .bluray:
            // Direct title page: /<dashed-name>/<id>/
            // dashedName is already lowercased, punctuation-stripped, and hyphen-joined.
            return URL(string: "https://www.blu-ray.com/\(dashedName)/\(identifier)/")
        }
    }

    /// Builds a fallback search URL for the given normalized title string.
    /// `normalizedTitle` must already have had dash variants collapsed and must
    /// be plain Unicode text — percent-encoding is applied internally.
    func searchURL(for normalizedTitle: String) -> URL? {
        // A value inside a query string: `.urlQueryAllowed` alone leaves `&`, `=`, `+` and
        // `?` literal, so "Fast & Furious" searched for "Fast" and a `+` read as a space.
        var valueAllowed = CharacterSet.urlQueryAllowed
        valueAllowed.remove(charactersIn: "&=+?")
        switch self {
        case .imdb:
            // IMDb find: restrict to feature films, exact-title search.
            guard let encoded = normalizedTitle.addingPercentEncoding(
                withAllowedCharacters: valueAllowed
            ) else { return nil }
            return URL(string: "https://www.imdb.com/find/?q=\(encoded)&s=tt&ttype=ft&exact=true")

        case .bluray:
            // Blu-ray.com quick-search, US theatrical section.
            // The keyword parameter uses "+" as a word separator on this site,
            // so we percent-encode the name and then swap encoded spaces for "+".
            guard let encoded = normalizedTitle
                .addingPercentEncoding(withAllowedCharacters: valueAllowed)?
                .replacingOccurrences(of: "%20", with: "+")
            else { return nil }
            return URL(string: "https://www.blu-ray.com/search/?quicksearch=1&quicksearch_country=US&quicksearch_keyword=\(encoded)&section=theatrical")
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
/// A single row used by RSBHelpers.searchableItemSection. Displays the item name on the
/// leading side with a "Search" button on the trailing edge. The item text is truncated
/// with an ellipsis when it would otherwise overlap or be clipped by the button.
///
/// The Search button fires a .activateTokenSearch UICommand that MainView intercepts to
/// perform a programmatic single-token search — the user sees instant results with no
/// intermediate state.
@MainActor
/// One crew name's row: the name, selectable, and its token-search button. Internal rather
/// than private so Metadata's pooled crew block (24.17) draws exactly the same row.
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
// `rsb-modules` measured the crew block at about 20 ms of Metadata's median 27 ms (Debug):
// in SwiftUI a row costs about half a millisecond to update even when nothing in it is
// built, and a film's crew lists run to twenty or thirty rows. `rsb-crew-parity` compares
// these rows with SearchableItemRow pixel for pixel, light and dark.
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
/// `sidebarFieldEdgeChrome`; the constants come from RSBHelpers and FieldEdgeTreatment.
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

    private let fillLayer = CAShapeLayer()
    private let borderLayer = CAGradientLayer()
    private let borderMask = CAShapeLayer()
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
        fillLayer.shadowOpacity = Float(FieldEdgeTreatment.shadowOpacity)
        fillLayer.shadowRadius = FieldEdgeTreatment.shadowRadius
        fillLayer.shadowOffset = CGSize(width: 0, height: FieldEdgeTreatment.shadowOffsetY)
        fillLayer.shadowColor = NSColor.black.cgColor
        layer?.addSublayer(fillLayer)
        borderLayer.startPoint = CGPoint(x: 0.5, y: 0)
        borderLayer.endPoint = CGPoint(x: 0.5, y: 1)
        borderLayer.locations = [0, NSNumber(value: FieldEdgeTreatment.borderFadeStart), 1]
        borderMask.fillColor = nil
        borderMask.strokeColor = NSColor.black.cgColor
        borderMask.lineWidth = FieldEdgeTreatment.borderWidth
        borderLayer.mask = borderMask
        layer?.addSublayer(borderLayer)

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
        let path = RoundedRectangle(cornerRadius: FieldEdgeTreatment.cornerRadius, style: .continuous)
            .path(in: b).cgPath
        fillLayer.frame = b
        fillLayer.path = path
        fillLayer.shadowPath = path
        borderLayer.frame = b
        borderMask.frame = b
        let inset = FieldEdgeTreatment.borderWidth / 2
        borderMask.path = RoundedRectangle(cornerRadius: FieldEdgeTreatment.cornerRadius - inset, style: .continuous)
            .path(in: b.insetBy(dx: inset, dy: inset)).cgPath

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
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fillLayer.fillColor = NSColor.controlBackgroundColor.cgColor
            let edge = NSColor.separatorColor
            borderLayer.colors = [edge.withAlphaComponent(edge.alphaComponent * FieldEdgeTreatment.borderOpacity).cgColor,
                                  edge.withAlphaComponent(edge.alphaComponent * FieldEdgeTreatment.borderOpacity).cgColor,
                                  edge.withAlphaComponent(0).cgColor]
        }
    }
}

/// A crew row's glyph, placed in its box exactly as SwiftUI places the Image in
/// SearchableItemRow. NSImageView centers differently, which put five of the seven crew
/// symbols half a pixel or more off.
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
    /// Built here rather than inside that function because the two call sites —
    /// WatchDetails' "Last Watched" and "Next Up for Rotation" rows — are computed view
    /// properties, so the function ran (and, before this, compiled this pattern) on every
    /// body pass of that module rather than once per film. Compiling an
    /// `NSRegularExpression` is the expensive half of the rule; matching against a short
    /// clause is not. `NSRegularExpression` is immutable and thread-safe once built, so a
    /// single shared instance is safe to match against from anywhere.
    ///
    /// Optional because the initializer is throwing. The pattern is a literal that does
    /// compile, so this is never nil in practice; `shorteningUnits` treats a nil as
    /// "nothing to abbreviate" — exactly what the previous `try?` did.
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
    /// "May" is listed with itself as its own abbreviation rather than omitted. Omitting it
    /// would be equivalent — it is already three letters — but listing it keeps the table a
    /// complete statement of the twelve months, so a reader does not have to work out
    /// whether May is missing on purpose. A value whose only month is May therefore rewrites
    /// to itself, and the `result == value` check below reports that as "nothing to
    /// shorten", exactly as if no month had been found.
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

    /// The shortened spellings of a "date plus relative-time parenthetical" value, in the
    /// order `fittingValueRow` should try them — each one a further step from the full
    /// spelling, so the first that fits is also the most informative that fits.
    ///
    ///   1. Units only. The parenthetical is the lesser half of the value, so it gives ground
    ///      first: "November 04, 2021 (4 yr. 4 mo. ago)".
    ///   2. Month only. Reached when there were no units to shorten — the prose forms
    ///      ("Less than a week ago", "Today") have none — so the date must give instead.
    ///   3. Both.
    ///
    /// Steps that would change nothing are omitted, and a step identical to one already in
    /// the ladder is dropped, so a value with no applicable rule yields an empty array and
    /// costs no measurement at all. Ordering by decreasing informativeness rather than by
    /// decreasing width is deliberate: `ViewThatFits` takes the FIRST candidate that fits, so
    /// the ladder is a preference list, and a step that happens to be wider than the one
    /// before it simply never wins.
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

        // Report "nothing to shorten" by comparing the result, rather than by testing
        // for the word up front. A case-INSENSITIVE presence check paired with
        // case-sensitive replacements disagreed on any other spelling — an all-caps
        // "REMASTERED" surviving an import passed the check, matched neither
        // replacement, and was returned as a non-nil "abbreviation" identical to the
        // input, costing fittingValueRow a ViewThatFits measurement whose extra
        // candidate could never win. Deriving the answer from the work actually done
        // makes the two incapable of disagreeing.
        return shortened == value ? nil : shortened
    }
}

// MARK: - Top-Pinned Layout

/// Keeps the root of a sidebar tab's hosted tree the same size during an animated update
/// that changes the tab's height (the Releases tab's purchase filter, the Details tab's
/// table expansion). Wrap the tab's whole content in it, inside SidebarScrollView.
///
/// Measured with the `releases-filter` harness scenario (99.56): when a filter change made
/// the content TALLER, and the root of the hosted tree took the new height in that same
/// animated pass, the whole stack — picker included — started half the growth lower and
/// slid back up over the length of the animation (123 pt for a 246 pt grow). The animated
/// cards were interpolated against the root's center, which had moved by half the growth.
/// A shrink never showed it, because there the root kept its size through the animated
/// pass and the hosting view shrank afterward, in a pass of its own.
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
