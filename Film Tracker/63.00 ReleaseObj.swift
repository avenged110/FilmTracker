// MARK: - ReleaseObj.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Defines the data model for a physical media release (DVD, Blu-ray, 4K UHD, etc.)
// associated with a Film object.

import Foundation
import SwiftData

// MARK: - Independence Vocabulary
/// The stored vocabulary for `Release.independence`, plus the rules that derive
/// combo-pack structure from it.
///
/// The values are plain `String`s in the model (they are persisted verbatim, exported to
/// XML backups, and read back by `SafeValueParser`), so this enum is a namespace of
/// constants and pure functions rather than a `RawRepresentable` case set — an unknown
/// value arriving from a legacy backup must round-trip untouched rather than fail to
/// decode.
///
/// `comboPackDualBD` is the second combo-pack form: a 4K UHD pack that bundles **two**
/// distinct Blu-ray copies of the film rather than one. It is offered only on 4K UHD
/// cards; the bundled Blu-ray children themselves always carry plain `comboPack`, which
/// is what keeps every existing child-side check (`independence == "Combo-pack" && format
/// != "4K UHD"`) correct without modification.
enum ReleaseIndependence {
    static let standalone       = "Standalone"
    static let comboPack        = "Combo-pack"
    static let comboPackDualBD  = "Combo-pack (dual BD)"
    static let multiPack        = "Multi-pack"

    /// How many child Blu-ray releases a 4K UHD parent carrying `value` should have.
    /// Returns 0 for every non-combo value, which is what makes it safe to call on any
    /// independence string without a prior membership test.
    static func childCount(for value: String) -> Int {
        switch value {
        case comboPackDualBD: return 2
        case comboPack:       return 1
        default:              return 0
        }
    }

    /// True for either combo-pack form. Used wherever the distinction between one and
    /// two bundled Blu-rays is irrelevant and only "is this a combo pack" matters.
    static func isComboPack(_ value: String) -> Bool { childCount(for: value) > 0 }

    /// The independence value implied by an actual child count — the inverse of
    /// `childCount(for:)`. Returns nil for counts outside 1...2, which have no
    /// corresponding value and must be handled by the caller (a parent found holding
    /// three children is a data anomaly, not a fourth pack type).
    static func value(forChildCount count: Int) -> String? {
        switch count {
        case 1:  return comboPack
        case 2:  return comboPackDualBD
        default: return nil
        }
    }

    /// The form shown in fixed-width table columns. `comboPackDualBD` is ~70% wider than
    /// the widest column that displays this field (78 pt) and would truncate mid-word;
    /// the dual-Blu-ray structure is already conveyed by the two stacked child rows
    /// directly beneath the parent, so the column states the pack type alone.
    static func compactDisplay(_ value: String) -> String {
        value == comboPackDualBD ? comboPack : value
    }
}

// MARK: - Studio Vocabulary

/// The stored vocabulary for `Release.studio`: every known studio name, in the order the
/// ReleaseCard Picker offers them, together with the two shorter spellings each goes by
/// where its full name will not fit.
///
/// # Three spellings, not two
///
/// A studio has up to three display forms, each a further retreat from the previous one:
///
///   • `name` — the complete name ("Universal Studios"). The stored value, what the
///     Picker offers, and what every surface with room to spare prints.
///   • `shorthand` — the everyday short name ("Universal"). What the RightSidebar's
///     "Source for Viewing" field prints when it has plenty of room: the field is a
///     one-line summary, and "Universal remastered Blu-ray disc" already says what
///     "Universal Studios remastered Blu-ray disc" says.
///   • `abbreviated` — the tightest form ("Uni"). What the sidebar retreats to when even
///     the shorthand would wrap, and what the PDF's Notes column falls back to when a
///     cell is over budget.
///
/// Each tier falls back to the one above it when a studio has no spelling at that tier,
/// so `abbreviated(_:)` on a name with only a shorthand yields the shorthand, and either
/// accessor on a name with neither yields the name itself. That fallback is what lets a
/// caller ask for a tier unconditionally: it always gets the shortest spelling the studio
/// actually has at or above that tier, never a blank and never a longer one.
///
/// # Why this is one table
///
/// Three features read this vocabulary and they must agree, because a reader moves between
/// them: the ReleaseCard's Studio Picker (which offers the names and decides whether a
/// stored value is a known studio or a free-text "Other"), the RightSidebar's "Source for
/// Viewing" field (`RSBHelpers`, gated by `Preferences.abbreviateSourceStudio`) and the
/// complete-library PDF's Notes column, which falls back to the abbreviated form when the
/// cell would otherwise truncate. The Picker list and the abbreviation mapping each used to
/// be a hand-maintained copy of the same names, and two copies of a twenty-entry vocabulary
/// is a table that drifts. Adding, renaming or re-abbreviating a studio is now one edit
/// to `entries`.
///
/// The callers still decide WHEN to shorten; this decides only WHAT to. That split is
/// deliberate: the sidebar's rule is a user preference plus a measurement and the PDF's is
/// a measurement, and neither belongs in a lookup table.
///
/// # Coverage
///
/// Values are plain `String`s in the model (persisted verbatim, exported to XML backups),
/// so this is a namespace of constants rather than a `RawRepresentable` case set — a
/// free-text "Other" studio, or a legacy name no longer offered, must round-trip untouched.
/// Not every known studio has a shorter form: a name already short enough (Criterion, MGM,
/// Imprint) has nothing to gain from one, and an unmapped name — including a free-text
/// "Other" entry — is returned unchanged so the lookup degrades gracefully rather than
/// blanking a studio it has not been taught. "Other" itself is intentionally absent from
/// the table — it is a Picker sentinel, not a value.
enum ReleaseStudio {
    /// One known studio: its stored name and, where it has them, its shorthand and its
    /// abbreviation. See the tier notes above for what each is for and how they fall back.
    struct Entry {
        let name: String
        let shorthand: String?
        let abbreviated: String?

        init(name: String, shorthand: String? = nil, abbreviated: String? = nil) {
            self.name = name
            self.shorthand = shorthand
            self.abbreviated = abbreviated
        }
    }

    /// The Picker's three tiers, each declared alphabetically and each drawn with a
    /// divider ahead of it (see `_StudioRow.studioItems`, 33_20) — a fourth, the free-text
    /// "Other" sentinel, is appended by that same Picker builder rather than living here,
    /// since it is not a stored studio name. Splitting `entries` into named tiers rather
    /// than one flat list is what lets the Picker draw those dividers at all: a flat array
    /// has no boundary to draw one at.
    ///
    /// MAJOR STUDIOS — the handful most releases in a typical library belong to.
    private static let majorStudios: [Entry] = [
        Entry(name: "20th Century Fox",         shorthand: "Fox"),
        Entry(name: "Arrow Video",              shorthand: "Arrow"),
        Entry(name: "Disney/Buena Vista",       shorthand: "Disney"),
        Entry(name: "Kino Lorber",              shorthand: "Kino",            abbreviated: "KL"),
        Entry(name: "Lionsgate Films",          shorthand: "Lionsgate",       abbreviated: "LGF"),
        Entry(name: "MGM"),
        Entry(name: "Paramount Pictures",       shorthand: "Paramount",       abbreviated: "PMT"),
        Entry(name: "Shout Factory",            shorthand: "Shout",           abbreviated: "SF"),
        Entry(name: "Sony Pictures",            shorthand: "Sony"),
        Entry(name: "Universal Studios",        shorthand: "Universal",       abbreviated: "Uni"),
        Entry(name: "Warner Bros.",             shorthand: "Warner",          abbreviated: "WB"),
    ]

