// MARK: - FSFramesList.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The reorderable frames/time-code table used by the FilmSheet Notes tab.
//
// Split out of 30_20_FSControlHelpers.swift alongside the parallel split of
// ReorderableStringList into 30_30_FSStringList.swift. The two list components
// remain separate types: a frames entry is a four-field comma-packed record with
// its own popover-driven editor, whereas a string-list entry is a bare value
// edited in place, so unifying them would mean one component carrying two
// disjoint row models and edit paths.
//
// What they DO share lives in FSControlHelpers.swift — `ListCircleButton`/
// `ListCircleButtonStyle` (the circular control family), `ListImportPopover`
// (the bulk-entry sheet and its parsing rule), and `ListRowMetrics` (shared row
// and control geometry) — so both tables' chrome is tuned in one place. Container
// chrome comes from `FieldEdgeTreatment` in 30_10_FSTextHelpers.swift likewise.
//
// MARK: Why this is one table and not two
//
// This component used to be instantiated twice on the Notes tab — once over
// `handbrakeFrames`, once over `correspondingTimecodes` — as parallel tables by
// convention only: entry n of one described the same moment as entry n of the
// other, with nothing enforcing it. A delete, reorder, or flag toggle on one
// table and not the other silently desynchronized the pair.
//
// The storage format is unchanged — two `[String]` arrays of four-field records —
// which is what keeps the right sidebar's read-only Notes tab (24_30_RTabNotes.swift)
// working untouched, with the two tables still separate there where horizontal
// space doesn't allow a combined view. What changed is that the FilmSheet presents
// them as one table of paired rows: a row carries a frame, a time code, and ONE
// set of flags, and every write path writes both arrays together. Divergence is no
// longer something the user has to avoid — it's something this component can't produce.
//
// Legacy records whose two arrays are of unequal length display as-is (the
// shorter side renders blank) and normalize on the first write of any kind, by
// padding the shorter array with placeholder records that repeat the longer side's
// flags (`ReorderableFramesList.placeholder(pairedWith:)`). Nothing is written merely
// by opening the sheet.

import SwiftUI
import AppKit
import Combine

// MARK: - Shared Color Constants
// Constructed once at process launch rather than bridged NSColor→Color on every
// render of the fade-style rows below. Declared privately here as well as in
// FSControlHelpers.swift: file-private constants do not collide across files,
// and duplicating one bridged color is cheaper than exposing it module-wide.
private let disabledControlTextColor = Color(NSColor.disabledControlTextColor)

// MARK: - Mark Style Enum
/// Controls which glyph is used to mark a frames-list entry as "see notes".
/// Stored as the second comma-separated component: "yes" = asterisk (legacy and
/// current default), "caret" = chevron.up, "number" = number sign, "no" = no mark.
enum MarkStyle: String, Hashable {
    case asterisk = "yes"
    case caret    = "caret"
    case number   = "number"
    case none     = "no"

    // No `displayName`: the only picker offering these cases labels them with its
    // own literals, so the property had no callers. `CaseIterable` is gone for
    // the same reason — `allCases` was never read, and the picker deliberately
    // offers only the glyph-bearing cases (`.none` is expressed by the row's
    // toggle rather than by its own segment), so an iterable list would
    // misdescribe the control.

    var symbolName: String {
        switch self {
        case .asterisk: return "asterisk"
        case .caret:    return "chevron.up"
        case .number:   return "number"
        case .none:     return ""
        }
    }

    // `fromString` is gone with its single caller. It was a hand-written switch over the
    // three raw values — exactly what `MarkStyle(rawValue:) ?? .none` already does — and
    // FramesEntryParser.parse now uses the failable initializer directly so that an
    // unrecognized token is distinguishable from a legitimate "no" rather than being
    // folded into it. A defaulting helper cannot express that distinction, which is why
    // it could not simply be kept alongside.
}

// MARK: - Frames Entry Parser

/// Reads the four-field, comma-packed string a frames entry is stored as.
///
/// Shared rather than duplicated. The FilmSheet's editable rows and the right
/// sidebar's read-only Notes tab both display the same records, and both used to
/// carry their own byte-identical copy of this function — two parsers for one
/// storage format, either of which could be corrected without the other. The
/// format is defined once here, and `PairedFramesRecord` is what writes it.
///
/// A string that is not four fields is treated as a bare text entry with no
/// metadata, which is what pre-metadata records look like: the whole string is
/// returned as the text, so nothing is lost when one is displayed.
enum FramesEntryParser {
    typealias Entry = (text: String, mark: MarkStyle, fadeIn: AudioFadeStyle, fadeOut: AudioFadeStyle)

    /// What a row shows for a side it has no record on at all — one array of a
    /// legacy pair being shorter than the other.
    ///
    /// Distinct from a *stored* placeholder, which is a real, four-field record
    /// holding `PairedFramesRecord.missingText`. The difference matters: a
    /// missing record is `nil` all the way through the row's update and delete
    /// paths, which is what lets those paths tell "this row has no time code
    /// entry" apart from "this row has a time code entry that says nothing".
    static let empty: Entry = (text: "", mark: .none, fadeIn: .none, fadeOut: .none)

    static func parse(_ entry: String) -> Entry {
        let components = entry.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        // Four fields is necessary but NOT sufficient to call this a record.
        //
        // The count alone used to decide it, which misread any bare-text entry that
        // happened to contain exactly three commas — a legacy or imported note like
        // "reel 2, 3, 4, and 5" — as a record, silently truncating it to its first field
        // and reading the rest as metadata. New data cannot reach that state
        // (PairedFramesRecord.cleaned strips commas out of the text before writing), but
        // records predating that rule can, and the misparse is destructive on the next
        // write because only the truncated text survives.
        //
        // Every record this app has EVER written puts an exact enum raw value in each of
        // the three metadata fields (PairedFramesRecord.make interpolates `.rawValue`),
        // so requiring them to parse is a free, strictly sharper test. Deriving the
        // accepted tokens from the enums rather than from a literal list is what keeps it
        // free: adding a MarkStyle or AudioFadeStyle case widens this automatically and
        // cannot leave the parser rejecting records a later build writes.
        guard components.count == 4,
              let mark    = MarkStyle(rawValue: components[1]),
              let fadeIn  = AudioFadeStyle(rawValue: components[2]),
              let fadeOut = AudioFadeStyle(rawValue: components[3])
        else { return (entry, .none, .none, .none) }
        return (components[0], mark, fadeIn, fadeOut)
    }

    /// Whether any entry in `entries` carries at least one of the three glyph-bearing
    /// metadata fields — the mark, the fade-in style, or the fade-out style.
    ///
    /// This is the gate on the Legend section in both the FilmSheet's Notes tab and the
    /// right sidebar's Notes tab. Those two used to show the legend whenever either
    /// frames table held *any* entry, which meant a table of plain, unannotated frames
    /// still explained eight glyphs that were nowhere on screen. The predicate lives
    /// here, beside the parser that defines what a glyph-bearing record looks like, so
    /// that adding a fourth metadata field later cannot leave one of the two tabs
    /// gating on a stale definition.
    ///
    /// Short-circuits on the first annotated entry, and parses nothing beyond it.
    static func containsLegendGlyphs(_ entries: [String]) -> Bool {
        entries.contains { entry in
            let parsed = parse(entry)
            return parsed.mark != .none || parsed.fadeIn != .none || parsed.fadeOut != .none
        }
    }
}

// MARK: - Paired Record Assembly

/// The two finished records one row's draft would write.
///
/// A named type rather than a `(frame:timecode:)` tuple. Tuples with labels are
/// legal as a property or return type but are not reliably accepted as the
/// parameter type of a *function type*, and this value is carried as exactly
/// that — `PairedFramesListRow.onUpdate`, a stored closure the row hands its
/// finished work back through. Naming it also makes the pairing the unit the
/// write paths deal in, which is the invariant this component exists to hold.
struct PairedFramesDraft {
    let frame: String
    let timecode: String
}


/// Builds the four-field records the two arrays store, and defines how one row's
/// two drafted text fields become the pair of records that row writes.
///
/// One place rather than three. The add popover, the per-row edit popover, and
/// the bulk import all produce the same shape, and each used to carry its own
/// string interpolation and its own trim-and-strip sequence. Those three agreed
/// by inspection; here they agree by construction — which matters considerably
/// more now that each of them writes TWO records that must carry identical
/// metadata.
enum PairedFramesRecord {

    /// Stands in for a side of a row the user left blank.
    ///
    /// A record cannot simply hold an empty text field. `FramesEntryParser`
    /// splits on commas with empty subsequences omitted, so ", no, none, none"
    /// yields three components and is read back as a bare-text entry rather than
    /// as the record it was written as. A visible placeholder is therefore the
    /// only representable way to say "this row has no time code", and it also
    /// reads correctly in the right sidebar's two separate tables, where the row
    /// numbers still have to line up against each other.
    static let missingText = "—"

    /// Trims, strips commas, and reports `nil` when nothing storable is left.
    ///
    /// Commas are stripped because a comma inside the text field would be read
    /// back as a field delimiter and shift every later field by one. Stripping
    /// can empty a field that trimming alone did not — a draft of nothing but
    /// commas — which is why the emptiness test is applied afterward.
    static func cleaned(_ raw: String) -> String? {
        let stripped = raw
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? nil : stripped
    }

    static func make(_ text: String,
                     mark: MarkStyle,
                     fadeIn: AudioFadeStyle,
                     fadeOut: AudioFadeStyle) -> String {
        "\(text), \(mark.rawValue), \(fadeIn.rawValue), \(fadeOut.rawValue)"
    }

    /// The two records a row's draft would write, or `nil` when neither text
    /// field holds anything storable.
    ///
    /// At least one side must carry content; the other is filled with the
    /// placeholder. Requiring both would refuse a legitimate entry — a marked
    /// frame whose time code has not been read off yet — and requiring neither
    /// would write a row that renders as two dashes and means nothing.
    ///
    /// The metadata is applied identically to both records. That single fact is
    /// the whole reason this component was combined.
    static func pair(frameText: String,
                     timecodeText: String,
                     mark: MarkStyle,
                     fadeIn: AudioFadeStyle,
                     fadeOut: AudioFadeStyle) -> PairedFramesDraft? {
        let frame = cleaned(frameText)
        let timecode = cleaned(timecodeText)
        guard frame != nil || timecode != nil else { return nil }
        return PairedFramesDraft(
            frame: make(frame ?? missingText, mark: mark, fadeIn: fadeIn, fadeOut: fadeOut),
            timecode: make(timecode ?? missingText, mark: mark, fadeIn: fadeIn, fadeOut: fadeOut))
    }

    /// What a text field is seeded with when a row is opened for editing: the
    /// stored text, or nothing when the stored text is the placeholder. Editing
    /// a blank side should begin blank rather than with a dash the user has to
    /// delete first.
    static func editableText(_ parsed: FramesEntryParser.Entry) -> String {
        parsed.text == missingText ? "" : parsed.text
    }
}

// MARK: - Frames Popover Row Helpers
//
// Both `ReorderableFramesList.addPopoverContent` and
// `PairedFramesListRow.editPopoverContent` render an identical triple of rows: a
// mark-style row and two fade-style rows (fade-in, fade-out), above an identical
// pair of labeled text fields. Previously these were inlined at both call sites
// as two copies of the same ~55 lines. The helper views below consolidate that
// layout so the two popovers share a single source of truth for every row's
// structure, spacing, disabled styling, and list of selectable fade styles.
//
// The helpers are fileprivate because they are only used within this file and
// nowhere else in the codebase.

/// The mark-style row of a frames popover: an enable toggle, a static "Mark with:"
/// label whose foreground dims when disabled, and a segmented Picker offering
/// Asterisk / Caret / Number. The Picker is disabled whenever the toggle is off.
fileprivate struct FramesMarkRow: View {
    @Binding var enabled: Bool
    @Binding var style: MarkStyle
    private static let styleSegments: [SheetSegmentedControl<MarkStyle>.Segment] =
        [.init(.asterisk, "Asterisk"), .init(.caret, "Caret"), .init(.number, "Number")]

    var body: some View {
        HStack(spacing: 6) {
            // An AppKit checkbox, so it is a stop in the popover's Tab walk — see
            // SheetCheckbox (30_20).
            SheetCheckbox(isOn: $enabled)
            Text("Mark with:")
                .font(.system(size: 12))
                .foregroundStyle(enabled ? .primary : disabledControlTextColor)
            // An AppKit segmented control, as the sheet's other segmented pickers are —
            // see SheetSegmentedControl (30_20).
            SheetSegmentedControl(selection: $style, segments: Self.styleSegments)
                .frame(width: 165)
                .disabled(!enabled)
        }
    }
}

/// A fade row (used for both fade-in and fade-out) of a frames popover: an enable
/// toggle, a leading label (e.g. "Audio fade-in uses"), a menu Picker of
/// AudioFadeStyle options, and a trailing "in FCP." suffix. Both texts dim when
/// disabled; the Picker is disabled whenever the toggle is off.
fileprivate struct FramesFadeRow: View {
    let leadingLabel: String
    @Binding var enabled: Bool
    @Binding var style: AudioFadeStyle

    // The four selectable fade styles, as the menu's rows. Declared static so the
    // array allocation happens once at type load time rather than on every body
    // evaluation.
    private static let styleItems: [SheetPopUpButton<AudioFadeStyle>.Item] =
        [.linear, .scurve, .plus, .minus].map { .option(tag: $0, title: $0.displayName) }

    var body: some View {
        HStack(spacing: 6) {
            // An AppKit checkbox, so it is a stop in the popover's Tab walk — see
            // SheetCheckbox (30_20).
            SheetCheckbox(isOn: $enabled)
            Text(leadingLabel)
                .font(.system(size: 12))
                .foregroundStyle(enabled ? .primary : disabledControlTextColor)
            // An AppKit pop-up, as every menu picker in the sheet is — see
            // SheetPopUpButton (30_20).
            SheetMenuPicker(selection: $style, items: Self.styleItems, width: 85)
                .disabled(!enabled)
            Text("in FCP.")
                .font(.system(size: 12))
                .foregroundStyle(enabled ? .primary : disabledControlTextColor)
        }
    }
}

/// Which of the two rows a strict field belongs to, and therefore what it
/// accepts. Declared here rather than inside the row view so the seeding rules
/// below can be stated as plain functions of it.
fileprivate enum FramesFieldKind {
    case frames
    case timeCode
}

