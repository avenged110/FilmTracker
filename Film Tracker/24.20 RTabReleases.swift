// MARK: - RTabReleases.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The right sidebar's card-based "Releases" tab (RightSidebarTab.releases), occupying
// the sidebar's second tab slot. Its one sub-module is the optional summary table in
// ReleasesTable.swift, prepended above the cards when the preference is on.
//
// Each disc-based release is drawn as a card on the sidebar's standard
// `controlBackgroundColor` plate. A combo-pack parent and its auto-created Blu-ray
// children share one taller plate, separated by full-bleed dividers, so a bundled
// product reads as the single physical acquisition it is.
//
// Everything this tab and its summary table must agree on — the region lock's mark and
// coloring, the composed video line, and the grouping and ordering of the release set —
// is defined once in RSBHelpers' "Releases Tab: Shared Derivations" section and used from
// both. Nothing in that list should be reimplemented here; what stays local to this file
// is the cards' own chrome and layout, which the table has no counterpart for.

import SwiftUI
import AppKit

// MARK: - Releases Tab

struct RTabReleases: View {
    @Environment(\.sidebarFilm) private var film: FilmSnapshot?

    /// Expansion state for the optional summary table. Threaded down from RightSidebar,
    /// which substitutes `.constant(true)` when the auto-expand preference is on.
    var releasesSummaryExpanded: Binding<Bool>

    /// When false, RSBReleasesSection is never constructed — no cached-release array,
    /// no table-data build, no `onChange` subscription — so the tab pays nothing for a
    /// table the user has turned off. @AppStorage makes the toggle take effect live.
    @AppStorage(preference: Preferences.showReleasesSummaryTableKey)
        private var showReleasesSummaryTable: Bool

    /// The card groups, derived from the film's releases.
    ///
    /// Building them requires a sort plus a per-release mapping pass, which is why they
    /// were previously cached in `@State` and rebuilt from `onChange(of: film?.releases)`.
    /// Measured, that build costs about 2 ms — while the second render pass the `@State`
    /// write forced costs considerably more, because a new film drew the whole card stack
    /// once with the previous film's groups and then again with the new ones. Deriving is
    /// both faster and removes any window in which the two could disagree.
    ///
    /// Read exactly once per render, into a local at the top of `body`. That matters
    /// here: this value is consumed twice (an empty check and the `ForEach`), and as a
    /// derived property each read would otherwise repeat the whole sort-and-map.
    private var releaseCardGroups: [RSBReleaseCardGroup] {
        RSBReleaseCardBuilder.buildGroups(from: film?.releases ?? [])
    }