    /// ARCHIVAL AND BOUTIQUE LABELS — reissue houses and mid-size distributors.
    private static let archivalAndBoutiqueLabels: [Entry] = [
        Entry(name: "ClassicFlix"),
        Entry(name: "Criterion"),
        Entry(name: "Echo Bridge Entertainment", shorthand: "Echo Bridge"),
        Entry(name: "Flicker Alley"),
        Entry(name: "Genius/Dimension"),
        Entry(name: "Image Entertainment",       shorthand: "Image"),
        Entry(name: "Kit Parker Films",          shorthand: "Kit Parker",     abbreviated: "KPF"),
        Entry(name: "Magnolia Pictures",         shorthand: "Magnolia"),
        Entry(name: "Mill Creek Entertainment",  shorthand: "Mill Creek",     abbreviated: "MC"),
        Entry(name: "MVD Visual",                shorthand: "MVD"),
        Entry(name: "Olive Films",               shorthand: "Olive"),
        Entry(name: "RLJ Entertainment"),
        Entry(name: "Samuel Goldwyn Films",      shorthand: "Samuel Goldwyn", abbreviated: "SGF"),
        Entry(name: "Starz/Anchor Bay",          shorthand: "Starz"),
        Entry(name: "Summit Entertainment",      shorthand: "Summit"),
        Entry(name: "Timeless Media Group",      shorthand: "Timeless Media", abbreviated: "TMG"),
        Entry(name: "Twilight Time",             shorthand: "Twilight Time",  abbreviated: "TT"),
        Entry(name: "VCI"),
        Entry(name: "Warner Archive",            shorthand: "WB Archive",     abbreviated: "WA"),
    ]

    /// SPECIALTY IMPORTS — smaller and region-specific labels.
    private static let specialtyImports: [Entry] = [
        Entry(name: "Capelight Pictures",        shorthand: "Capelight"),
        Entry(name: "Concorde Video"),
        Entry(name: "Entertainment One"),
        Entry(name: "Eureka Entertainment",      shorthand: "Eureka"),
        Entry(name: "Imprint"),
        Entry(name: "Koch Media"),
        Entry(name: "Powerhouse Films",          shorthand: "Powerhouse",     abbreviated: "PHF"),
        Entry(name: "Second Sight",              shorthand: "Second Sight",   abbreviated: "SS"),
        Entry(name: "Studio Canal",              shorthand: "StudioCanal",    abbreviated: "SC"),
        Entry(name: "Turbine Media"),
        Entry(name: "Via Vision",                shorthand: "Via Vision",     abbreviated: "VV"),
    ]

    /// The three tiers in Picker order. `entries` below flattens them for every consumer
    /// that only needs the vocabulary as a whole (membership tests, the shorthand and
    /// abbreviation lookups); only the Picker builder needs the tier boundaries themselves.
    static let sections: [[Entry]] = [majorStudios, archivalAndBoutiqueLabels, specialtyImports]

    /// The single source of truth, flattened from `sections`. Order is Picker order.
    static let entries: [Entry] = sections.flatMap { $0 }

    /// The known names in Picker order.
    static let ordered: [String] = entries.map(\.name)

    /// The known names as a set, for O(1) membership tests.
    static let known: Set<String> = Set(ordered)

    /// Stored studio name → shorthand, for the names that have one.
    private static let shorthands: [String: String] = Dictionary(
        uniqueKeysWithValues: entries.compactMap { entry in
            entry.shorthand.map { (entry.name, $0) }
        }
    )

    /// Stored studio name → abbreviation, for the names that have one.
    private static let abbreviations: [String: String] = Dictionary(
        uniqueKeysWithValues: entries.compactMap { entry in
            entry.abbreviated.map { (entry.name, $0) }
        }
    )

    /// True when `studio` is a name the Picker offers (as opposed to "" or free text).
    static func isKnown(_ studio: String) -> Bool { known.contains(studio) }

    /// The shorthand, or the name unchanged when there is none.
    static func shorthand(_ studio: String) -> String { shorthands[studio] ?? studio }

    /// The abbreviation, falling back to the shorthand and then to the name itself, so the
    /// result is always the tightest spelling the studio has.
    static func abbreviated(_ studio: String) -> String { abbreviations[studio] ?? shorthand(studio) }
}

// MARK: - Artwork Vocabulary
/// The stored vocabulary for `Release.hasArtwork`, plus the per-independence option lists
/// the card's artwork picker offers.
///
/// Open vocabulary, as everywhere else here: the tags are persisted verbatim and read back
/// with no membership check (see the pickers' tag-set guarantees), so the stored set is
/// open by design and a closed Swift type would misdescribe it.
///
/// This began as a single constant for `steelbook`, on the reasoning that every other tag
/// was "only ever a menu entry" and so a literal was harmless. THAT IS NO LONGER TRUE —
/// the releases table branches on six of these tags by value and the right sidebar's
/// `artworkNote` switches on eight, so the picker that writes them and the two surfaces
/// that read them were three independent spellings of one vocabulary. They are one now.
///
/// `steelbook` keeps its own note because it carries a rule the others do not: it is the
/// sole tag offered under EVERY combination of purchased state and independence type,
/// which makes it the one value the card's cascades have to reason about. Two cascades
/// once did so against two separate literals — and they disagreed, so a type change
/// discarded a steelbook the purchase cascade had been written to preserve.
enum ReleaseArtwork {
    /// A steelbook case. Offered regardless of purchased state and independence type, so
    /// no cascade may retract it on the grounds that a vocabulary changed underneath it.
    static let steelbook = "Steelbook"

    // MARK: Standalone tags
    static let yes                  = "Yes"
    static let no                   = "No"
    static let yesIncorrectRelease  = "Yes (Incorrect release)"
    static let yesCustom            = "Yes (Custom)"

    // MARK: Pack-qualified tags
    static let yesComboPack = "Yes (Combo-pack)"
    static let yesMultiPack = "Yes (Multi-pack)"

    /// The negative pack-qualified forms. NOT offered by the picker — both pack types
    /// offer a plain `no` — but records carrying them exist (legacy data, or a restore
    /// from an older backup), and both the releases table and the sidebar recognize them.
    /// Declared here so those two agree on the spelling of a tag neither can produce.
    static let noComboPack = "No (Combo-pack)"
    static let noMultiPack = "No (Multi-pack)"

    // MARK: Picker option lists
    //
    // Each list is what the card offers ON TOP OF `steelbook`, which is seeded
    // unconditionally. Selected by the release's independence value.

    static let standaloneOptions = [yes, yesIncorrectRelease, yesCustom, no]
    static let comboPackOptions  = [yesComboPack, no]
    static let multiPackOptions  = [yesMultiPack, no]

    /// The tags that answer "yes, artwork is present", including the pack-qualified forms
    /// and the unofferable negative forms' counterparts. `steelbook` is deliberately
    /// absent: it is affirmative too, but both readers give it its own presentation
    /// (a distinct glyph, a distinct note) before consulting this.
    static let affirmativeTags: Set<String> = [yes, yesMultiPack, yesComboPack]

    /// The tags that answer "no artwork", including the two the picker cannot produce.
    static let negativeTags: Set<String> = [no, noMultiPack, noComboPack]
}

