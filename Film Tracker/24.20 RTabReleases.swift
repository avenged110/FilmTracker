// MARK: - RTabReleases.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The card-based Releases tab in RightSidebar (RightSidebarTab.releases). Its optional summary
// table (ReleasesTable.swift) sits above the cards when the preference is on.
//
// Each disc release is a card on the `controlBackgroundColor` plate. A combo pack and its
// auto-created Blu-ray children share one taller plate, separated by full-bleed dividers.
//
// The region lock, composed video line, and release grouping and ordering are defined once in
// RSBHelpers' "Releases Tab: Shared Derivations" section, which this tab and the table both use.
// Do not reimplement them here. This file owns only the card chrome and layout.

import SwiftUI
import AppKit

// MARK: - Releases Tab

struct RTabReleases: View {
    var releasesSummaryExpanded: Binding<Bool>

    /// The purchase filter, owned by RightSidebar. This tab is torn down on a selection change,
    /// so a filter held here would be lost, and "remember the filter" could not work.
    var purchaseFilter: Binding<RSBPurchaseFilter>

    /// The content is built inside the scroll view, so the filter's animated mirror lives in
    /// the hosted tree. State passed in through a rootView replacement carries no animation
    /// transaction, so a filter change would never animate.
    var body: some View {
        SidebarScrollView {
            RTabReleasesContent(releasesSummaryExpanded: releasesSummaryExpanded,
                                purchaseFilterBinding: purchaseFilter)
        }
    }
}

private struct RTabReleasesContent: View {
    @Environment(\.sidebarFilm) private var film: FilmSnapshot?

    /// Expansion state for the optional summary table. Threaded down from RightSidebar,
    /// which substitutes `.constant(true)` when the auto-expand preference is on.
    var releasesSummaryExpanded: Binding<Bool>

    /// When false, RSBReleasesSection is not built: no card array, table data, or `onChange`
    /// subscription. @AppStorage makes the toggle take effect live.
    @AppStorage(preference: Preferences.showReleasesSummaryTableKey)
        private var showReleasesSummaryTable: Bool

    /// The card groups, derived from the film's releases. A cache written from `onChange` would
    /// draw a new film's card stack twice, once with the old groups. Read once per render into a
    /// local in `body`, because each read repeats the whole sort and map.
    private var releaseCardGroups: [RSBReleaseCardGroup] {
        RSBReleaseCardBuilder.buildGroups(from: filteredFilm?.releases ?? [])
    }

    /// RightSidebar's filter, which survives this view being torn down. RightSidebar resets it
    /// on a selection change unless the remember preference is on.
    var purchaseFilterBinding: Binding<RSBPurchaseFilter>

    /// Which releases the tab shows: a local mirror of `purchaseFilterBinding`, as RTabDetailsContent
    /// does for table expansion. The picker writes the mirror, so the change animates in the hosted
    /// tree. The mirror syncs with RightSidebar both ways, and changes from RightSidebar land unanimated.
    @State private var purchaseFilter: RSBPurchaseFilter

    init(releasesSummaryExpanded: Binding<Bool>, purchaseFilterBinding: Binding<RSBPurchaseFilter>) {
        self.releasesSummaryExpanded = releasesSummaryExpanded
        self.purchaseFilterBinding = purchaseFilterBinding
        _purchaseFilter = State(initialValue: purchaseFilterBinding.wrappedValue)
    }

    /// The scroll view's visible height, for centering the empty states in it.
    @Environment(\.sidebarViewport) private var viewport

    /// The film with releases narrowed to `purchaseFilter`, passed to the summary table through the
    /// environment so both show one set. Filtering on `purchased` keeps combo packs whole, because
    /// `syncComboChildFields` locks a child's purchased flag to its parent's.
    private var filteredFilm: FilmSnapshot? {
        guard var film, purchaseFilter != .all else { return film }
        film.releases = film.releases.filter { purchaseFilter.includes($0.purchased) }
        return film
    }

    /// Whether the film has any disc release, filtered or not. Without one, the picker stays drawn
    /// but disabled, with no segment selected.
    private var hasDiscReleases: Bool {
        film?.releases.contains { ReleaseFormat(rawValue: $0.format) != nil } ?? false
    }