    var body: some View {
        // Resolved once and passed down; see `releaseCardGroups`.
        let groups = releaseCardGroups

        return SidebarScrollView {
            // Spacing matches the horizontal and bottom insets below, so the gaps between
            // cards and the gaps to those three edges are one measure. The top inset is
            // deliberately tighter: the content sits directly beneath the tab header,
            // which already supplies visual separation of its own.
            VStack(alignment: .leading, spacing: RSBCardChrome.sidebarInset) {
                if groups.isEmpty {
                    emptyState
                } else {
                    // `spacing: 0` because everything above the cards sets its own gaps
                    // explicitly (see below) rather than inheriting the outer stack's
                    // card spacing, which is far wider than the Details tab's module
                    // metrics this header is meant to match. With the summary table off
                    // this collapses to nothing but the card stack, so the cards sit at
                    // the top of the scroll view exactly as they did before.
                    VStack(alignment: .leading, spacing: 0) {
                        // Scrolls with the cards because it is a sibling inside the same
                        // scrolled VStack. Gated on a non-empty group set so the section's
                        // own "No Releases Added" placeholder can never duplicate the tab's.
                        if showReleasesSummaryTable {
                            RSBReleasesSection(releasesExpanded: releasesSummaryExpanded,
                                               mode: .releaseCard)
                                // 12 = RTabDetails' module stack spacing (4) plus
                                // RSBHelpers.sectionDivider's vertical padding (8). The
                                // gaps are spelled out here instead of reusing
                                // `sectionDivider` because that helper's padding assumes
                                // the Details stack's 4pt spacing on either side of it,
                                // which this stack (spacing 0) does not supply.
                                .padding(.bottom, 12)
                            Divider()
                            allReleasesHeader
                                .padding(.top, 12)
                                // Matches RSBHelpers.headerRowSpacing-scale gap the
                                // Details modules put between their title and content
                                // (e.g. CalendarTable's VStack(spacing: 6)).
                                .padding(.bottom, 6)
                        }
                        // Nested so the cards keep their own inter-card spacing
                        // independent of the header block's tighter metrics.
                        VStack(alignment: .leading, spacing: RSBCardChrome.sidebarInset) {
                            ForEach(groups) { group in
                                RSBReleaseCardGroupView(group: group)
                            }
                        }
                    }
                    // Preserves the full-width proposal the cards previously received
                    // directly from the outer stack, now that they sit one level deeper.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, RSBCardChrome.sidebarInset)
            .padding(.top, 8)
            .padding(.bottom, RSBCardChrome.sidebarInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // No refresh handler: the groups are derived, so they are correct on the first
        // frame and on every subsequent one. FilmSnapshot is a value type and
        // RightSidebar refreshes the environment snapshot on both .updated and
        // .releaseChanged before children observe the change, so no AppEventBus
        // subscription is needed here either.
    }

    /// Titles the card stack when the summary table sits above it, so the two blocks
    /// read as separate modules rather than one run-on list. Drawn with the same shared
    /// builder as every other module title in the sidebar, which is what the note this
    /// replaces asked for by naming the four files to keep it in step with.
    private var allReleasesHeader: some View {
        RSBHelpers.moduleHeader("All Releases")
    }

    private var emptyState: some View {
        Text("No Releases Added")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
    }
}

// MARK: - Card Models

/// One release, pre-resolved for display. Every derived string here mirrors the
/// corresponding column in `DiscReleasesTable.buildTableData` so the two presentations
/// cannot drift apart in what they report.
private struct RSBReleaseCard: Identifiable, Equatable {
    let id: UUID

    // Header
    let format: String            // Full format name, as shown on the FilmSheet badge
    let studio: String
    let purchased: Bool

    // Badge row
    let regionIndicator: RSBRegionIndicator?

    /// The stored region lock spelled out, for the indicator's tooltip. Empty when none is
    /// recorded.
    let regionLabel: String

    /// Whether the release carries subtitles. Surfaced as a glyph that appears only when
    /// true — its absence is the negative case, so no crossed-out state is drawn.
    let hasSubtitles: Bool

    /// A short phrase describing the artwork *when there is something to say about it*.
    /// Empty for the ordinary case of a release whose artwork is present and correct,
    /// which is the assumed default and so goes unstated.
    let artworkNote: String

    // Specification fields
    let releaseYear: String
    let originalReleaseYear: String
    /// Codec and master type.
    let video: String

    /// Whether the release is a remaster. Surfaced as a line that appears only when true —
    /// its absence is the negative case, so no "not remastered" state is drawn. This is
    /// what retires the table's Rem. column suppression rule, which existed only to keep a
    /// column of red crosses from implying data that had not been entered yet.
    let remastered: Bool
    let hdr: String               // Empty for Blu-ray/DVD (the table's "N/A")
    let aspectRatio: String

    /// How many aspect ratios `aspectRatio` was joined from.
    ///
    /// Kept alongside the joined string rather than recovered from it by counting
    /// separators: an individual stored ratio is free to contain a comma, and a
    /// count derived from the display string would then be wrong in exactly the
    /// case — a long list — where it is being consulted. Read only by
    /// `aspectRatioContentHelp`, which uses it to decide whether the row is at
    /// risk of truncating.
    let aspectRatioCount: Int

    let audio: String
    let discs: String
    let nationalOrigin: String
    let includedVersions: String

    /// Whether the versions line is drawn at all.
    ///
    /// A release is assumed to contain the theatrical version, so a list that says
    /// only that says nothing and the line is suppressed. Anything else — an
    /// extended cut alone, a theatrical-plus-director's-cut pairing — is a
    /// departure from the assumption and is stated.
    ///
    /// Decided per *card group* rather than per release, which is why it is stored
    /// here rather than derived in the view from `includedVersions` alone. A
    /// combo-pack's halves are read against each other: if either names something
    /// beyond theatrical, both halves keep their line, so the reader can see what
    /// the other disc carries instead of being left to infer it from one half's
    /// silence. See `showsIncludedVersions(in:)`.
    let showsIncludedVersions: Bool

    // Acquisition (suppressed entirely for combo-pack children)
    /// Cost and amount spent as one phrase — "$29.99, $24.99 spent" — since a currency
    /// amount needs no label and the pair reads naturally on a single line. Empty for an
    /// unpurchased release, which has neither, and for a purchased one whose cost was
    /// never entered — see the "cost of exactly 0" note where this is built.
    let spendLine: String

    /// Condition and purchase date as one sentence — "Purchased used on Jan 3, 2019".
    /// Degrades cleanly when either half is missing, to "Purchased on Jan 3, 2019" or
    /// "Purchased used". Empty for an unpurchased release.
    let purchaseLine: String

    /// Where an unpurchased release can be found, in place of the whole purchase block.
    /// Empty for a purchased release.
    let marketAvailability: String

    /// The lowest price seen and when, as one phrase. Degrades to naming whichever half
    /// exists. Empty for a purchased release, or when neither half has been recorded.
    let lowestPriceLine: String

    /// Whether an unpurchased release sits on the wishlist. False for a purchased one,
    /// where the flag would be stale rather than informative.
    let isWishlisted: Bool

    /// User-authored notes, empty when there are none.
    ///
    /// Notes are the one combo-pack field `syncComboChildFields` does NOT copy down, so a
    /// child's notes are its own. Where the summary table marks an empty child's cell "–"
    /// — a placeholder pointing the reader at the parent row — the card simply draws no
    /// notes line, which says the same thing without spending a row on it.
    let notes: String
}

/// A card's worth of releases: a single standalone release, or a combo-pack parent
/// followed by its attached children on the same plate.
private struct RSBReleaseCardGroup: Identifiable, Equatable {
    /// The primary (parent) release's UUID — stable across recomputes so ForEach can
    /// diff groups rather than treating every rebuild as a full replacement.
    let id: UUID
    let releases: [RSBReleaseCard]
}

// MARK: - Card Builder
// Pure, nonisolated transformation from snapshots to display models. Kept free of any
// view or environment dependency, which is what lets `releaseCardGroups` call it
// directly as a derived value.
private enum RSBReleaseCardBuilder {

    /// Takes the film's whole release array rather than the film: the groups depend on
    /// nothing else about it — see `RTabReleases.releaseCardGroups`.
    static func buildGroups(from releases: [ReleaseSnapshot]) -> [RSBReleaseCardGroup] {
        // Same source set as RSBReleasesSection: the disc formats only. Membership is
        // decided by `ReleaseFormat`, so a format string this build does not recognize is
        // excluded from the cards exactly as it is from the summary table. The by-dateAdded
        // ordering the former `FilmSnapshot.releases4K/2K/SD` accessors produced is not
        // reproduced here because it was never observable: the grouping below is keyed off
        // a dictionary and re-sorted into a total order regardless of input sequence.
        let source = releases.filter { ReleaseFormat(rawValue: $0.format) != nil }
        guard !source.isEmpty else { return [] }

        // Grouping and ordering are `releasesGroupedByHierarchy`'s, shared verbatim with
        // the summary table above these cards — see that function for the keys and for
        // why the ordering has to bottom out in something unique. Sharing it is what
        // guarantees a table row and the card beneath it name the same release; the two
        // used to be textually identical implementations in two files, each documented as
        // needing to mirror the other.
        //
        // Every group is non-empty by construction, so `[0]` is the primary release.
        return releasesGroupedByHierarchy(source).map { members in
            // Decided once for the whole group and handed to every member, so a
            // combo pack's halves agree — see `showsIncludedVersions(in:)`.
            let showsVersions = showsIncludedVersions(in: members)
            return RSBReleaseCardGroup(
                id: members[0].id,
                releases: members.map { model(for: $0, showsIncludedVersions: showsVersions) })
        }
    }

    /// Whether the versions line is drawn for every member of one card group.
    ///
    /// The rule the cards state is "this release contains the theatrical version
    /// unless told otherwise", so the line earns its row only when some member
    /// departs from that: it names a version other than theatrical, or it names
    /// theatrical alongside something else. A release naming theatrical and
    /// nothing else — and one naming nothing at all, which is the same claim made
    /// by omission — contributes nothing.
    ///
    /// Group-wide rather than per release. A combo pack is one physical purchase
    /// whose halves are read as a pair, and suppressing the line on the half that
    /// happens to be theatrical-only, while the other half carries an extended
    /// cut, would leave the reader to work out which disc has which from an
    /// absence. Once either half has something to say, both say what they hold.
    ///
    /// The comparison is trimmed and case-insensitive because the value is stored
    /// as the picker's own tag but has also been written by import; the tag
    /// spelling is `ReleaseCard`'s version vocabulary.
    private static func showsIncludedVersions(in members: [ReleaseSnapshot]) -> Bool {
        members.contains { release in
            release.includedVersions.contains { version in
                let normalized = version
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return !normalized.isEmpty && normalized != "theatrical"
            }
        }
    }

    // MARK: Model Mapping

    private static func model(for release: ReleaseSnapshot,
                              showsIncludedVersions: Bool) -> RSBReleaseCard {
        let is4K = release.format == ReleaseFormat.uhd4K.rawValue

        // Region lock and the composed video line are both shared with the summary table
        // above these cards — see RSBHelpers' shared-derivations section.
        let regionLock = RSBRegionIndicator.displayValue(release.regionLock,
                                                         format: release.format)
        let video = releaseVideoDisplay(for: release)

        // Disc count, phrased as a full noun phrase for its own line, with the
        // recordable-media suffix. Pluralization is on the count itself, so a
        // single-disc release reads "1 disc" rather than "1 discs".
        let discNoun = release.numberOfDiscs == 1 ? "disc" : "discs"
        let discPhrase = "\(release.numberOfDiscs) \(discNoun)"
        let discs = ReleaseReplicationType.isRecordable(release.replicationType)
            ? "\(discPhrase) (BD-R)"
            : discPhrase

        // Acquisition. Combo-pack children omit this block entirely (see isChild), so no
        // placeholder strings are produced for them here.
        let spendLine: String
        let purchaseLine: String
        let marketAvailability: String
        let lowestPriceLine: String
        let isWishlisted: Bool

        if release.purchased {
            // Currency figures are LOCKED, not merely defaulted, for a combo-pack release
            // that is not the 4K master: the FilmSheet disables both fields and its
            // independence cascade zeroes them, because the pack's cost is recorded once
            // on the 4K parent. Reading them back out would report a confident
            // "$0.00, $0.00 spent" for a release that in fact cost whatever the pack did.
            //
            // The predicate is the sheet's own (`ReleaseCard.pricingRow`), not `isChild`.
            // Those coincide for an auto-created child, but a Blu-ray or DVD the user
            // marks "Combo-pack" by hand has no parent wired to it — `handleComboPackChange`
            // only runs for a 4K card — so it carries `parentReleaseID == nil` while its
            // currency fields are locked and zeroed all the same. `isChild` is kept as a
            // disjunct anyway so the invariant is stated rather than left incidental.
            // The summary table already suppresses exactly this case, printing "–".
            //
            // Scope is the spend line alone: purchase date and condition are NOT locked
            // for such a release, so `purchaseLine` below reports real values.
            let currencyLocked = release.isChild
                || (ReleaseIndependence.isComboPack(release.independence)
                    && release.format != ReleaseFormat.uhd4K.rawValue)
            // A cost of exactly 0 means the field was never filled in — SwiftData's
            // Double default, not a user-entered "free" — so the whole line is
            // suppressed rather than printing "$0.00, $0.00 spent", which reads as
            // asserting a price rather than the absence of one. Amount spent alone
            // being blank is a real, statable claim ("bought it but haven't logged
            // what it cost"), so THAT half still prints "$0.00 spent" once a cost
            // exists to pair it with.
            if currencyLocked || release.cost == 0 {
                spendLine = ""
            } else {
                let cost = Fmt.dollars(release.cost)
                let amountSpent = Fmt.dollars(release.amountSpent)
                spendLine = "\(cost), \(amountSpent) spent"
            }

            // Condition reads mid-sentence here rather than as a standalone field, so it
            // is lowercased; a date that was never entered drops the clause entirely
            // rather than filling it with a placeholder.
            let condition = release.condition.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let date = displayDate(release.purchaseDate)
            var line = "Purchased"
            if !condition.isEmpty { line += " \(condition)" }
            if !date.isEmpty { line += " on \(date)" }
            purchaseLine = line

            marketAvailability = ""
            lowestPriceLine = ""
            isWishlisted = false
        } else {
            // Unpurchased releases report market availability in place of the whole
            // purchase block, matching the table's reuse of its Purchase Date column.
            spendLine = ""
            purchaseLine = ""
            // Expanded rather than joined verbatim. The stored vocabulary is abbreviated
            // for the releases table's fixed-width column ("OOP (cheap)"); a card line is
            // prose with room to spare, so it prints the full form the picker offers.
            // See ReleaseMarketAvailability.
            marketAvailability = ReleaseMarketAvailability.displayList(release.marketAvailability)

            // Price and date are independently optional, and each says something on its
            // own: a price with no date is the best figure seen at some unrecorded point,
            // while a date with no price records that the release was seen for sale at all
            // without noting what it went for. Each case gets its own phrasing rather than
            // a single template with a hole in it.
            let price = release.lowestPrice > 0
                ? Fmt.dollars(release.lowestPrice)
                : ""
            let priceDate = displayDate(release.lowestPriceDate)

            switch (price.isEmpty, priceDate.isEmpty) {
            case (false, false): lowestPriceLine = "Lowest price \(price) on \(priceDate)"
            case (true, false):  lowestPriceLine = "Last seen for sale on \(priceDate)"
            case (false, true):  lowestPriceLine = "Lowest price seen is \(price)"
            case (true, true):   lowestPriceLine = ""
            }

            // Wishlist positions are 1-based; 0 means "not on the wishlist".
            isWishlisted = release.wishlist >= 1
        }

        let releaseYear = release.releaseYear.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseYear = release.baseReleaseYear.trimmingCharacters(in: .whitespacesAndNewlines)

        return RSBReleaseCard(
            id: release.id,
            format: release.format,
            studio: release.studio.trimmingCharacters(in: .whitespacesAndNewlines),
            purchased: release.purchased,
            regionIndicator: RSBRegionIndicator.resolve(regionLock, format: release.format),
            regionLabel: regionLock.trimmingCharacters(in: .whitespacesAndNewlines),
            hasSubtitles: release.hasSubtitles,
            artworkNote: artworkNote(for: release.hasArtwork),
            releaseYear: releaseYear,
            // Suppressed when identical to the release year, where it would be noise.
            originalReleaseYear: baseYear == releaseYear ? "" : baseYear,
            video: video,
            remastered: release.remastered,
            // HDR is meaningful only for 4K UHD; the table's "N/A" for the other two
            // formats carries no information on a card, so the field is simply omitted.
            hdr: is4K ? hdrDisplay(for: release.hasHDR) : "",
            aspectRatio: release.releaseAspectRatio.joined(separator: ", "),
            aspectRatioCount: release.releaseAspectRatio.count,
            audio: release.audio,
            discs: discs,
            nationalOrigin: release.nationalOrigin.trimmingCharacters(in: .whitespacesAndNewlines),
            includedVersions: release.includedVersions.joined(separator: ", "),
            showsIncludedVersions: showsIncludedVersions,
            spendLine: spendLine,
            purchaseLine: purchaseLine,
            marketAvailability: marketAvailability,
            lowestPriceLine: lowestPriceLine,
            isWishlisted: isWishlisted,
            notes: release.notes.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A stored date string formatted for display, or "" when there is no usable date.
    ///
    /// Gated on the parse rather than on `isEmpty`, which is the distinction that matters
    /// here. `formatDateString` returns the literal "Unknown date" when parsing fails, and
    /// that string is written for a table cell, where it reads as a placeholder. These
    /// lines are prose, where it reads as a statement — "Purchased used on Unknown date",
    /// or worse "Last seen for sale on Unknown date", a phrasing chosen *because* a date
    /// was thought to exist. Returning "" instead lets each line degrade to the shorter
    /// form it already knows how to build ("Purchased used", "Lowest price seen is $9.99").
    private static func displayDate(_ stored: String) -> String {
        parseDate(from: stored) == nil ? "" : formatDateString(stored)
    }

    /// The HDR picker's "None" tag is an affirmative statement that the release carries no
    /// HDR, not an absent value, so it is phrased as one rather than shown as the bare word
    /// "None" beside a codec. Every other tag is already self-describing and passes through.
    private static func hdrDisplay(for value: String) -> String {
        value == ReleaseHDR.noneTag ? "No HDR" : value
    }

    /// Artwork, phrased as a note rather than an indicator, and only when it departs from
    /// the assumed default. A release whose artwork is present and correct — the picker's
    /// plain "Yes", and the unset "" — returns an empty string and draws no line at all.
    ///
    /// The cases below are the `hasArtwork` picker's tag vocabulary verbatim (see
    /// `ReleaseCard`'s artwork picker): the tags are the stored values, so this switch and
    /// that picker cannot fall out of step over spelling. Anything outside the vocabulary
    /// falls through to the raw stored value rather than being silently swallowed.
    private static func artworkNote(for value: String) -> String {
        switch value {
        // "Yes (Combo-pack)" joins the plain "Yes" in going unstated: on a combo-pack the
        // artwork is a property of the pack, already described by the parent release's own
        // line, so repeating it says nothing new.
        case "", ReleaseArtwork.yes, ReleaseArtwork.yesComboPack: return ""
        case ReleaseArtwork.steelbook:  return "Steelbook"
        case ReleaseArtwork.yesIncorrectRelease: return "Release-mismatched artwork"
        case ReleaseArtwork.yesCustom:  return "Custom artwork"
        case ReleaseArtwork.yesMultiPack: return "Multi-pack artwork"
        // "No (Combo-pack)" and "No (Multi-pack)" are not in the picker's current
        // vocabulary — both pack types offer a plain "No" — but the summary table still
        // recognizes them, so records carrying them exist (legacy data, or a restore from
        // an older backup). Phrasing them here keeps the two presentations saying the same
        // thing about the same release instead of the card falling through to the raw tag.
        case _ where ReleaseArtwork.negativeTags.contains(value):
                                        return "Missing artwork"
        default:                        return value
        }
    }
}

// MARK: - Card Chrome
// Fills, inks, and shadow values shared by the card body and its badges, kept together
// so the header band, the format badge, and the year badge cannot drift apart.
private enum RSBCardChrome {

    /// Format header tints — the same values `ReleaseCardView` bands its FilmSheet cards
    /// with (33_20), restated here rather than reached into that file's private chrome.
    /// Purchase status no longer tints the header at all; it lives entirely in the
    /// trailing glyph now, so these three are keyed on format alone.
    static let tint4K     = Color(red: 0.05, green: 0.05, blue: 0.06)
    static let tintBluRay = Color(red: 0.10, green: 0.22, blue: 0.42)
    static let tintDVD    = Color(white: 0.30)
    /// A format string this build does not recognize: the sidebar's neutral badge gray.
    static let tintUnknown = Preferences.darkGray

    /// Purchase-glyph color for the "purchased" state, matching the summary table's
    /// checkmark badge exactly (see `symbolBadge` in ReleasesTable.swift). The "not
    /// purchased" dashed-circle glyph stays white, as it always has — the band no longer
    /// carries purchase status, but the glyph itself never did either.
    static let checkmarkGreen = Preferences.green

    /// Wash distinguishing an attached child half from its parent. Also serves as the
    /// child's header fill, in place of a purchase tint.
    static let childWash = Color.primary.opacity(0.035)

    /// Format-badge plate and lettering. Both are fixed rather than appearance-adaptive:
    /// the badge must read identically on the parent's dark tinted band and on the child
    /// half's light wash, and the band's color must never show through the glyphs.
    static let badgePlate = Color(white: 0.93)
    static let badgeInk = Color(red: 0.11, green: 0.11, blue: 0.12)
    /// Format badge only. The badge-row pills are fully rounded capsules instead.
    static let badgeCornerRadius: CGFloat = 4

    /// Fill shared by the year badge's compartments and the region/origin pill, and the
    /// stroke for the year badge's connector outline.
    ///
    /// `Preferences.darkGray` is an opaque mix matching how `Color.gray.opacity(0.5)` — the
    /// value the FilmSheet's reorderable list buttons carry — renders over a dark-mode
    /// window background, so the sidebar's badges read as the same family of neutral
    /// chrome. A gray rather than a semantic background color: the semantic layers are
    /// defined relative to the window background and so sit close to the card's own fill,
    /// which would make the badges disappear into it.
    ///
    /// Opacity is what lets one value serve as both fill and outline. The connector outline
    /// is stroked on the badge's own bounds and therefore shares an edge with the release
    /// year's fill; two translucent layers meeting there would composite to roughly double
    /// alpha and read as a darker rim, whereas two opaque layers of one color meeting is
    /// that color.
    static let badgeFill = Preferences.darkGray

    /// Diameter of the region lock's disc. Declared here, alongside the height derived from
    /// it, rather than on `RSBIndicatorView` that draws it: a `View`'s type is `@MainActor`
    /// by inference and so are its statics, while this enum is nonisolated — deriving one
    /// from the other across that boundary is a main-actor-isolated value in a nonisolated
    /// context. Keeping both on the nonisolated side lets the derivation stand and still
    /// leaves one source of truth.
    static let regionBadgeDiameter: CGFloat = 14

    /// Uniform height for everything on the badge row: the region lock's disc plus
    /// breathing room, so the year badge and the region/origin pill sit on a shared
    /// baseline rather than the pill growing alone around a differently-sized badge.
    /// Derived rather than stated, so resizing the disc carries the pills with it.
    static let badgeRowHeight: CGFloat = regionBadgeDiameter + 6

    /// Shared by the purchase glyph and both badges, seating them on the band without
    /// reading as raised controls.
    static let glyphShadowOpacity: Double = 0.6
    static let glyphShadowRadius: CGFloat = 1.5
    static let glyphShadowOffsetY: CGFloat = 0.5

    // MARK: Layout

    /// The right sidebar's standard horizontal inset, shared with RTabDetails.
    /// Also used as the gap between stacked cards so the spacing reads as
    /// uniform on all four sides.
    static let sidebarInset: CGFloat = 16

    /// Inset applied to the card body's content on all sides.
    static let contentPadding: CGFloat = 10

    /// Top inset only, tightened relative to the others. The badge row that opens the
    /// details already carries its own visual weight and sits directly under a filled
    /// header band, so the full content inset read as a gap there.
    static let contentTopPadding: CGFloat = contentPadding - 2

    /// Width reserved for the header's trailing purchase glyph, so its center sits on a
    /// fixed axis rather than drifting with the glyph's intrinsic size.
    static let trailingGlyphWidth: CGFloat = 17

    /// Height reserved for the header's trailing purchase glyph, so the header's own
    /// height stays fixed regardless of which of the two glyphs is showing.
    ///
    /// Without this, the header HStack sizes itself to its tallest child, and the two
    /// glyphs are NOT the same intrinsic height: the "circle.dashed" SF Symbol at 16pt
    /// semibold (its bounding box, not its stated font size) is a couple of points taller
    /// than the 18pt-diameter checkmark badge circle that sits beside it in the purchased
    /// case — so the whole header shrank by that difference whenever a release was
    /// purchased. 20pt matches what "circle.dashed" was already occupying, which is what
    /// silently set the header's height before the checkmark badge existed to disagree
    /// with it.
    static let trailingGlyphHeight: CGFloat = 20

    // MARK: Card Edge Treatment
    // The FilmSheet reorderable lists' strategy — an outline that wraps the top and fades
    // out toward the bottom, with the lower edge carried by a shadow instead — restated
    // here at slightly stronger settings.
    //
    // The gradient's stop structure and the fade start are taken verbatim from
    // `FieldEdgeTreatment`; only the two strengths differ, and they are declared locally
    // rather than by editing that type because it is the shared reference the sheet's
    // text fields and reorderable lists all stroke against. Raising them there to suit
    // the sidebar would silently restyle every one of those controls.

    static let borderWidth: CGFloat = FieldEdgeTreatment.borderWidth
    static let borderOpacity: Double = 0.32
    static let borderFadeStart: Double = FieldEdgeTreatment.borderFadeStart

    /// Border color, fading to nothing over the last stretch of the drop. Vertical rather
    /// than uniform so the lower edge is carried by the shadow.
    static let borderGradient = LinearGradient(
        stops: [
            .init(color: Color(NSColor.separatorColor).opacity(borderOpacity), location: 0.0),
            .init(color: Color(NSColor.separatorColor).opacity(borderOpacity), location: borderFadeStart),
            .init(color: Color(NSColor.separatorColor).opacity(0), location: 1.0)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let shadowOpacity: Double = 0.26
    static let shadowRadius: CGFloat = FieldEdgeTreatment.shadowRadius
    static let shadowOffsetY: CGFloat = FieldEdgeTreatment.shadowOffsetY
}

extension View {
    /// The drop shadow shared by the purchase glyph, the format badge, and the year badge.
    fileprivate func rsbBadgeShadow() -> some View {
        shadow(
            color: .black.opacity(RSBCardChrome.glyphShadowOpacity),
            radius: RSBCardChrome.glyphShadowRadius,
            x: 0,
            y: RSBCardChrome.glyphShadowOffsetY)
    }
}

// MARK: - Card Group View
// One plate per acquisition. A combo-pack parent and its attached child or children
// share the plate, producing the double-height card — or, for a "Combo-pack (dual BD)"
// pack that bundles two distinct Blu-ray copies, a triple-height one. The parent half
// opens with a purchase-tinted band; each child half opens with the same faint wash it
// carries throughout, separated from what precedes it by a divider, since its meaning is
// inherited from the parent it is attached to rather than restated. The stack is built by
// iterating the group, so the number of attached halves follows the data with no ceiling
// baked into the layout.
//
// Edge treatment follows the FilmSheet reorderable lists' — a subtle outline that wraps
// the top and fades out toward the bottom, with the lower edge carried by a shadow
// instead. See `RSBCardChrome` for the strengths and why they are stated locally.
private struct RSBReleaseCardGroupView: View {
    let group: RSBReleaseCardGroup

    static let cornerRadius: CGFloat = 8

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    /// How many halves of this plate are attached children. Index 0 is always the group's
    /// top-level parent — `releasesGroupedByHierarchy` keys on `parentReleaseID ?? id` and
    /// sorts `isTopLevel` first — so this is simply everything after it: one for a
    /// "Combo-pack" pack, two for "Combo-pack (dual BD)", and zero for a standalone
    /// release.
    private var attachedChildCount: Int { max(0, group.releases.count - 1) }

    /// The banner an attached child shows in place of the parent's studio and purchase
    /// status. When a pack bundles two Blu-rays the halves are otherwise identical at a
    /// glance — same format badge, same wash, same inherited fields — so each is numbered
    /// to make plain that they are two discs and not one card drawn twice. A single child
    /// is left unnumbered: "1 of 1" would add a count where there is nothing to count.
    private func childBanner(at index: Int) -> String {
        attachedChildCount > 1
            ? "Included in Combo-pack (\(index) of \(attachedChildCount))"
            : "Included in Combo-pack"
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(group.releases.enumerated()), id: \.element.id) { index, release in
                RSBReleaseCardBody(
                    model: release,
                    attachedChildBanner: index > 0 ? childBanner(at: index) : nil)
                    .background(index > 0 ? RSBCardChrome.childWash : Color.clear)
            }
        }
        .background(shape.fill(Color(NSColor.controlBackgroundColor)))
        // Clips the child wash and the tinted header band to the plate's rounded corners
        // before the outline is stroked over the result, so the band's fill and the
        // outline meet cleanly at the top corners rather than one overrunning the other.
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                RSBCardChrome.borderGradient,
                lineWidth: RSBCardChrome.borderWidth))
        .shadow(
            color: .black.opacity(RSBCardChrome.shadowOpacity),
            radius: RSBCardChrome.shadowRadius,
            x: 0,
            y: RSBCardChrome.shadowOffsetY)
    }
}

// MARK: - Card Body

private struct RSBReleaseCardBody: View {
    let model: RSBReleaseCard

    /// Non-nil when this half is a combo-pack child attached beneath its parent, in which
    /// case it holds the banner text that names the relationship (and, on a dual-BD pack,
    /// which of the two Blu-rays this is). Such a half takes its meaning from the parent
    /// it is attached to, so it drops the purchase tint in favor of the child wash and is
    /// set off by a divider instead.
    ///
    /// Carrying the text rather than a bare Bool keeps the numbering with the view that
    /// can actually see how many siblings there are — the group — instead of forcing this
    /// half to be told its index and its total separately.
    let attachedChildBanner: String?

    /// Whether this half is a combo-pack child drawn beneath its parent — the single
    /// question every suppression on this card actually asks.
    ///
    /// This used to be one of two concepts. The card also carried the release's own
    /// `isChild` flag (`parentReleaseID != nil`) and gated the acquisition block and the
    /// artwork note on that instead. The two can only disagree for an ORPHANED child — one
    /// naming a parent absent from the film's release set — which `releasesGroupedByHierarchy`
    /// puts in a group of its own, so it is drawn at index 0 with no parent above it while
    /// still reporting `isChild == true`. That card suppressed its cost, purchase date and
    /// condition with no parent half anywhere to carry them.
    ///
    /// Orphans are now impossible by construction, so the two are the same value and only
    /// this one survives — see `releasesGroupedByHierarchy`'s "GROUP SHAPE" note for why
    /// index 0 of a group is always the parent, and for the one residual (a parent removed
    /// by the caller's format filter) where they can still differ.
    ///
    /// Keeping the LAYOUT one is what makes that residual safe as well as making the code
    /// say what it means: it states the reason the figures are omitted — they are already
    /// visible directly above — rather than a property that merely correlates with it. A
    /// release drawn with no parent above it therefore shows its own acquisition figures,
    /// which is the correct outcome in every case, including the one this cannot rule out.
    private var isAttachedChild: Bool { attachedChildBanner != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isAttachedChild {
                // Full-bleed: separates this half from the parent's details above.
                Divider()
            }
            header
            details
                .padding(.horizontal, RSBCardChrome.contentPadding)
                .padding(.bottom, RSBCardChrome.contentPadding)
                // A child half opens with the divider that closes its header, and that
                // divider has to sit flush against the header's lower edge for the header
                // to stand the same height as a parent's tinted band. Any top padding here
                // would push it down and make the child header visibly taller.
                .padding(.top, isAttachedChild ? 0 : RSBCardChrome.contentTopPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header
    // Format badge, studio, and purchase status on one horizontal plane, on a full-bleed
    // band. On a parent half the band is tinted by purchase status, and the color change
    // is itself the separation from the details below — no divider is needed. On an
    // attached child the band is left to the child wash showing through from behind, so
    // the two halves read as one card rather than two stacked ones.

    /// White on the dark tinted band. Only ever read on a parent half — a child names its
    /// relationship to the parent instead of carrying a studio — so it needs no untinted
    /// variant.
    private var titleColor: Color {
        model.studio.isEmpty ? Color.white.opacity(0.55) : .white
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.format)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(RSBCardChrome.badgeInk)
                .frame(width: 52, alignment: .center)
                .padding(.vertical, 1)
                .background(RSBCardChrome.badgePlate)
                .clipShape(RoundedRectangle(
                    cornerRadius: RSBCardChrome.badgeCornerRadius, style: .continuous))
                .fixedSize()
                .rsbBadgeShadow()

            if let banner = attachedChildBanner {
                // A child half names its relationship to the parent instead of restating
                // the parent's studio and purchase status. Both are properties of the
                // combo-pack as a whole, already shown on the half directly above, so
                // repeating them here would say nothing the attachment does not.
                Text(banner)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(model.studio.isEmpty ? "Unknown Studio" : model.studio)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // The band is now tinted by FORMAT, matching the FilmSheet's release
                // cards, so purchase status carries entirely in this glyph. A purchased
                // release gets the exact same checkmark badge the summary table draws
                // (see `symbolBadge`, 24_21) at a slightly larger size for the card;
                // an unpurchased one gets the dashed-circle glyph in the same red used
                // there.
                Group {
                    if model.purchased {
                        // The shadow goes on the circular fill alone, via
                        // `circleShadow` — not chained on as `.rsbBadgeShadow()` —
                        // so it cannot also fall across the checkmark glyph's own
                        // shadow (from `IndicatorBadge`'s `inkNeedsShadow`), which
                        // stays exactly what it already was.
                        symbolBadge("checkmark", RSBCardChrome.checkmarkGreen, diameter: 18,
                                    circleShadow: (RSBCardChrome.glyphShadowOpacity,
                                                   RSBCardChrome.glyphShadowRadius,
                                                   RSBCardChrome.glyphShadowOffsetY))
                    } else {
                        Image(systemName: "circle.dashed")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .rsbBadgeShadow()
                    }
                }
                .frame(width: RSBCardChrome.trailingGlyphWidth,
                       height: RSBCardChrome.trailingGlyphHeight, alignment: .center)
                .help(model.purchased ? "Purchased" : "Not purchased")
            }
        }
        .padding(.horizontal, RSBCardChrome.contentPadding)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { bandFill }
    }

    /// Same lookup as `ReleaseCardView.bandTint` (33_20): `model.format` carries the full
    /// format name that mapping is keyed on.
    private var bandTint: Color {
        switch ReleaseFormat(rawValue: model.format) {
        case .uhd4K:  return RSBCardChrome.tint4K
        case .bluRay: return RSBCardChrome.tintBluRay
        case .dvd:    return RSBCardChrome.tintDVD
        case nil:     return RSBCardChrome.tintUnknown
        }
    }

    @ViewBuilder
    private var bandFill: some View {
        if !isAttachedChild {
            bandTint
        } else {
            // The child wash is already applied behind the whole half by the group view;
            // leaving the band clear lets it show through unbroken.
            Color.clear
        }
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The child header's closing divider lives here, at the top of the padded
            // details block, so it picks up the card's content inset the same way the
            // text below it does rather than stating a margin of its own.
            if isAttachedChild {
                Divider()
            }
            if hasBadgeRow {
                // The same two equal flexible columns at the same spacing as every field
                // row below, so the pill — which fills its column — has its left edge on
                // the second column's axis and its right edge at the card's, while the
                // fixed-width year badge sits on the first column's axis.
                HStack(spacing: 10) {
                    // Each column is held open by a zero-height Color.clear underlay rather
                    // than by the badge alone. An absent badge is an EmptyView, which has no
                    // layout footprint at all — `frame(maxWidth:)` on it yields nothing, and
                    // the surviving badge would take the whole row instead of its column.
                    columnSlot {
                        // Shown on a child half too, even though a combo-pack child's
                        // release year is locked to its parent's and so restates it. The
                        // redundancy is the lesser cost: the badge row's leading column is
                        // reserved regardless, so suppressing the badge left a conspicuous
                        // gap beside the region pill rather than tightening anything.
                        if !model.releaseYear.isEmpty {
                            RSBYearBadge(
                                releaseYear: model.releaseYear,
                                baseReleaseYear: model.originalReleaseYear)
                        }
                    }
                    columnSlot {
                        if model.regionIndicator != nil || !model.nationalOrigin.isEmpty {
                            RSBRegionOriginPill(
                                region: model.regionIndicator,
                                regionLabel: model.regionLabel,
                                nationalOrigin: model.nationalOrigin)
                        }
                    }
                }
            }

            // Glyph-led lines sharing a leading glyph column, so their text starts at a
            // common x-origin. Several carry a second line in the trailing column, each
            // appearing only when it has something to say and leaving its partner to span
            // the full width alone.
            //
            // Where the remaster flag lands depends on the format. A 4K release has an HDR
            // value, which takes the video row's trailing slot and pushes the flag down
            // beside the aspect ratio; the other two formats have no HDR, so the flag stays
            // in the video row rather than leaving that slot empty and opening a new line.
            // Both of those rows can themselves be absent, in which case the flag falls
            // through to a line of its own — see `remasteredNeedsOwnRow`.
            if showsVideoRow {
                glyphRow(RSBRowItem(symbol: "tv", text: model.video), trailing: videoRowTrailing)
            }
            if showsAspectRatioRow {
                glyphRow(
                    RSBRowItem(
                        symbol: "aspectratio.fill", text: model.aspectRatio,
                        help: "Aspect ratio"),
                    trailing: aspectRatioRowTrailing,
                    leadingContentHelp: aspectRatioContentHelp)
            }
            if remasteredNeedsOwnRow, let remasteredItem {
                glyphRow(remasteredItem)
            }
            if !model.audio.isEmpty {
                glyphRow(RSBRowItem(symbol: "speaker.wave.2.fill", text: model.audio))
            }
            // The disc line is unconditional: `discs` is built from the disc count and so
            // always carries at least "1 disc". Subtitles ride in the trailing column and
            // are shown only when present — their absence is the negative case, so nothing
            // is drawn rather than a line stating it.
            glyphRow(
                RSBRowItem(symbol: "opticaldisc.fill", text: model.discs),
                trailing: model.hasSubtitles
                    ? RSBRowItem(symbol: "captions.bubble.fill", text: "Includes subtitles")
                    : nil)
            // Combo-pack children inherit the parent's artwork verbatim, so restating it
            // on the child half would only repeat the line directly above.
            if !isAttachedChild && !model.artworkNote.isEmpty {
                glyphRow(RSBRowItem(symbol: "text.book.closed.fill", text: model.artworkNote))
            }
            // Suppressed when the release contains only the theatrical version,
            // which every release is assumed to carry — see
            // `RSBReleaseCard.showsIncludedVersions`. The emptiness test stays as
            // the guard against drawing a glyph beside nothing; the flag is what
            // decides whether a populated list is worth a row.
            if model.showsIncludedVersions && !model.includedVersions.isEmpty {
                glyphRow(RSBRowItem(
                    symbol: "film.stack.fill", text: model.includedVersions,
                    help: "Versions included"))
            }

            // Everything the card says about acquiring the release, below one divider.
            // Suppressed entirely for combo-pack children, whose cost, amount spent, and
            // purchase date are all recorded on the parent 4K release above. A purchased
            // release fills this with what it cost and when; an unpurchased one with where
            // it can be found, what it has been seen going for, and whether it is wanted.
            //
            // Gated on the LAYOUT fact — "a parent half is drawn directly above me" — not on
            // the release's own child flag. The two are now provably the same thing (see
            // `attachedChildBanner`), so this is the one that says what the suppression
            // actually depends on: the figures are omitted because they are visible above,
            // and this is the condition that means exactly that.
            if !isAttachedChild && !acquisitionBlockIsEmpty {
                Divider()
                if !model.spendLine.isEmpty {
                    glyphRow(RSBRowItem(symbol: "cart.fill", text: model.spendLine))
                }
                if !model.purchaseLine.isEmpty {
                    glyphRow(RSBRowItem(symbol: "calendar.badge.clock", text: model.purchaseLine))
                }
                // The wishlist flag rides in the trailing column beside market availability
                // when there is one, and takes the leading column itself when there is not,
                // rather than sitting alone in a second column with an empty first.
                if !model.marketAvailability.isEmpty {
                    glyphRow(
                        RSBRowItem(
                            symbol: "cart.fill.badge.questionmark",
                            text: model.marketAvailability,
                            help: "Market availability"),
                        trailing: wishlistItem)
                } else if let wishlistItem {
                    glyphRow(wishlistItem)
                }
                if !model.lowestPriceLine.isEmpty {
                    glyphRow(RSBRowItem(
                        symbol: "calendar.badge.clock", text: model.lowestPriceLine,
                        help: "Lowest price"))
                }
            }
            // Wrapped lines align under the first line's text rather than under its glyph,
            // because RSBGlyphLine puts the text in its own column beside the glyph.
            if !model.notes.isEmpty {
                glyphRow(RSBRowItem(symbol: "note.text", text: model.notes, help: "Notes"))
            }
        }
    }

    /// A glyph-led line, optionally paired with a second one in the trailing column. The
    /// two columns are equal and flexible at a shared 10pt spacing, matching the badge row
    /// above, so every trailing item on the card — the remaster flag, the subtitles line,
    /// the wishlist flag — starts on one common second-column axis.
    ///
    /// Both halves of a paired row truncate: a wrap on one side would push its partner out
    /// of vertical alignment with the single-line rows above and below it. Unpaired, a line
    /// spans the full width and wraps freely.
    ///
    /// `leadingContentHelp`, when given, puts a tooltip on the leading line's *text*
    /// column — distinct from the glyph's own tooltip, which names the field. It is
    /// meant for a paired row whose leading half is truncating, where the tooltip is
    /// the only way to read what was cut off; callers pass `nil` in every other
    /// case rather than tooltipping text the reader can already see in full.
    @ViewBuilder
    private func glyphRow(_ leading: RSBRowItem,
                          trailing: RSBRowItem? = nil,
                          leadingContentHelp: String? = nil) -> some View {
        if let trailing {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                RSBGlyphLine(item: leading, truncates: true, contentHelp: leadingContentHelp)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RSBGlyphLine(item: trailing, truncates: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            RSBGlyphLine(item: leading)
        }
    }

    /// One column of the badge row: exactly half the available width, occupied or not.
    private func columnSlot<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        ZStack {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 0)
            content()
        }
    }

    private var remasteredItem: RSBRowItem? {
        model.remastered ? RSBRowItem(symbol: "scanner.fill", text: "Remastered") : nil
    }

    private var wishlistItem: RSBRowItem? {
        model.isWishlisted ? RSBRowItem(symbol: "gift.fill", text: "Wishlisted") : nil
    }

    private var showsVideoRow: Bool { !model.video.isEmpty }
    private var showsAspectRatioRow: Bool { !model.aspectRatio.isEmpty }

    /// HDR on a 4K release; otherwise the remaster flag, which has nowhere else to be.
    private var videoRowTrailing: RSBRowItem? {
        model.hdr.isEmpty
            ? remasteredItem
            : RSBRowItem(symbol: "sun.max.fill", text: model.hdr, help: "HDR")
    }

    /// True once the video row above has taken the remaster flag into its trailing slot.
    /// Requires the row to actually be drawn: HDR being empty is what *offers* the slot,
    /// but an empty video string means there is no row to put it in.
    private var videoRowTookRemastered: Bool { showsVideoRow && model.hdr.isEmpty }

    /// The remaster flag, once the video row above has declined or could not take it.
    private var aspectRatioRowTrailing: RSBRowItem? {
        videoRowTookRemastered ? nil : remasteredItem
    }

    /// The full aspect-ratio list as a tooltip on that row's text, for the one
    /// state in which the row cannot show all of it.
    ///
    /// Three conditions, all of which must hold, because each is separately
    /// necessary for the text to actually be cut off:
    ///
    /// * The row is **paired** — `aspectRatioRowTrailing` is non-`nil`, i.e. the
    ///   remaster flag has landed here rather than in the video row above. Only a
    ///   paired row truncates; an unpaired one spans the card and wraps freely,
    ///   so its text is fully visible and a tooltip would restate it.
    /// * **Three or more** ratios. One or two fit the half-width column at this
    ///   size; three is where the joined list first runs past it.
    /// * The release is **remastered** — implied by the flag being the trailing
    ///   item at all, and stated anyway so the condition reads as the one
    ///   described rather than as an inference from `aspectRatioRowTrailing`'s
    ///   internals.
    ///
    /// Outside that state this is `nil` and the text carries no tooltip, which
    /// matters because the text is selectable: a help modifier over content the
    /// user may be dragging to copy is worth accepting only when it is the sole
    /// way to read that content. The glyph's own "Aspect ratio" tooltip is
    /// unaffected in every state — it names the field, this names the value.
    private var aspectRatioContentHelp: String? {
        guard model.remastered,
              model.aspectRatioCount >= 3,
              aspectRatioRowTrailing != nil
        else { return nil }
        return model.aspectRatio
    }

    /// True when the flag is set but neither host row will be drawn, so it needs a line of
    /// its own.
    ///
    /// Both hosts are genuinely optional. `video` is empty for a Blu-ray whose codec has
    /// not been chosen — `ReleaseFormat.bluRay`'s new-release defaults leave `videoFormat`
    /// blank, unlike 4K ("HEVC") and DVD ("MPEG2") — and `aspectRatio` is empty until the
    /// user picks one. Without this fallback, marking such a release remastered set a flag
    /// the card then never showed.
    private var remasteredNeedsOwnRow: Bool {
        model.remastered && !videoRowTookRemastered && !showsAspectRatioRow
    }

    private var acquisitionBlockIsEmpty: Bool {
        model.spendLine.isEmpty
            && model.purchaseLine.isEmpty
            && model.marketAvailability.isEmpty
            && model.lowestPriceLine.isEmpty
            && !model.isWishlisted
    }

    /// True when either badge has something to show. Guards the row so an otherwise empty
    /// HStack does not contribute its spacing to the details stack.
    private var hasBadgeRow: Bool {
        !model.releaseYear.isEmpty
            || model.regionIndicator != nil
            || !model.nationalOrigin.isEmpty
    }
}

// MARK: - Badge Row
// The release year and the region/origin pill, sharing the first line under the header.
// Both use the same opaque gray fill so they read as a matched pair.


// The release year, with the base (original) release year alongside it when the release
// has one. Both compartments are a fixed width sized for four numerals, and the trailing
// one's footprint is reserved whether or not it has a value, so the badge is identical
// across every release and nothing shifts between the two cases.
private struct RSBYearBadge: View {
    let releaseYear: String
    let baseReleaseYear: String

    /// Floor only. Each compartment takes half of the badge row's leading column, so the
    /// badge mirrors the region/origin pill filling the trailing column. The reserved base
    /// year slot is sized identically whether or not it holds a value, so the release year
    /// occupies the same half in both cases and nothing shifts between cards.
    private static let minimumCompartmentWidth: CGFloat = 48

    /// Gap between the two compartments.
    private static let compartmentGap: CGFloat = 3

    private var hasBaseYear: Bool { !baseReleaseYear.isEmpty }

    /// Fully rounded, matching the region/origin pill beside it — the two badges share
    /// one fill and one silhouette so they read as a matched pair on the badge row.
    private var compartmentShape: Capsule { Capsule(style: .continuous) }

    /// Encloses both compartments and the gap between them, in the same capsule profile.
    /// Coincident with the leading compartment's own capsule along their shared edge.
    private var connectorShape: Capsule { Capsule(style: .continuous) }

    var body: some View {
        HStack(spacing: Self.compartmentGap) {
            // Only the release year is filled. The contrast between a filled compartment
            // and a bare one is what distinguishes the two years at a glance; the outline
            // below is what shows they belong together.
            // The shadow rides on the fill shape rather than the composed view, so it
            // outlines the capsule alone. Applied to the whole badge it would also trace
            // the numerals, which reads as a text shadow in light mode.
            compartment(releaseYear, isOnFill: true)
                .background(compartmentShape.fill(RSBCardChrome.badgeFill).rsbBadgeShadow())

            // Bare text in a reserved slot of the same width. Drawn only when there is a
            // value, but its space is occupied either way, so the badge's footprint never
            // changes between the two cases.
            compartment(baseReleaseYear, isOnFill: false)
                .opacity(hasBaseYear ? 1 : 0)
        }
        // The outline is stroked on the badge's own bounds, so it shares the outermost
        // edge of the release year's fill rather than sitting in a ring outside it, which
        // keeps the badge exactly `badgeRowHeight` tall — matching the region/origin pill
        // beside it.
        //
        // A BACKGROUND, not an overlay. Both draw the same geometry, but an overlay renders
        // above the compartment's own fill, so along the edge they share the outline sat on
        // top of the fill — and since it carries a shadow, that shadow fell across the fill
        // too, making the outline look like a separate layer resting on the badge. As a
        // background the whole stroke renders beneath the compartment, so the fill covers it
        // along their shared edge and only the two short stubs where the outline emerges
        // past the fill remain visible — which is what the connection should look like.
        .background {
            if hasBaseYear {
                connectorShape
                    .strokeBorder(RSBCardChrome.badgeFill, lineWidth: 1)
                    .rsbBadgeShadow()
            }
        }
        .help(hasBaseYear
              ? "Release year \(releaseYear); original release \(baseReleaseYear)"
              : "Release year \(releaseYear)")
    }

    /// `isOnFill` distinguishes the release year, which sits on the gray capsule and takes
    /// a constant white, from the base year, which sits on the card and takes the adaptive
    /// label color. The fill is a fixed opaque gray at both appearances, so white is the
    /// legible choice on it in light mode as well as dark.
    private func compartment(_ text: String, isOnFill: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(isOnFill ? Color.white : Color.primary)
            .lineLimit(1)
            .frame(
                minWidth: Self.minimumCompartmentWidth,
                maxWidth: .infinity,
                minHeight: RSBCardChrome.badgeRowHeight,
                maxHeight: RSBCardChrome.badgeRowHeight)
    }
}

/// Region lock and country of origin as a single pill: the region's indicator badge on
/// the left, the country centered in the remaining space beside it.
///
/// The badge is `RSBIndicatorView` — the same colored disc, lettering, and globe glyph
/// the ReleasesTable draws, at the same `regionBadgeDiameter` (14pt) that table's
/// `IndicatorBadge` uses — rather than a flattened mark, so the region reads identically
/// in both presentations. That diameter is also what sets `badgeRowHeight`.
///
/// The pill is a fixed overall width, and the region's slot is reserved whether or not
/// there is a region to draw, so the pill neither changes size between countries nor
/// shifts its country text between releases.
private struct RSBRegionOriginPill: View {
    let region: RSBRegionIndicator?

    /// The stored region lock spelled out, for the badge's tooltip. Carried alongside the
    /// indicator rather than reconstructed from it: "Region B" and "Region B
    /// (Loosely-locked)" both draw as a lettered "B" and are distinguished only by tint, so
    /// the drawn mark is not a reliable source for the text.
    let regionLabel: String

    let nationalOrigin: String

    /// Floor only. The pill is placed in the badge row's trailing column and stretches to
    /// fill it, so its left edge lands on the same axis as the second column of every
    /// field row below. This minimum keeps "United States" — the widest country name in
    /// use — from ellipsizing when the sidebar is at its narrowest.
    private static let minimumPillWidth: CGFloat = 116
    private static let regionSlotWidth: CGFloat = RSBCardChrome.regionBadgeDiameter

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let region {
                    RSBIndicatorView(indicator: region)
                } else {
                    // Placeholder for a release with no recorded region lock, so the pill
                    // keeps the same internal geometry as every other one on screen and
                    // the country text does not shift left to fill the gap.
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white)
                }
            }
            .frame(width: Self.regionSlotWidth)
            // See RSBGlyphLine.glyph: the tracking region has to be the slot's whole box,
            // not the disc's drawn edge, for the tooltip to be reliable on sustained hover.
            .contentShape(Rectangle())
            // On the SLOT, covering both branches. Attached to the badge alone, the
            // placeholder had no tooltip at all — so a release with no recorded region, and
            // one whose stored region is outside the vocabulary and draws as an illegible
            // sliver in this 14pt slot, were the two cases with nothing to read and no way
            // to ask. Those are precisely the cases that need it; the ones that draw a
            // recognizable mark are the ones that could arguably do without.
            //
            // Still the slot rather than the whole pill: it names the region lock, which is
            // what this slot encodes, while the country beside it already names itself.
            .help(regionHelp)