// MARK: - Condition Vocabulary
/// The stored vocabulary for `Release.condition`.
///
/// Open, and unusually so: this is the one release field with NO unset representation in
/// its own vocabulary, and also the one most likely to arrive empty — it defaults to ""
/// throughout the persistence layer, and `DBRestorer`'s `parseString` yields "" for a
/// backup predating the field. The card's segmented picker grows a third segment to show
/// such a value rather than silently rendering with nothing selected; see
/// `_ConditionPicker`. Consumers must therefore treat "" as legal, not as an error.
enum ReleaseCondition {
    static let new  = "New"
    static let used = "Used"

    /// The two segments the picker offers, in order.
    static let pickerOptions = [new, used]

    /// Values the picker can produce. Anything else — "" included — is anomalous and gets
    /// the card's third segment.
    static let known: Set<String> = [new, used]

    /// True for a value outside the vocabulary, which the card must surface rather than
    /// mask. Empty counts as anomalous: legal to hold, but not something to hide.
    static func isAnomalous(_ value: String) -> Bool { !known.contains(value) }
}

// MARK: - Master Type Vocabulary
/// The stored vocabulary for `Release.masterType`, the 4K-only field recording whether the
/// disc was mastered from a true 4K source or upscaled from a 2K one.
///
/// Open vocabulary, for the same reason as every other release field in this file: the
/// value is persisted verbatim, exported to XML backups, and read back by
/// `SafeValueParser` with no membership check, so a value this build does not recognize
/// must round-trip untouched rather than be coerced or rejected. That is why this is a
/// namespace of constants and predicates over `String` rather than a closed Swift type.
///
/// THE EMPTY STRING IS THE THIRD STATE, and it is not an anomaly. `newReleaseDefaults`
/// pre-fills `nativeFourK` for 4K UHD alone; `ReleaseCardModel` initializes the field to
/// "" and every other format leaves it there. That "" can never go stale on a Blu-ray or
/// DVD because a release's `format` is fixed at creation — there is no format picker on
/// the card — so the field is written only by the 4K trait row, which is only built for
/// `.uhd4K`. Consumers must therefore treat "" as "not applicable", never as a value to
/// display or tally, which is what `isKnown(_:)` exists to express.
enum ReleaseMasterType {
    /// Mastered from a true 4K source. The default for a new 4K UHD release — the common
    /// case, and the one the card's trait row is phrased as the negative of.
    static let nativeFourK = "Native 4K"

    /// Upscaled from a 2K master. The "on" state of the card's "Upscaled 4K Master" trait.
    static let upscaled = "Upscaled"

    /// True for a value this build can interpret — i.e. one the card's trait row can
    /// actually produce. Deliberately false for "" (a non-4K release, which has no master
    /// type) and for any legacy or hand-edited value outside the pair, so a display site
    /// can fall back rather than print a fragment of data it cannot vouch for.
    static func isKnown(_ value: String) -> Bool {
        value == nativeFourK || value == upscaled
    }
}

// MARK: - HDR Vocabulary
/// The stored vocabulary for `Release.hasHDR`, the 4K-only field recording which HDR
/// format — if any — the disc carries.
///
/// Open vocabulary, as above; the picker that offers these tags is a `TaggedPicker`
/// precisely so a stored value outside the list survives being shown rather than
/// rendering as a blank control over real data.
///
/// `noneTag` is the one tag that is an ASSERTION rather than an absence: it states that
/// the release carries no HDR, which is different from "" (nobody has said). Both the
/// search filter and the sidebar's display treat them differently, so they cannot be
/// collapsed.
enum ReleaseHDR {
    static let dolbyVision = "Dolby Vision"
    static let hdr10       = "HDR10"
    static let hdr10Plus   = "HDR10+"

    /// An affirmative "this release has no HDR". Named `noneTag` rather than `none` so it
    /// can never be confused with `Optional.none` at a call site that infers its type.
    static let noneTag = "None"

    /// The picker's option list, in the order it offers them. `noneTag` sits last: it is
    /// the negative answer, and the three formats are what the user is usually reaching
    /// for.
    static let pickerOptions: [String] = [dolbyVision, hdr10, hdr10Plus, noneTag]

    /// The tags that represent an actual HDR format — `pickerOptions` minus `noneTag`.
    /// Excludes "" (unset) by construction.
    static let capableTags: Set<String> = [dolbyVision, hdr10, hdr10Plus]

    /// True when `value` names a real HDR format. Backs the bare "hdr" search token.
    static func isCapable(_ value: String) -> Bool { capableTags.contains(value) }

    /// True for either HDR10 generation. "HDR10+" is a superset of HDR10 in practice — a
    /// disc carrying it plays back as HDR10 on hardware that does not know the extension —
    /// so a search for "hdr10" matches both, while "hdr10+" matches only the tag itself.
    static func isHDR10Family(_ value: String) -> Bool {
        value == hdr10 || value == hdr10Plus
    }
}

// MARK: - Scanning Method Vocabulary
/// The stored vocabulary for `Release.scanningMethod`, the Blu-ray-only field. Open
/// vocabulary, as above.
///
/// DVD does not use this field as a choice: every DVD is interlaced, which the release
/// card shows as a locked trait and `newReleaseDefaults` writes as the stored value, so a
/// DVD carries `interlaced` without the user ever having selected it. 4K UHD is
/// progressive by definition and leaves the field "".
enum ReleaseScanningMethod {
    static let progressive = "Progressive"
    static let interlaced  = "Interlaced"

    /// True for an interlaced release. The one question any consumer asks of this field:
    /// both the sidebar's video line and the card's trait row are phrased as
    /// "Interlaced ⇒ qualify the codec", with progressive and unset alike saying nothing.
    static func isInterlaced(_ value: String) -> Bool { value == interlaced }
}

// MARK: - Replication Type Vocabulary
/// The stored vocabulary for `Release.replicationType` — whether the disc was factory
/// pressed or burned to recordable media. Open vocabulary, as above.
///
/// ONE stored tag, two user-facing spellings. The release card labels the trait
/// "Recordable (BD-R)" on Blu-ray and "Recordable (DVD-R)" on DVD, but both write
/// `recordable`; only the label differs, and the suffix shown in the sidebar and the
/// releases table is likewise a presentation choice made at those sites. Nothing may
/// branch on the disc-type spelling when reading this field.
enum ReleaseReplicationType {
    /// Factory-pressed. The "off" state of the card's recordable trait — written
    /// explicitly rather than cleared, since this field has no meaningful unset state.
    ///
    /// Also the value every new card starts at, but note WHERE that happens: unlike
    /// `masterType` and `scanningMethod`, this is not a `NewReleaseDefaults` field,
    /// because it does not vary by format. `ReleaseCardModel`'s own initializer seeds it
    /// for all three formats, which is the only path a new release is created through.
    static let pressed = "Pressed"

    /// Burned to recordable media (BD-R / DVD-R).
    static let recordable = "Recordable"

    /// True for a recordable disc. The only question consumers ask of this field.
    static func isRecordable(_ value: String) -> Bool { value == recordable }
}

// MARK: - Video Codec Vocabulary
/// The stored vocabulary for `Release.videoFormat`. Open vocabulary, as above — the
/// Blu-ray picker is a `TaggedPicker` for the same round-trip reason as the HDR one.
///
/// Only Blu-ray offers a choice. 4K UHD ships `hevc` and nothing else, and DVD ships
/// `mpeg2` and nothing else, so both are written by `newReleaseDefaults` and shown as
/// fixed text rather than as a picker. That is also why `hevc` is the sidebar's fallback
/// for a 4K release whose codec is somehow unset: the format implies it, so filling it in
/// asserts nothing that is not already true.
enum ReleaseVideoFormat {
    static let hevc  = "HEVC"
    static let avc   = "AVC"
    static let vc1   = "VC-1"
    static let mpeg2 = "MPEG2"