    var body: some View {
        // Resolved once and passed down; see `releaseCardGroups`.
        let groups = releaseCardGroups
        let narrowedFilm = filteredFilm

        return RSBTopPinnedLayout {
            // Spacing matches the horizontal and bottom insets, so the gaps between cards and to
            // those edges are one measure. The top inset is tighter because the header sits just above.
            VStack(alignment: .leading, spacing: RSBCardChrome.sidebarInset) {
                purchaseFilterPicker
                // The card stack is one AppKit view (RSBCardStack). It stays mounted through an empty
                // result, so a filter or film change re-points it rather than inserting it. SwiftUI
                // re-measures the whole tab on each AppKit insertion.
                ZStack(alignment: .topLeading) {
                    if groups.isEmpty {
                        emptyState
                            .transition(OpacityTransition())
                    }
                    // spacing: 0, since the summary block sets its own gaps. The outer stack's spacing is
                    // wider than the Details module metrics this block should match. With the summary table
                    // off, this is the card stack alone.
                    VStack(alignment: .leading, spacing: 0) {
                        if !groups.isEmpty {
                            summaryBlock(narrowedFilm)
                        }
                        RSBCardStack(groups: RSBProfileFlags.noReleaseCards ? [] : groups,
                                     today: CurrentDay.shared.today)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: groups.isEmpty ? .infinity : nil, alignment: .top)
            }
            // With nothing to list, the stack fills the viewport so the placeholder can center (see `emptyStackHeight`).
            .frame(height: groups.isEmpty ? emptyStackHeight : nil, alignment: .top)
            // Scoped to the filter, so only a filter change animates. New films and edited releases swap
            // in on the first frame. This re-enables animation past MainView's container-wide
            // `animation = nil`, and works only because the filter's @State lives in the hosted tree (see `body`).
            .animation(.smooth(duration: 0.3), value: purchaseFilter)
            .padding(.horizontal, RSBCardChrome.sidebarInset)
            .padding(.top, 8)
            .padding(.bottom, RSBCardChrome.sidebarInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // Local → RightSidebar, so the choice outlives this view.
        .onChange(of: purchaseFilter) { _, value in
            if purchaseFilterBinding.wrappedValue != value { purchaseFilterBinding.wrappedValue = value }
        }
        // RightSidebar → local, unanimated: its selection-change reset lands with the new
        // film, which swaps in in one step.
        .onChange(of: purchaseFilterBinding.wrappedValue) { _, value in
            if purchaseFilter != value { RSBHelpers.withoutAnimation { purchaseFilter = value } }
        }
        #if DEBUG
        // The `releases-filter` harness scenario (99.56) switches the filter through this.
        .onAppear {
            let filter = $purchaseFilter
            ReleasesFilterProbe.select = { filter.wrappedValue = RSBPurchaseFilter(rawValue: $0) ?? .all }
        }
        .onDisappear { ReleasesFilterProbe.select = nil }
        #endif
        // No refresh handler. The groups are derived, and RightSidebar refreshes the environment
        // snapshot on .updated and .releaseChanged before children observe them, so no AppEventBus
        // subscription is needed.
    }

    /// The optional summary table and the "All Releases" title above the cards.
    @ViewBuilder
    private func summaryBlock(_ narrowedFilm: FilmSnapshot?) -> some View {
        // Scrolls with the cards, as a sibling in the same VStack. Callers gate it on a non-empty
        // group set, so the section's own placeholder cannot duplicate the tab's.
        if showReleasesSummaryTable {
            RSBReleasesSection(releasesExpanded: releasesSummaryExpanded,
                               mode: .releaseCard)
                .environment(\.sidebarFilm, narrowedFilm)
                // 12 = the Details stack's 4 pt spacing plus the 8 pt padding of RSBHelpers.sectionDivider.
                // That helper assumes the Details stack's 4 pt spacing on each side, which this spacing-0 stack
                // does not supply, so the gaps are written out here.
                .padding(.bottom, 12)
            Divider()
            allReleasesHeader
                .padding(.top, 12)
                // Matches the gap the Details modules put between a title and its content (CalendarTable's spacing of 6).
                .padding(.bottom, 6)
        }
    }

    /// Titles the card stack when the summary table sits above it, so the two blocks read as separate
    /// modules. Drawn with the shared module-title builder used across the sidebar.
    private var allReleasesHeader: some View {
        RSBHelpers.moduleHeader(purchaseFilter.cardsTitle)
    }

    /// The stack's height when there is nothing to list: the viewport minus the insets, so the content
    /// is one viewport tall and does not scroll. The 16 pt spacing above the placeholder and the 16 pt
    /// bottom inset make the region symmetric, so the placeholder centers between the picker and the
    /// viewport's bottom. Before the viewport is measured, or outside a sidebar scroll view, it falls back to 80 pt.
    private var emptyStackHeight: CGFloat {
        max(80, (viewport?.height ?? 0) - 8 - RSBCardChrome.sidebarInset)
    }

    /// Full width at the top of the tab, at the standard control size, with the same insets as
    /// the Details tab's "Add Viewing Event" row.
    ///
    /// Bound through an optional, so with no disc releases it shows no segment selected. The stored filter is kept for the next film.
    private var purchaseFilterPicker: some View {
        let selection = Binding<RSBPurchaseFilter?>(
            get: { hasDiscReleases ? purchaseFilter : nil },
            set: { if let value = $0 { purchaseFilter = value } })
        return Picker("Show", selection: selection) {
            ForEach(RSBPurchaseFilter.allCases) { filter in
                Text(filter.title).tag(Optional(filter))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .disabled(!hasDiscReleases)
    }

    private var emptyState: some View {
        // The filter can outlive a film change (rememberReleasesFilter). A film with no disc releases has a
        // disabled picker with no selection, so it shows the unfiltered message rather than the narrower one.
        Text(hasDiscReleases ? purchaseFilter.emptyText : RSBPurchaseFilter.all.emptyText)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            // Fills the space the stack leaves below the picker, centered in it.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.vertical, 12)
    }
}

// MARK: - Purchase Filter

enum RSBPurchaseFilter: String, CaseIterable, Identifiable {
    case all, purchased, unpurchased

    var id: Self { self }

    var title: String {
        switch self {
        case .all:         "All"
        case .purchased:   "Purchased"
        case .unpurchased: "Unpurchased"
        }
    }

    /// Titles the cards when the summary table sits above them.
    var cardsTitle: String {
        switch self {
        case .all:         "All Releases"
        case .purchased:   "All Purchased Releases"
        case .unpurchased: "All Unpurchased Releases"
        }
    }

    /// Shown in place of the cards when the filter leaves nothing.
    var emptyText: String {
        switch self {
        case .all:         "No Releases Added"
        case .purchased:   "No Purchased Releases"
        case .unpurchased: "No Unpurchased Releases"
        }
    }

    func includes(_ purchased: Bool) -> Bool {
        switch self {
        case .all:         true
        case .purchased:   purchased
        case .unpurchased: !purchased
        }
    }
}

// MARK: - Card Models

/// One release, pre-resolved for display. Each derived string mirrors the matching column in
/// `DiscReleasesTable.buildTableData`, so the two presentations cannot drift apart.
private extension RSBReleaseCard {
    /// "Released on October 17, 2026" — or "Releases on …" while the date is still ahead,
    /// since a release cataloged before it comes out has not been released. A year-only
    /// value reads "Released in 2014" / "Releases in 2027".
    static func releasePhrase(_ date: ReleaseDateValue, today: Date) -> String {
        let verb = date.isUpcoming(today: today) ? "Releases" : "Released"
        return "\(verb) \(date.isYearOnly ? "in" : "on") \(date.displayText)"
    }
}

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
    /// The parsed release date, or nil when empty or unreadable (the year badge then shows the stored text).
    /// Kept parsed because "Released" or "Releases" depends on the day the card is drawn, and the model is built once per release.
    let releaseDate: ReleaseDateValue?
    /// Codec and master type.
    let video: String

    /// Whether the release is a remaster. Shown only when true, since absence is the negative case.
    /// This replaces the table's Rem. column suppression, which existed only to avoid a column of red crosses.
    let remastered: Bool
    let hdr: String               // Empty for Blu-ray/DVD (the table's "N/A")
    let aspectRatio: String

    /// How many aspect ratios `aspectRatio` was joined from. Stored separately, because a ratio can
    /// contain a comma, so counting separators in the display string would fail for long lists.
    /// Read only by `aspectRatioContentHelp`, to decide whether the row may truncate.
    let aspectRatioCount: Int

    let audio: String
    let discs: String
    let nationalOrigin: String
    let includedVersions: String

    /// Whether the versions line is drawn. A release is assumed to contain the theatrical version, so a
    /// theatrical-only list says nothing and is suppressed. Anything else, such as an extended cut or a
    /// theatrical-plus-director's-cut pairing, is stated. This is decided per card group, not per release:
    /// if either combo-pack half names a non-theatrical version, both keep the line, so the reader does not
    /// infer one disc's contents from the other's silence. See `showsIncludedVersions(in:)`.
    let showsIncludedVersions: Bool

    // Acquisition (suppressed entirely for combo-pack children)
    /// Cost and amount spent as one phrase, such as "$29.99, $24.99 spent". Empty for an unpurchased
    /// release, and for a purchased one whose cost was never entered (see the "cost of exactly 0" note).
    let spendLine: String

    /// Condition and purchase date as one sentence, such as "Purchased used on Jan 3, 2019". If either half
    /// is missing, it reads "Purchased on Jan 3, 2019" or "Purchased used". Empty for an unpurchased release.
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

    /// User-authored notes, empty when none. `syncComboChildFields` does not copy notes, so a child's notes
    /// are its own. The summary table shows an empty child's cell as "–", pointing to the parent row. The card
    /// draws no notes line instead.
    let notes: String
}

/// A card's worth of releases: a single standalone release, or a combo-pack parent
/// followed by its attached children on the same plate.
private struct RSBReleaseCardGroup: Identifiable, Equatable {
    /// The primary (parent) release's UUID. Stable across recomputes, so ForEach can diff groups.
    let id: UUID
    let releases: [RSBReleaseCard]
}

// MARK: - Card Builder
// Pure, nonisolated transform from snapshots to display models, with no view or environment
// dependency. That lets `releaseCardGroups` call it directly.
private enum RSBReleaseCardBuilder {

    /// Takes the film's release array, since the groups depend on nothing else about it (see `releaseCardGroups`).
    static func buildGroups(from releases: [ReleaseSnapshot]) -> [RSBReleaseCardGroup] {
        // Same source as RSBReleasesSection: disc formats only. `ReleaseFormat` decides membership, so an
        // unrecognized format string is excluded here as it is in the table. The old per-format accessors'
        // ordering is not kept, since grouping re-sorts into a total order regardless of input order.
        let source = releases.filter { ReleaseFormat(rawValue: $0.format) != nil }
        guard !source.isEmpty else { return [] }

        // Grouping and ordering come from `releasesGroupedByHierarchy`, shared with the summary table. Sharing it
        // guarantees a table row and the card beneath it name the same release. See that function for its keys
        // and why the ordering ends in a unique value. Every group is non-empty, so `[0]` is the primary release.
        return releasesGroupedByHierarchy(source).map { members in
            // Decided once for the whole group and handed to every member, so a
            // combo pack's halves agree — see `showsIncludedVersions(in:)`.
            let showsVersions = showsIncludedVersions(in: members)
            return RSBReleaseCardGroup(
                id: members[0].id,
                releases: members.map { model(for: $0, showsIncludedVersions: showsVersions) })
        }
    }

    /// Whether the versions line is drawn for every member of one card group. The cards claim that a release
    /// contains the theatrical version unless stated otherwise. A member earns the line by naming a version other
    /// than theatrical, or theatrical alongside something else. A release naming only theatrical, or nothing, contributes nothing.
    ///
    /// Group-wide, because a combo pack is read as a pair. If one half is theatrical-only and the other has an
    /// extended cut, hiding the first half's line would make the reader infer which disc has what from an absence.
    ///
    /// The comparison is trimmed and case-insensitive, since import can write the value as well as the picker.
    /// The tag spelling is `ReleaseCard`'s version vocabulary.
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
            // A cost of exactly 0 means the field was never filled in — Core Data's
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
            // The status and price elements joined as "Out-of-print (cheap)". See
            // ReleaseMarketAvailability.
            marketAvailability = ReleaseMarketAvailability.displayText(release.marketAvailability)

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

        // The year of the release date, whichever shape it is stored in. Trimmed, as
        // ReleaseDateValue.yearText trims every value it passes through.
        let releaseYear = ReleaseDateValue.yearText(of: release.releaseDate, format: release.format)
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
            releaseDate: ReleaseDateValue(release.releaseDate, format: release.format),
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

    /// A stored date formatted for display, or "" when unusable. Gated on the parse, not on `isEmpty`.
    /// `formatDateString` returns "Unknown date" on failure. That works as a table placeholder, but in prose
    /// it reads as a claim ("Purchased used on Unknown date"). Returning "" lets each line use its shorter form.
    private static func displayDate(_ stored: String) -> String {
        parseDate(from: stored) == nil ? "" : formatDateString(stored)
    }

    /// The HDR "None" tag is a statement that the release has no HDR, so it reads "No HDR" rather than a bare "None".
    /// Other tags are self-describing and pass through.
    private static func hdrDisplay(for value: String) -> String {
        value == ReleaseHDR.noneTag ? "No HDR" : value
    }

    /// Artwork as a note, shown only when it departs from the default. Plain "Yes" and the unset "" return "" and draw no line.
    /// The cases are the `hasArtwork` picker's tag values verbatim (see `ReleaseCard`), so the two cannot drift apart.
    /// Unknown values fall through to the raw stored value.
    private static func artworkNote(for value: String) -> String {
        switch value {
        // "Yes (Combo-pack)" is unstated too. It describes the pack, which the parent's line already covers.
        case "", ReleaseArtwork.yes, ReleaseArtwork.yesComboPack: return ""
        case ReleaseArtwork.steelbook:  return "Steelbook"
        case ReleaseArtwork.yesIncorrectRelease: return "Release-mismatched artwork"
        case ReleaseArtwork.yesCustom:  return "Custom artwork"
        case ReleaseArtwork.yesMultiPack: return "Multi-pack artwork"
        // "No (Combo-pack)" and "No (Multi-pack)" are not offered in the picker, but the table
        // still recognizes them, so legacy or restored records may carry them. Phrasing them here
        // keeps both views consistent.
        case _ where ReleaseArtwork.negativeTags.contains(value):
                                        return "Missing artwork"
        default:                        return value
        }
    }
}

// MARK: - Card Chrome
// Fills, inks, and shadow values shared by the card body and its badges, kept together
// so the header band, the format badge, and the year badge cannot drift apart.
enum RSBCardChrome {

    /// Format header tints — `ReleaseFormatPalette`'s, the same ones `ReleaseCardView` bands
    /// its FilmSheet cards with (33_20).
    /// Purchase status no longer tints the header at all; it lives entirely in the
    /// trailing glyph now, so these three are keyed on format alone.
    static let tint4K     = Color(nsColor: ReleaseFormatPalette.tint4K)
    static let tintBluRay = Color(nsColor: ReleaseFormatPalette.tintBluRay)
    static let tintDVD    = Color(nsColor: ReleaseFormatPalette.tintDVD)
    /// A format string this build does not recognize: the sidebar's neutral badge gray.
    static let tintUnknown = Preferences.darkGray

    /// Purchase-glyph color for "purchased", matching the table's checkmark badge (see `symbolBadge` in ReleasesTable.swift).
    /// The "not purchased" dashed-circle glyph stays white.
    static let checkmarkGreen = Preferences.green

    /// Wash that marks an attached child half, in the label color at this opacity. It is also the child's header fill.
    static let childWashOpacity: CGFloat = 0.035

    /// Format-badge plate and lettering. Both are fixed, so the badge reads the same on the dark band and the light child wash.
    static let badgePlate = Color(white: 0.93)
    static let badgeInk = Color(red: 0.11, green: 0.11, blue: 0.12)
    /// Format badge only. The badge-row pills are fully rounded capsules instead.
    static let badgeCornerRadius: CGFloat = 4

    /// Fill for the year badge's compartments and the region/origin pill, and the year badge's connector stroke.
    /// `Preferences.darkGray` is an opaque gray that matches the FilmSheet's list buttons over a dark window.
    /// Semantic background colors sit too close to the card's fill, so the badges would disappear into it.
    /// The value is opaque, so the connector stroke and the year fill meet without a darker rim.
    static let badgeFill = Preferences.darkGray

    /// Diameter of the region lock's disc, matching the table's `IndicatorBadge`. It also sets the badge row's height.
    static let regionBadgeDiameter: CGFloat = 14

    /// Uniform height for the badge row, so the year badge and the region pill share a baseline. Derived from the disc size.
    static let badgeRowHeight: CGFloat = regionBadgeDiameter + 6

    /// Shadow for the purchase glyph and both badges, so they sit on the band without looking raised.
    static let glyphShadowOpacity: Double = 0.6
    static let glyphShadowRadius: CGFloat = 1.5
    static let glyphShadowOffsetY: CGFloat = 0.5

    // MARK: Layout

    /// The sidebar's standard inset, shared with RTabDetails. It is also the gap between stacked cards, so spacing is uniform.
    static let sidebarInset: CGFloat = 16

    /// Inset applied to the card body's content on all sides.
    static let contentPadding: CGFloat = 10

    /// Top inset, tightened because the badge row sits directly under the filled header band.
    static let contentTopPadding: CGFloat = contentPadding - 2

    /// Width reserved for the trailing purchase glyph, so its center stays on a fixed axis.
    static let trailingGlyphWidth: CGFloat = 17

    /// Height reserved for the trailing purchase glyph, so the header keeps a fixed height whichever glyph shows.
    /// The two glyphs have different intrinsic heights, and without this the header would shrink for purchased releases.
    /// 20 pt matches the dashed-circle glyph's original size.
    static let trailingGlyphHeight: CGFloat = 20

    // MARK: Card Edge Treatment
    // The FilmSheet reorderable lists' edge: an outline that wraps the top and fades toward the bottom, with the
    // lower edge carried by a shadow. This is restated at slightly stronger settings. The stop structure and fade start
    // come from `FieldEdgeTreatment`. Only the strengths differ, and they are local so the shared type's controls are unchanged.

    static let borderWidth: CGFloat = FieldEdgeTreatment.borderWidth
    static let borderOpacity: Double = 0.32
    static let borderFadeStart: Double = FieldEdgeTreatment.borderFadeStart

    /// Card corner radius (continuous).
    static let cardCornerRadius: CGFloat = 8

    static let shadowOpacity: Double = 0.26
    static let shadowRadius: CGFloat = FieldEdgeTreatment.shadowRadius
    static let shadowOffsetY: CGFloat = FieldEdgeTreatment.shadowOffsetY
}

// MARK: - Card Body

/// One release's half of a card, as RSBCardBodyView draws it. It holds the model, whether it hangs under a
/// combo-pack parent, and what derives from both: the header colors, the badge row, and the glyph rows.
@MainActor
fileprivate struct RSBReleaseCardBody {
    let model: RSBReleaseCard

    /// Non-nil for a combo-pack child attached beneath its parent. It holds the banner text naming the relationship,
    /// including which Blu-ray of a dual-BD pack this is. The child drops the purchase tint for the child wash.
    /// Carrying the text, not a Bool, keeps the numbering with the group view, which can see the siblings.
    let attachedChildBanner: String?

    /// Whether this half is a combo-pack child drawn beneath its parent. Every suppression on the card asks this question.
    /// It replaces the release's own `isChild` flag, which could disagree only for an orphaned child with no parent in the film.
    /// Grouping keeps index 0 as the parent (see `releasesGroupedByHierarchy`'s "GROUP SHAPE"). The one remaining case is a
    /// parent removed by the format filter. There, a card with no parent above shows its own figures, which is correct.
    fileprivate var isAttachedChild: Bool { attachedChildBanner != nil }

    /// Today, for the release-date wording. Read through CurrentDay, so the card re-renders on release day.
    fileprivate var today: Date { CurrentDay.shared.today }

    // MARK: Header
    // Format badge, studio, and purchase glyph share a full-bleed band. A parent's band is tinted, and the tint
    // separates it from the details, so no divider is needed. A child's band shows the child wash, so the two halves read as one card.

    /// White on the dark band. Only parent halves read it, since a child names its parent instead of a studio.
    fileprivate var titleColor: Color {
        model.studio.isEmpty ? Color.white.opacity(0.55) : .white
    }

    /// Same lookup as `ReleaseCardView.bandTint` (33.20). `model.format` holds the full format name it is keyed on.
    fileprivate var bandTint: Color {
        switch ReleaseFormat(rawValue: model.format) {
        case .uhd4K:  return RSBCardChrome.tint4K
        case .bluRay: return RSBCardChrome.tintBluRay
        case .dvd:    return RSBCardChrome.tintDVD
        case nil:     return RSBCardChrome.tintUnknown
        }
    }

    /// The rows above the acquisition block.
    fileprivate var mainRows: [RSBGlyphRowSpec] {
        var rows: [RSBGlyphRowSpec] = []
        func glyphRow(_ leading: RSBRowItem, trailing: RSBRowItem? = nil, leadingContentHelp: String? = nil) {
            rows.append(RSBGlyphRowSpec(leading: leading, trailing: trailing, leadingContentHelp: leadingContentHelp))
        }
        // Glyph-led lines share a leading column, so their text aligns. Some have a trailing item that
        // appears only when it has content. The remaster flag goes in the video row's trailing slot, or the
        // aspect-ratio row's if HDR is absent. If neither row can take it, it gets its own line (see `remasteredNeedsOwnRow`).
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
        // The disc line is always shown, since `discs` carries at least "1 disc". Subtitles go in the trailing column, only when present.
        glyphRow(
            RSBRowItem(symbol: ContentGlyphs.disc, text: model.discs),
            trailing: model.hasSubtitles
                ? RSBRowItem(symbol: "captions.bubble.fill", text: "Includes subtitles")
                : nil)
        // Children inherit the parent's artwork, so the child half does not repeat it.
        if !isAttachedChild && !model.artworkNote.isEmpty {
            glyphRow(RSBRowItem(symbol: "text.book.closed.fill", text: model.artworkNote))
        }
        // Hidden when the list is theatrical-only (see `RSBReleaseCard.showsIncludedVersions`). The emptiness test
        // prevents a glyph beside nothing.
        if model.showsIncludedVersions && !model.includedVersions.isEmpty {
            glyphRow(RSBRowItem(
                symbol: "film.stack.fill", text: model.includedVersions,
                help: "Versions included"))
        }
        // The full release date, shown last before the acquisition block. A year-only value adds nothing beyond the year badge.
        // Children omit it, since their date is the parent's, shown above.
        if !isAttachedChild, let releaseDate = model.releaseDate, !releaseDate.isYearOnly {
            glyphRow(RSBRowItem(symbol: "calendar",
                                text: RSBReleaseCard.releasePhrase(releaseDate, today: today),
                                italic: releaseDate.isUpcoming(today: today)))
        }
        return rows
    }

    /// The acquisition block, below one divider. Combo-pack children omit it, since the parent above records their cost, amount spent,
    /// and purchase date. A purchased release shows what it cost and when. An unpurchased one shows where to find it, its lowest price, and whether it is wishlisted.
    /// The gate is "a parent half is drawn directly above me" (see `attachedChildBanner`), since the figures are visible there.
    fileprivate var acquisitionRows: [RSBGlyphRowSpec] {
        var rows: [RSBGlyphRowSpec] = []
        func glyphRow(_ leading: RSBRowItem, trailing: RSBRowItem? = nil, leadingContentHelp: String? = nil) {
            rows.append(RSBGlyphRowSpec(leading: leading, trailing: trailing, leadingContentHelp: leadingContentHelp))
        }
        if !model.spendLine.isEmpty {
            glyphRow(RSBRowItem(symbol: "cart.fill", text: model.spendLine))
        }
        if !model.purchaseLine.isEmpty {
            glyphRow(RSBRowItem(symbol: "calendar.badge.clock", text: model.purchaseLine))
        }
        // The wishlist flag sits beside market availability when present, otherwise it takes the leading column.
        if !model.marketAvailability.isEmpty {
            glyphRow(
                RSBRowItem(
                    symbol: "cart.fill.badge.questionmark",
                    text: model.marketAvailability,
                    help: "Market availability",
                    glyphOverhangs: true),
                trailing: wishlistItem.map { item in
                    var item = item
                    item.glyphOverhangs = true
                    return item
                })
        } else if let wishlistItem {
            glyphRow(wishlistItem)
        }
        if !model.lowestPriceLine.isEmpty {
            glyphRow(RSBRowItem(
                symbol: "calendar.badge.clock", text: model.lowestPriceLine,
                help: "Lowest price"))
        }
        return rows
    }

    /// The notes line. Wrapped lines align under the text, since RSBGlyphRowView keeps the text in its own column.
    fileprivate var notesRow: [RSBGlyphRowSpec] {
        model.notes.isEmpty ? [] : [RSBGlyphRowSpec(leading: RSBRowItem(symbol: "note.text", text: model.notes, help: "Notes"))]
    }

    private var remasteredItem: RSBRowItem? {
        model.remastered ? RSBRowItem(symbol: "scanner.fill", text: "Remastered") : nil
    }

    private var wishlistItem: RSBRowItem? {
        model.isWishlisted ? RSBRowItem(symbol: "gift.fill", text: "Wishlisted") : nil
    }

    private var showsVideoRow: Bool { !model.video.isEmpty }
    private var showsAspectRatioRow: Bool { !model.aspectRatio.isEmpty }

    /// HDR on a 4K release. Otherwise the trailing slot takes the remaster flag.
    private var videoRowTrailing: RSBRowItem? {
        model.hdr.isEmpty
            ? remasteredItem
            : RSBRowItem(symbol: "sun.max.fill", text: model.hdr, help: "HDR")
    }

    /// True when the video row has taken the remaster flag. That needs the row drawn, and HDR empty.
    private var videoRowTookRemastered: Bool { showsVideoRow && model.hdr.isEmpty }

    /// The remaster flag, when the video row above did not take it.
    private var aspectRatioRowTrailing: RSBRowItem? {
        videoRowTookRemastered ? nil : remasteredItem
    }

    /// The full aspect-ratio list as a tooltip, for the one state where the row cannot show it all. That needs all three:
    /// the row is paired (the remaster flag is in its trailing slot, which is the only case that truncates),
    /// there are three or more ratios (the joined list first overflows the column there), and the release is remastered.
    /// Otherwise it is nil, because the text is selectable and a tooltip is needed only when it is the sole way to read it.
    /// The glyph's own "Aspect ratio" tooltip names the field and is unaffected.
    private var aspectRatioContentHelp: String? {
        guard model.remastered,
              model.aspectRatioCount >= 3,
              aspectRatioRowTrailing != nil
        else { return nil }
        return model.aspectRatio
    }

    /// True when the flag is set but neither host row is drawn, so the flag needs its own line.
    /// Both hosts are optional. A Blu-ray's `video` is empty until a codec is chosen (4K and DVD default to values), and
    /// `aspectRatio` is empty until the user picks one. Without this fallback, a remastered flag would never show.
    private var remasteredNeedsOwnRow: Bool {
        model.remastered && !videoRowTookRemastered && !showsAspectRatioRow
    }

    fileprivate var acquisitionBlockIsEmpty: Bool {
        model.spendLine.isEmpty
            && model.purchaseLine.isEmpty
            && model.marketAvailability.isEmpty
            && model.lowestPriceLine.isEmpty
            && !model.isWishlisted
    }

    /// True when a badge has content. This keeps an empty HStack from adding spacing to the stack.
    fileprivate var hasBadgeRow: Bool {
        !model.releaseYear.isEmpty
            || model.regionIndicator != nil
            || !model.nationalOrigin.isEmpty
    }
}

// MARK: - Glyph Rows

/// One glyph-led line: its symbol, its text, and the tooltip on its glyph. The tooltip names a field whose value
/// would be unclear alone, such as an aspect ratio or a price date. Rows that name themselves carry none.
/// A line can pair with a second line in the trailing column. The columns are equal, with the badge row's spacing, so trailing items align.
/// Both halves of a pair truncate, so one side's wrap cannot push the other out of line. An unpaired line spans the card and wraps.
///
/// `leadingContentHelp` puts a tooltip on the leading text, for a truncating paired row. Otherwise it is nil.
struct RSBGlyphRowSpec {
    let leading: RSBRowItem
    var trailing: RSBRowItem? = nil
    var leadingContentHelp: String? = nil
}

struct RSBRowItem {
    let symbol: String
    let text: String
    var help: String? = nil
    /// Sets the text in italics — used for an upcoming release's date.
    var italic: Bool = false
    /// Lets a glyph that stands above the baseline overhang the row's top, instead of lowering the text.
    /// The market-availability glyph and the wishlist gift are taller than `cart.fill`, so they need this.
    var glyphOverhangs: Bool = false
}

/// A card's glyph rows, pooled and laid out top to bottom at the details stack's spacing. Frames round to window
/// pixels, as SwiftUI rounds stack children. The acquisition divider splits a card into two runs.
final class RSBGlyphRowListView: NSView {
    static let spacing: CGFloat = 8

    private var rows: [RSBGlyphRowView] = []
    private var count = 0

    override var isFlipped: Bool { true }

    func update(rows specs: [RSBGlyphRowSpec]) {
        while rows.count < specs.count {
            #if DEBUG
            CardRowsProbe.rowsCreated += 1
            #endif
            let row = RSBGlyphRowView()
            // Framed by layout(), not constraints. Constraints would add every row to Auto Layout, which the hosting view walks on each film change.
            row.translatesAutoresizingMaskIntoConstraints = false
            rows.append(row)
            addSubview(row)
        }
        for (i, row) in rows.enumerated() {
            row.isHidden = i >= specs.count
            guard i < specs.count else { continue }
            row.configure(leading: specs[i].leading, trailing: specs[i].trailing,
                          leadingContentHelp: specs[i].leadingContentHelp)
        }
        count = specs.count
        needsLayout = true
    }

    /// A new width re-wraps the rows: lay out again.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let heights = rows.prefix(count).map { $0.height(forWidth: width) }
        return heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * Self.spacing
    }

    override func layout() {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { CardRowsProbe.layouts += 1; CardRowsProbe.layoutTime += CACurrentMediaTime() - t0 }
        #endif
        super.layout()
        let scale = unsafe window?.backingScaleFactor ?? 2
        let windowHeight = unsafe window?.contentView?.bounds.height ?? 0
        let originY = windowHeight - convert(NSPoint.zero, to: nil).y
        func pixel(_ v: CGFloat) -> CGFloat { ((originY + v) * scale + 0.5).rounded(.down) / scale - originY }
        var y: CGFloat = 0
        for row in rows.prefix(count) {
            let height = row.height(forWidth: bounds.width)
            let top = pixel(y)
            row.frame = NSRect(x: 0, y: top, width: bounds.width, height: pixel(y + height) - top)
            y += height + Self.spacing
        }
    }
}

/// One row of an RSBGlyphRowListView.
final class RSBGlyphRowView: NSView {
    static let glyphColumn: CGFloat = 14
    static let glyphGap: CGFloat = 6
    static let pairSpacing: CGFloat = 10

    private let columns = [RSBGlyphColumn(), RSBGlyphColumn()]
    private var paired = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        for column in columns { column.install(in: self) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(leading: RSBRowItem, trailing: RSBRowItem?, leadingContentHelp: String?) {
        paired = trailing != nil
        columns[0].configure(leading, wraps: !paired, contentHelp: leadingContentHelp)
        if let trailing { columns[1].configure(trailing, wraps: false, contentHelp: nil) }
        columns[1].isHidden = !paired
        needsLayout = true
    }

    private func columnWidths(_ width: CGFloat) -> [CGFloat] {
        paired ? Array(repeating: (width - Self.pairSpacing) / 2, count: 2) : [width]
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        zip(columns, columnWidths(width)).map { $0.metrics(width: $1).height }.max() ?? 0
    }

    override func layout() {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        let labelsBefore = columns.map(\.label.frame)
        defer {
            CardRowsProbe.rowLayouts += 1
            CardRowsProbe.rowLayoutTime += CACurrentMediaTime() - t0
            if columns.map(\.label.frame) != labelsBefore { CardRowsProbe.labelMoves += 1 }
        }
        #endif
        super.layout()
        let scale = unsafe window?.backingScaleFactor ?? 2
        let widths = columnWidths(bounds.width)
        let metrics = zip(columns, widths).map { $0.metrics(width: $1) }
        // The pair shares a baseline: the lower of the two, as an HStack aligned on the first
        // text baseline places it.
        let baseline = metrics.map(\.baseline).max() ?? 0
        let windowHeight = unsafe window?.contentView?.bounds.height ?? 0
        let originY = windowHeight - convert(NSPoint.zero, to: nil).y
        var x: CGFloat = 0
        for (column, width) in zip(columns, widths) {
            column.layout(x: x, width: width, baseline: baseline, rowHeight: bounds.height, scale: scale, originY: originY)
            x += width + Self.pairSpacing
        }
    }
}

/// One glyph-led line inside an RSBGlyphRowView: the glyph, the label, and the two tooltip areas.
@MainActor
final class RSBGlyphColumn {
    private static let font = NSFont.systemFont(ofSize: 11)
    private static let italicFont: NSFont = {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: 11) ?? font
    }()

    /// A line of the 11 pt text as SwiftUI lays it out, and the step to each further line.
    private static let textLayout = SwiftUIVerticalMetrics.measure(Text("Xg").font(.system(size: 11)),
                                                                   twoLines: Text("Xg\nXg").font(.system(size: 11)))
    private static let italicLayout = SwiftUIVerticalMetrics.measure(Text("Xg").font(.system(size: 11)).italic(),
                                                                     twoLines: Text("Xg\nXg").font(.system(size: 11)).italic())

    let glyph = RSBBaselineGlyphView()
    private var italic = false
    private var glyphOverhangs = false
    let label = NSTextField(labelWithString: "")
    /// Carry the tooltips over SwiftUI's hit areas: the glyph's 14 pt column, and the text's
    /// whole flexible frame.
    private let glyphHelp = NSView()
    private let textHelp = NSView()
    private var wraps = false

    var isHidden = false {
        didSet { for v in [glyph, label, glyphHelp, textHelp] { v.isHidden = isHidden } }
    }

    func install(in view: NSView) {
        // Framed by RSBGlyphRowView.layout (see RSBGlyphRowListView.update).
        for v in [glyph, label, glyphHelp, textHelp] { v.translatesAutoresizingMaskIntoConstraints = false }
        label.textColor = .labelColor
        label.isSelectable = true
        label.maximumNumberOfLines = 1
        view.addSubview(glyphHelp)
        view.addSubview(textHelp)
        view.addSubview(glyph)
        view.addSubview(label)
    }

    func configure(_ item: RSBRowItem, wraps: Bool, contentHelp: String?) {
        self.wraps = wraps
        italic = item.italic
        glyphOverhangs = item.glyphOverhangs
        let font = item.italic ? Self.italicFont : Self.font
        if label.font != font { label.font = font }
        if label.stringValue != item.text { label.stringValue = item.text }
        label.maximumNumberOfLines = wraps ? 0 : 1
        label.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = !wraps
        label.cell?.wraps = wraps
        glyph.symbolName = item.symbol
        glyphHelp.toolTip = item.help
        glyphHelp.describeForAccessibility(item.help)
        textHelp.toolTip = contentHelp
    }

    struct Metrics {
        /// The label's size and its first baseline from the row's top, and the row's height.
        var labelSize: CGSize
        var labelTop: CGFloat
        var baseline: CGFloat
        var glyphTop: CGFloat
        var height: CGFloat
    }

    private func textSize(width: CGFloat) -> CGSize {
        guard let cell = label.cell else { return .zero }
        if wraps {
            // The cell keeps 2 pt of padding on each side inside its bounds (the label's frame
            // is the text's width plus 4), so it wraps at the column's width plus that; at the
            // column's own width it broke a line 4 pt early. The size returned is the text's.
            let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(0, width) + 4, height: .greatestFiniteMagnitude))
            return CGSize(width: size.width - 4, height: size.height)
        }
        let natural = label.intrinsicContentSize
        return CGSize(width: min(natural.width, max(0, width)), height: natural.height)
    }

    func metrics(width: CGFloat) -> Metrics {
        let textWidth = width - RSBGlyphRowView.glyphColumn - RSBGlyphRowView.glyphGap
        let size = textSize(width: textWidth)
        // SwiftUI's unrounded measures. SwiftUI rounds the row's frame where it places it, and the row rounds its parts the same way (see RSBGlyphRowView.layout).
        let text = italic ? Self.italicLayout : Self.textLayout
        let lines = max(1, (size.height / label.intrinsicContentSize.height).rounded())
        let textHeight = text.height + (lines - 1) * text.lineHeight
        let glyphLayout = glyph.layout
        // The taller glyph above the baseline sets the baseline (unless the glyph overhangs). The deeper one below sets the height.
        let baseline = glyphOverhangs ? text.baseline : max(text.baseline, glyphLayout.baseline)
        let labelTop = baseline - text.baseline
        let glyphTop = baseline - glyph.heightAboveBaseline
        let height = max(labelTop + textHeight, baseline - glyphLayout.baseline + glyphLayout.height)
        return Metrics(labelSize: size, labelTop: labelTop, baseline: baseline, glyphTop: glyphTop, height: height)
    }

    func layout(x: CGFloat, width: CGFloat, baseline: CGFloat, rowHeight: CGFloat, scale: CGFloat, originY: CGFloat) {
        // Rounded to the window's pixels. `originY` is the row's top in flipped window space, so each part lands where SwiftUI would put it.
        func pixel(_ v: CGFloat) -> CGFloat { ((originY + v) * scale + 0.5).rounded(.down) / scale - originY }
        let m = metrics(width: width)
        let shift = baseline - m.baseline
        let textX = x + RSBGlyphRowView.glyphColumn + RSBGlyphRowView.glyphGap
        label.frame = NSRect(x: textX - 2, y: pixel(m.labelTop + shift),
                             width: m.labelSize.width + 4, height: m.labelSize.height)
        glyph.frame = NSRect(x: x, y: pixel(m.glyphTop + shift), width: RSBGlyphRowView.glyphColumn, height: glyph.imageHeight)
        glyphHelp.frame = glyph.frame
        textHelp.frame = NSRect(x: textX, y: 0, width: max(0, x + width - textX), height: rowHeight)
    }
}

/// A glyph line's symbol at 11 pt, secondary, centered in its column on the alignment
/// rectangle's width, its baseline (the alignment rectangle's bottom) on the text's.
final class RSBBaselineGlyphView: NSView {
    private static var images: [String: NSImage] = [:]
    /// Keyed by symbol and display scale. SwiftUI rounds symbol layout to the pixel, so a symbol can differ by half a point between 1x and 2x.
    private static var layouts: [String: SwiftUIVerticalMetrics] = [:]