            Text(nationalOrigin)
                // Constant white, like the release year beside it: the fill is a fixed
                // opaque gray at both appearances, so the adaptive label color would go
                // dark against it in light mode.
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 8)
        .frame(
            minWidth: Self.minimumPillWidth,
            maxWidth: .infinity,
            minHeight: RSBCardChrome.badgeRowHeight,
            maxHeight: RSBCardChrome.badgeRowHeight)
        // The shadow rides on the capsule rather than the composed view, so it does not
        // also trace the country text and the region badge's glyph.
        .background(Capsule(style: .continuous).fill(RSBCardChrome.badgeFill).rsbBadgeShadow())
    }

    private var regionHelp: String {
        regionLabel.isEmpty ? "No region lock recorded" : regionLabel
    }
}

// MARK: - Region Indicator Rendering
// The card's drawing of an `RSBRegionIndicator`. What the mark *is* and how a playable one
// is colored versus a locked one are `RSBRegionIndicator` / `RSBRegionBadge`'s, shared with
// the summary table; this view supplies only the card's own chrome, which genuinely differs
// from the table's: everything here sits on the region/origin pill's fixed opaque gray, so
// the globe and the raw-value fallback take a constant white where the table's take the
// adaptive label color, and the disc carries the pill's badge shadow.