    /// The Blu-ray picker's option list, in offered order.
    static let bluRayPickerOptions: [String] = [avc, vc1, mpeg2]
}

// MARK: - Market Availability Vocabulary
/// The stored vocabulary for `Release.marketAvailability`, paired with the unabbreviated
/// form each tag is shown as.
///
/// The stored values are abbreviated because they originated in a fixed-width table
/// column ("OOP (cheap)"), and — like every other release vocabulary in this file — they
/// are persisted verbatim, exported to XML backups, and read back by `SafeValueParser`,
/// so they cannot simply be renamed. The expansion therefore lives at the display layer,
/// as a lookup keyed by tag, and this is its single definition: the release card's picker
/// builds its option titles from it, and the right sidebar's release cards print through
/// it. A tag with no entry is its own title, which is the correct answer for both the
/// values that need no expansion ("Available", "Unavailable") and for an unknown value
/// arriving from a legacy or hand-edited backup.
enum ReleaseMarketAvailability {
    /// The locked value carried by a non-4K release inside a combo pack.
    static let comboPackOnly = "Combo-pack only"

    // MARK: The stored tags
    //
    // Added after the abbreviation trap this vocabulary was always going to spring: the
    // Reports tab tallied out-of-print releases against "Out of print (cheap)" and friends
    // — neither the stored tag NOR its expansion, which is "Out-of-print (cheap)" with a
    // hyphen — so all three OOP arms of that filter were dead and the count silently
    // reported only the "Unavailable" ones. A vocabulary whose stored form and displayed
    // form differ CANNOT be safely respelled from memory at a call site.

    static let available   = "Available"
    static let unavailable = "Unavailable"
    static let importOnly     = "Import only"
    static let importOnlyOOP  = "Import only (OOP)"
    static let oopCheap      = "OOP (cheap)"
    static let oopReasonable = "OOP (reasonable)"
    static let oopExpensive  = "OOP (expensive)"
    static let tempNA        = "Temp. N/A"

    /// The import tags, withheld for a release whose national origin is the United States.
    static let importOnlyTags: Set<String> = [importOnly, importOnlyOOP]

    /// The three out-of-print price tiers. `importOnlyOOP` is deliberately absent: it is
    /// an import that also happens to be out of print, and the picker offers it in the
    /// import group rather than this one.
    static let outOfPrintTags: Set<String> = [oopCheap, oopReasonable, oopExpensive]

    /// The tags meaning a release cannot currently be bought new at retail — the
    /// out-of-print tiers plus a flat `unavailable`. Backs the Reports tab's
    /// "unpurchased and out-of-print" tally.
    static let unobtainableTags: Set<String> = outOfPrintTags.union([unavailable])

    /// True when `tags` contains any tag meaning the release cannot be bought new.
    static func isUnobtainable(_ tags: [String]) -> Bool {
        tags.contains { unobtainableTags.contains($0) }
    }

    /// The picker's tags for a non-US release, in menu order. A US release drops
    /// `importOnlyTags` — an American release cannot be an import.
    static let allTags: [String] = [
        available, importOnly, importOnlyOOP,
        oopCheap, oopReasonable, oopExpensive, tempNA, unavailable,
    ]

    private static let titles: [String: String] = [
        importOnlyOOP: "Import only, out-of-print",
        oopCheap:      "Out-of-print (cheap)",
        oopReasonable: "Out-of-print (reasonable)",
        oopExpensive:  "Out-of-print (expensive)",
        tempNA:        "Temporarily unavailable",
    ]

    /// The unabbreviated form of one stored tag.
    static func displayTitle(_ tag: String) -> String { titles[tag] ?? tag }

    /// The unabbreviated forms of a stored array, joined for a single line of prose.
    static func displayList(_ tags: [String]) -> String {
        tags.map(displayTitle).joined(separator: ", ")
    }
}

// MARK: - Audio Format Vocabulary
/// The stored vocabulary for `Release.audioFormat`, plus the three quality questions
/// consumers ask of it. Open vocabulary, as everywhere else here.
///
/// Each of those questions was previously answered by a separate pair of string
/// comparisons at each site that asked it. `_AudioSection.isObjectBased` even documented
/// itself as "the single definition of object-based" — accurate about the two consumers it
/// was extracted for, but the Reports tab's data-viz pass had grown a third copy of the
/// same comparison that the extraction never reached. That is the shape this file exists
/// to prevent: a rule that believes it is centralized while a copy of it lives elsewhere.
enum ReleaseAudioFormat {
    static let dolbyAtmos   = "Dolby Atmos"
    static let dolbyTrueHD  = "Dolby TrueHD"
    static let dolbyDigital = "Dolby Digital"
    static let lpcm         = "LPCM"
    static let dtsHDMA      = "DTS-HD MA"
    static let dtsHDHR      = "DTS-HD HR"
    static let dtsX         = "DTS:X"
    static let dts          = "DTS"

    // MARK: Per-format option lists

    /// DVD's narrower vocabulary — the HD formats did not exist on the disc. This being a
    /// strict SUBSET of `hdOptions` is what makes the pickers' tag-set guarantee
    /// load-bearing rather than merely defensive: a value perfectly ordinary on Blu-ray is
    /// out-of-vocabulary on DVD, and a DVD restored holding `dtsHDMA` would render blank
    /// on a bare Picker.
    static let dvdOptions = [dolbyDigital, dts]

    /// The 4K UHD and Blu-ray vocabulary, in menu order. Matches the Data Visualizations
    /// tab's Audio card codec bar order (27.40 RPTabDataViz.swift).
    static let hdOptions = [dolbyAtmos, dolbyTrueHD, dolbyDigital, lpcm,
                            dtsX, dtsHDMA, dtsHDHR, dts]

    // MARK: Quality questions

    /// Object-based formats, for which the Channels picker is locked to 7.1.
    static let objectBasedTags: Set<String> = [dolbyAtmos, dtsX]

    /// True for an object-based format. The single definition, consulted by the control
    /// that LOCKS the channels field, the cascade that CLEARS it, and the Reports tab's
    /// object-based tally.
    static func isObjectBased(_ value: String) -> Bool { objectBasedTags.contains(value) }

    /// Formats that carry a lossless track. Drives the release quality score.
    static let losslessTags: Set<String> = [dolbyAtmos, dtsX, dtsHDMA, dolbyTrueHD, lpcm]

    /// True for a lossless format.
    static func isLossless(_ value: String) -> Bool { losslessTags.contains(value) }

    /// The two lossy formats that are notable when they appear on an HD disc — a 4K UHD or
    /// Blu-ray carrying one is the "lossy BD audio" the Reports tab counts. Deliberately
    /// NOT simply "not lossless": an unset field is not a lossy soundtrack, and neither is
    /// a value from a future build.
    static let lossyHDTags: Set<String> = [dolbyDigital, dtsHDHR]

    /// True for a lossy format on an HD disc. The caller checks the format itself.
    static func isLossyOnHDDisc(_ value: String) -> Bool { lossyHDTags.contains(value) }
}