    var symbolName: String? {
        didSet {
            guard symbolName != oldValue else { return }
            image = symbolName.flatMap { name in
                if let cached = Self.images[name] { return cached }
                let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
                Self.images[name] = image
                return image
            }
            needsDisplay = true
        }
    }
    private var image: NSImage?

    /// The height and baseline SwiftUI gives the symbol on this view's display, which sets the row's height. Outside a window, the main screen's scale is used.
    var layout: SwiftUIVerticalMetrics {
        guard let name = symbolName, image != nil else { return .zero }
        let scale = unsafe window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let key = "\(name)@\(scale)"
        if let cached = Self.layouts[key] { return cached }
        let layout = SwiftUIVerticalMetrics.measure(Image(systemName: name).font(.system(size: 11)), scale: scale)
        Self.layouts[key] = layout
        return layout
    }

    var imageHeight: CGFloat { image?.size.height ?? 0 }
    var heightAboveBaseline: CGFloat { (image?.size.height ?? 0) - (image?.alignmentRect.minY ?? 0) }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let scale = unsafe window?.backingScaleFactor ?? 2
        func pixel(_ v: CGFloat) -> CGFloat { (v * scale + 0.5).rounded(.down) / scale }
        let align = image.alignmentRect
        let rect = NSRect(x: pixel((bounds.width - align.width) / 2) - align.minX, y: 0,
                          width: image.size.width, height: image.size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.secondaryLabelColor.set()
        rect.fill(using: .sourceIn)
    }
}

/// A view's height and first baseline as SwiftUI lays it out, unrounded, read through a Layout that records them.
/// AppKit's measures (an NSImage's size, a text field's line height) differ slightly, so rows placed by them land half a point off.
struct SwiftUIVerticalMetrics {
    var height: CGFloat
    var baseline: CGFloat
    /// The step from one line to the next, for text.
    var lineHeight: CGFloat = 0