/// How a row's two strict halves become the one string the record stores, and
/// how a stored string is read back apart into two halves.
///
/// The join is the whole reason the strict mode is safe to turn on and off: it
/// produces exactly the shape the permissive single field always produced — one
/// element, one string — so nothing downstream of this view (the duplicate
/// check, the four-field record assembly, the right sidebar's read-only tables,
/// the export) can tell which mode wrote a given row.
fileprivate enum FramesRangeText {
    /// The most digits a strict-mode frame field accepts.
    ///
    /// A cap rather than an unbounded field, because the field it feeds is half a
    /// popover row wide and a runaway paste should be refused at the intercept
    /// rather than scrolled through.
    ///
    /// Applies only when `Preferences.strictFramesTableChecking` is on; the
    /// permissive field is uncapped, exactly as it always was.
    ///
    /// Held here rather than beside the table's geometry constants deliberately.
    /// Those live on `ReorderableFramesList`, which is a `View` and therefore
    /// inferred `@MainActor`; this value is read from `StrictFramesRangeRow.init`,
    /// which is not necessarily main-actor isolated. Keeping it on this plain enum
    /// means the read needs no isolation reasoning at all — and it belongs here on
    /// the merits anyway, being an input rule rather than a measurement.
    static let frameDigitLimit = 6

    /// En dash, spaced. The dash a range is written with in prose, not a hyphen.
    static let separator = " – "

    /// Every dash a stored record might have been written with, longest first so
    /// a multi-character form is never matched by one of its own characters.
    ///
    /// Records predate this mode, and were typed by hand — a hyphen or an em dash
    /// is as likely as the en dash this mode now writes. All three are read back
    /// as the same range so that opening an old record for editing shows two
    /// halves rather than one half containing a dash.
    private static let recognizedSeparators = [" – ", " — ", " - ", "–", "—", "-"]

    /// The one string the two halves write.
    ///
    /// A half-filled range writes the half that exists, with no dangling dash:
    /// "1200" rather than "1200 – ". A frame whose end has not been read off yet
    /// is a legitimate entry, and it must read the same as it would have in the
    /// permissive mode.
    static func join(_ leading: String, _ trailing: String) -> String {
        switch (leading.isEmpty, trailing.isEmpty) {
        case (true, true):   return ""
        case (false, true):  return leading
        case (true, false):  return trailing
        case (false, false): return leading + separator + trailing
        }
    }

    /// A stored value read back as two halves, splitting on the first recognized
    /// dash. A value with no dash is a single entry and becomes the leading half.
    static func split(_ raw: String) -> (leading: String, trailing: String) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        for separator in recognizedSeparators {
            if let range = value.range(of: separator) {
                return (String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces),
                        String(value[range.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return (value, "")
    }

    /// What a strict field is seeded with for a stored half.
    ///
    /// Seeding normalizes, but seeding alone writes nothing: the composed value
    /// is pushed to the binding only when the user actually edits a half, so
    /// merely opening an old row for editing cannot rewrite it, and the Update
    /// button stays disabled until something really changes. That is the same
    /// rule the permissive mode has always followed.
    static func seed(_ raw: String, kind: FramesFieldKind) -> String {
        switch kind {
        case .frames:
            return String(raw.filter(\.isASCIIDigit).prefix(FramesRangeText.frameDigitLimit))
        case .timeCode:
            return TimeCodeText.normalizedForDisplay(raw)
        }
    }
}

// MARK: - Time Code Range Display

/// A stored time-code value drawn as three horizontal sub-columns — the
/// beginning code left-aligned, the dash centered, the ending code
/// right-aligned — rather than as one run of text.
///
/// **What this buys.** Time codes are written "##:##:##", so the two halves of a
/// range are the same character count on essentially every row. In a
/// proportional face they are nonetheless not the same *width*: a row of "1"s
/// measures visibly narrower than a row of "8"s, so a left-aligned single run
/// leaves the dash and the ending code landing at a slightly different x on
/// every row. That reads as raggedness in a column whose contents are, by
/// construction, uniform. Pinning each part to its own sub-column fixes the
/// dash's position outright and pins both codes to the outer edges of the
/// group, which is where the eye reads the column boundary. A monospaced face
/// would also fix it, and was rejected: at these column widths the digit
/// advance it forces costs more horizontal space than the table has.
///
/// **Why it is not applied unconditionally.** The permissive entry mode accepts
/// arbitrary text, so a stored value is not guaranteed to be a range of time
/// codes at all — it may be prose, a single code, a placeholder dash, or a
/// legacy record of any shape. Fixed sub-columns would truncate those. This
/// view therefore uses the aligned layout only for a value it has measured as
/// fitting, and falls back to the plain flexible run that the tables drew
/// before it existed for everything else.
///
/// **Why the widths are measured rather than derived.** An earlier version
/// estimated glyph advances as fractions of the point size. The estimates ran
/// low, the sub-columns came out narrower than a full "00:00:00", and both ends
/// of every range truncated — the one outcome this view must not produce, since
/// a value that fit as a single run cannot stop fitting merely because it has
/// been distributed across sub-columns. The widths now come from AppKit's own
/// text measurement of the exact strings involved, at the exact font the labels
/// draw in, so the aligned group is the width of the widest range the column
/// can hold as a single run: two full time codes plus the separator between them.
///
/// The caller supplies the surrounding frame and alignment; this view sizes to
/// its content in both modes.
struct TimeCodeRangeText: View {
    /// The stored value, exactly as the record holds it.
    let text: String

    /// Point size the value is drawn at. Also the basis for every width below,
    /// so a caller at a different size gets sub-columns measured to match rather
    /// than sub-columns tuned for 12pt.
    var fontSize: CGFloat = 12

    /// The shape a half can hold, with `#` standing for a numeral. The half
    /// sub-column is measured against this shape filled with the widest numeral.
    ///
    /// The widest numeral rather than "0": the system face's numerals are
    /// proportional (at 12pt "1" is 5.6pt, "0" 7.6pt, "4" 7.7pt), so "00:00:00"
    /// is not the widest code. Measured against it, a half like "04:44:48"
    /// overran its sub-column and that row fell back to the plain run, leaving
    /// its dash out of line with the rest of the column.
    private static let referenceShape = "##:##:##"

    /// The two sub-column widths for a given point size.
    private struct Metrics {
        /// Rendered width of `referenceShape` in the widest numeral, and
        /// therefore of each half's sub-column.
        let half: CGFloat
        /// Rendered width of the stored separator *including* its spaces.
        ///
        /// Measuring the spaced form rather than the bare dash is what keeps
        /// this layout the same total width as the single run: the run drew
        /// " – " between the halves, so the sub-column that replaces it must
        /// occupy exactly that, no more. The dash is then centered within it,
        /// which reproduces the old spacing as well as the old width.
        let dash: CGFloat
    }

    /// Measured metrics, memoized per point size.
    ///
    /// Text measurement is not free and this view draws once per table row, so
    /// the result is cached. Main-actor isolated rather than
    /// `nonisolated(unsafe)`: the only caller is `body`, which is already on the
    /// main actor, so the isolation costs nothing and the cache needs no
    /// synchronization reasoning.
    @MainActor private static var metricsCache: [CGFloat: Metrics] = [:]

    @MainActor private static func metrics(fontSize: CGFloat) -> Metrics {
        if let cached = metricsCache[fontSize] { return cached }

        // `NSFont.systemFont(ofSize:)` is the same face SwiftUI's
        // `.system(size:)` resolves to at these sizes and weights, so measuring
        // through AppKit describes what SwiftUI will actually draw.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize)
        ]

        // Rounded up rather than to nearest: a sub-column a fraction of a point
        // narrower than its content truncates, and a fraction wider costs
        // nothing that matters.
        let widestHalf = "0123456789".map { digit in
            (referenceShape.replacingOccurrences(of: "#", with: String(digit)) as NSString)
                .size(withAttributes: attributes).width
        }.max() ?? 0
        let measured = Metrics(
            half: widestHalf.rounded(.up),
            dash: (FramesRangeText.separator as NSString)
                .size(withAttributes: attributes).width.rounded(.up)
        )

        metricsCache[fontSize] = measured
        return measured
    }

    /// The dash drawn between the halves: the stored separator without its
    /// spaces, since the sub-column supplies the spacing here. Taken from
    /// `FramesRangeText` rather than restated, so the glyph shown always matches
    /// the glyph written.
    private static let dashGlyph =
        FramesRangeText.separator.trimmingCharacters(in: .whitespaces)

    /// Whether a half is a well-formed time code: numerals and colons only.
    ///
    /// A shape test rather than a width test. A half carrying letters or
    /// punctuation may well be narrow enough to fit a sub-column, but it is not
    /// a time code, and pinning it to the outer edge of one would misrepresent
    /// it as the end of a range.
    private static func isTimeCodeShaped(_ half: String) -> Bool {
        !half.isEmpty && half.allSatisfy { $0 == ":" || $0.isASCIIDigit }
    }

    /// The two halves, if and only if both exist, both are time-code shaped, and
    /// both fit their sub-column.
    ///
    /// The fit test is belt-and-braces for a well-formed code: the sub-column is
    /// `referenceShape` in the widest numeral, so no "##:##:##" can exceed it. A
    /// hand-typed value with extra digits could, though, and that value must fall
    /// back rather than lose its tail — which is the failure this whole block
    /// exists to prevent.
    @MainActor private func alignedHalves(within metrics: Metrics)
        -> (leading: String, trailing: String)? {
        let halves = FramesRangeText.split(text)
        guard Self.isTimeCodeShaped(halves.leading),
              Self.isTimeCodeShaped(halves.trailing)
        else { return nil }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize)
        ]
        let leadingWidth = (halves.leading as NSString)
            .size(withAttributes: attributes).width
        let trailingWidth = (halves.trailing as NSString)
            .size(withAttributes: attributes).width

        guard leadingWidth <= metrics.half, trailingWidth <= metrics.half else {
            return nil
        }
        return halves
    }

    var body: some View {
        let metrics = Self.metrics(fontSize: fontSize)

        return Group {
            if let halves = alignedHalves(within: metrics) {
                // Spacing is 0 and every gap comes from a sub-column's own
                // measured width, so the group totals what the widest possible
                // range occupies as a single run — a point or two more than
                // "00:00:00 – 00:00:00", which the flexible column absorbs.
                HStack(spacing: 0) {
                    Text(halves.leading)
                        .frame(width: metrics.half, alignment: .leading)
                    Text(Self.dashGlyph)
                        .frame(width: metrics.dash, alignment: .center)
                    Text(halves.trailing)
                        .frame(width: metrics.half, alignment: .trailing)
                }
            } else {
                Text(text)
            }
        }
        .font(.system(size: fontSize))
        .lineLimit(1)
        // Reachable only on the fallback branch — an aligned half is measured to
        // fit before its frame is ever drawn — but kept for that branch, which
        // draws exactly what the tables drew before this view existed.
        .truncationMode(.tail)
    }
}

/// One strict row: a label, two equal-width validated fields, and the dash
/// between them.
///
/// The two halves are this view's own state, and the bound record string is
/// written from them. Holding it this way is what keeps the strict mode entirely
/// inside these fields — the popovers, their Add and Update enablement, and every
/// commit path go on reading and writing one string per row, exactly as they do
/// when the preference is off.
fileprivate struct StrictFramesRangeRow: View {
    let label: String
    let kind: FramesFieldKind
    let placeholder: String
    @Binding var text: String

    @State private var leading: String
    @State private var trailing: String

    init(label: String, kind: FramesFieldKind, placeholder: String, text: Binding<String>) {
        self.label = label
        self.kind = kind
        self.placeholder = placeholder
        self._text = text
        // Seeded from the stored value at construction rather than in onAppear.
        // A popover's content is built when it is presented and discarded when it
        // closes, so this runs exactly once per editing session — and it runs
        // before the first draw, which is what keeps the fields from flashing
        // empty behind an existing record.
        let halves = FramesRangeText.split(text.wrappedValue)
        _leading  = State(initialValue: FramesRangeText.seed(halves.leading, kind: kind))
        _trailing = State(initialValue: FramesRangeText.seed(halves.trailing, kind: kind))
    }

    /// Digits for a frame number; digits and colons for a time code.
    private var maxDigits: Int {
        switch kind {
        case .frames:   return FramesRangeText.frameDigitLimit
        case .timeCode: return TimeCodeText.digitCount
        }
    }

    private var style: DigitTextField.Style {
        switch kind {
        case .frames:   return .digits
        case .timeCode: return .timeCode
        }
    }

    var body: some View {
        // The label hugs the leading edge at its own fixed width; the field
        // group (leading half, dash, trailing half) hugs the trailing edge.
        // The `Spacer` between them is what does the work — it absorbs
        // whatever width the row has beyond the label and the fields, so the
        // two halves' right edge lands at the row's right edge regardless of
        // how wide the popover happens to be, rather than sitting wherever
        // the label's fixed width plus fixed field widths happen to end.
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: PairedEntryFields.labelWidth, alignment: .leading)

            Spacer(minLength: PairedEntryFields.rowSpacing)

            HStack(spacing: PairedEntryFields.rowSpacing) {
                // The leading half advances to the trailing one on fill; the
                // trailing one does not advance at all. See `advancesOnFill`.
                field($leading, advancesOnFill: true)

                // The dash the two halves are joined with, shown between them
                // so the row reads as the range it will be stored as.
                Text("–")
                    .font(.system(size: 12))

                field($trailing, advancesOnFill: false)
            }
        }
        .frame(maxWidth: .infinity)
        // Composed on every keystroke, so the Add and Update buttons measure the
        // same value the commit will write. Writing only on change is deliberate:
        // an untouched row never has its stored text rewritten by being looked at.
        .onChange(of: leading)  { _, _ in compose() }
        .onChange(of: trailing) { _, _ in compose() }
        // Belt and braces against the halves outliving an editing session.
        //
        // The seeding above happens in `init`, which SwiftUI honors only the FIRST
        // time a given view identity appears — so it is correct only if a popover's
        // content is genuinely torn down when it closes. It is, but that is a
        // framework behavior this view would be silently wrong about if it ever
        // changed: reopening the popover on a DIFFERENT row would show the previous
        // row's halves, and the commit would then write them. `onAppear` runs on
        // every presentation, so re-seeding here closes that gap regardless.
        //
        // Guarded on disagreement, and idempotent when it does run — seeding an
        // already-seeded value returns it unchanged — so the ordinary case does two
        // string comparisons and nothing else. Deliberately does NOT write to
        // `text`: a legitimate disagreement also arises the moment an unnormalized
        // legacy record is seeded ("1:23:45" displayed as "01:23:45"), and that
        // must not be committed by merely opening the row.
        .onAppear {
            guard FramesRangeText.join(leading, trailing) != text else { return }
            let halves = FramesRangeText.split(text)
            leading  = FramesRangeText.seed(halves.leading, kind: kind)
            trailing = FramesRangeText.seed(halves.trailing, kind: kind)
        }
    }

    /// Both halves use a fixed `PairedEntryFields.fieldWidth` rather than
    /// `maxWidth: .infinity`, since the row no longer divides the popover's free
    /// width between them. A strict field holds at most six digits
    /// (`FramesRangeText.frameDigitLimit`) or an eight-character time code
    /// ("00:00:00"), and `fieldWidth` fits exactly that, with the field's own
    /// `isScrollable` cell as the safety margin for a rare long value. Fixed
    /// widths on both halves also let `PairedEntryFields.doubleFieldRowWidth` —
    /// what the permissive mode's single field matches — be a closed-form sum.
    ///
    /// **On when the zero-completion lands.** A partial time code completes when
    /// the field's editing session ends, and the commit buttons read the draft at
    /// click time. The two are correctly ordered because AppKit resigns the field
    /// editor on the mouse-DOWN that moves focus to the button — posting
    /// `controlTextDidEndEditing`, and therefore completing/recomposing — before
    /// the button's action runs on mouse-up (the same ordering
    /// `CurrencyInputField`'s digit padding and dollars auto-fill depend on).
    /// Worth noting: getting this wrong is easy to misread as corruption but
    /// isn't — every keystroke pushes to the binding via `controlTextDidChange`
    /// regardless, so worst case a partial entry commits as typed, same as
    /// permissive mode. Nothing is lost, mispaired, or written to the wrong row.
    ///
    /// **On `advancesOnFill`.** True for the leading half only, so completing it
    /// hands focus to the half beside it — where the next keystroke belongs. The
    /// trailing half is left alone: advancing from it would throw focus out of the
    /// row into whatever the popover places next, unrequested. The field defers
    /// the move by one main-queue hop rather than moving inside the keystroke; see
    /// `DigitTextField.Coordinator.controlTextDidChange` for why.
    ///
    /// Nothing about the composed value changes either way: both halves push
    /// every keystroke to their binding, and `compose()` runs off `onChange` of
    /// either, so the row's stored string is identical regardless of how focus moved.
    private func field(_ binding: Binding<String>, advancesOnFill: Bool) -> some View {
        DigitTextField(text: binding,
                       maxLength: maxDigits,
                       style: style,
                       alignment: .natural,
                       placeholder: placeholder,
                       advancesOnFill: advancesOnFill)
            // Fixed width and fixed height both now — see the note above the
            // row's `body`. The `width:height:` overload is what takes both as
            // plain fixed values; the `minHeight:maxHeight:` pair only exists
            // on the flexible overload, which does not accept `width:` at all
            // (hence the "Extra argument" error when the two were combined).
            .frame(width: PairedEntryFields.fieldWidth,
                   height: Self.fieldHeight)
    }

    /// Matches the height AppKit gives a rounded-bezel text field at 13pt, which
    /// is what the permissive mode's `.roundedBorder` fields draw at.
    private static let fieldHeight: CGFloat = 22

    private func compose() {
        let composed = FramesRangeText.join(leading, trailing)
        if composed != text { text = composed }
    }
}