// MARK: - Audio Channel Vocabulary
/// The stored vocabulary for `Release.audioChannels`. Open vocabulary, as everywhere else
/// here — and unusually likely to hold something outside it, since `DBRestorer`'s numeric
/// coercion can yield bare integers ("7", "5") for a value written as a number.
///
/// `surround71` is the one layout named in logic rather than merely listed: the card locks
/// the field to it for an object-based audio format and retracts it on the way back out.
/// That pair of writes and the option list that offers the layout were three separate
/// literals; a drift between them would have left the lock writing a value its own picker
/// did not offer.
enum ReleaseAudioChannels {
    static let mono10       = "1.0"
    static let mono20       = "2.0 Mono"
    static let stereo20     = "2.0"
    static let surround30   = "3.0"
    static let surround40   = "4.0"
    static let surround50   = "5.0"
    static let surround51   = "5.1"
    static let surround61   = "6.1"
    static let surround71   = "7.1"

    /// Menu order. `surround71` is withheld on DVD — it is not a DVD layout — which is
    /// exactly the condition the pickers' tag-set fallback covers, both for a DVD restored
    /// holding it and for the bare integers the restorer can produce.
    static let commonOptions = [mono10, mono20, stereo20, surround30,
                                surround40, surround50, surround51, surround61]

    /// The layouts offered for a given format.
    static func options(isDVD: Bool) -> [String] {
        isDVD ? commonOptions : commonOptions + [surround71]
    }
}

// MARK: - Country of Origin Vocabulary
/// Every country a release can be from, and everything the app says about each one.
///
/// THE single source of truth for national origin. Before this existed the same list was
/// written out three times — as the card's picker menu (`ReleaseCard`), as the sidebar's
/// demonym switch (`RSBHelpers`), and as the PDF's import-note switch (`PDFReport`) —
/// plus a fourth partial copy as the Region A set below, plus the literal "United States"
/// spelled at half a dozen "is this an import?" sites. Adding a country meant finding all
/// of them. Now a country is one row here, and the picker order, both display forms, the
/// region rule, and the domestic test all derive from it.
///
/// - `name`: the stored `nationalOrigin` value, verbatim. Persisted as-is and never
///   validated on read, so the picker tolerates a stored value not in this list (see
///   `TaggedPicker`); everything else treats an unknown name as its own display form.
/// - `demonym`: the adjective a reader would use — "German import", "German Blu-ray".
/// - `shortForm`: the compact spelling the sidebar's Source for Viewing field uses in
///   place of the demonym, where width is scarce. `nil` means the demonym is short enough.
/// - `isRegionA`: Blu-ray region for discs pressed there; everything else is Region B.
struct ReleaseOrigin: Sendable {
    let name: String
    let demonym: String
    let shortForm: String?
    let isRegionA: Bool

    /// Rows in picker order. `domestic` is first because it is the default.
    static let all: [ReleaseOrigin] = [
        ReleaseOrigin(name: "United States", demonym: "American",    shortForm: "USA", isRegionA: true),
        ReleaseOrigin(name: "England",       demonym: "English",     shortForm: "GBR", isRegionA: false),
        ReleaseOrigin(name: "Canada",        demonym: "Canadian",    shortForm: "CAN", isRegionA: true),
        ReleaseOrigin(name: "Germany",       demonym: "German",      shortForm: "DEU", isRegionA: false),
        ReleaseOrigin(name: "Australia",     demonym: "Australian",  shortForm: "AUS", isRegionA: false),
        ReleaseOrigin(name: "Japan",         demonym: "Japanese",    shortForm: "JPN", isRegionA: true),
        ReleaseOrigin(name: "France",        demonym: "French",      shortForm: "FRA", isRegionA: false),
        ReleaseOrigin(name: "New Zealand",   demonym: "New Zealand", shortForm: "NZL", isRegionA: false),
        ReleaseOrigin(name: "Italy",         demonym: "Italian",     shortForm: "ITA", isRegionA: false),
        ReleaseOrigin(name: "Finland",       demonym: "Finnish",     shortForm: "FIN", isRegionA: false),
        ReleaseOrigin(name: "Sweden",        demonym: "Swedish",     shortForm: "SWE", isRegionA: false),
        ReleaseOrigin(name: "Spain",         demonym: "Spanish",     shortForm: "ESP", isRegionA: false),
    ]

    /// The stored names in picker order — what the card's menu offers.
    static let names: [String] = all.map(\.name)

    /// The one origin that is not an import: the library's home market, and the default
    /// for a new release.
    static let domestic = "United States"

    private static let byName: [String: ReleaseOrigin] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    /// True for a release from anywhere but `domestic`. An EMPTY origin is the unset
    /// state, not a foreign one, and says nothing either way — every consumer of this
    /// question had written that clause out by hand, identically.
    static func isImport(_ name: String) -> Bool {
        !name.isEmpty && name != domestic
    }

    /// The adjective for a stored name. An unknown name comes back unchanged, so a
    /// restored record with a country not in the list degrades to "Norway import" rather
    /// than to nothing.
    static func demonym(for name: String) -> String {
        byName[name]?.demonym ?? name
    }

    /// The compact form for the sidebar: the short form where one is defined, else the
    /// demonym, else the unknown name unchanged.
    static func shortForm(for name: String) -> String {
        guard let row = byName[name] else { return name }
        return row.shortForm ?? row.demonym
    }
}

// MARK: - Blu-ray Region Compatibility
/// Which Blu-ray region codes a country of origin permits, and the resolution that follows
/// when an origin changes underneath a stored region.
///
/// The single statement of the rule. It previously lived entirely inside `_CountryRow`,
/// which was the right place while the only consumer was the card's own region picker — but
/// a combo-pack child's `nationalOrigin` is pushed down by `syncComboChildFields` rather
/// than chosen on the child's card, and the card's cascade is (correctly) suppressed for
/// children, so nothing applied the rule on that path at all. Lifting it here lets
/// `syncComboChild` apply the identical resolution at the data layer, which is where a
/// parent-driven origin change actually lands.
///
/// Blu-ray only. 4K is region free by definition and DVD's region vocabulary is fixed and
/// does not vary with origin, so neither format has a compatibility question to ask.
enum ReleaseRegionRules {
    /// Countries whose releases are Region A. Every other origin is treated as Region B;
    /// an EMPTY origin is the unset state and constrains nothing, so both flags are false
    /// and every region stays on offer.
    ///
    /// Derived from `ReleaseOrigin.all` rather than listed again here.
    static let regionAOnlyOrigins: Set<String> =
        Set(ReleaseOrigin.all.filter(\.isRegionA).map(\.name))

    // MARK: The tag vocabulary
    //
    // Extended from the compatibility rule's own needs to the full stored set, because the
    // tags were being respelled at every surface that touched them: the card's two region
    // pickers, the sidebar's region-indicator resolver, the search token mapper, and the
    // new-release defaults. `regionBTags` in particular was defined here AND respelled as
    // a two-element literal in both the card's option builder and the search mapper.

    /// No region coding, or coding that imposes no restriction. Legal on every format —
    /// the Blu-ray picker offers it unconditionally regardless of national origin, which
    /// is what lets `newReleaseDefaults` pre-fill it without the origin cascade ever
    /// clearing it — and it is the implied value for 4K UHD, which has no region coding
    /// at all.
    static let regionFree = "Region Free"

    /// The Blu-ray/4K lettered regions.
    static let regionA = "Region A"
    static let regionB = "Region B"

    /// The tag that sets `regionLockBypass`. A Region B disc with a known bypass, so it
    /// counts as Region B for compatibility but as playable for the sidebar's indicator.
    static let looselyLockedTag = "Region B (Loosely-locked)"