    static let zero = SwiftUIVerticalMetrics(height: 0, baseline: 0)

    /// Written by the probe's layout pass inside `measure` and read right after it, on the
    /// main actor both times; Layout's Sendable requirement cannot see that.
    private final class Sink: @unchecked Sendable { var metrics = SwiftUIVerticalMetrics.zero }

    private struct Probe: Layout {
        let sink: Sink
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let view = subviews.first else { return .zero }
            let d = view.dimensions(in: .unspecified)
            sink.metrics = SwiftUIVerticalMetrics(height: d.height, baseline: d[.firstTextBaseline])
            return CGSize(width: d.width, height: d.height)
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: .unspecified)
        }
    }

    /// Measured at the display's scale. SwiftUI rounds symbol layout to the pixel, so at 1x every symbol measure comes back in whole points. Text measures the same at 1x and 2x.
    @MainActor static func measure<V: View>(_ view: V, scale: CGFloat? = nil) -> SwiftUIVerticalMetrics {
        let sink = Sink()
        let renderer = ImageRenderer(content: Probe(sink: sink) { view })
        renderer.scale = scale ?? NSScreen.main?.backingScaleFactor ?? 2
        _ = renderer.cgImage
        return sink.metrics
    }

    @MainActor static func measure<V: View, W: View>(_ view: V, twoLines: W) -> SwiftUIVerticalMetrics {
        var metrics = measure(view)
        metrics.lineHeight = measure(twoLines).height - metrics.height
        return metrics
    }
}