/// The two labeled text-field rows both entry popovers open with.
///
/// Laid out the way `ViewingDatesTable`'s add and edit popovers lay out their
/// date and version rows: a fixed-width leading label followed by the control,
/// so the two fields are the same width and share a left edge. Extracted so the
/// add and edit popovers cannot drift apart in label width, spacing, or
/// placeholder wording — the same argument that produced `FramesMarkRow` above.
///
/// Two shapes, one contract. Which one is drawn is decided by
/// `Preferences.strictFramesTableChecking`; both write the same two strings, so
/// nothing above or below this view is aware of the difference.
fileprivate struct PairedEntryFields: View {
    @Binding var frameText: String
    @Binding var timecodeText: String

    /// Read here rather than passed in, so both popovers pick the mode up from
    /// one place and a change to the preference reaches an open popover without
    /// either of them having to carry the value down.
    @AppStorage(preference: Preferences.strictFramesTableCheckingKey)
        private var strictChecking: Bool

    /// Wide enough for "Time Codes:" at 12pt, which is the longer of the two
    /// labels and therefore the one that sets the column.
    fileprivate static let labelWidth: CGFloat = 80
    fileprivate static let rowSpacing: CGFloat = 7

    /// The width of one strict-mode half-field (`StrictFramesRangeRow`'s
    /// `leading`/`trailing` fields).
    ///
    /// Sized to what the fields actually hold — up to six digits
    /// (`FramesRangeText.frameDigitLimit`) or an eight-character time code
    /// ("00:00:00") — rather than an equal split of the popover's width.
    /// `DigitTextField` sets its cell's `isScrollable`, so a value that briefly
    /// runs longer mid-edit scrolls in place instead of clipping.
    ///
    /// 78, not the original 62/72 estimates. The binding constraint is the time
    /// code: `DigitTextField` draws at `monospacedDigitSystemFont(ofSize: 13)`,
    /// where "00:00:00" measures ~51pt of glyphs plus a rounded-bezel cell's own
    /// insets/border. 62 left the last digits scrolling against the edge while
    /// typing — the fallback `isScrollable` is meant for, not the normal case.
    /// 82 was reached by measuring the rendered field rather than deriving it
    /// (the bezel spends more around its text than arithmetic suggested) and
    /// seats the full code outright; trimmed by 4pt per field afterward to tighten
    /// the popover now that the field group is right-aligned rather than
    /// hugging the label. The trailing `isScrollable` cell remains the safety
    /// margin for a value that briefly runs longer mid-edit.
    ///
    /// Both field kinds take the same width deliberately: the frame fields hold
    /// at most six digits (~47pt) and would fit in less, but different widths
    /// per half would read as misalignment rather than a tighter fit.
    fileprivate static let fieldWidth: CGFloat = 78

    /// The rendered width of the "–" separator `StrictFramesRangeRow` draws
    /// between its two halves, at the row's 12pt text size.
    ///
    /// Not pixel-measured — the separator is a bare `Text` with no frame of
    /// its own, so its true width is whatever SwiftUI's intrinsic sizing
    /// gives it — but close enough that `doubleFieldRowWidth` below, which
    /// cannot read that intrinsic value, comes out visually flush with the
    /// strict row it is matching.
    private static let dashWidth: CGFloat = 12

    /// The full width a strict row's control area occupies: both halves plus
    /// the separator and the spacing on either side of it.
    ///
    /// This is what the permissive mode's single field is sized to below —
    /// per the same reasoning `ListRowMetrics` states for the table proper,
    /// a field one mode draws and a field the other draws are describing the
    /// same stored value, and should occupy the same footprint whichever mode
    /// is active, rather than the permissive field defaulting to whatever
    /// space happens to be left over once the popover's other rows are laid
    /// out.
    fileprivate static let doubleFieldRowWidth: CGFloat =
        fieldWidth * 2 + rowSpacing * 2 + dashWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if strictChecking {
                // Strict mode: each row is a validated range.
                StrictFramesRangeRow(label: "Frames:",
                                     kind: .frames,
                                     placeholder: "000000",
                                     text: $frameText)
                StrictFramesRangeRow(label: "Time Codes:",
                                     kind: .timeCode,
                                     placeholder: "00:00:00",
                                     text: $timecodeText)
            } else {
                HStack(spacing: Self.rowSpacing) {
                    Text("Frames:")
                        .font(.system(size: 12))
                        .frame(width: Self.labelWidth, alignment: .leading)
                    TextField("Frame number", text: $frameText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: Self.doubleFieldRowWidth)
                }
                HStack(spacing: Self.rowSpacing) {
                    Text("Time Codes:")
                        .font(.system(size: 12))
                        .frame(width: Self.labelWidth, alignment: .leading)
                    TextField("Time code", text: $timecodeText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: Self.doubleFieldRowWidth)
                }
            }
        }
        // Keyed on the mode so that toggling the preference while a popover is
        // open rebuilds these rows — and therefore re-seeds the strict halves
        // from the current record — rather than leaving stale state behind.
        .id(strictChecking)
    }
}

// MARK: - Reorderable Frames List Component

/// The Notes tab's single frames table: one row per moment in the film, holding
/// a HandBrake frame, its corresponding time code, and the mark and fade
/// metadata that applies to both.
///
/// Two arrays in, two arrays out. Row n is `frames[n]` paired with
/// `timecodes[n]`, which is the relationship the two separate tables always had
/// by convention; expressing it in the component is what makes it hold.
struct ReorderableFramesList: View {

    @Binding var frames: [String]
    @Binding var timecodes: [String]

    /// Which build wave this table belongs to. `0` — the default — builds it
    /// synchronously, exactly as before.
    ///
    /// The gate lives INSIDE this component rather than at the call site, and
    /// that placement is the point: the stand-in has to be the table's exact
    /// height, and that height is a function of the two arrays. Computing it in
    /// the owning tab's body would read `frames.count` and `timecodes.count`
    /// there, putting both arrays into the tab's observation set — precisely the
    /// coupling `NotesLegendSection` and `FilmSheetListRow` were extracted
    /// to break, and which would make adding a single frame entry re-render the
    /// whole tab again. Read here, they are already this view's own inputs and
    /// cost nothing new.
    ///
    /// See `DeferredFieldContent` (30_20_FSControlHelpers.swift) for the rest.
    var renderWave: Int = 0

    /// Tells any row holding an open popover to close it.
    ///
    /// Two things drive it, and both are cases where a row's popover would
    /// otherwise be left anchored to something that has moved out from under it:
    /// a scroll of the enclosing sheet, and a drag-to-reorder. The second is the
    /// same guarantee the string list's `endEditing()` expresses for an in-row
    /// editor — no editor may outlive the arrangement of rows it was opened
    /// against.
    ///
    /// A publisher rather than a `scrollY` value passed down into every row.
    /// Both express the same thing, but a stored value is an *input* to each
    /// row: changing it invalidated all of them, so a single scroll re-evaluated
    /// up to 99 row bodies to let at most one of them close a popover.
    /// `.onReceive` is not an input — the publisher's identity is stable across
    /// scrolls — so only the row that actually reacts writes state and
    /// re-renders.
    @State private var dismissRowPopovers = PassthroughSubject<Void, Never>()

    // MARK: Import Popover State
    //
    // The presentation flag, so a scroll or a reorder can close the popover, and the
    // both-lists replace mode, which the popover resolves on open. The drafted text
    // lives in the popover and opens empty on every presentation. Mirrors
    // ReorderableStringList.

    @State private var showImportPopover = false
    @State private var importReplaces = false

    // Add-popover state (owned by the parent list, not per-row)
    /// Bumped each time a row is committed, which is what asks the add row to
    /// scroll itself back into the viewport. See `ListAddRowRevealer`.
    @State private var addRevealToken = 0

    @State private var showAddPopover = false

    /// Whether the clear-table confirmation is up.
    ///
    /// A destructive action with no undo, so it is confirmed rather than merely
    /// performed — the same standard the single-row delete meets by living
    /// behind a popover the user had to open first. There is no such gesture in
    /// front of this one, so the alert supplies it.
    @State private var showClearAlert = false

    @State private var addFrameText = ""
    @State private var addTimecodeText = ""
    @State private var addEntryMarkEnabled = false
    @State private var addEntryMarkStyle  = MarkStyle.asterisk
    @State private var addEntryFadeInEnabled = false
    @State private var addEntryFadeIn = AudioFadeStyle.scurve
    @State private var addEntryFadeOutEnabled = false
    @State private var addEntryFadeOut = AudioFadeStyle.scurve

    /// Hard cap on row count, matching the two-digit index column the rows
    /// render. Named rather than repeated as a literal at the sites that enforce
    /// it, which previously had to be kept in step by hand.
    private static let maxItems = 99

    // MARK: Row Geometry
    //
    // Row height, per-row inset, list padding, and every control dimension come
    // from `ListRowMetrics` (30_20_FSControlHelpers.swift), shared with
    // `ReorderableStringList` so the sheet's tables cannot drift apart. Only the
    // measurements specific to this table live here.

    /// Width of the mark/fade indicator block on an entry row, and of the
    /// stand-in the add row draws in its place.
    ///
    /// `fileprivate` rather than `private` so `PairedFramesListRow` reads the
    /// same value instead of restating the literal: the add row's stand-in and
    /// the real block have to be the same width or the trailing controls fall
    /// out of column.
    /// Composed from the parts below rather than stated as a literal, so the
    /// block and its contents cannot disagree: a row draws the mark container,
    /// then the two fade pairs — the mark-to-pair gap set by
    /// `metadataGlyphSpacing`, the pair-to-pair gap by `pairGroupSpacing`.
    /// Changing any of the four constants resizes the block — and, with it, the
    /// add row's stand-in — automatically.
    fileprivate static let metadataBlockWidth: CGFloat =
        markGlyphWidth + 2 * fadePairWidth + metadataGlyphSpacing + pairGroupSpacing

    /// Gap between the mark container and the first fade pair.
    fileprivate static let metadataGlyphSpacing: CGFloat = 4

    /// Gap between the two fade pairs themselves.
    fileprivate static let pairGroupSpacing: CGFloat = 3

    /// Gap between the metadata glyph block and the edit button.
    fileprivate static let trailingGlyphGap: CGFloat = 6

    /// Width of the mark container. One glyph at 12pt, so the container is the
    /// glyph's own size.
    fileprivate static let markGlyphWidth: CGFloat = 12

    /// Gap between the two glyphs WITHIN one fade pair — the direction arrow and
    /// the curve shape that qualifies it.
    ///
    /// The two glyphs of a pair are one statement ("fades in, on an S-curve"),
    /// and setting them closer to each other than either sits to anything else is
    /// what makes them read as one rather than as two adjacent marks.
    fileprivate static let fadeGlyphSpacing: CGFloat = 1

    /// Width of one fade pair: the 12pt direction arrow, the intra-pair gap, and
    /// the 16pt curve glyph. Stated as the sum so the fixed frame can never be
    /// wider than what it contains — slack in that frame would center the pair
    /// inside it and undo the tightening above.
    fileprivate static let fadePairWidth: CGFloat = 12 + fadeGlyphSpacing + 16

    /// Width of the leading index column, and of the stand-in the add row draws
    /// in its place so the placeholder's first glyph lines up with the text of
    /// every row above it.
    fileprivate static let indexColumnWidth: CGFloat = 24

    /// Advance width of one glyph in the index's monospaced 12pt font.
    ///
    /// SF Mono advances at 0.6em, so every character in the index — both
    /// numerals and the period — occupies exactly this much. Having the value
    /// named is what lets the clear-table control be centered on the numerals
    /// rather than on the column, without measuring text at layout time.
    fileprivate static let indexGlyphAdvance: CGFloat = 12 * 0.6

    /// Horizontal correction that moves the clear-table control off the center
    /// of the index column and onto the center of the numerals within it.
    ///
    /// The index is drawn trailing-aligned as three monospaced characters —
    /// two numerals and a period — so the numerals end one advance short of the
    /// column's trailing edge, putting their center at
    /// `indexColumnWidth - 2 * indexGlyphAdvance`. The column's own center is
    /// half its width, and the difference between the two is this offset: 2.4pt
    /// left at the current geometry.
    ///
    /// Applied as an `.offset` rather than by narrowing the control's frame,
    /// because the control is 20pt wide inside a 24pt column and any frame that
    /// centers it correctly would be narrower than the control itself. `.offset`
    /// moves hit testing along with the drawing, so the target stays under the
    /// glyph.
    fileprivate static let clearButtonCenteringOffset: CGFloat =
        (indexColumnWidth - 2 * indexGlyphAdvance) - indexColumnWidth / 2

    /// Gap between the index's period and the first data column.
    ///
    /// The index is drawn trailing-aligned inside `indexColumnWidth`, so a
    /// two-digit index already sits a few points in from that column's leading
    /// edge; matching the gap on the right of the period to that inset is
    /// what makes the index read as a label attached to its row rather than
    /// as a column of its own.
    fileprivate static let indexTrailingGap: CGFloat = 3

    /// Gap between the index/frames group and the time-code column.
    ///
    /// Tightened from the row's original uniform 8pt spacing to 6pt, to help
    /// fund the frames column's widened value, while staying visibly wider
    /// than the tighter, intra-group gaps (`indexTrailingGap`,
    /// `metadataGlyphSpacing`, `pairGroupSpacing`) so the boundary between
    /// distinct columns still reads as more significant than the boundary
    /// between elements grouped within one.
    fileprivate static let indexGroupTrailingGap: CGFloat = 6

    /// Gap between the time-code column and the metadata glyph block.
    ///
    /// Tightened from the row's original uniform 8pt spacing to 6pt, for the
    /// same reason as `indexGroupTrailingGap` and to the same value, so the
    /// two column boundaries either side of the flexible time-code column
    /// remain visually consistent with each other.
    fileprivate static let timecodeTrailingGap: CGFloat = 6

    /// Width of the frames column.
    ///
    /// Fixed rather than sized to content, so every row's frame number begins at
    /// the same x and — because this column no longer varies — so does every
    /// row's time code. The metadata glyphs already worked this way; the two text
    /// columns now match them, which is what lets the table be read down a
    /// column instead of across each row.
    ///
    /// Widened from 96pt through several earlier compressions of the metadata
    /// glyph block (see `metadataGlyphSpacing`'s and `pairGroupSpacing`'s
    /// history), then grown substantially further here — funded first by
    /// tightening `indexTrailingGap`, `indexGroupTrailingGap`, and
    /// `timecodeTrailingGap`, with the remainder necessarily coming out of the
    /// flexible time-code column's own width, since no further gap could be
    /// tightened without the row's distinct columns losing their separation
    /// entirely. The time-code column, being the one flexible element in the
    /// row, is the correct place for a requirement this size to land once the
    /// fixed gaps have given up what they reasonably can.
    fileprivate static let frameColumnWidth: CGFloat = 108