    /// The Region B tags, including the loosely-locked variant that also drives
    /// `regionLockBypass`.
    static let regionBTags: Set<String> = [regionB, looselyLockedTag]

    /// The DVD region numbers this app's pickers offer. DVD numbers its regions where
    /// Blu-ray letters them, and the range stops at 5 rather than the nominal 8 because
    /// 6–8 (China, aircraft, and the unused reserve) are outside this library's scope.
    static let dvdRegionNumbers = 1...5

    /// The prefix a numbered region tag is built from. The trailing space is part of the
    /// shape, exactly as with `FilmDigitalSource.remasteredPrefix` — `dvdRegionTag`
    /// composes with it and `regionNumber(in:)` strips it, so the two cannot disagree
    /// about spacing the way three hand-typed copies did.
    static let numberedRegionPrefix = "Region "

    /// The DVD region tag for a number, e.g. `"Region 1"`. The single place the tag's
    /// shape is defined, so the picker that offers them and the search mapper that parses
    /// them cannot disagree about spacing or capitalization.
    static func dvdRegionTag(_ number: Int) -> String { "\(numberedRegionPrefix)\(number)" }

    /// The region number `value` names, or nil when it is not exactly a numbered region
    /// tag — the read-side inverse of `dvdRegionTag`.
    ///
    /// DELIBERATELY WIDER THAN `dvdRegionNumbers`: this reads stored data, which can
    /// predate the picker or arrive from a backup, so it accepts the full nominal 1…8 even
    /// though the picker only ever offers 1…5. Narrowing it to the picker's range would
    /// make a legitimately stored Region 6 disc render as an unparsed raw string.
    static func regionNumber(in value: String) -> Int? {
        guard value.hasPrefix(numberedRegionPrefix) else { return nil }
        let suffix = value.dropFirst(numberedRegionPrefix.count)
        guard suffix.count == 1, let digit = Int(suffix), (1...8).contains(digit) else { return nil }
        return digit
    }

    /// The Blu-ray tags permitted under a given origin scope, in menu order. `regionFree`
    /// is always first and always present.
    static func bluRayTags(regionAOnly: Bool, regionBOnly: Bool) -> [String] {
        var tags = [regionFree]
        if !regionBOnly { tags.append(regionA) }
        if !regionAOnly { tags += [regionB, looselyLockedTag] }
        return tags
    }

    /// The DVD picker's option list, in menu order.
    static let dvdTags: [String] = [regionFree] + dvdRegionNumbers.map(dvdRegionTag)

    /// Whether `origin` restricts the release to one region.
    static func scope(for origin: String) -> (aOnly: Bool, bOnly: Bool) {
        guard !origin.isEmpty else { return (false, false) }
        let aOnly = regionAOnlyOrigins.contains(origin)
        return (aOnly, !aOnly)
    }

    /// True when `regionLock` cannot coexist with `origin` and must be cleared.
    ///
    /// A value outside the Blu-ray vocabulary entirely (a DVD region string from a legacy
    /// backup) is NOT incompatible: the rule has nothing to say about it, and clearing it
    /// would discard a stored value this build cannot interpret rather than preserving it
    /// for the user to correct — the same data-preservation rule the pickers' tag-set
    /// guarantees follow.
    static func isIncompatible(regionLock: String, origin: String) -> Bool {
        let (aOnly, bOnly) = scope(for: origin)
        if aOnly { return regionBTags.contains(regionLock) }
        if bOnly { return regionLock == regionA }
        return false
    }
}

// MARK: - Format Vocabulary
/// The stored vocabulary for `Release.format`, plus the per-format rules that were
/// previously restated as a `switch` at every site that needed one.
///
/// UNKNOWN VALUES ROUND-TRIP, exactly as they do for `ReleaseIndependence`. `format` is
/// persisted verbatim, exported to XML backups, and read back by `SafeValueParser`, so a
/// value this build does not recognize must survive a load/save cycle untouched. That is
/// why the model keeps storing a plain `String` and every lookup here is expressed as a
/// static function over one: `ReleaseFormat(rawValue:)` returning nil is a normal,
/// expected outcome with a defined fallback, not an error.
///
/// Declaration order is the carousel's display order. `FSTabReleasesView` derives both its
/// segmented picker and its Option-arrow cycling order from `allCases`, so a fourth format
/// would appear in both by adding one case here.
enum ReleaseFormat: String, CaseIterable, Sendable {
    case uhd4K  = "4K UHD"
    case bluRay = "Blu-ray"
    case dvd    = "DVD"

    // MARK: Release-year floor

    /// The earliest year a release of this format could physically exist.
    var yearFloor: Int {
        switch self {
        case .uhd4K:  return 2016
        case .bluRay: return 2006
        case .dvd:    return 1997
        }
    }

    /// The floor for a stored format string. An unrecognized format falls back to the DVD
    /// floor — the earliest of the three, and therefore the least restrictive choice,
    /// which preserves the behavior of the `default:` arm this replaced.
    static func yearFloor(for format: String) -> Int {
        ReleaseFormat(rawValue: format)?.yearFloor ?? ReleaseFormat.dvd.yearFloor
    }

    // MARK: Display order

    /// Rank within the canonical format ordering — 4K UHD, then Blu-ray, then DVD.
    ///
    /// Every list that shows more than one format sorts by this: the FilmSheet carousel,
    /// the right sidebar's release cards, and the sidebar's releases table.
    ///
    /// MARK: This switch MUST match the declaration order above
    ///
    /// It used to read `allCases.firstIndex(of: self)`, which derived the order from the
    /// declaration rather than restating it — strictly better as documentation, but it put
    /// two array allocations and a linear search behind what reads as a stored constant.
    /// `allCases` is synthesized to BUILD its array on each access, so both the index
    /// lookup and the `??` fallback allocated, and the string-keyed
    /// `displayRank(for:)` below added a `RawRepresentable` init on top.
    ///
    /// That cost lands in a sort comparator, evaluated twice per comparison:
    /// `FSTabReleases.unifiedReleaseOrder` (run from `releases.didSet`, so on every add,
    /// delete, and combo-pack reconciliation) and `releaseSortKeysPrecede` in RSBHelpers.
    /// At the ten-release cap that is tens of allocations rather than thousands — this is
    /// not a frame-time fix — but a comparator is the wrong place to allocate at all, and
    /// the switch costs nothing.
    ///
    /// The trade is real and is the only thing given up: adding or reordering a case above
    /// now requires editing this switch too. The compiler enforces the first half of that
    /// (a new case makes this switch non-exhaustive and the build fails); it cannot enforce
    /// the second, so a REORDER is the edit to be careful about.
    var displayRank: Int {
        switch self {
        case .uhd4K:  return 0
        case .bluRay: return 1
        case .dvd:    return 2
        }
    }

    /// One past the last known rank — the position an unrecognized format sorts at.
    ///
    /// A `static let` rather than an inline `allCases.count`: this is the fallback arm of
    /// `displayRank(for:)`, which sits inside the same sort comparators as `displayRank`
    /// itself, and `allCases` allocates its array on every access. Computed once, on first
    /// use, and still derived from the case list rather than written as a literal.
    static let unknownRank: Int = ReleaseFormat.allCases.count

    /// The rank for a stored format string. An unrecognized format sorts *after* every
    /// known one rather than colliding with DVD's rank — a film restored from a backup
    /// written by a future build can carry a format string this one knows nothing about,
    /// and grouping it with DVDs would be a claim this build cannot support.
    static func displayRank(for format: String) -> Int {
        ReleaseFormat(rawValue: format)?.displayRank ?? unknownRank
    }