#if DEBUG
/// What RSBGlyphRowListView does per card build, for `rsb-cards` (99.20): layout passes, time spent in them, and rows made.
@MainActor enum CardRowsProbe {
    static var layouts = 0, rowsCreated = 0
    static var layoutTime: CFTimeInterval = 0
    static var rowLayouts = 0, labelMoves = 0
    static var rowLayoutTime: CFTimeInterval = 0
    static func reset() {
        layouts = 0; rowsCreated = 0; rowLayouts = 0; labelMoves = 0; rowLayoutTime = 0; layoutTime = 0
    }
}
#endif

// MARK: - Card Stack
//
// The whole card stack as one AppKit view. It draws each group's plate, outline, and shadow, and each
// release's header band, badge row, dividers, and glyph rows (RSBGlyphRowListView), from RSBReleaseCardBody's values.
// It replaced SwiftUI cards that drew the same result. The AppKit version updates faster, because SwiftUI
// re-measures the whole tab each time it inserts a card, and most of a SwiftUI card's cost was selectable text.
//
// One acquisition per plate. A combo-pack parent and its children share it, giving a double-height card, or
// a triple-height one for a "Combo-pack (dual BD)" pack. The parent opens with a format-tinted band. Each child
// carries a faint wash and opens with a divider, since its meaning comes from the parent above. The edge follows
// the FilmSheet reorderable lists: an outline that wraps the top and fades toward the bottom, with the lower edge
// carried by a shadow (see RSBCardChrome).
//
// Matching SwiftUI takes a few rules, kept for later changes. Label frames are the text width + 4 at x − 2,
// left-aligned and placed by hand, since a self-centering NSTextField starts the line between pixels. Text and
// symbol heights come from SwiftUIVerticalMetrics at the display's scale. Child frames round to the window's
// pixels (PixelSnap). A view's own shadow goes through NSView.shadow (RSBViewShadow), and a sublayer's takes
// SwiftUI's radius.
fileprivate struct RSBCardStack: NSViewRepresentable {
    let groups: [RSBReleaseCardGroup]
    /// Passed so a day change updates the cards ("Releases on" becomes "Released on"). The stack also keys its no-change check on it.
    let today: Date

    func makeNSView(context: Context) -> RSBCardStackView { RSBCardStackView() }

    func updateNSView(_ view: RSBCardStackView, context: Context) {
        let animated = context.transaction.animation != nil && !context.transaction.disablesAnimations
        view.update(groups: groups, today: today, animated: animated)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RSBCardStackView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 268
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

/// SwiftUI's measures for the card's text and dividers, read once (see SwiftUIVerticalMetrics).
@MainActor
private enum RSBCardMetrics {
    static let badgeText = SwiftUIVerticalMetrics.measure(Text("2023").font(.system(size: 11, weight: .heavy)))
    static let studioText = SwiftUIVerticalMetrics.measure(Text("Xg").font(.system(size: 12, weight: .semibold)))
    static let bannerText = SwiftUIVerticalMetrics.measure(Text("Xg").font(.system(size: 10, weight: .medium)))
    static let divider = SwiftUIVerticalMetrics.measure(Divider())
    static let headerHeight = max(badgeText.height + 2, studioText.height, RSBCardChrome.trailingGlyphHeight)
    static let childHeaderHeight = max(badgeText.height + 2, bannerText.height)

    static func color(_ color: Color) -> NSColor { NSColor(color) }
}

/// Rounds a container's child frames where the window's pixels are, as SwiftUI rounds them.
@MainActor
private struct PixelSnap {
    let originY: CGFloat
    let scale: CGFloat
    init(_ view: NSView) {
        scale = unsafe view.window?.backingScaleFactor ?? 2
        let windowHeight = unsafe view.window?.contentView?.bounds.height ?? 0
        originY = windowHeight - view.convert(NSPoint.zero, to: nil).y
    }
    func y(_ v: CGFloat) -> CGFloat { ((originY + v) * scale + 0.5).rounded(.down) / scale - originY }
    func x(_ v: CGFloat) -> CGFloat { (v * scale + 0.5).rounded(.down) / scale }
    func rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
        let top = self.y(y), left = self.x(x)
        return NSRect(x: left, y: top, width: self.x(x + width) - left, height: self.y(y + height) - top)
    }
}

final class RSBCardStackView: NSView {
    /// The cards shown, top to bottom, each with its group.
    private var visible: [(id: UUID, view: RSBCardGroupView)] = []
    /// Cards fading out after a filter change, still at their old frames. A group that returns before its card is gone reuses that card, as SwiftUI does.
    private var leaving: [(id: UUID, view: RSBCardGroupView)] = []
    private var pool: [RSBCardGroupView] = []
    private var fadeToken = 0
    /// What the cards were last drawn from. The groups and the day are all a card reads, so an update that repeats both changes nothing.
    private var drawn: (groups: [RSBReleaseCardGroup], today: Date)?

    override var isFlipped: Bool { true }

    private func takeView() -> RSBCardGroupView {
        if let view = pool.popLast() {
            view.isHidden = false
            view.alphaValue = 1
            return view
        }
        let view = RSBCardGroupView()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        return view
    }

    private func retire(_ view: RSBCardGroupView) {
        view.layer?.removeAllAnimations()
        view.isHidden = true
        view.alphaValue = 1
        pool.append(view)
    }

    /// `animated` is set for a filter change, which RTabReleasesContent's `.animation` scopes to the filter. Anything else, such as a new film or an edited release, swaps in at once.
    fileprivate func update(groups: [RSBReleaseCardGroup], today: Date, animated: Bool) {
        if let drawn, drawn.groups == groups, drawn.today == today { return }
        drawn = (groups, today)
        guard animated, unsafe window != nil, bounds.width > 0 else {
            let gone = leaving
            leaving = []
            for entry in gone { retire(entry.view) }
            // Re-point the cards in place, by position: a new film's groups are all new.
            var views = visible.map(\.view)
            while views.count > groups.count { retire(views.removeLast()) }
            while views.count < groups.count { views.append(takeView()) }
            for (view, group) in zip(views, groups) {
                view.layer?.removeAllAnimations()
                view.configure(group)
            }
            visible = zip(groups, views).map { ($0.id, $1) }
            needsLayout = true
            return
        }
        // Matches SwiftUI's ForEach, by identity. A card that stays moves to its new place. A card that goes fades out where it was.
        // A new card fades in where it lands. All of this runs on the filter's spring (`.smooth(duration: 0.3)`).
        var byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.view) })
        var next: [(id: UUID, view: RSBCardGroupView, inserted: Bool)] = []
        for group in groups {
            if let view = byID.removeValue(forKey: group.id) {
                view.configure(group)
                next.append((group.id, view, false))
            } else if let i = leaving.firstIndex(where: { $0.id == group.id }) {
                // Coming back mid-fade: fade it in again from where it is.
                let view = leaving.remove(at: i).view
                let opacity = view.layer?.presentation()?.opacity ?? 0
                view.alphaValue = 1
                view.layer?.add(spring("opacity", from: opacity, to: 1), forKey: "fade")
                view.configure(group)
                next.append((group.id, view, false))
            } else {
                let view = takeView()
                view.configure(group)
                next.append((group.id, view, true))
            }
        }
        visible = next.map { ($0.id, $0.view) }
        let frames = targetFrames(width: bounds.width)
        for (entry, frame) in zip(next, frames) {
            let view = entry.view
            if entry.inserted {
                view.frame = frame
                view.alphaValue = 1
                view.layer?.add(spring("opacity", from: 0, to: 1), forKey: "fade")
            } else {
                let from = view.layer?.presentation()?.position ?? view.layer?.position ?? .zero
                view.frame = frame
                if let to = view.layer?.position, to != from {
                    view.layer?.add(spring("position", from: NSValue(point: from), to: NSValue(point: to)), forKey: "move")
                }
            }
        }
        for (id, view) in byID {
            leaving.append((id, view))
            // From its current opacity: it may still be fading in.
            let opacity = view.layer?.presentation()?.opacity ?? 1
            view.alphaValue = 0
            let fade = spring("opacity", from: opacity, to: 0)
            CATransaction.begin()
            // Only this fade's own finish retires the card: one replaced or removed early
            // (the card came back, or the stack was re-pointed) also calls this.
            // (The layer keeps a copy of the animation, so it is told apart by a token.)
            fadeToken += 1
            let token = fadeToken
            fade.setValue(token, forKey: "token")
            CATransaction.setCompletionBlock { [weak self, weak view] in
                guard let self, let view,
                      (view.layer?.animation(forKey: "fade")?.value(forKey: "token") as? Int).map({ $0 == token }) ?? true,
                      let i = self.leaving.firstIndex(where: { $0.view === view }) else { return }
                self.leaving.remove(at: i)
                self.retire(view)
            }
            view.layer?.add(fade, forKey: "fade")
            CATransaction.commit()
        }
    }

    /// The filter's spring. SwiftUI's `.smooth(duration: 0.3)` is a spring with a 0.3 s perceptual duration and no bounce, which this initializer takes.
    ///
    /// Started two display frames late. Core Animation times an animation from the frame it is shown in, while SwiftUI times it from its update,
    /// which reaches the screen two frames later. Without the delay, the AppKit cards led SwiftUI's on the same curve (`releases-filter` checks this).
    private func spring(_ keyPath: String, from: Any, to: Any) -> CASpringAnimation {
        let animation = CASpringAnimation(perceptualDuration: 0.3, bounce: 0)
        animation.keyPath = keyPath
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        let fps = Double(unsafe window?.screen?.maximumFramesPerSecond ?? 60)
        animation.beginTime = CACurrentMediaTime() + 2 / max(fps, 1)
        animation.fillMode = .backwards
        return animation
    }

    #if DEBUG
    /// For `releases-filter`'s burst checks (99.56): cards shown, cards fading out, the lowest opacity a shown card is drawn at, and shown cards that are hidden or transparent.
    var debugState: (shown: Int, leaving: Int, minOpacity: Float, drawnHidden: Int) {
        let opacities = visible.map { $0.view.layer?.presentation()?.opacity ?? $0.view.layer?.opacity ?? 1 }
        let hidden = visible.filter { $0.view.isHidden || $0.view.alphaValue < 1 }.count
        return (visible.count, leaving.count, opacities.min() ?? 1, hidden)
    }
    #endif

    func height(forWidth width: CGFloat) -> CGFloat {
        let heights = visible.map { $0.view.height(forWidth: width) }
        return heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * RSBCardChrome.sidebarInset
    }

    private func targetFrames(width: CGFloat) -> [NSRect] {
        let snap = PixelSnap(self)
        var y: CGFloat = 0
        return visible.map { entry in
            let h = entry.view.height(forWidth: width)
            defer { y += h + RSBCardChrome.sidebarInset }
            return snap.rect(x: 0, y: y, width: width, height: h)
        }
    }

    /// Moved to a display of another scale, or into a window at all. Frames were rounded for the old pixels, and symbol measures, and so the stack's height, can differ by scale.
    /// Relayout everything and have SwiftUI ask for the height again.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidateForPixels()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if unsafe window != nil { invalidateForPixels() }
    }

    private func invalidateForPixels() {
        var pending: [NSView] = [self]
        while let view = pending.popLast() {
            view.needsLayout = true
            pending.append(contentsOf: view.subviews)
        }
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        for (entry, frame) in zip(visible, targetFrames(width: bounds.width)) where entry.view.frame != frame {
            entry.view.frame = frame
        }
    }
}