private struct RSBIndicatorView: View {
    let indicator: RSBRegionIndicator

    /// Local alias for readability; the constant itself lives on the nonisolated
    /// `RSBCardChrome` so the badge row's height can be derived from it.
    private static let diameter = RSBCardChrome.regionBadgeDiameter

    var body: some View {
        switch indicator {
        case let .character(label, playable):
            ZStack {
                Circle()
                    .fill(RSBRegionBadge.fill(playable: playable))
                    .frame(width: Self.diameter, height: Self.diameter)
                    .rsbBadgeShadow()
                Text(label)
                    .font(RSBRegionBadge.characterFont)
                    .foregroundStyle(RSBRegionBadge.ink(playable: playable))
                    .shadow(
                        color: .black.opacity(
                            RSBRegionBadge.inkNeedsShadow(playable: playable) ? 0.5 : 0),
                        radius: 0.5, x: 0, y: 0.5)
            }
        case .globe:
            Image(systemName: "globe")
                .font(.system(size: Self.diameter))
                .foregroundStyle(.white)
                .frame(width: Self.diameter, height: Self.diameter)
        case let .raw(value):
            // The slot is sized for the disc, so there is no room to render an arbitrary
            // string legibly; shrinking to fit salvages a short one, and the slot's tooltip
            // carries the value in full either way.
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.tail)
        }
    }
}