    // MARK: Abbreviated badge

    /// The short form shown in fixed-width badges — the releases table's format column and
    /// the wishlist report's PDF export, whose Format column is 9% of the page width.
    /// The wishlist report's on-screen rows deliberately do NOT use this: they print the
    /// stored format verbatim to match the release cards. See `WishlistRelease.formatBadge`.
    var badge: String {
        switch self {
        case .uhd4K:  return "4K"
        case .bluRay: return "BD"
        case .dvd:    return "DVD"
        }
    }

    /// The badge for a stored format string. An unrecognized format is shown verbatim:
    /// there is no abbreviation to apply, and the stored value is the only truthful
    /// thing the badge can say about it.
    static func badge(for format: String) -> String {
        ReleaseFormat(rawValue: format)?.badge ?? format
    }

    // MARK: New-release defaults

    /// The field values a freshly created release of a given format starts with.
    ///
    /// Every string field defaults to the empty string, which is also
    /// `ReleaseCardModel`'s own init value for each of them — so a format that does not
    /// pre-fill a field leaves it exactly as the model built it, and `apply(to:)` can
    /// write the full set unconditionally without needing to know which fields a given
    /// format cares about. `hasSubtitles` follows the same rule with `false` as its
    /// neutral value.
    ///
    /// `independence` is the one field whose default is not format-dependent: every new
    /// release starts as a standalone one, and a pack is something the user then types it
    /// into. It is declared with that value rather than "" so no per-format initializer
    /// has to restate it, and so the unrecognized-format fallback below inherits it too.
    struct NewReleaseDefaults: Sendable {
        var nationalOrigin:  String = ""
        var videoFormat:     String = ""
        var audioFormat:     String = ""
        var scanningMethod:  String = ""
        var regionLock:      String = ""
        var masterType:      String = ""
        var hasSubtitles:    Bool   = false
        var independence:    String = ReleaseIndependence.standalone
        /// "Theatrical" for every format: the cut a release is assumed to carry.
        var includedVersions: [String] = [ViewingVersion.theatrical.displayName]
    }

    var newReleaseDefaults: NewReleaseDefaults {
        switch self {
        // Subtitles are all but universal on the two HD formats, so they start selected
        // and the user unticks the rare disc that lacks them. DVD is left unticked: the
        // format spans far enough back, and enough bare catalog reissues, that a
        // pre-selected trait there would assert something about the disc more often than
        // it saved a click.
        case .uhd4K:
            return NewReleaseDefaults(nationalOrigin: ReleaseOrigin.domestic,
                                      videoFormat:    ReleaseVideoFormat.hevc,
                                      regionLock:     ReleaseRegionRules.regionFree,
                                      masterType:     ReleaseMasterType.nativeFourK,
                                      hasSubtitles:   true)
        case .bluRay:
            return NewReleaseDefaults(nationalOrigin: ReleaseOrigin.domestic,
                                      videoFormat:    ReleaseVideoFormat.avc,
                                      audioFormat:    "DTS-HD MA",
                                      scanningMethod: ReleaseScanningMethod.progressive,
                                      // The overwhelmingly common case for the format,
                                      // and always a legal tag on the Blu-ray region
                                      // picker regardless of national origin — see
                                      // _CountryRow.bluRayRegionOptions, which offers
                                      // "Region Free" unconditionally, so this default
                                      // can never be cleared by the origin cascade.
                                      regionLock:     ReleaseRegionRules.regionFree,
                                      hasSubtitles:   true)
        case .dvd:
            return NewReleaseDefaults(nationalOrigin: ReleaseOrigin.domestic,
                                      videoFormat:    ReleaseVideoFormat.mpeg2,
                                      audioFormat:    "Dolby Digital",
                                      scanningMethod: ReleaseScanningMethod.interlaced,
                                      // Matches the default national origin. The DVD
                                      // region picker's tag set is fixed (it does not
                                      // vary with origin), so this is always valid.
                                      regionLock:     ReleaseRegionRules.dvdRegionTag(1))
        }
    }

    /// Defaults for a stored format string. An unrecognized format gets the national
    /// origin and the universal `independence` default alone, matching the `default:` arm
    /// this replaced — there is no technical vocabulary to apply for a format this build
    /// knows nothing about.
    static func newReleaseDefaults(for format: String) -> NewReleaseDefaults {
        ReleaseFormat(rawValue: format)?.newReleaseDefaults
            ?? NewReleaseDefaults(nationalOrigin: ReleaseOrigin.domestic)
    }
}

// MARK: - Release Display Labels
/// The card's label, e.g. "Release 2", beside its format badge. Single source of truth for
/// a string several sites previously built by interpolation, so changing the wording (the
/// "#" that used to precede the number, say) is one edit here.
///
/// The number is the card's 1-based position within its own format's carousel, which is
/// what the header displays; callers derive it from `FSTabReleases.displayNumbers` (or from
/// the equivalently sorted list `comboChildren(of:)` produces) rather than from
/// `sortOrder` directly.
enum ReleaseLabel {
    static func short(number: Int) -> String {
        "Release \(number)"
    }
}

// MARK: - Release Model Object Definition
@Model
final class Release {
    // Primary stable id for the release.
    var id: UUID

    // MARK: - Basic Information
    var studio: String
    var releaseYear: String
    var baseReleaseYear: String
    var purchased: Bool
    /// Wishlist position (0 = not on wishlist, ≥1 = wishlist display order).
    /// Stored as `Int` rather than `Bool` so the display ordering is persisted in-model
    /// and survives the backup/restore cycle without any separate order storage.
    var wishlist: Int
    var format: String // Values: "4K UHD", "Blu-ray", "DVD"
    var includedVersions: [String]
    // Values: "Standalone", "Combo-pack", "Combo-pack (dual BD)", "Multi-pack".
    // See ReleaseIndependence for the vocabulary and the child-count rules derived
    // from it. "Combo-pack (dual BD)" only ever appears on a 4K UHD parent.
    var independence: String

    // MARK: - Technical Details
    //
    // Every String field below holds an OPEN vocabulary — see the enum named beside it for
    // the tags, the rules, and the reason none of them is a closed Swift type. Write and
    // compare through those enums; never spell a tag out at a call site.
    var videoFormat: String // Blu-ray and DVD-only. See ReleaseVideoFormat.
    var releaseAspectRatio: [String]
    var scanningMethod: String // Blu-ray only. See ReleaseScanningMethod.
    var audioFormat: String // See ReleaseAudioFormat.
    var audioChannels: String // See ReleaseAudioChannels.
    var hasSubtitles: Bool
    var numberOfDiscs: Int
    var discMultiPack: Bool
    var hasArtwork: String // See ReleaseArtwork.
    var remastered: Bool
    var nationalOrigin: String
    var replicationType: String // See ReleaseReplicationType.
    var discCapacity: [String]

    // MARK: - Format-Specific Items
    var hasHDR: String // 4K-only. See ReleaseHDR.
    var masterType: String // 4K-only. See ReleaseMasterType.
    var regionLock: String // Blu-ray and DVD-only. See ReleaseRegionRules.
    /// Mirrors `regionLock == ReleaseRegionRules.looselyLockedTag`; written by the card's
    /// region cascade. Blu-ray only.
    var regionLockBypass: Bool