    /// Shared by the add and edit popovers, so the two are the same size and
    /// their identical contents cannot be laid out against different widths.
    ///
    /// Narrowed alongside `PairedEntryFields.fieldWidth` and
    /// `doubleFieldRowWidth`, but not by the same amount: the field row was the
    /// widest row before this pass, but once its fields no longer claim the full
    /// available width, the widest row becomes one of the two `FramesFadeRow`s —
    /// "Audio fade-out uses" plus its picker and "in FCP." suffix is the longest
    /// single line this popover draws. This value keeps that row comfortably on
    /// one line with its prior margin, so the popover shrinks by only what the
    /// freed field space allows.
    ///
    /// Now stated as `ViewingDatesTable`'s popover width, so every popover the
    /// FilmSheet presents from a table is one size. The row that sets the floor
    /// is still a `FramesFadeRow`, clearing 290 with room to spare (~271pt for
    /// its checkbox, label, menu, and suffix). The field row, wider than before
    /// (see `fieldWidth`), comes to 80 + 7 + 82 + 7 + 12 + 7 + 82 = 277pt — still
    /// not the widest.
    fileprivate static let entryPopoverWidth: CGFloat = 290

    /// The number of paired rows the table shows.
    ///
    /// The longer of the two arrays. They are equal in every record this
    /// component has ever written; taking the maximum is what keeps a legacy
    /// pair of unequal arrays fully visible rather than silently truncating the
    /// longer one to the length of the shorter.
    private var rowCount: Int { max(frames.count, timecodes.count) }

    /// Rows drawn: every paired entry, plus the unconditional trailing add row.
    private var displayedRowCount: Int { rowCount + 1 }

    /// Computed height that exactly matches content.
    private var listHeight: CGFloat {
        ListRowMetrics.listHeight(rowCount: displayedRowCount)
    }

    /// Whether the table has room for another row. At the cap the add row stays
    /// visible but inert: its "+" is disabled and grays out, which states the
    /// limit rather than silently removing the control.
    private var canAdd: Bool { rowCount < Self.maxItems }

    /// The pending "this already exists" confirmation, or `nil` when there is
    /// none. Held on the table rather than on the row or popover that raised it:
    /// both commit paths dismiss their popover on the same interaction, so an
    /// alert anchored there would be torn down before it could be answered.
    @State private var duplicatePrompt: ListDuplicatePrompt?

    /// Whether the add popover's draft would produce a storable row.
    ///
    /// Measured on the finished pair, which is exactly what `commitAdd` writes,
    /// so "the button was enabled" and "there is something to write" are one
    /// statement rather than two that must agree. A draft of nothing but commas
    /// or whitespace in both fields yields `nil` here and leaves Add disabled,
    /// rather than closing the popover and producing no row.
    private var isAddButtonEnabled: Bool { assembledAddPair() != nil }

    // MARK: - Body

    var body: some View {
        // `listHeight` is exactly what `listContainer` hands to
        // `listContainerChrome(height:)`, so a deferred build reserves the space
        // the finished table will occupy and the swap moves nothing.
        DeferredFieldContent(wave: renderWave, placeholderHeight: listHeight) {
            listContainer
        }
    }

    /// The table itself. Split out of `body` so the whole of it — the `List`, its
    /// chrome, the scroll observer, and both alerts — is what the wave gate
    /// defers, rather than only part of it.
    private var listContainer: some View {
        List {
            // `id: \.self` is what selects `ForEach`'s data-and-identity
            // initializer over the constant-range one, which is the distinction
            // that actually matters here: the row count changes with every add,
            // delete, and import, and the constant-range form does not support
            // that. Stating the identity is sufficient for it — the range needs
            // no `Array` around it, which is what the string and text lists have
            // always done with `items.indices` (the same `Range<Int>` type).
            // Materializing one allocated a fresh array on every body pass, up
            // to 99 elements, for a value `ForEach` reads and discards.
            ForEach(0..<rowCount, id: \.self) { index in
                PairedFramesListRow(
                    index: index,
                    // Each row receives only its own two records, never the
                    // arrays. Handing the arrays down would make every row an
                    // observer of every edit, so a single commit would
                    // re-evaluate up to 99 row bodies.
                    frameRecord: index < frames.count ? frames[index] : nil,
                    timecodeRecord: index < timecodes.count ? timecodes[index] : nil,
                    dismissRowPopovers: dismissRowPopovers,
                    // The arrays live here, so the duplicate comparison, the
                    // position verification, and both writes do too. The row
                    // hands over the finished pair and the pair it opened
                    // against; see `updateRow` and `deleteRow`.
                    onUpdate: { pair, expectedFrame, expectedTimecode in
                        updateRow(at: index,
                                  to: pair,
                                  expectingFrame: expectedFrame,
                                  expectingTimecode: expectedTimecode)
                    },
                    onDelete: { expectedFrame, expectedTimecode in
                        deleteRow(at: index,
                                  expectingFrame: expectedFrame,
                                  expectingTimecode: expectedTimecode)
                    }
                )
                .listRowInsets(ListRowMetrics.rowInsets)
            }
            .onMove { source, destination in
                // Editors must close before the move, on the same terms as the
                // string list's `endEditing()`: a popover is anchored to a row
                // at a position, and the move redefines what occupies it.
                //
                // In practice a transient `NSPopover` is dismissed by the drag's
                // own mouseDown before this runs, so this is the belt to that
                // brace — and the `expecting` checks on both the update and the
                // delete are what make a late commit safe rather than merely
                // unlikely.
                closeAllEditors()
                // Both arrays move together, which is the guarantee two separate
                // tables could not make. `mutate` normalizes first, so the
                // offsets are valid in both even for a legacy uneven pair.
                mutate { f, t in
                    f.move(fromOffsets: source, toOffset: destination)
                    t.move(fromOffsets: source, toOffset: destination)
                }
            }

            // The add row, outside the `ForEach` and therefore outside
            // `.onMove` — it is not an entry, so it must be neither draggable
            // nor a valid drop destination. `.onMove` bounds both the source and
            // the destination to its own `ForEach`'s range, so keeping this a
            // sibling gives that for free.
            addRow
                // The add row's leading indent flips with the table's emptiness
                // (see `addRow`: the index-column stand-in is only reserved once
                // there is a row to align against). That flip must not slide —
                // animating a horizontal shift of the placeholder concurrently
                // with a row insert reads as the label being dragged sideways by
                // the row rather than as the column simply appearing.
                .animation(nil, value: rowCount == 0)
                // Brings this row back into the viewport after a commit pushes
                // it down. A background contributes no layout and consumes no
                // events, so the row is unaffected.
                .background(ListAddRowRevealer(token: addRevealToken))
                .listRowInsets(ListRowMetrics.rowInsets)
        }
        // List style, sizing, clip, border, and shadow — one modifier, shared with the
        // string and text lists so all three tables are drawn identically and in
        // the same order. The order is load-bearing: sizing before the clip is
        // what keeps the last alternating background band's overhang from
        // escaping it as a one-point sliver below the border. The full account is
        // on `listContainerChrome(height:)` (30_20_FSControlHelpers.swift).
        .listContainerChrome(height: listHeight)
        // Scroll detection, done in AppKit rather than in SwiftUI.
        // `ScrollActivityObserver` (30_20_FSControlHelpers.swift) watches the
        // enclosing clip view's bounds — the signal AppKit already posts for its
        // own use — so SwiftUI does no work at all until something actually has
        // to change, which with the per-row `.onReceive` means only when a
        // popover is open.
        .background(
            ScrollActivityObserver {
                closeAllEditors()
            }
        )
        // Raised by `commitAdd` and by a row's Update when the finished pair
        // already exists verbatim on another row.
        .listDuplicateAlert($duplicatePrompt)
        // Attached to the List rather than to the button that raises it, for the
        // reason `duplicatePrompt` is held here: the add row is rebuilt as the
        // table's contents change, and an alert anchored to a view that the
        // confirmed action itself destroys has nothing left to dismiss from.
        .alert("Clear Table Contents", isPresented: $showClearAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear Table", role: .destructive) { clearTable() }
        } message: {
            Text("Are you sure you want to clear the HandBrake Frames table's contents? This action cannot be undone unless all changes to the sheet are discarded.")
        }
    }

    // MARK: - Add Row

    /// The table's trailing row: a permanent invitation to add the next entry.
    ///
    /// Its "+" opens the add popover rather than an inline field. That
    /// divergence from `ReorderableStringList` is forced by the model: a row is
    /// two text values plus three toggles and pickers, which a one-line row
    /// cannot express. The row is the trigger; the popover is the editor,
    /// exactly as it already is for the per-row "info" button.
    private var addRow: some View {
        HStack(spacing: 8) {
            // The index column and the first data column, grouped so the gap
            // after the period is set by `indexTrailingGap` here exactly as it
            // is on an entry row — the placeholder therefore begins precisely
            // where a row's frame number does.
            HStack(spacing: Self.indexTrailingGap) {
                // The index column's slot on the add row. It holds one of
                // three things, and its width is the same in all three cases so
                // the placeholder beside it never moves:
                //
                //  - two or more rows: the clear-table control, centered on the
                //    column of index numbers above it;
                //  - exactly one row: an empty stand-in, so the placeholder
                //    still aligns with that row's text;
                //  - no rows: nothing at all. The index column exists in nothing
                //    but the stand-in at that point, so holding it open indents
                //    the placeholder against no visible column — which reads as
                //    a layout error rather than as alignment.
                //
                // The two-row threshold is deliberate. Clearing a one-row table
                // is the row's own Delete with an extra confirmation in front of
                // it, so the control would offer nothing the user does not
                // already have, and a destructive button that appears the
                // instant a table stops being empty invites a misclick for no
                // gain.
                if rowCount >= 2 {
                    ListCircleButton(
                        systemImage: "xmark",
                        fill: Preferences.red,
                        diameter: ListRowMetrics.circleDiameter,
                        // Smaller than the "+" it shares the row with, which is
                        // what makes it read as the same size: `xmark` runs its
                        // strokes corner to corner where `plus` stops short of
                        // its box, so nominal parity draws a visibly larger
                        // mark — the wrong emphasis for the one control here
                        // that destroys data. See `xmarkGlyphSize`.
                        glyphSize: ListRowMetrics.xmarkGlyphSize,
                        help: "Clear all entries",
                        // Per-symbol correction, held with the family's others
                        // rather than as a literal here.
                        glyphOffset: ListCircleButtonStyle.xmarkGlyphOffset,
                        action: { showClearAlert = true }
                    )
                    .frame(width: Self.indexColumnWidth)
                    .offset(x: Self.clearButtonCenteringOffset)
                } else if rowCount > 0 {
                    Color.clear
                        .frame(width: Self.indexColumnWidth, height: 12)
                }

                // At the cap the invitation is replaced by the reason there is
                // none: the "+" beside it can only gray out and darken, which
                // says "not now" without saying why. Scaled rather than
                // truncated, because a sentence cut off mid-word explains
                // nothing.
                Text(canAdd ? "Add new…" : ListAddRowCopy.atCapacity)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(.tertiary)
                    // Applied only while the index stand-in above is withdrawn.
                    // It is the same inset `ReorderableStringList` and
                    // `ReorderableTextList` give their own placeholders, so an
                    // empty frames table's "Add new…" begins in the same column
                    // as theirs.
                    .padding(.leading, rowCount == 0 ? ListRowMetrics.fieldTextInset : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Stand-in for the metadata glyph block, so the "+" sits in the same
            // column as the rows' "info" buttons rather than drifting left.
            // Narrowed by exactly the width the bulk-import control occupies —
            // see `ListRowMetrics.controlSpan` — so that column is unmoved by
            // the control's presence.
            //
            // Omitted at the cap, so the at-capacity sentence has the full width
            // up to the trailing controls to run in. The "+" is disabled in that
            // state, so there is nothing left for the column alignment to serve.
            if canAdd {
                Color.clear
                    .frame(width: Self.metadataBlockWidth - ListRowMetrics.controlSpan, height: 12)
            }

            // Bulk import, in the slot immediately left of the "+", from the
            // shared control all three tables present it with. The account of
            // why it is permanently gray and deliberately NOT gated on `canAdd`
            // lives on `ListBulkImportButton` (30_20_FSControlHelpers.swift).
            ListBulkImportButton(
                isPresented: $showImportPopover,
                help: "Add multiple entries from comma-separated lists",
                onOpen: {
                    // Replace mode is the only mode that can do anything at the
                    // cap, so the popover opens in it and locks it.
                    importReplaces = !canAdd
                },
                popoverContent: { importPopoverContent }
            )

            ListCircleButton(
                systemImage: "plus",
                fill: Preferences.green,
                diameter: ListRowMetrics.circleDiameter,
                // "plus" is optically heavier than "info" at the same nominal
                // size, so it is set fractionally smaller. Matches the string
                // list's add row.
                glyphSize: ListRowMetrics.plusGlyphSize,
                isActive: showAddPopover,
                // Disabled at the cap; the factory substitutes its own gray fill
                // in that state, which is why no fill is chosen for it here.
                isEnabled: canAdd,
                help: "Add an entry",
                // Per-symbol correction, shared with the string list's add row
                // so both tables' "+" sit identically in their circles.
                glyphOffset: ListCircleButtonStyle.plusGlyphOffset,
                action: {
                    resetAddFields()
                    showAddPopover = true
                }
            )
            .popover(isPresented: $showAddPopover, arrowEdge: .trailing) {
                addPopoverContent
                    .frame(width: Self.entryPopoverWidth)
                    .padding(16)
            }
        }
        .frame(height: ListRowMetrics.rowContentHeight)
        .listRowSeparator(.hidden)
    }

    // MARK: - Bulk Import

    /// Content for the bulk-entry popover, presented from the add row's control.
    ///
    /// A dedicated two-field popover rather than the shared `ListImportPopover`:
    /// this table imports two parallel lists at once, and that control is built
    /// around a single entry area. The parsing rule, the cap arithmetic, and the
    /// commit rule are still the shared ones — see `PairedFramesImportPopover`
    /// and `commitImport`.
    ///
    /// The control moved into the add row; the state and the commit did not. The
    /// presentation flag, the replace toggle, and `commitImport` all stay on this
    /// type, because the arrays are here and the cap is here.
    private var importPopoverContent: some View {
        PairedFramesImportPopover(
            maxItems: Self.maxItems,
            currentCount: rowCount,
            replaces: $importReplaces,
            onImport: { parsedFrames, parsedTimecodes, replacingFrames, replacingTimecodes in
                // Dismiss, then commit once the popover has finished closing.
                // An import changes the row count, which moves this popover's
                // own anchor — see `ListPopoverDismissal`.
                //
                // The two dispositions are carried through rather than re-read
                // from `importReplaces` at commit time: only the both-lists
                // switch is stored there, and the per-list switches live and die
                // with the presentation that is closing as this runs.
                showImportPopover = false
                ListPopoverDismissal.afterClose {
                    commitImport(frameEntries: parsedFrames,
                                 timecodeEntries: parsedTimecodes,
                                 replacingFrames: replacingFrames,
                                 replacingTimecodes: replacingTimecodes)
                }
            },
            onCancel: { showImportPopover = false }
        )
    }

    // MARK: - Add Popover Content

    @ViewBuilder
    private var addPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Entry #\(rowCount + 1)")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            PairedEntryFields(frameText: $addFrameText,
                              timecodeText: $addTimecodeText)

            Divider()

            FramesMarkRow(enabled: $addEntryMarkEnabled,
                          style:   $addEntryMarkStyle)

            FramesFadeRow(leadingLabel: "Audio fade-in uses",
                          enabled: $addEntryFadeInEnabled,
                          style:   $addEntryFadeIn)

            FramesFadeRow(leadingLabel: "Audio fade-out uses",
                          enabled: $addEntryFadeOutEnabled,
                          style:   $addEntryFadeOut)

            Divider()

            HStack(spacing: 8) {
                Button("Cancel") {
                    showAddPopover = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    // Dismiss BEFORE committing. The commit may raise the
                    // duplicate confirmation, and an alert presented while this
                    // popover is still up would be competing with it for the
                    // window's presentation. The write itself is unaffected: it
                    // is performed by the table, not by this view.
                    //
                    // Held until the close animation has finished, additionally,
                    // because the appended row grows the table under a popover
                    // that is still tracking its anchor — see
                    // `ListPopoverDismissal`.
                    showAddPopover = false
                    ListPopoverDismissal.afterClose { commitAdd() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isAddButtonEnabled)
            }
        }
    }