// MARK: - Glyph Rows

/// One glyph-led line's content: its symbol, its text, and the tooltip its glyph carries.
///
/// The tooltip exists because several glyphs are only self-evident once you already know
/// what the card shows — an aspect ratio, an HDR format, and a lowest-price date all read
/// as bare values beside a small symbol. Naming the field on hover keeps the row compact
/// without leaving it ambiguous. Rows whose text names itself ("Remastered", "3 discs")
/// carry no tooltip, since repeating the visible text would be noise.
private struct RSBRowItem {
    let symbol: String
    let text: String
    var help: String? = nil
}

/// A line led by a secondary-colored glyph. The glyph occupies a fixed width so the text of
/// stacked lines starts at the same x-origin regardless of glyph shape, and wrapped lines
/// align under the first line's text rather than under the glyph.
private struct RSBGlyphLine: View {
    let item: RSBRowItem

    /// Clamp the text to one line with a trailing ellipsis instead of letting it wrap. Set
    /// for both halves of a paired row — see `glyphRow`.
    var truncates: Bool = false

    /// A tooltip for the *text* column, as opposed to `item.help`, which is the
    /// glyph's. Supplied only where the line truncates and the tooltip is therefore
    /// the sole way to read the whole value — see `aspectRatioContentHelp`. `nil`
    /// leaves the text with no tooltip at all, which is the default and remains the
    /// case for every other line on the card.
    var contentHelp: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            glyph
            text
        }
    }

    /// The line's value, with its optional whole-column tooltip.
    ///
    /// The help modifier goes on the text's own flexible frame rather than on the
    /// `Text`, so the target is the entire remainder of the line — including the
    /// space to the right of a short value — rather than only the drawn glyphs. As
    /// with the glyph, `contentShape` is what makes that hold: a `Text`'s
    /// interaction shape is its rendered characters, so without it the cursor would
    /// fall between words and lose the tooltip.
    ///
    /// The two tracking regions do not overlap. The glyph's is its own 14pt box and
    /// this one begins after the stack's 6pt spacing, so hovering the symbol shows
    /// the field name and hovering the value shows the value — which is the whole
    /// reason this is a second tooltip rather than a longer version of the first.
    @ViewBuilder
    private var text: some View {
        let label = Text(item.text)
            .font(.system(size: 11))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .lineLimit(truncates ? 1 : nil)
            .truncationMode(.tail)
            // Only meaningful when wrapping. `fixedSize` vertically tells the text to
            // take the height its wrapped content needs rather than being clipped to
            // one line; with `lineLimit(1)` there is nothing to grow into.
            .fixedSize(horizontal: false, vertical: !truncates)
            .frame(maxWidth: .infinity, alignment: .leading)

        if let contentHelp {
            label
                .contentShape(Rectangle())
                .help(contentHelp)
        } else {
            label
        }
    }

    /// The tooltip is attached to the glyph alone, not the whole line: the text beside it is
    /// selectable, and a help modifier spanning both would put a tooltip on content the user
    /// may be trying to copy.
    @ViewBuilder
    private var glyph: some View {
        // `contentShape` is what makes the tooltip reliable. A help modifier's tracking
        // region follows the view's interaction shape, which for an Image is its drawn
        // glyph — a handful of thin strokes at 11pt, with gaps between them that count as
        // misses. Sustained hover would land in one of those gaps and no tooltip would
        // appear until the cursor left and came back. Declaring the full 14pt frame as the
        // interaction shape makes every point over the glyph's box a hit.
        let image = Image(systemName: item.symbol)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: 14, alignment: .center)
            .contentShape(Rectangle())

        if let help = item.help {
            image.help(help)
        } else {
            image
        }
    }
}