/// One acquisition's plate: the release bodies stacked inside the clipped, outlined,
/// shadowed rounded rectangle.
fileprivate final class RSBCardGroupView: NSView {
    private let shadowLayer = CAShapeLayer()
    private let content = RSBFlippedView()
    private let borderLayer = CAGradientLayer()
    private let borderMask = CAShapeLayer()
    private var bodies: [RSBCardBodyView] = []
    private var count = 0

    override var isFlipped: Bool { true }

    /// A new width re-wraps the rows and re-rounds every frame below: lay out again.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        shadowLayer.shadowOpacity = Float(RSBCardChrome.shadowOpacity)
        shadowLayer.shadowRadius = RSBCardChrome.shadowRadius
        shadowLayer.shadowOffset = CGSize(width: 0, height: RSBCardChrome.shadowOffsetY)
        shadowLayer.shadowColor = NSColor.black.cgColor
        layer?.addSublayer(shadowLayer)
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.cornerRadius = RSBCardChrome.cardCornerRadius
        content.layer?.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        borderLayer.startPoint = CGPoint(x: 0.5, y: 0)
        borderLayer.endPoint = CGPoint(x: 0.5, y: 1)
        borderLayer.locations = [0, NSNumber(value: RSBCardChrome.borderFadeStart), 1]
        borderMask.fillColor = nil
        borderMask.strokeColor = NSColor.black.cgColor
        borderMask.lineWidth = RSBCardChrome.borderWidth
        borderLayer.mask = borderMask
        borderLayer.zPosition = 10
        layer?.addSublayer(borderLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(_ group: RSBReleaseCardGroup) {
        while bodies.count < group.releases.count {
            let body = RSBCardBodyView()
            body.translatesAutoresizingMaskIntoConstraints = false
            bodies.append(body)
            content.addSubview(body)
        }
        let children = max(0, group.releases.count - 1)
        for (i, body) in bodies.enumerated() {
            body.isHidden = i >= group.releases.count
            guard i < group.releases.count else { continue }
            let banner: String? = i == 0 ? nil
                : (children > 1 ? "Included in Combo-pack (\(i) of \(children))" : "Included in Combo-pack")
            body.configure(RSBReleaseCardBody(model: group.releases[i], attachedChildBanner: banner))
        }
        count = group.releases.count
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        bodies.prefix(count).map { $0.height(forWidth: width) }.reduce(0, +)
    }

    override func layout() {
        super.layout()
        let b = bounds
        let path = RoundedRectangle(cornerRadius: RSBCardChrome.cardCornerRadius, style: .continuous).path(in: b).cgPath
        shadowLayer.frame = b
        shadowLayer.path = path
        shadowLayer.shadowPath = path
        content.frame = b
        borderLayer.frame = b
        borderMask.frame = b
        let inset = RSBCardChrome.borderWidth / 2
        borderMask.path = RoundedRectangle(cornerRadius: RSBCardChrome.cardCornerRadius - inset, style: .continuous)
            .path(in: b.insetBy(dx: inset, dy: inset)).cgPath
        let snap = PixelSnap(content)
        var y: CGFloat = 0
        for body in bodies.prefix(count) {
            let h = body.height(forWidth: b.width)
            body.frame = snap.rect(x: 0, y: y, width: b.width, height: h)
            y += h
        }
    }

    override func updateLayer() { super.updateLayer(); applyColors() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            shadowLayer.fillColor = NSColor.controlBackgroundColor.cgColor
            let edge = NSColor.separatorColor
            let c = edge.withAlphaComponent(edge.alphaComponent * RSBCardChrome.borderOpacity).cgColor
            borderLayer.colors = [c, c, edge.withAlphaComponent(0).cgColor]
        }
    }
}