    // MARK: - Array Normalization

    /// Both arrays, padded to equal length with placeholder records — see
    /// `padded(_:to:flagsFrom:)`.
    ///
    /// Every mutation goes through this. A row is only meaningful as a pair, so
    /// an index that is valid in one array and not the other has no well-defined
    /// behavior for a move, a delete, or an in-place write. Normalizing first
    /// gives every operation two arrays of the same shape and makes the index
    /// unambiguous.
    ///
    /// Nothing is padded merely by displaying the table — this runs on the write
    /// paths only — so opening a film whose legacy arrays are uneven does not
    /// mark the sheet dirty. The normalization lands the first time the user
    /// actually changes something, which is also the first moment it can matter.
    private func paddedArrays() -> (frames: [String], timecodes: [String]) {
        let n = max(frames.count, timecodes.count)
        // At most one side is short, and the other is exactly `n` long, so each pad reads
        // its flags from a counterpart that has a record at every position it fills.
        return (Self.padded(frames, to: n, flagsFrom: timecodes),
                Self.padded(timecodes, to: n, flagsFrom: frames))
    }

    /// Applies `body` to normalized copies of both arrays and writes each back
    /// only if it actually changed.
    ///
    /// Working on copies and writing once keeps a single logical edit to at most
    /// one observation invalidation per array, rather than one per element
    /// touched. The inequality guards are what stop a no-op path from waking
    /// `FSTabNotes.checkForChanges()` for a value that did not move — the same
    /// argument `ListImportCommit` makes for returning a value instead of taking
    /// an `inout`.
    private func mutate(_ body: (inout [String], inout [String]) -> Void) {
        var (f, t) = paddedArrays()
        body(&f, &t)
        if f != frames { frames = f }
        if t != timecodes { timecodes = t }
    }

    // MARK: - Add Helpers

    /// Closes every editor this table can have open — each row's edit popover,
    /// the add popover, and the bulk-import popover.
    ///
    /// One method rather than the same three lines at each caller, because the
    /// callers are exactly the two events that invalidate a popover's anchor: a
    /// scroll and a reorder. Both flags are guarded rather than assigned
    /// unconditionally, so a scroll tick with nothing open reads two `Bool`s and
    /// writes nothing — no SwiftUI invalidation reaches the view tree.
    ///
    /// The row popovers are reached through the subject rather than a flag,
    /// because each row owns its own presentation state; see
    /// `dismissRowPopovers` for why that is a publisher and not a value.
    private func closeAllEditors() {
        dismissRowPopovers.send()
        if showAddPopover { showAddPopover = false }
        if showImportPopover { showImportPopover = false }
    }

    private func resetAddFields() {
        addFrameText = ""
        addTimecodeText = ""
        addEntryMarkEnabled = false
        addEntryMarkStyle   = .asterisk
        addEntryFadeInEnabled = false
        addEntryFadeIn = .scurve
        addEntryFadeOutEnabled = false
        addEntryFadeOut = .scurve
    }

    /// The pair the add popover's current draft would write, or `nil` when
    /// neither field holds anything storable. Read by the Add button's
    /// enablement and by the commit, so the two cannot disagree.
    private func assembledAddPair() -> PairedFramesDraft? {
        PairedFramesRecord.pair(
            frameText: addFrameText,
            timecodeText: addTimecodeText,
            mark: addEntryMarkEnabled ? addEntryMarkStyle : .none,
            fadeIn: addEntryFadeInEnabled ? addEntryFadeIn : .none,
            fadeOut: addEntryFadeOutEnabled ? addEntryFadeOut : .none
        )
    }

    private func commitAdd() {
        // Bounded here as well as at the "+" button. The button is disabled at
        // the cap, so this cannot normally be reached — but the cap is a limit
        // on the model, not a UI rule, and `commitImport` enforces it on its own
        // path rather than trusting its caller for the same reason.
        guard canAdd else { return }
        guard let pair = assembledAddPair() else { return }
        confirmingDuplicate(pair, excluding: nil,
                            prompt: ListDuplicatePrompt { appendPair(pair) })
    }

    /// The append itself, shared by the immediate and confirmed paths.
    ///
    /// The cap is checked again here rather than only in `commitAdd`: on the
    /// confirmed path an alert stood between the two, so the guard is what keeps
    /// this method safe to call from either.
    private func appendPair(_ pair: PairedFramesDraft) {
        guard canAdd else { return }
        mutate { f, t in
            f.append(pair.frame)
            t.append(pair.timecode)
        }
        // Only on a write that actually grew the table, so a rejected draft
        // leaves the viewport alone.
        addRevealToken &+= 1
    }

    /// Empties both arrays, deferred by one main-loop turn.
    ///
    /// **Why the hop.** The alert's dismissal is an AppKit animation, and the
    /// button's action runs while that animation's CoreAnimation transaction is
    /// still open. Emptying the arrays there removes every row from the List
    /// inside that transaction, so the row-removal animation and the alert's own
    /// fade are committed together — which is what produces a torn or skipped
    /// dismissal. `DispatchQueue.main.async` puts the mutation on the following
    /// turn of the run loop, after the alert's transaction has closed, so the
    /// two animate independently and in order.
    ///
    /// `ListPopoverDismissal.nextTurn` — a `Task { @MainActor in }` hop that a save
    /// can settle early — rather than `DispatchQueue.main.async`, on the same
    /// reasoning `ListPopoverDismissal` sets out: this is dispatched from a
    /// SwiftUI button action rather than from a synchronous AppKit event
    /// callback, so there is no QoS to inherit and the concurrency-native form
    /// is the correct one. It also keeps the closure clear of
    /// `DispatchQueue`'s `@Sendable` requirement, which the captured `Binding`s
    /// would not satisfy.
    ///
    /// No delay beyond the hop. Yielding one turn is what closes the alert's
    /// transaction, which is the whole problem; waiting out the full dismissal
    /// animation on top of that would leave a table the user has already
    /// confirmed clearing visibly populated for another fifth of a second.
    ///
    /// Editors are closed first and synchronously. A row popover left open
    /// across this would be anchored to a row that is about to stop existing.
    ///
    /// Both writes are guarded, so a table already empty on both sides — which
    /// the two-row threshold on the control makes unreachable through the UI —
    /// wakes `FSTabNotes.checkForChanges()` for neither array.
    private func clearTable() {
        closeAllEditors()
        ListPopoverDismissal.nextTurn {
            if !frames.isEmpty { frames = [] }
            if !timecodes.isEmpty { timecodes = [] }
        }
    }

    // MARK: - Duplicate Confirmation

    /// Runs `prompt` immediately, or parks it behind a confirmation when the
    /// finished PAIR already exists verbatim on another row.
    ///
    /// The comparison is on the pair rather than on either record alone, which
    /// is the only definition that makes sense once a row is two records: a
    /// repeated frame number paired with a different time code is a different
    /// row, and prompting on it would be wrong. `ListDuplicateCheck` compares one
    /// value against one array and cannot express that, so the walk is done here
    /// — over the normalized arrays, so a legacy uneven pair is still compared
    /// position by position rather than falling off the end of the shorter one.
    ///
    /// Bulk import deliberately does NOT route through here: a pasted list is
    /// reviewed as a whole before it is imported, and interrupting it once per
    /// repeated entry would make the control unusable.
    ///
    /// The pending write arrives already wrapped in a `ListDuplicatePrompt`
    /// rather than as a bare closure, for the reason stated on that type: a
    /// closure held as a property of a struct is escaping by construction, which
    /// is what lets it be parked in `@State` until the alert is answered.
    private func confirmingDuplicate(_ candidate: PairedFramesDraft,
                                     excluding index: Int?,
                                     prompt: ListDuplicatePrompt) {
        let (f, t) = paddedArrays()
        var isDuplicate = false
        for position in f.indices where position != index {
            if f[position] == candidate.frame && t[position] == candidate.timecode {
                isDuplicate = true
                break
            }
        }
        if isDuplicate {
            duplicatePrompt = prompt
            ListPopoverDismissal.noteDeferredPrompt()
        } else {
            prompt.confirm()
        }
    }

    // MARK: - Row Update

    /// Writes a row's edited pair, behind the duplicate confirmation when that
    /// pair already exists elsewhere.
    ///
    /// The values the edit opened against are carried through so the eventual
    /// write can verify them. The write may be deferred past the popover's close
    /// animation and past a modal alert, and an index addresses a POSITION:
    /// verifying the pair still standing there makes a late write either correct
    /// or a no-op, on any timeline. Same rule `ReorderableStringList` states as
    /// `expecting` on its own drafted commits.
    ///
    /// Verified before the duplicate check as well as at the write. A row that
    /// has moved since the edit opened would otherwise be compared with its
    /// stale index excluded, and could raise a prompt whose "Add Anyway" the
    /// write then silently drops.
    private func updateRow(at index: Int,
                           to pair: PairedFramesDraft,
                           expectingFrame: String?,
                           expectingTimecode: String?) {
        guard rowHolds(index, frame: expectingFrame, timecode: expectingTimecode) else { return }
        confirmingDuplicate(pair, excluding: index, prompt: ListDuplicatePrompt {
            writeRow(at: index, pair: pair,
                     expectingFrame: expectingFrame,
                     expectingTimecode: expectingTimecode)
        })
    }

    private func writeRow(at index: Int,
                          pair: PairedFramesDraft,
                          expectingFrame: String?,
                          expectingTimecode: String?) {
        guard rowHolds(index, frame: expectingFrame, timecode: expectingTimecode) else { return }
        mutate { f, t in
            guard f.indices.contains(index), t.indices.contains(index) else { return }
            f[index] = pair.frame
            t[index] = pair.timecode
        }
    }

    // MARK: - Row Deletion

    /// Removes the row the popover was showing when Delete was clicked.
    ///
    /// **Why the values and not just the index**
    ///
    /// The delete is dispatched through `ListPopoverDismissal.afterClose`, which
    /// holds it for the length of the popover's close animation. The sheet is
    /// fully interactive across that interval, so the index captured when the
    /// row was built is not by itself a reliable identifier of what the user
    /// asked to remove: a reorder landing inside the window would leave it
    /// pointing at a different row, and a bounds check would happily let that
    /// through — it prevents a trap, not a wrong deletion.
    ///
    /// The fallback search covers the case where the row is still present but
    /// has moved, so a reorder inside the window delays the deletion rather than
    /// misdirecting it; a row that is gone altogether leaves nothing to do. A
    /// table holding two identical pairs makes the fallback ambiguous, and
    /// harmlessly so: removing either occurrence yields the same arrays, because
    /// the two are the same values.
    private func deleteRow(at index: Int,
                           expectingFrame: String?,
                           expectingTimecode: String?) {
        if rowHolds(index, frame: expectingFrame, timecode: expectingTimecode) {
            removePair(at: index)
            return
        }
        // The search runs over the normalized arrays, so an expectation of `nil`
        // — a side that had no record — is matched against the placeholder the
        // normalization gives it, which is exactly what that position will hold
        // once the removal's own `mutate` normalizes. That placeholder carries the
        // other half's flags; see `padded(_:to:flagsFrom:)`.
        let (f, t) = paddedArrays()
        let wantedFrame = expectingFrame ?? Self.placeholder(pairedWith: expectingTimecode)
        let wantedTimecode = expectingTimecode ?? Self.placeholder(pairedWith: expectingFrame)
        guard let moved = f.indices.first(where: { f[$0] == wantedFrame && t[$0] == wantedTimecode })
        else { return }
        removePair(at: moved)
    }

    /// Whether position `index` still holds the records a row's edit opened on.
    ///
    /// Read against the LIVE arrays, not the normalized copies. The expectation
    /// a row hands over is `nil` for a side it had no record on at all, and
    /// normalizing would turn that into the placeholder and fail a comparison
    /// that should have succeeded.
    private func rowHolds(_ index: Int, frame: String?, timecode: String?) -> Bool {
        let currentFrame = index < frames.count ? frames[index] : nil
        let currentTimecode = index < timecodes.count ? timecodes[index] : nil
        return currentFrame == frame && currentTimecode == timecode
    }

    private func removePair(at index: Int) {
        mutate { f, t in
            guard f.indices.contains(index), t.indices.contains(index) else { return }
            f.remove(at: index)
            t.remove(at: index)
        }
    }

    // MARK: - Bulk Import Commit