    // MARK: - Purchase Information
    var marketAvailability: [String] // See ReleaseMarketAvailability.
    var numberOfCopies: Int
    var cost: Double
    var amountSpent: Double
    var purchaseDate: String
    var lowestPrice: Double
    var lowestPriceDate: String
    var condition: String // See ReleaseCondition.

    // MARK: - Additional Notes
    var notes: String

    // MARK: - Metadata
    var dateAdded: Date
    var sortOrder: Int

    // MARK: - Relationship to Film
    var film: Film?

    // MARK: - Release Hierarchy
    // A release may optionally be a "child" of another release belonging to the same film.
    // Only one level of depth is supported: a parent release can have children, but a
    // child release cannot itself have children. This constraint is enforced by
    // DataCoordinator at the business-logic layer, not in the schema itself.
    //
    // SwiftData requires both sides of a self-referential relationship to be declared.
    // The inverse linkage is handled via the explicit @Relationship annotations below.
    //
    // Delete rule: .nullify — deleting a parent release clears the parentRelease pointer
    // on its children, making them independent top-level releases rather than cascading
    // deletion through to them. This is the safe default that preserves child release data.
    @Relationship(deleteRule: .nullify, inverse: \Release.childReleases)
    var parentRelease: Release?

    @Relationship(deleteRule: .nullify)
    var childReleases: [Release] = []

    // MARK: - Initialization
    init(
        id: UUID = UUID(),
        studio: String = "",
        releaseYear: String = "",
        baseReleaseYear: String = "",
        purchased: Bool = false,
        wishlist: Int = 0,
        format: String = "",
        includedVersions: [String] = [],
        independence: String,
        videoFormat: String = "",
        releaseAspectRatio: [String] = [],
        scanningMethod: String = "",
        audioFormat: String = "",
        audioChannels: String = "",
        hasSubtitles: Bool = false,
        numberOfDiscs: Int = 1,
        discMultiPack: Bool = false,
        hasArtwork: String = "",
        remastered: Bool = false,
        nationalOrigin: String = "",
        replicationType: String = "",
        discCapacity: [String] = [],
        hasHDR: String = "",
        masterType: String = "",
        regionLock: String = "",
        regionLockBypass: Bool = false,
        marketAvailability: [String] = [],
        numberOfCopies: Int = 1,
        cost: Double = 0.0,
        amountSpent: Double = 0.0,
        purchaseDate: String = "",
        lowestPrice: Double = 0.0,
        lowestPriceDate: String = "",
        condition: String = "",
        notes: String = "",
        dateAdded: Date = Date(),
        sortOrder: Int = 0,
        film: Film? = nil,
        parentRelease: Release? = nil) {
        self.id = id
        self.studio = studio
        self.releaseYear = releaseYear
        self.baseReleaseYear = baseReleaseYear
        self.purchased = purchased
        self.wishlist = wishlist
        self.format = format
        self.includedVersions = includedVersions
        self.independence = independence
        self.videoFormat = videoFormat
        self.releaseAspectRatio = releaseAspectRatio
        self.scanningMethod = scanningMethod
        self.audioFormat = audioFormat
        self.audioChannels = audioChannels
        self.hasSubtitles = hasSubtitles
        self.numberOfDiscs = numberOfDiscs
        self.discMultiPack = discMultiPack
        self.hasArtwork = hasArtwork
        self.remastered = remastered
        self.nationalOrigin = nationalOrigin
        self.replicationType = replicationType
        self.discCapacity = discCapacity
        self.hasHDR = hasHDR
        self.masterType = masterType
        self.regionLock = regionLock
        self.regionLockBypass = regionLockBypass
        self.marketAvailability = marketAvailability
        self.numberOfCopies = numberOfCopies
        self.cost = cost
        self.amountSpent = amountSpent
        self.purchaseDate = purchaseDate
        self.lowestPrice = lowestPrice
        self.lowestPriceDate = lowestPriceDate
        self.condition = condition
        self.notes = notes
        self.dateAdded = dateAdded
        self.sortOrder = sortOrder
        self.film = film
        self.parentRelease = parentRelease }
}

// MARK: - ExportableModel Conformance
extension Release: ExportableModel {
    static var entityName: String { "Release" }

    static func fetchAll(in context: ModelContext) async throws -> [Release] {
        let desc = FetchDescriptor<Release>(sortBy: [SortDescriptor(\.dateAdded)])
        return try context.fetch(desc) }

    func extractExportValues() -> (properties: [String: Any], relationships: [String: [Any]]) {
        var props: [String: Any] = [:]
        props["id"] = self.id
        props["studio"] = self.studio
        props["releaseYear"] = self.releaseYear
        props["baseReleaseYear"] = self.baseReleaseYear
        props["purchased"] = self.purchased
        props["wishlist"] = self.wishlist
        props["format"] = self.format
        props["includedVersions"] = self.includedVersions
        props["independence"] = self.independence
        props["videoFormat"] = self.videoFormat
        props["releaseAspectRatio"] = self.releaseAspectRatio
        props["scanningMethod"] = self.scanningMethod
        props["audioFormat"] = self.audioFormat
        props["audioChannels"] = self.audioChannels
        props["hasSubtitles"] = self.hasSubtitles
        props["numberOfDiscs"] = self.numberOfDiscs
        props["discMultiPack"] = self.discMultiPack
        props["hasArtwork"] = self.hasArtwork
        props["remastered"] = self.remastered
        props["nationalOrigin"] = self.nationalOrigin
        props["replicationType"] = self.replicationType
        props["discCapacity"] = self.discCapacity
        props["hasHDR"] = self.hasHDR
        props["masterType"] = self.masterType
        props["regionLock"] = self.regionLock
        props["regionLockBypass"] = self.regionLockBypass
        props["marketAvailability"] = self.marketAvailability
        props["numberOfCopies"] = self.numberOfCopies
        props["cost"] = self.cost
        props["amountSpent"] = self.amountSpent
        props["purchaseDate"] = self.purchaseDate
        props["lowestPrice"] = self.lowestPrice
        props["lowestPriceDate"] = self.lowestPriceDate
        props["condition"] = self.condition
        props["notes"] = self.notes
        props["dateAdded"] = self.dateAdded
        props["sortOrder"] = self.sortOrder

        // Export the related film ID for reconstruction during import.
        props["filmID"] = self.film?.id
        // Export the parent release ID ONLY when a parent exists. Omitting the key for a
        // top-level (parentless) release is the correct representation: the restorer's
        // hierarchy pass treats an absent parentReleaseID as "top-level" — identical to how
        // it handles legacy backups that predate this field — and emits no warning.
        //
        // The previous `self.parentRelease?.id as Any` form boxed Optional<UUID>.none for
        // every parentless release. The export pipeline (DBReader) has no NSNull/optional
        // case for that boxed value, so it fell through to its String(describing:) fallback
        // and serialized the literal text "nil". On restore, parseOptionalUUID then logged
        // that "nil" as a malformed UUID for every top-level release — i.e. the vast
        // majority — polluting both the backup file and the restore log. Guarding with
        // `if let` writes a clean UUID when a parent is present and nothing when it is not.
        //
        // childReleases are not exported here — they are reconstructed during restore by
        // linking each child's parentReleaseID back to its parent.
        if let parentReleaseID = self.parentRelease?.id {
            props["parentReleaseID"] = parentReleaseID
        }
        // No relationship arrays needed - film and parentRelease are referenced by ID.
        let rels: [String: [Any]] = [:]
        return (properties: props, relationships: rels) }

    func exportStableID() -> String? { return self.id.uuidString }
}