/// A layer-drawn capsule or circle with the card's badge shadow, optionally dashed.
final class RSBShapeView: NSView {
    enum Style { case fill(NSColor), stroke(NSColor, dashed: Bool) }
    private let shape = CAShapeLayer()
    /// A rounded rectangle of this radius instead of a capsule (the format badge).
    var cornerRadius: CGFloat? { didSet { needsLayout = true } }
    var style: Style = .fill(.gray) { didSet { needsLayout = true; applyColors() } }
    var shadowed = true { didSet { shape.shadowOpacity = shadowed ? Float(RSBCardChrome.glyphShadowOpacity) : 0 } }
    /// Draws only the part right of this x (the upcoming connector's mask).
    var visibleFromX: CGFloat = 0 { didSet { needsLayout = true } }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowRadius = RSBCardChrome.glyphShadowRadius
        shape.shadowOffset = CGSize(width: 0, height: RSBCardChrome.glyphShadowOffsetY)
        shape.shadowOpacity = Float(RSBCardChrome.glyphShadowOpacity)
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layout() {
        super.layout()
        shape.frame = bounds
        switch style {
        case .fill:
            let path = (cornerRadius.map { RoundedRectangle(cornerRadius: $0, style: .continuous).path(in: bounds) }
                        ?? Capsule(style: .continuous).path(in: bounds)).cgPath
            shape.path = path
            shape.shadowPath = path
            shape.lineDashPattern = nil
            shape.mask = nil
        case .stroke(_, let dashed):
            shape.path = Capsule(style: .continuous).path(in: bounds.insetBy(dx: 0.5, dy: 0.5)).cgPath
            shape.shadowPath = nil
            shape.lineWidth = 1
            shape.lineDashPattern = dashed ? [3, 2] : nil
            if visibleFromX > 0 {
                let mask = CALayer()
                mask.backgroundColor = NSColor.black.cgColor
                mask.frame = CGRect(x: visibleFromX, y: -2, width: max(0, bounds.width - visibleFromX), height: bounds.height + 4)
                shape.mask = mask
            } else {
                shape.mask = nil
            }
        }
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch style {
            case .fill(let color):
                shape.fillColor = color.cgColor
                shape.strokeColor = nil
            case .stroke(let color, _):
                shape.fillColor = nil
                shape.strokeColor = color.cgColor
            }
        }
    }
}

/// A card symbol: FramesGlyphView's placement, with an optional shadow under the glyph, as `.shadow` puts under an Image.
final class RSBSymbolView: FramesGlyphView {
    func setShadow(opacity: Double, radius: CGFloat, offsetY: CGFloat) {
        wantsLayer = true
        shadow = RSBViewShadow.make(opacity: opacity, radius: radius, offsetY: offsetY)
    }

    func set(_ name: String, size: CGFloat, weight: NSFont.Weight) {
        pointSize = size
        self.weight = weight
        symbolName = name
    }
}