    /// Turns two parsed lists into records and writes them in one mutation per
    /// array, with each column appended to or replaced independently.
    ///
    /// **Dispositions.** The popover supplies one flag per column rather than
    /// one for the import, because the two lists are routinely gathered from
    /// different places at different times: a user who has just imported frames
    /// into an empty table and received a column of placeholders needs the next
    /// paste to overwrite the time codes and leave the frames alone. A single
    /// shared flag could only append both or replace both, and the latter would
    /// require re-pasting the frames alongside every correction.
    ///
    /// `ListImportCommit.resolved` is deliberately not used here, and this is
    /// the one caller of the three tables' import path that cannot use it. It
    /// takes one disposition for one array and rejects an empty batch outright,
    /// whereas this commit has two dispositions and two batches, either of which
    /// may legitimately be empty — an empty batch on the append path leaves its
    /// column untouched, and an empty batch under the both-lists mode fills its
    /// column with placeholders. Its cap rule is reproduced below against the
    /// resulting row count, which is the quantity this table's cap is expressed
    /// in.
    ///
    /// **Metadata.** Records built here take the "none" defaults, which is
    /// exactly the pair `commitAdd` produces with all three toggles off — with
    /// one exception. When a column is replaced while its counterpart is *not*,
    /// the surviving counterpart's record at that position supplies the mark and
    /// the two fade styles. Those flags describe the row rather than either half
    /// of it: `PairedFramesRecord.pair` writes them identically to both records,
    /// and `PairedFramesListRow.flags` reads them back from whichever record
    /// survives. Rebuilding one column with `.none` would therefore desynchronize
    /// a pair the rest of this file treats as one annotated row, and would
    /// discard marks the user set on rows the import was only filling in. A
    /// whole-table replace has no surviving counterpart to inherit from, so it
    /// clears the metadata as it always has.
    ///
    /// **Uneven results.** The two columns are paired by position, and whichever
    /// ends up shorter is filled out with placeholder records carrying the row's
    /// flags from the longer side (`padded(_:to:flagsFrom:)`). That is
    /// the honest reading of "I have the frames but not the time codes yet", and
    /// it keeps the two arrays the same length — the invariant every other path
    /// here depends on. The popover states the pairing rule before the import is
    /// committed, so the fill is never a surprise.
    private func commitImport(frameEntries: [String],
                              timecodeEntries: [String],
                              replacingFrames: Bool,
                              replacingTimecodes: Bool) {
        guard !frameEntries.isEmpty || !timecodeEntries.isEmpty else { return }

        // Normalized first, so a position is a row in both arrays and the
        // inheritance lookups below are indexed unambiguously.
        let (currentFrames, currentTimecodes) = paddedArrays()

        // Inheritance applies only to the column being rebuilt over a column
        // that is being kept. When both are replaced — the both-lists mode, or
        // both per-list switches checked — there is no surviving row to read
        // flags from, and taking them from an array that is itself about to be
        // discarded would resurrect metadata the user asked to clear.
        let newFrames = Self.importRecords(
            from: frameEntries,
            inheritingFrom: (replacingFrames && !replacingTimecodes) ? currentTimecodes : nil)
        let newTimecodes = Self.importRecords(
            from: timecodeEntries,
            inheritingFrom: (replacingTimecodes && !replacingFrames) ? currentFrames : nil)

        var updatedFrames = replacingFrames ? newFrames : currentFrames + newFrames
        var updatedTimecodes = replacingTimecodes ? newTimecodes : currentTimecodes + newTimecodes

        // The cap is a row count, and a row exists wherever either column has an
        // entry — so the pair is measured by its longer half. Resolved BEFORE
        // either array is written, which is what keeps a refused batch from
        // landing in one array and leaving the other untouched.
        let count = max(updatedFrames.count, updatedTimecodes.count)
        // Zero is not reachable from an enabled Import button, which requires at
        // least one parsed entry. Refused rather than written regardless: an
        // import that emptied the table would be a destructive operation behind
        // a button that does not describe one, and clearing has its own
        // confirmed control.
        guard count > 0, count <= Self.maxItems else { return }

        updatedFrames = Self.padded(updatedFrames, to: count, flagsFrom: updatedTimecodes)
        updatedTimecodes = Self.padded(updatedTimecodes, to: count, flagsFrom: updatedFrames)

        // Close any open editor, matching the `endEditing()`
        // `ReorderableStringList.commitImport` performs at this same point and
        // the `closeAllEditors()` `ReorderableTextList.commitImport` performs at
        // its own. Ordered after the guard for the reason the string list
        // states: a rejected batch must not close a field the user is still
        // working in.
        //
        // The gap this closes is real but narrow. The commit is dispatched
        // through `ListPopoverDismissal.afterClose`, and the sheet stays fully
        // interactive across that interval — so a row's edit popover can be
        // opened between the Import click and this running. An import that
        // replaces a column then redefines or removes the row that popover is
        // anchored to, leaving an editor floating over a row that no longer
        // holds the pair it was opened on. The `expecting` checks in `writeRow`
        // and `deleteRow` already make a late commit from such an editor a no-op
        // rather than a write to the wrong row; this closes the visual half
        // those checks cannot reach. The editor is drafted, so closing it
        // discards nothing that was committed.
        closeAllEditors()

        // Measured before the write, so the comparison is against the table the
        // import is replacing rather than the one it produced.
        let grew = count > rowCount
        if updatedFrames != frames { frames = updatedFrames }
        if updatedTimecodes != timecodes { timecodes = updatedTimecodes }

        // The add row moves down by one row per entry gained, so a bulk import
        // can push it well below the fold. Only on growth: an import that
        // shrinks the table moves the add row UP, and scrolling to it then would
        // drag the viewport for no reason.
        if grew { addRevealToken &+= 1 }
    }

    /// Builds one column's worth of records from a parsed list.
    ///
    /// `counterpart`, when supplied, is the column that is being kept, and each
    /// position takes its mark and fade styles from the record at the same
    /// position there — see `commitImport` on why the flags belong to the row
    /// rather than to either record. A position past the end of `counterpart` is
    /// a row the table does not have yet, so there is nothing to inherit and the
    /// defaults apply.
    ///
    /// `cleaned` returning `nil` is unreachable from `parseItems`, whose output
    /// is trimmed, non-empty, and free of commas by construction. It is honored
    /// anyway so that this function is safe for any caller rather than only for
    /// the one it has.
    private static func importRecords(from entries: [String],
                                      inheritingFrom counterpart: [String]?) -> [String] {
        var built: [String] = []
        built.reserveCapacity(entries.count)
        for (position, entry) in entries.enumerated() {
            guard let text = PairedFramesRecord.cleaned(entry) else { continue }
            var mark = MarkStyle.none
            var fadeIn = AudioFadeStyle.none
            var fadeOut = AudioFadeStyle.none
            if let counterpart, position < counterpart.count {
                let inherited = FramesEntryParser.parse(counterpart[position])
                mark = inherited.mark
                fadeIn = inherited.fadeIn
                fadeOut = inherited.fadeOut
            }
            built.append(PairedFramesRecord.make(text, mark: mark, fadeIn: fadeIn, fadeOut: fadeOut))
        }
        return built
    }

    /// `column` filled out to `count` rows with placeholder records, each carrying the
    /// mark and fade styles of `counterpart`'s record at the same position. Returned
    /// unchanged when it is already that long.
    ///
    /// The flags describe the ROW, not either half of it (see `commitImport`), so a
    /// placeholder must repeat them. Padding with a fixed unannotated placeholder (the
    /// former `PairedFramesRecord.missing`) did not: replacing the Frames column with fewer
    /// entries than the table had rows, or the first write to a legacy uneven pair, left
    /// every padded row with a flagless frame record beside an annotated time code. The
    /// row's glyphs vanished here — `PairedFramesListRow.flags` prefers the frame record —
    /// while the right sidebar's time-code table still drew them, and the row's next Update
    /// rewrote both halves from the frame side, dropping the marks for good.
    ///
    /// A counterpart position with no flags, or past its end, yields the plain unannotated
    /// placeholder ("—, no, none, none"), so every other padding case writes what it always
    /// did.
    static func padded(_ column: [String], to count: Int, flagsFrom counterpart: [String]) -> [String] {
        guard column.count < count else { return column }
        var result = column
        result.reserveCapacity(count)
        for position in column.count..<count {
            result.append(placeholder(pairedWith: position < counterpart.count
                                                  ? counterpart[position] : nil))
        }
        return result
    }

    /// The placeholder record that stands in for a missing half of a row whose other half
    /// is `record`: the missing text, with `record`'s flags — or with none when `record` is
    /// nil or carries none.
    ///
    /// The one definition `padded` fills with and `deleteRow`'s fallback search looks for,
    /// so the search always matches what normalization actually wrote.
    static func placeholder(pairedWith record: String?) -> String {
        let row = record.map(FramesEntryParser.parse) ?? FramesEntryParser.empty
        return PairedFramesRecord.make(PairedFramesRecord.missingText,
                                       mark: row.mark, fadeIn: row.fadeIn, fadeOut: row.fadeOut)
    }
}

// MARK: - PairedFramesListRow

/// A self-contained row view for `ReorderableFramesList`.
///
/// Each row owns its own popover state, which is what eliminated the shared-state
/// race that used to keep the "info" popover from re-opening after being closed.
///
/// It receives its two records as plain values rather than as bindings. A row is
/// a pair addressed by position across two arrays, and only the table can write
/// that safely — so the row hands its finished pair back instead of writing
/// through a binding onto one of them. Passing values rather than the arrays
/// also keeps a commit from invalidating every other row.
private struct PairedFramesListRow: View {

    let index: Int

    /// This row's stored records, or `nil` for a side whose array is shorter
    /// than the other — a legacy pair that was never written by this component.
    let frameRecord: String?
    let timecodeRecord: String?

    /// Fires when the enclosing content scrolls. Received rather than observed
    /// as a value, so a scroll re-renders only the row that has a popover open.
    let dismissRowPopovers: PassthroughSubject<Void, Never>

    /// Hands the finished pair, plus the pair this edit opened against, back to
    /// the table. The table owns the arrays and therefore owns the duplicate
    /// comparison, the position verification, and the write.
    let onUpdate: (PairedFramesDraft, String?, String?) -> Void

    /// Removes this row, carrying the pair it was showing at the moment Delete
    /// was clicked so the table can confirm it is removing that row rather than
    /// whatever has since arrived at this position. See
    /// `ReorderableFramesList.deleteRow(at:expectingFrame:expectingTimecode:)`.
    let onDelete: (String?, String?) -> Void

    // Row control geometry comes from `ListRowMetrics`, shared with
    // `StringListRow`'s per-row controls: 16pt of circle plus the button style's
    // 2pt shadow margin on each side is exactly the row's 20pt content height,
    // so the button fits without forcing the row taller.

    // Each row owns its popover state independently
    @State private var showPopover = false

    // Popover edit fields
    @State private var entryFrameText = ""
    @State private var entryTimecodeText = ""
    @State private var entryMarkEnabled = false
    @State private var entryMarkStyle   = MarkStyle.asterisk
    @State private var entryFadeInEnabled = false
    @State private var entryFadeIn = AudioFadeStyle.scurve
    @State private var entryFadeOutEnabled = false
    @State private var entryFadeOut = AudioFadeStyle.scurve

    // Parse results, computed once per construction. The table constructs a row
    // only when its own body re-runs — which is exactly when a record can have
    // changed — so parsing here costs the same as the `@State` cache these used
    // to be (whose initial-value expression was evaluated on every construction
    // anyway, then discarded). Plain values also cannot lag the records they
    // describe: the cache needed an `onChange` per record to catch up, which ran
    // a second body pass after every reorder, import, or edit.
    //
    // Declared through `FramesEntryParser.Entry` rather than by restating the
    // tuple, so their shape cannot fall out of step with what the parser
    // actually returns.
    private let parsedFrame: FramesEntryParser.Entry
    private let parsedTimecode: FramesEntryParser.Entry

    init(index: Int,
         frameRecord: String?,
         timecodeRecord: String?,
         dismissRowPopovers: PassthroughSubject<Void, Never>,
         onUpdate: @escaping (PairedFramesDraft, String?, String?) -> Void,
         onDelete: @escaping (String?, String?) -> Void) {
        self.index = index
        self.frameRecord = frameRecord
        self.timecodeRecord = timecodeRecord
        self.dismissRowPopovers = dismissRowPopovers
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.parsedFrame = Self.parsed(frameRecord)
        self.parsedTimecode = Self.parsed(timecodeRecord)
    }

    private static func parsed(_ record: String?) -> FramesEntryParser.Entry {
        guard let record else { return FramesEntryParser.empty }
        return FramesEntryParser.parse(record)
    }

    /// The metadata this row displays and edits.
    ///
    /// Taken from the frames record when there is one, and from the time-code
    /// record otherwise. The two agree in everything this component writes —
    /// that is the entire point of the pairing — so the preference only ever
    /// resolves a legacy pair that was allowed to diverge, and committing any
    /// edit rewrites both sides from this single set.
    private var flags: (mark: MarkStyle, fadeIn: AudioFadeStyle, fadeOut: AudioFadeStyle) {
        frameRecord != nil
            ? (parsedFrame.mark, parsedFrame.fadeIn, parsedFrame.fadeOut)
            : (parsedTimecode.mark, parsedTimecode.fadeIn, parsedTimecode.fadeOut)
    }

    var body: some View {
        // Resolved once per pass and reused by all three glyph blocks below,
        // rather than recomputed at each of them.
        let marks = flags

        // Spacing is 0 here rather than a uniform value, and each gap is drawn
        // as its own fixed-width `Spacer` below, so the trailing gap to the
        // edit button can be tightened independently of the row's other two
        // gaps without disturbing them.
        HStack(spacing: 0) {
            // Index and frames column, grouped so the gap after the period is
            // set independently of the gaps between the row's other columns.
            HStack(spacing: ReorderableFramesList.indexTrailingGap) {
                // Index (monospaced, always 2 digits).
                //
                // Zero-padded rather than drawn as the bare ordinal. The column
                // is trailing-aligned and the font is monospaced, so an unpadded
                // index already lined up on its period — but rows 1 through 9
                // then left the tens place blank, breaking the column of
                // numerals that the rows from 10 up form. Padding fills that
                // place, which also makes the index exactly three glyphs on
                // every row: the assumption `clearButtonCenteringOffset` is
                // derived from, and now true of the whole table rather than of
                // most of it.
                //
                // Two places suffices because `maxItems` caps the table at 99
                // rows.
                Text("\(Fmt.padded(index + 1, 2)).")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: ReorderableFramesList.indexColumnWidth, alignment: .trailing)

                // Frames column — fixed width, left-aligned, so every row's
                // frame number begins at the same x.
                Text(parsedFrame.text)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: ReorderableFramesList.frameColumnWidth, alignment: .leading)
            }

            Spacer()
                .frame(width: ReorderableFramesList.indexGroupTrailingGap)

            // Time-codes column — takes the remaining width, left-aligned for
            // the same reason. Its left edge is fixed because everything before
            // it is.
            // Drawn in three sub-columns rather than as one run, so the dash and
            // the ending code land at the same x on every row despite the
            // proportional face. Font, line limit, and truncation belong to that
            // view, which needs the point size to derive its sub-column widths.
            // It falls back to a plain run for any value it cannot align, so the
            // flexible frame around it is still the operative one in that case.
            TimeCodeRangeText(text: parsedTimecode.text)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
                .frame(width: ReorderableFramesList.timecodeTrailingGap)

            // Metadata glyphs with fixed-width containers for alignment. One set
            // per ROW, not per array: the pair carries one mark and one pair of
            // fades, which is what removes the hand-synchronization this
            // component was combined to eliminate.
            // Spacings and container widths come from the table's geometry
            // constants rather than from literals here, so the block and the
            // `metadataBlockWidth` the add row's stand-in is sized to are
            // computed from one set of numbers. The mark-to-pair gap and the
            // pair-to-pair gap are set independently — `metadataGlyphSpacing`
            // and `pairGroupSpacing` respectively — so the two fade pairs can
            // sit tighter to each other than either does to the mark.
            HStack(spacing: ReorderableFramesList.metadataGlyphSpacing) {
                // Mark indicator
                Group {
                    if marks.mark != .none {
                        Image(systemName: marks.mark.symbolName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: ReorderableFramesList.markGlyphWidth, height: 12)

                HStack(spacing: ReorderableFramesList.pairGroupSpacing) {
                    // Fade-in indicator: direction arrow plus curve shape, set
                    // tighter to each other than to anything around them.
                    HStack(spacing: ReorderableFramesList.fadeGlyphSpacing) {
                        Group {
                            if marks.fadeIn != .none {
                                Image(systemName: "arrow.up.right.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 12, height: 12)
                        Group {
                            if marks.fadeIn != .none {
                                fadeGlyphImage(for: marks.fadeIn)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 16, height: 12)
                    }
                    .frame(width: ReorderableFramesList.fadePairWidth)

                    // Fade-out indicator — same pairing, same tightening.
                    HStack(spacing: ReorderableFramesList.fadeGlyphSpacing) {
                        Group {
                            if marks.fadeOut != .none {
                                Image(systemName: "arrow.down.right.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 12, height: 12)
                        Group {
                            if marks.fadeOut != .none {
                                fadeGlyphImage(for: marks.fadeOut)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 16, height: 12)
                    }
                    .frame(width: ReorderableFramesList.fadePairWidth)
                }
            }
            // Shared with the add row's stand-in, which subtracts the
            // bulk-import control's span from this same value. Restating a
            // literal in either place would let the trailing controls fall out
            // of column silently.
            .frame(width: ReorderableFramesList.metadataBlockWidth)

            // Trailing gap to the edit button — see `trailingGlyphGap`. Set
            // explicitly here — rather than folded into the outer HStack's own
            // spacing — so this one gap can be adjusted without moving the
            // index/frames, time-code, or glyph groups relative to each other.
            Spacer()
                .frame(width: ReorderableFramesList.trailingGlyphGap)

            // Edit button — toggles the popover for this specific row.
            //
            // Built from the shared factory rather than drawn inline, so it is
            // the same control as the string list's per-row pencil: same
            // diameter, same glyph weight, same shadow, same press response.
            // `info` rather than `info.circle` because the factory already
            // supplies the circle.
            //
            // `isActive` holds the accent fill for as long as the popover is
            // open. `showPopover` is this row's own state, so no other row's
            // button lights up.
            ListCircleButton(
                systemImage: "info",
                fill: Color.gray.opacity(0.5),
                diameter: ListRowMetrics.circleDiameter,
                glyphSize: ListRowMetrics.circleGlyphSize,
                isActive: showPopover,
                help: showPopover ? "Finish editing" : "Edit this entry",
                // `info` is the one glyph in the family that is not symmetric in
                // its own box; the correction lives with the family's other
                // per-symbol corrections rather than as a literal here.
                glyphOffset: ListCircleButtonStyle.infoGlyphOffset,
                action: {
                    if showPopover {
                        showPopover = false
                    } else {
                        loadEntry()
                        showPopover = true
                    }
                }
            )
            .popover(isPresented: $showPopover, arrowEdge: .trailing) {
                editPopoverContent
                    .frame(width: ReorderableFramesList.entryPopoverWidth)
                    .padding(16)
            }
        }
        .frame(height: ListRowMetrics.rowContentHeight)
        .listRowSeparator(.hidden)
        .onReceive(dismissRowPopovers) { _ in
            if showPopover { showPopover = false }
        }
    }

    // MARK: - Edit Popover Content

    @ViewBuilder
    private var editPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Entry #\(index + 1)")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            PairedEntryFields(frameText: $entryFrameText,
                              timecodeText: $entryTimecodeText)

            Divider()

            FramesMarkRow(enabled: $entryMarkEnabled,
                          style:   $entryMarkStyle)

            FramesFadeRow(leadingLabel: "Audio fade-in uses",
                          enabled: $entryFadeInEnabled,
                          style:   $entryFadeIn)

            FramesFadeRow(leadingLabel: "Audio fade-out uses",
                          enabled: $entryFadeOutEnabled,
                          style:   $entryFadeOut)

            Divider()

            HStack(spacing: 8) {
                Button("Cancel") {
                    showPopover = false
                }
                .keyboardShortcut(.cancelAction)

                // Shared with the text list's and `ViewingDatesTable`'s Delete
                // buttons; the full account of the treatment is on
                // `PopoverDeleteButton` (30_20_FSControlHelpers.swift).
                //
                // Dismiss BEFORE mutating. The delete removes this row, which
                // tears down the view the popover is anchored to; ordering it
                // this way leaves AppKit nothing to dismiss a popover from.
                // Held until the close animation has finished for the same
                // reason an add is: removing a row moves every anchor below it,
                // including this one — see `ListPopoverDismissal`.
                PopoverDeleteButton(action: {
                    // Captured here, at the click, rather than read inside the
                    // deferred closure: a row addresses a POSITION, so reading
                    // the records after the delay would ask "what is at this
                    // position now" — which is precisely the question the
                    // verification exists to stop the delete from depending on.
                    let removingFrame = frameRecord
                    let removingTimecode = timecodeRecord
                    showPopover = false
                    ListPopoverDismissal.afterClose {
                        onDelete(removingFrame, removingTimecode)
                    }
                }, bindsOptionDelete: true)

                Spacer()

                Button("Update") {
                    // Assembled at the click, so the deferred commit carries a
                    // finished value rather than depending on this view — whose
                    // teardown the dismissal below has already begun — still
                    // being around to produce one.
                    guard let pair = assembledPair() else { return }
                    let expectedFrame = frameRecord
                    let expectedTimecode = timecodeRecord
                    // Dismiss BEFORE committing, on the same terms as Delete
                    // above: the commit may raise the table's duplicate
                    // confirmation, and an alert presented while this popover is
                    // still up would be competing with it.
                    showPopover = false
                    ListPopoverDismissal.afterClose {
                        onUpdate(pair, expectedFrame, expectedTimecode)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isUpdateEnabled)
            }
        }
    }

    // MARK: - Helpers

    private func loadEntry() {
        let marks = flags
        entryFrameText      = PairedFramesRecord.editableText(parsedFrame)
        entryTimecodeText   = PairedFramesRecord.editableText(parsedTimecode)
        entryMarkEnabled    = marks.mark != .none
        entryMarkStyle      = marks.mark != .none ? marks.mark : .asterisk
        entryFadeInEnabled  = marks.fadeIn != .none
        entryFadeIn         = marks.fadeIn != .none ? marks.fadeIn : .scurve
        entryFadeOutEnabled = marks.fadeOut != .none
        entryFadeOut        = marks.fadeOut != .none ? marks.fadeOut : .scurve
        // Nothing further to capture: the baseline the Update button measures
        // against is the two stored records themselves.
    }

    /// The pair the current popover fields would produce, or `nil` when neither
    /// text field holds anything storable.
    ///
    /// Assembling it in one place is what keeps the Update button's enablement
    /// and the commit in exact agreement. Measuring both on the finished records
    /// — trimmed, comma-stripped, placeholder-filled — removes by construction
    /// the gap where an edit that changed only surrounding whitespace, or that
    /// added a comma the commit strips, enabled the button and then wrote
    /// nothing.
    private func assembledPair() -> PairedFramesDraft? {
        PairedFramesRecord.pair(
            frameText: entryFrameText,
            timecodeText: entryTimecodeText,
            mark: entryMarkEnabled ? entryMarkStyle : .none,
            fadeIn: entryFadeInEnabled ? entryFadeIn : .none,
            fadeOut: entryFadeOutEnabled ? entryFadeOut : .none
        )
    }

    /// Enabled only when there is something to write AND it differs from what is
    /// stored. A row from a legacy uneven pair has a `nil` on one side, and any
    /// assembled pair necessarily differs from that — which is what lets such a
    /// row be normalized through an ordinary Update.
    private var isUpdateEnabled: Bool {
        guard let pair = assembledPair() else { return false }
        return pair.frame != frameRecord || pair.timecode != timecodeRecord
    }

    @ViewBuilder
    private func fadeGlyphImage(for style: AudioFadeStyle) -> some View {
        Image(systemName: style.glyph)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Paired Bulk-Import Popover

/// The frames table's bulk-entry popover: two comma/line-separated lists,
/// imported as paired rows.
///
/// A dedicated control rather than `ListImportPopover`, which is built around a
/// single entry area and could not express two parallel lists without growing a
/// second mode every other caller would have to ignore. Everything that is not
/// the second field is borrowed rather than restated: the parsing rule is
/// `ListImportPopover.parseItems`, so this control accepts exactly the same
/// separators as the other three tables.
///
/// The cap-and-replace rule is not `ListImportCommit`'s. This popover offers
/// three replace switches — one per list plus one for both — so that a user who
/// gathers frames and time codes at different moments can overwrite one column
/// without re-supplying the other, and a single flag over a single array cannot
/// express that. The arithmetic is the shared helper's, restated per column; see
/// `columnLimit` here and `ReorderableFramesList.commitImport`.
///
/// The local `@State` mirrors exist for the reason `ListImportPopover`'s do: a
/// popover's content is hosted in its own window with its own update graph, so a
/// write that invalidates the presenting table is no guarantee that this view is
/// re-evaluated in step. Writing local state invalidates *this* view by
/// definition, so a keystroke recomputes the row count, its color, the mismatch
/// note, and the Import button's enablement together. The drafts are this view's
/// alone and open empty on every presentation; only the both-lists switch is
/// mirrored to the caller, whose commit path is handed the resolved dispositions.
private struct PairedFramesImportPopover: View {

    /// Upper bound on the resulting ROW count — the unit this table's cap is
    /// expressed in, now that a row is two records.
    let maxItems: Int

    /// How many rows the destination table is holding right now. Appending is
    /// bounded by the headroom, replacing by the whole cap; see `columnLimit`.
    let currentCount: Int

    @Binding var replaces: Bool

    /// Receives the two parsed lists, in the order they were typed, followed by
    /// the disposition each list's column is to be written with: `true` replaces
    /// that column, `false` appends to it. The popover has already checked each
    /// list against the limit its own disposition allows, but the caller
    /// re-checks before mutating.
    let onImport: ([String], [String], Bool, Bool) -> Void
    let onCancel: () -> Void

    @State private var framesDraft: String = ""
    @State private var timecodesDraft: String = ""
    @State private var replaceLocal: Bool? = nil

    /// The two per-list replace switches, deliberately local and deliberately
    /// not mirrored back to the caller.
    ///
    /// Unlike the both-lists switch above — which the caller stores, and seeds from
    /// its cap state before every presentation — these are ephemeral by design. They exist to serve a sequence of imports, one list
    /// per presentation, and each presentation of that sequence targets a
    /// *different* list than the last. Carrying a checked box forward would
    /// therefore be wrong every time it mattered, so a presentation always opens
    /// with both off and the user states the target for the paste in front of
    /// them.
    @State private var replaceFramesOnly = false
    @State private var replaceTimecodesOnly = false

    /// Return runs Import; Option-Return enters a line break. Owned here rather
    /// than inherited: this popover is presented from inside the FilmSheet, and
    /// SwiftUI popovers inherit the presenting view's environment — so without
    /// its own value, Return would run the *sheet's* action and save and dismiss
    /// the whole sheet behind a paste that had not been imported yet.
    @State private var submitAction = FieldSubmitAction()

    /// Content width, exclusive of `padding`, and the same 290 every other
    /// FilmSheet popover is now stated in — `ViewingDatesTable`'s add and edit
    /// popovers being the reference. Nothing here needed the extra 50pt: both
    /// entry areas fill whatever width they are given, and the instruction
    /// paragraph above them already wraps.
    private static let width: CGFloat = 290
    private static let padding: CGFloat = 16
    private static let footnoteSize: CGFloat = 11
    /// Visible lines in each entry area before it begins scrolling.
    private static let visibleLines: Int = 3

    /// The mode in force: the local mirror once seeded, the caller's value
    /// before that, so there is one answer at every moment of the popover's
    /// life.
    private var mode: Bool { replaceLocal ?? replaces }

    /// The both-lists switch. Checking it takes ownership of the whole table, so
    /// the two per-list switches are cleared as it goes on: leaving one checked
    /// underneath a mode that already replaces everything would state a
    /// narrowing that is not in force, and it is the box the user just clicked
    /// that should win.
    private var modeBinding: Binding<Bool> {
        Binding(get: { mode }, set: { newValue in
            replaceLocal = newValue
            if newValue {
                if replaceFramesOnly { replaceFramesOnly = false }
                if replaceTimecodesOnly { replaceTimecodesOnly = false }
            }
        })
    }

    private var isAtCapacity: Bool { currentCount >= maxItems }
    private var hasEntries: Bool { currentCount > 0 }

    /// Whether the per-list switches are locked for reasons that apply to both
    /// of them at once.
    ///
    /// Three conditions, and each is the condition that makes the distinction
    /// they draw meaningless rather than merely inadvisable. With an empty table
    /// there is nothing to replace in either list; at the cap the popover has
    /// already forced the both-lists mode on, which is a superset of either; and
    /// while that mode is on it is by definition replacing both.
    private var perListLocked: Bool { !hasEntries || isAtCapacity || mode }

    /// Whether one list's switch is locked, which additionally happens whenever
    /// the *other* list's switch is checked.
    ///
    /// The two are mutually exclusive because checking both would say exactly
    /// what the both-lists switch below already says, and offering one statement
    /// two spellings invites the user to wonder which of them they picked. The
    /// lock is one-directional in practice: the box already checked stays live,
    /// so switching targets is unchecking one and checking the other rather than
    /// a state the user cannot leave.
    private func perListLockedWithOther(checked other: Bool) -> Bool {
        perListLocked || other
    }

    /// Whether each column is to be *replaced* rather than appended to, as
    /// declared by the checkboxes.
    ///
    /// The `hasEntries` term is defensive rather than load-bearing: the switches
    /// are locked off at an empty table, and with no existing rows the two
    /// dispositions produce the same array anyway. It is here so that a table
    /// emptied from elsewhere while this popover is open cannot leave a stale
    /// `true` describing rows that no longer exist.
    private var framesReplacesDeclared: Bool { mode || (replaceFramesOnly && hasEntries) }
    private var timecodesReplacesDeclared: Bool { mode || (replaceTimecodesOnly && hasEntries) }

    /// What is actually sent to the caller, which differs from the declared form
    /// in exactly one case: a per-list switch checked over an *empty* field.
    ///
    /// Read literally, that combination says "replace this list with nothing" —
    /// which would silently wipe a column on a single mis-clicked checkbox, and
    /// there is no reading of this popover under which emptying a list is the
    /// intent. So a per-list switch takes effect only for a list that was
    /// actually supplied; an unsupplied list falls to the append path, where an
    /// empty batch is a no-op and the column is left exactly as it was.
    ///
    /// The both-lists switch is deliberately NOT subject to this: replacing the
    /// whole table with one list and a column of placeholders is its
    /// long-standing and unambiguous behavior, and it says so on its label.
    ///
    /// Nothing enabled by the declared form can be refused by the effective one.
    /// The effective form only ever turns a replace into an append, which lowers
    /// that column's limit — and it can only do so for a list that parsed to
    /// zero entries, which satisfies every limit.
    private func framesReplacesEffective(_ parsedFrames: [String]) -> Bool {
        mode || (framesReplacesDeclared && !parsedFrames.isEmpty)
    }

    private func timecodesReplacesEffective(_ parsedTimecodes: [String]) -> Bool {
        mode || (timecodesReplacesDeclared && !parsedTimecodes.isEmpty)
    }

    /// Replacing discards that column first, so the whole cap is available to
    /// it. Appending keeps what is there, so only the headroom is — clamped at
    /// zero.
    ///
    /// One limit per column rather than one for the popover, now that the two
    /// columns can be written with different dispositions. The pair is exactly
    /// equivalent to the rule the commit enforces: the resulting table is
    /// `max(frames.count, timecodes.count)` rows, so it fits the cap precisely
    /// when each column does.
    private var framesLimit: Int { columnLimit(replacing: framesReplacesDeclared) }
    private var timecodesLimit: Int { columnLimit(replacing: timecodesReplacesDeclared) }

    private func columnLimit(replacing: Bool) -> Int {
        replacing ? maxItems : max(0, maxItems - currentCount)
    }

    /// The separator and pairing rules, which never change.
    ///
    /// Split away from the room sentence so that the half of this paragraph that
    /// is fixed is laid out as fixed. The two used to be interpolated together,
    /// which made a constant statement share a line box with a varying one and
    /// left the whole block's height at the mercy of a checkbox.
    private static let entryRules = "Separate entries with commas or line breaks. Lists are paired in order; if one is longer than the other, unmatched entries will be automatically populated with a “\(PairedFramesRecord.missingText)”."

    /// How much room is left, for the two columns together when one number
    /// covers both and for each of them by name when it does not.
    ///
    /// Naming both numbers in the divergent case is the only honest option:
    /// quoting either one alone would contradict the Import button for some
    /// paste, since the button is gated on both. The equal case — every state
    /// before the per-list switches existed, and still the common one — reads as
    /// one short sentence, so the popover says nothing about two lists unless
    /// the user has actually asked for the two to be treated differently.
    private static func roomDescription(frames: Int, timecodes: Int) -> String {
        guard frames != timecodes else {
            return "Room for \(allowanceDescription(frames))."
        }
        return "Room for \(allowanceDescription(frames)) in Frames and \(allowanceDescription(timecodes)) in Time Codes."
    }

    private static func allowanceDescription(_ limit: Int) -> String {
        switch limit {
        case ...0: return "no further entries"
        case 1:    return "1 more entry"
        default:   return "up to \(limit) entries"
        }
    }

    /// Lines the room sentence is always given, whether or not it uses them.
    ///
    /// Two is both the reserved height and the ceiling. The longest string the
    /// sentence can produce is the divergent form at its widest — "Room for no
    /// further entries in Frames and up to 99 entries in Time Codes." at 73
    /// characters — which sets to two lines at this size and width with room to
    /// spare, while the equal form is comfortably one. Reserving the maximum
    /// rather than fitting the current text is the whole point: an `NSPopover`
    /// that changes height while a text view inside it has focus moves every
    /// control below the caret, and this sentence is directly above both entry
    /// areas.
    private static let roomLines: Int = 2

    /// A string of exactly `roomLines` empty lines, used as the invisible
    /// height-setter the room sentence is drawn over. See `roomSentence`.
    ///
    /// Built from the line count rather than written as a literal, so raising
    /// `roomLines` reserves the extra line automatically. Each line holds a
    /// space rather than nothing: a truly empty line is still laid out, but the
    /// space makes the intent explicit and is immune to any future trimming.
    private static let roomHeightPlaceholder =
        Array(repeating: " ", count: roomLines).joined(separator: "\n")

    var body: some View {
        // Parsed once per body evaluation and reused by the readout, the
        // mismatch note, the enablement rule, and the commit — so the popover
        // never parses the same text twice and all four necessarily agree.
        let parsedFrames = ListImportPopover.parseItems(from: framesDraft)
        let parsedTimecodes = ListImportPopover.parseItems(from: timecodesDraft)
        let rows = max(parsedFrames.count, parsedTimecodes.count)
        // Each list is measured against its own column's limit. The readout
        // below still counts entries *typed*, which is the quantity the limits
        // were restated in terms of — see `columnLimit`.
        let framesRoom = framesLimit
        let timecodesRoom = timecodesLimit
        let isOverflowing = parsedFrames.count > framesRoom || parsedTimecodes.count > timecodesRoom

        VStack(alignment: .leading, spacing: 12) {
            // Named for what the two lists below actually are, rather than for
            // the row they combine into. Matches the "Bulk Import <content>"
            // form every other CSV-button popover uses.
            Text("Bulk Import Frames and Time Codes")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            // Two statements on two lines: what this popover always does with
            // what is typed below it, and how much of it there is room for right
            // now. The second changes with the disposition of each list — the
            // full cap for a list being replaced, the remaining room for one
            // being appended to — and is recomputed from the three checkboxes,
            // so toggling any of them updates the sentence, the readout's color,
            // and the Import button together.
            //
            // The pairing rule is shown at all times rather than only when the
            // two lists actually disagree, and the room sentence is given a
            // fixed two lines whether it needs them or not. Both are the same
            // decision: this block sits directly above two focusable text views,
            // and an `NSPopover` that changes height while one of them has focus
            // moves every control below the caret. The popover's geometry is
            // therefore independent of its content and of its checkboxes.
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.entryRules)
                    .fixedSize(horizontal: false, vertical: true)

                // Given its space unconditionally, so that a checkbox changing
                // the sentence from one line to two cannot move the entry areas
                // below it. See `roomLines`.
                roomSentence(frames: framesRoom, timecodes: timecodesRoom)
            }
            .font(.system(size: Self.footnoteSize))
            .foregroundStyle(.secondary)

            // Scrolling text views rather than text fields: pasted lists are
            // routinely long, and three visible lines with scrolling beyond that
            // lets the whole entry be reviewed before importing. Line breaks
            // remain one of the two supported separators — they just take
            // Option-Return here, as they do in every other instance of this
            // control.
            VStack(alignment: .leading, spacing: 4) {
                perListHeader("Frames:",
                              isOn: $replaceFramesOnly,
                              locked: perListLockedWithOther(checked: replaceTimecodesOnly))
                FixedHeightScrollingTextView(text: $framesDraft,
                                             placeholder: "1234, 5678, 9012")
                    .frame(height: FixedHeightScrollingTextView.fixedHeight(lineCount: Self.visibleLines))
            }

            VStack(alignment: .leading, spacing: 4) {
                perListHeader("Time Codes:",
                              isOn: $replaceTimecodesOnly,
                              locked: perListLockedWithOther(checked: replaceFramesOnly))
                FixedHeightScrollingTextView(text: $timecodesDraft,
                                             placeholder: "00:01:23, 00:04:56, 00:07:89")
                    .frame(height: FixedHeightScrollingTextView.fixedHeight(lineCount: Self.visibleLines))
            }

            // Label supplied as a view rather than as a string, so the red at the
            // cap applies to the text and not to the checkbox glyph beside it —
            // the constraint is being explained, not flagged as an error in the
            // control itself. An empty table locks the same control for the
            // opposite and entirely unremarkable reason, so it takes the
            // system's disabled text color instead.
            // An AppKit checkbox beside its label rather than a Toggle wrapping it, so
            // the box is a stop in the popover's Tab walk (SheetCheckbox, 30_20). The
            // label still toggles it on click, as a Toggle's label would.
            HStack(spacing: Preferences.spacingAfterCheckbox) {
                SheetCheckbox(isOn: modeBinding)
                Text("Replace all existing entries for both lists")
                    .foregroundStyle(isAtCapacity
                                     ? Color(nsColor: .systemRed)
                                     : (hasEntries
                                        ? Color(nsColor: .labelColor)
                                        : disabledControlTextColor))
                    .onTapGesture { modeBinding.wrappedValue.toggle() }
            }
            .font(.system(size: 12))
            .disabled(isAtCapacity || !hasEntries)

            Divider()

            // Cancel leads, per the platform convention for a dismissive action;
            // the readout sits directly to the left of Import, which is what it
            // describes.
            HStack(alignment: .center, spacing: 8) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)

                Spacer(minLength: 8)

                // Shown only once something has been entered. With both fields
                // empty there is nothing to report, and a permanent "No entries
                // detected." reads as an error before the user has done
                // anything.
                if rows > 0 {
                    // Colored off `isOverflowing` — the exact term the Import
                    // button is disabled on — rather than off a separately
                    // written comparison, so the red and the disabled button can
                    // only ever appear and clear together. The count itself
                    // stays the aggregate row count while the test is per list,
                    // so when the two lists have different limits the red says
                    // "one of these does not fit" rather than naming which; the
                    // paragraph above carries both numbers.
                    Text(rows == 1 ? "1 row detected" : "\(rows) rows detected")
                        .font(.system(size: Self.footnoteSize))
                        .foregroundStyle(isOverflowing
                                         ? Color(nsColor: .systemRed)
                                         : Color(nsColor: .secondaryLabelColor))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Button("Import") {
                    onImport(parsedFrames, parsedTimecodes,
                             framesReplacesEffective(parsedFrames),
                             timecodesReplacesEffective(parsedTimecodes))
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rows == 0 || isOverflowing)
            }
        }
        .frame(width: Self.width)
        .padding(Self.padding)
        // Return runs Import; Option-Return enters a line break.
        .fieldSubmitAction(submitAction)
        .onAppear {
            // Every presentation opens empty. The drafts used to be mirrored to the
            // caller so a reopened popover could restore them, but every table clears
            // that storage in `onOpen` before presenting, so the restore never had
            // anything to restore. Reset here rather than relied upon from the
            // property initializers, for the reason the per-list switches below give:
            // SwiftUI may reuse this node for a later presentation.
            if !framesDraft.isEmpty { framesDraft = "" }
            if !timecodesDraft.isEmpty { timecodesDraft = "" }
            // The mode this presentation opens in, resolved once and then
            // written to both copies, so the local mirror and the caller's
            // storage can never begin a session disagreeing. At the cap,
            // replacing is the only mode that can do any work, so it is forced
            // ON; with nothing to replace, the two modes are identical, so it is
            // locked OFF. The two conditions are mutually exclusive given a
            // positive cap, so their order is immaterial.
            var resolved = replaces
            if isAtCapacity { resolved = true }
            if !hasEntries { resolved = false }
            if replaces != resolved { replaces = resolved }
            if replaceLocal != resolved { replaceLocal = resolved }
            // The per-list switches are ephemeral, so a presentation begins with
            // both off. Written here rather than relied upon from the property
            // initializers: SwiftUI may reuse this node for a later
            // presentation, in which case the initializers do not run again and
            // a box checked for the previous paste would still be checked over
            // the next one — silently replacing a list the user had not named.
            if replaceFramesOnly { replaceFramesOnly = false }
            if replaceTimecodesOnly { replaceTimecodesOnly = false }
            // Installed in `onAppear`, not in `body` — assigning the handler is
            // a mutation of a shared object and must not happen during view
            // evaluation. The closure captures this view value, and `@State`
            // reads route through SwiftUI's storage rather than a captured copy,
            // so the drafts are the text current at the moment Return is
            // pressed.
            //
            // The guards below are precisely the Import button's own
            // `.disabled(rows == 0 || isOverflowing)`, expanded to the two
            // per-list comparisons that term is built from, so Return is inert
            // exactly when the button is rather than importing something the
            // button would have refused.
            submitAction.setHandler {
                let f = ListImportPopover.parseItems(from: framesDraft)
                let t = ListImportPopover.parseItems(from: timecodesDraft)
                guard max(f.count, t.count) > 0 else { return false }
                guard f.count <= framesLimit, t.count <= timecodesLimit else { return false }
                onImport(f, t,
                         framesReplacesEffective(f),
                         timecodesReplacesEffective(t))
                return true
            }
        }
        // Cleared on dismissal so a handler capturing a finished presentation
        // cannot survive into the next one if SwiftUI reuses this node.
        .onDisappear {
            submitAction.setHandler(nil)
        }
        // Mirrored back on every change, so the caller's storage stays the value
        // the next presentation is seeded from.
        .onChange(of: replaceLocal) { _, newValue in
            guard let newValue else { return }
            if replaces != newValue { replaces = newValue }
        }
    }

    /// The room sentence, drawn at a height that is the same in every state this
    /// popover can be in.
    ///
    /// **Why not `lineLimit(_:reservesSpace:)`.** That is what this was, and it
    /// very nearly worked: the block reserved two lines whether the sentence
    /// used one or two, so checking a per-list "Replace existing entries" switch
    /// — which is what makes the two columns' limits diverge and the sentence
    /// grow from its one-line equal form to its two-line divergent one — no
    /// longer moved the entry areas by a whole line. What it did still move them
    /// by was a point or two, and the `.fixedSize(vertical:)` beside it is why.
    /// `reservesSpace` sets a *floor* of `roomLines` line heights; `fixedSize`
    /// then asks for the text's own *ideal* height, which for a genuinely
    /// wrapped two-line sentence is the measured height of two laid-out line
    /// fragments — leading included, and not identical to twice the reserved
    /// line height. The larger of the two won, so the one-line state was drawn
    /// at the reserved height and the two-line state at the measured one. The
    /// pair could not simply be separated, either: without `fixedSize` the text
    /// resolves at its single-line ideal and truncates inside the space it has
    /// already been given, rather than wrapping into it.
    ///
    /// **What this does instead.** An invisible `Text` of exactly `roomLines`
    /// empty lines sets the height, and the real sentence is drawn over it as an
    /// overlay. An overlay never contributes to its host's size, so the sentence
    /// cannot influence the height at all — one line or two, appended or
    /// replaced, either switch checked or neither. And the height it is measured
    /// against is a real multi-line `Text` laid out by the same font and the same
    /// framework, so a wrapped sentence lands in exactly the space reserved for
    /// it rather than in an arithmetic approximation of it.
    ///
    /// `lineLimit(roomLines)` stays as the ceiling: it is unreachable at the
    /// current widths (see `roomLines`), and it is what guarantees that if a
    /// future phrasing ever did run long it would truncate inside the reserved
    /// box instead of drawing past its bottom edge.
    private func roomSentence(frames: Int, timecodes: Int) -> some View {
        Text(Self.roomHeightPlaceholder)
            .hidden()
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                Text(Self.roomDescription(frames: frames, timecodes: timecodes))
                    .lineLimit(Self.roomLines)
                    // Wraps into the reserved second line rather than truncating
                    // at the first — the overlay is given the host's width but
                    // its ideal height, so this is what lets it use two lines.
                    // It can no longer disturb the layout by doing so.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
    }

    /// One entry area's caption: the list's name at the leading edge and that
    /// list's own replace switch pushed to the trailing edge, on a single line.
    ///
    /// Built once and called twice rather than written out per field, on the
    /// same grounds as `FramesMarkRow` and `FramesFadeRow` above: the two
    /// captions are read as a pair, and a difference in font, spacing, or
    /// enablement between them would be visible and meaningless.
    ///
    /// `fixedSize()` on the toggle is what makes the alignment the caption
    /// promises actually hold. Without it the control accepts the width the
    /// `Spacer` leaves and its label may be laid out inside a wider box, so the
    /// text would stop short of the entry area's right edge by an amount that
    /// varies with the label. Sized to its content, the label's trailing edge is
    /// the row's trailing edge, which is the field's.
    ///
    /// The label color is stated explicitly, so the disabled case has to be
    /// stated too — an explicit `labelColor` would otherwise defeat the dimming
    /// `.disabled` applies. This mirrors the both-lists checkbox below, minus
    /// its at-capacity red: at the cap these are locked by that checkbox having
    /// been forced on, and repeating the warning on all three rows would spread
    /// one constraint across the whole popover.
    ///
    /// `locked` is passed in rather than read here, because half of it is the
    /// state of the *other* caption's switch — see `perListLockedWithOther`.
    private func perListHeader(_ title: String,
                               isOn: Binding<Bool>,
                               locked: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)

            Spacer(minLength: 8)

            // AppKit checkbox + label, as above.
            HStack(spacing: Preferences.spacingAfterCheckbox) {
                SheetCheckbox(isOn: isOn)
                Text("Replace existing entries")
                    .foregroundStyle(locked
                                     ? disabledControlTextColor
                                     : Color(nsColor: .labelColor))
                    .onTapGesture { isOn.wrappedValue.toggle() }
            }
            .fixedSize()
            .disabled(locked)
        }
        .font(.system(size: 12))
    }
}

// MARK: - Audio Fade Style Enum
enum AudioFadeStyle: String, Hashable {
    case linear, scurve, plus, minus, none
    
    var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .scurve: return "S-curve"
        case .plus: return "+3dB"
        case .minus: return "-3dB"
        case .none: return "None"
        }
    }
    
    var glyph: String {
        switch self {
        case .linear: return "line.diagonal"
        case .scurve: return "point.bottomleft.forward.to.point.topright.scurvepath"
        case .plus: return "wave.3.up"
        case .minus: return "wave.3.down"
        case .none: return ""
        }
    }
    
    // `fromString` is gone with its two callers, for the same reason MarkStyle's is: it
    // was literally `AudioFadeStyle(rawValue: str) ?? .none`, and FramesEntryParser.parse
    // now needs the failable initializer's nil to tell an unrecognized token apart from a
    // stored "none".
}