/// One release's half of a card: the header band, badge row, glyph rows, and dividers, as RSBReleaseCardBody lays them out.
fileprivate final class RSBCardBodyView: NSView {
    private var body: RSBReleaseCardBody?

    private let wash = NSView()
    private let band = NSView()
    private let topDivider = NSView()
    private let formatPlate = RSBShapeView()
    private let formatLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let purchaseCircle = RSBShapeView()
    private let purchaseGlyph = RSBSymbolView()
    private let purchaseHelp = NSView()

    private let yearFill = RSBShapeView()
    private let yearConnector = RSBShapeView()
    private let yearLabel = NSTextField(labelWithString: "")
    private let baseYearLabel = NSTextField(labelWithString: "")
    private let yearHelp = NSView()
    private let regionPill = RSBShapeView()
    private let regionCircle = RSBShapeView()
    private let regionChar = NSTextField(labelWithString: "")
    /// Carries the letter's ink shadow (see RSBViewShadow).
    private let regionCharShadow = RSBFlippedView()
    private let regionGlyph = RSBSymbolView()
    private let regionHelp = NSView()
    private let originLabel = NSTextField(labelWithString: "")

    private let detailsDivider = NSView()
    private let acquisitionDivider = NSView()
    private let mainRows = RSBGlyphRowListView()
    private let lowerRows = RSBGlyphRowListView()
    private var splitsAcquisition = false

    override var isFlipped: Bool { true }

    /// A new width re-wraps the rows and re-rounds every frame, so lay out again.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    init() {
        super.init(frame: .zero)
        let all: [NSView] = [wash, band, topDivider, formatPlate, formatLabel, titleLabel, purchaseCircle, purchaseGlyph,
                             purchaseHelp, yearConnector, yearFill, yearLabel, baseYearLabel, yearHelp, regionPill,
                             regionCircle, regionCharShadow, regionGlyph, regionHelp, originLabel, detailsDivider,
                             acquisitionDivider, mainRows, lowerRows]
        for v in all {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        for v in [wash, band, topDivider, detailsDivider, acquisitionDivider] { v.wantsLayer = true }
        formatPlate.style = .fill(RSBCardMetrics.color(RSBCardChrome.badgePlate))
        formatPlate.cornerRadius = RSBCardChrome.badgeCornerRadius
        formatLabel.font = .systemFont(ofSize: 11, weight: .heavy)
        formatLabel.textColor = RSBCardMetrics.color(RSBCardChrome.badgeInk)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        purchaseCircle.style = .fill(RSBCardMetrics.color(RSBCardChrome.checkmarkGreen))
        purchaseGlyph.tint = .white
        yearFill.style = .fill(RSBCardMetrics.color(RSBCardChrome.badgeFill))
        for l in [yearLabel, baseYearLabel] { l.font = .systemFont(ofSize: 11, weight: .heavy) }
        regionPill.style = .fill(RSBCardMetrics.color(RSBCardChrome.badgeFill))
        regionChar.font = .systemFont(ofSize: 10, weight: .semibold)
        regionChar.translatesAutoresizingMaskIntoConstraints = false
        regionCharShadow.addSubview(regionChar)
        regionCharShadow.wantsLayer = true
        originLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        originLabel.textColor = .white
        originLabel.lineBreakMode = .byTruncatingTail
        originLabel.cell?.truncatesLastVisibleLine = true
        regionGlyph.tint = .white
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(_ body: RSBReleaseCardBody) {
        self.body = body
        let model = body.model
        let child = body.isAttachedChild
        wash.isHidden = !child
        band.isHidden = child
        topDivider.isHidden = !child
        detailsDivider.isHidden = !child
        formatLabel.stringValue = model.format
        if let banner = body.attachedChildBanner {
            titleLabel.stringValue = banner
            titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
            titleLabel.textColor = .secondaryLabelColor
        } else {
            titleLabel.stringValue = model.studio.isEmpty ? "Unknown Studio" : model.studio
            titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            titleLabel.textColor = NSColor(body.titleColor)
        }
        purchaseCircle.isHidden = child || !model.purchased
        purchaseGlyph.isHidden = child
        purchaseHelp.isHidden = child
        if model.purchased {
            purchaseGlyph.set("checkmark", size: 18 * 8 / 14, weight: .bold)
            purchaseGlyph.centersVectorBoundsHorizontally = true
            purchaseGlyph.setShadow(opacity: 0.5, radius: 0.5, offsetY: 0.5)
        } else {
            purchaseGlyph.set("circle.dashed", size: 16, weight: .semibold)
            purchaseGlyph.centersVectorBoundsHorizontally = false
            purchaseGlyph.setShadow(opacity: RSBCardChrome.glyphShadowOpacity, radius: RSBCardChrome.glyphShadowRadius,
                                    offsetY: RSBCardChrome.glyphShadowOffsetY)
        }
        purchaseCircle.shadowed = true
        purchaseHelp.toolTip = model.purchased ? "Purchased" : "Not purchased"
        purchaseHelp.describeForAccessibility(child ? nil : purchaseHelp.toolTip)

        // Badge row.
        let showsBadges = body.hasBadgeRow
        let today = body.today
        let upcoming = model.releaseDate?.isUpcoming(today: today) ?? false
        let hasYear = showsBadges && !model.releaseYear.isEmpty
        let hasBase = !model.originalReleaseYear.isEmpty
        for v in [yearFill, yearLabel, yearHelp] as [NSView] { v.isHidden = !hasYear }
        yearFill.style = upcoming ? .stroke(.tertiaryLabelColor, dashed: true) : .fill(RSBCardMetrics.color(RSBCardChrome.badgeFill))
        yearFill.shadowed = !upcoming
        yearLabel.stringValue = model.releaseYear
        yearLabel.textColor = upcoming ? .labelColor : .white
        baseYearLabel.stringValue = model.originalReleaseYear
        baseYearLabel.textColor = .labelColor
        baseYearLabel.isHidden = !hasYear || !hasBase
        yearConnector.isHidden = !hasYear || !hasBase
        yearConnector.style = .stroke(upcoming ? .tertiaryLabelColor : RSBCardMetrics.color(RSBCardChrome.badgeFill), dashed: upcoming)
        yearConnector.shadowed = !upcoming
        let releaseHelp = model.releaseDate.map { RSBReleaseCard.releasePhrase($0, today: today) } ?? "Release year \(model.releaseYear)"
        yearHelp.toolTip = hasBase ? "\(releaseHelp); original release \(model.originalReleaseYear)" : releaseHelp
        yearLabel.setAccessibilityHelp(yearHelp.toolTip)

        let hasRegion = showsBadges && (model.regionIndicator != nil || !model.nationalOrigin.isEmpty)
        for v in [regionPill, originLabel, regionHelp] as [NSView] { v.isHidden = !hasRegion }
        regionCircle.isHidden = true
        regionChar.isHidden = true
        regionGlyph.isHidden = !hasRegion
        switch model.regionIndicator {
        case let .character(label, playable)?:
            regionCircle.isHidden = !hasRegion
            regionChar.isHidden = !hasRegion
            regionGlyph.isHidden = true
            regionCircle.style = .fill(NSColor(RSBRegionBadge.fill(playable: playable)))
            regionChar.stringValue = label
            regionChar.textColor = NSColor(RSBRegionBadge.ink(playable: playable))
            regionCharShadow.shadow = RSBRegionBadge.inkNeedsShadow(playable: playable)
                ? RSBViewShadow.make(opacity: 0.5, radius: 0.5, offsetY: 0.5) : nil
        case .globe?:
            regionGlyph.set("globe", size: RSBCardChrome.regionBadgeDiameter, weight: .regular)
        case let .raw(value)?:
            regionGlyph.isHidden = true
            regionChar.isHidden = !hasRegion
            regionChar.stringValue = value
            regionChar.textColor = .white
            regionCharShadow.shadow = nil
        case nil:
            regionGlyph.set("circle.dashed", size: 14, weight: .regular)
        }
        originLabel.stringValue = model.nationalOrigin
        regionHelp.toolTip = model.regionLabel.isEmpty ? "No region lock recorded" : model.regionLabel
        regionHelp.describeForAccessibility(hasRegion ? regionHelp.toolTip : nil)

        // Rows.
        splitsAcquisition = !child && !body.acquisitionBlockIsEmpty
        mainRows.update(rows: splitsAcquisition ? body.mainRows : body.mainRows + body.notesRow)
        lowerRows.update(rows: splitsAcquisition ? body.acquisitionRows + body.notesRow : [])
        lowerRows.isHidden = !splitsAcquisition
        acquisitionDivider.isHidden = !splitsAcquisition
        needsLayout = true
        applyColors()
    }

    /// The details stack's items, top to bottom, with their heights.
    private enum Item { case divider(NSView), badges, rows(RSBGlyphRowListView) }

    private func items() -> [Item] {
        guard let body else { return [] }
        var items: [Item] = []
        if body.isAttachedChild { items.append(.divider(detailsDivider)) }
        if !yearFill.isHidden || !regionPill.isHidden { items.append(.badges) }
        items.append(.rows(mainRows))
        if splitsAcquisition {
            items.append(.divider(acquisitionDivider))
            items.append(.rows(lowerRows))
        }
        return items
    }

    private func itemHeight(_ item: Item, width: CGFloat) -> CGFloat {
        switch item {
        case .divider: return RSBCardMetrics.divider.height
        case .badges: return RSBCardChrome.badgeRowHeight
        case .rows(let list): return list.height(forWidth: width)
        }
    }

    private var headerBlockHeight: CGFloat {
        guard let body else { return 0 }
        return (body.isAttachedChild ? RSBCardMetrics.childHeaderHeight : RSBCardMetrics.headerHeight) + 8
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let body else { return 0 }
        let inner = width - 2 * RSBCardChrome.contentPadding
        let list = items()
        let details = list.map { itemHeight($0, width: inner) }.reduce(0, +) + CGFloat(max(0, list.count - 1)) * 8
        let top: CGFloat = body.isAttachedChild ? 0 : RSBCardChrome.contentTopPadding
        let lead: CGFloat = body.isAttachedChild ? RSBCardMetrics.divider.height : 0
        return lead + headerBlockHeight + top + details + RSBCardChrome.contentPadding
    }

    override func layout() {
        super.layout()
        guard let body else { return }
        let snap = PixelSnap(self)
        let w = bounds.width
        let pad = RSBCardChrome.contentPadding
        // Labels are left-aligned and placed here, centered ones included. A text field that centers its own text starts
        // the line between pixels. SwiftUI rounds the text frame to the pixel, and this matches it.
        func label(_ field: NSTextField, x: CGFloat, width: CGFloat, centerY: CGFloat, height: CGFloat, align: CGFloat = 0) {
            let natural = field.intrinsicContentSize.width
            let textWidth = min(natural, width)
            field.frame = snap.rect(x: x + (width - textWidth) * align - 2, y: centerY - height / 2,
                                    width: textWidth + 4, height: height)
        }
        wash.frame = bounds
        var y: CGFloat = 0
        if body.isAttachedChild {
            topDivider.frame = snap.rect(x: 0, y: 0, width: w, height: RSBCardMetrics.divider.height)
            y += RSBCardMetrics.divider.height
        }
        // Header band.
        let headerH = headerBlockHeight
        band.frame = snap.rect(x: 0, y: y, width: w, height: headerH)
        let mid = y + headerH / 2
        let badgeH = RSBCardMetrics.badgeText.height + 2
        formatPlate.frame = snap.rect(x: pad, y: mid - badgeH / 2, width: 52, height: badgeH)
        label(formatLabel, x: pad, width: 52, centerY: mid, height: RSBCardMetrics.badgeText.height, align: 0.5)
        let titleX = pad + 52 + 8
        if body.isAttachedChild {
            label(titleLabel, x: titleX, width: w - titleX - pad, centerY: mid, height: RSBCardMetrics.bannerText.height)
        } else {
            let glyphX = w - pad - RSBCardChrome.trailingGlyphWidth
            label(titleLabel, x: titleX, width: glyphX - 8 - titleX, centerY: mid, height: RSBCardMetrics.studioText.height)
            let glyphFrame = snap.rect(x: glyphX, y: mid - RSBCardChrome.trailingGlyphHeight / 2,
                                       width: RSBCardChrome.trailingGlyphWidth, height: RSBCardChrome.trailingGlyphHeight)
            purchaseHelp.frame = glyphFrame
            purchaseCircle.frame = snap.rect(x: glyphX + (RSBCardChrome.trailingGlyphWidth - 18) / 2, y: mid - 9, width: 18, height: 18)
            // The checkmark centers on its circle, as the summary table's symbolBadge does. The dashed circle sits on
            // the slot. Both share a center but round from different origins.
            purchaseGlyph.frame = body.model.purchased ? purchaseCircle.frame : glyphFrame
        }
        y += headerH
        // Details.
        if !body.isAttachedChild { y += RSBCardChrome.contentTopPadding }
        let inner = w - 2 * pad
        for (i, item) in items().enumerated() {
            if i > 0 { y += 8 }
            let h = itemHeight(item, width: inner)
            switch item {
            case .divider(let view):
                view.frame = snap.rect(x: pad, y: y, width: inner, height: h)
            case .rows(let list):
                list.frame = snap.rect(x: pad, y: y, width: inner, height: h)
            case .badges:
                // Two equal columns, unless a badge's minimum (the year's two 48 pt compartments, the pill's 116 pt)
                // is wider than its half. Then it takes its minimum and the other column takes the rest, as at a legacy scroller's width.
                let available = inner - 10
                let yearMinimum: CGFloat = yearFill.isHidden ? 0 : 2 * 48 + 3
                let pillMinimum: CGFloat = regionPill.isHidden ? 0 : 116
                var yearColumn = available / 2
                if pillMinimum > available / 2 { yearColumn = max(yearMinimum, available - pillMinimum) }
                else if yearMinimum > available / 2 { yearColumn = yearMinimum }
                let pillColumn = max(pillMinimum, available - yearColumn)
                let rowMid = y + h / 2
                let compartment = max(48, (yearColumn - 3) / 2)
                yearFill.frame = snap.rect(x: pad, y: y, width: compartment, height: h)
                yearConnector.frame = snap.rect(x: pad, y: y, width: 2 * compartment + 3, height: h)
                yearConnector.visibleFromX = (yearConnector.style.isDashed) ? max(0, compartment - h / 2) : 0
                yearHelp.frame = yearConnector.frame
                label(yearLabel, x: pad, width: compartment, centerY: rowMid, height: RSBCardMetrics.badgeText.height, align: 0.5)
                label(baseYearLabel, x: pad + compartment + 3, width: compartment, centerY: rowMid,
                      height: RSBCardMetrics.badgeText.height, align: 0.5)
                let pillX = pad + yearColumn + 10
                regionPill.frame = snap.rect(x: pillX, y: y, width: pillColumn, height: h)
                let slot = snap.rect(x: pillX + 8, y: rowMid - 7, width: 14, height: 14)
                regionCircle.frame = slot
                regionGlyph.frame = slot
                regionHelp.frame = snap.rect(x: pillX + 8, y: y, width: 14, height: h)
                regionCharShadow.frame = snap.rect(x: pillX + 8, y: y, width: 14, height: h)
                label(regionChar, x: pillX + 8, width: 14, centerY: rowMid, height: RSBCardMetrics.bannerText.height, align: 0.5)
                regionChar.frame = regionChar.frame.offsetBy(dx: -regionCharShadow.frame.minX, dy: -regionCharShadow.frame.minY)
                let originX = pillX + 8 + 14 + 6
                label(originLabel, x: originX, width: pillX + pillColumn - 8 - originX, centerY: rowMid,
                      height: RSBCardMetrics.badgeText.height, align: 0.5)
            }
            y += h
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }

    private func applyColors() {
        guard let body else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            wash.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(RSBCardChrome.childWashOpacity).cgColor
            band.layer?.backgroundColor = NSColor(body.bandTint).cgColor
            for d in [topDivider, detailsDivider, acquisitionDivider] {
                d.layer?.backgroundColor = NSColor.separatorColor.cgColor
            }
        }
    }
}

/// A plain flipped container.
final class RSBFlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension NSView {
    /// Makes the tooltip's box the accessibility element for the glyph under it, named by the tooltip, as SwiftUI does for an Image with `.help`. Nil removes it.
    func describeForAccessibility(_ label: String?) {
        setAccessibilityElement(label != nil)
        setAccessibilityRole(label != nil ? .image : nil)
        setAccessibilityLabel(label)
    }
}

private extension RSBShapeView.Style {
    var isDashed: Bool { if case .stroke(_, true) = self { return true } else { return false } }
}

/// A SwiftUI `.shadow(color: .black.opacity(o), radius: r, y: dy)` for a whole view. AppKit keeps a layer-backed view's
/// layer in step with the view's `shadow`, so a shadow set on that layer directly is overwritten. This goes through the view's
/// property. A shadow on a sublayer the view adds, as RSBShapeView does, is unaffected.
enum RSBViewShadow {
    /// NSShadow's blur radius for a SwiftUI shadow radius. Fitted against SwiftUI's rendering: 2 was closest across 0.5–4
    /// for the checkmark, the dashed circle, and the region letter.
    static let blurScale: CGFloat = 2

    static func make(opacity: Double, radius: CGFloat, offsetY: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(opacity)
        shadow.shadowBlurRadius = radius * blurScale
        // AppKit copies this offset straight onto the view's layer, and a flipped view's layer is
        // geometry-flipped, so positive is down there. Every caller's view is flipped.
        shadow.shadowOffset = NSSize(width: 0, height: offsetY)
        return shadow
    }
}
