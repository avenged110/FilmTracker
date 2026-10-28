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
    var releasesSummaryExpanded: Binding<Bool>

    /// The purchase filter, owned by RightSidebar. It lives there rather than in this tab
    /// because the tab itself does not survive a selection change: an off-screen tab slot
    /// is torn down until the new film's neighbors are armed, and the whole plane goes on
    /// a deselect, so a filter held here was lost and "remember the filter" could not work.
    var purchaseFilter: Binding<RSBPurchaseFilter>

    /// The content is its own view, built INSIDE the scroll view, so the filter's animated
    /// mirror lives in the hosted tree. SidebarScrollView hosts its content in a separate
    /// NSHostingView; state owned out here reaches it as a rootView replacement, which
    /// carries no animation transaction, so a filter change could never animate.
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
    /// here: this value is consumed several times (the empty checks and the card stack),
    /// and as a derived property each read would otherwise repeat the whole sort-and-map.
    private var releaseCardGroups: [RSBReleaseCardGroup] {
        RSBReleaseCardBuilder.buildGroups(from: filteredFilm?.releases ?? [])
    }

    /// RightSidebar's filter, which survives this view being torn down. RightSidebar also
    /// resets it on a selection change unless the remember preference is on.
    var purchaseFilterBinding: Binding<RSBPurchaseFilter>

    /// Which releases the tab shows: a local mirror of `purchaseFilterBinding`, the same
    /// pattern RTabDetailsContent uses for its table expansion. The picker writes the mirror,
    /// so the change animates inside the hosted tree; the mirror is kept in step with
    /// RightSidebar in both directions, and changes arriving from there land unanimated.
    @State private var purchaseFilter: RSBPurchaseFilter

    init(releasesSummaryExpanded: Binding<Bool>, purchaseFilterBinding: Binding<RSBPurchaseFilter>) {
        self.releasesSummaryExpanded = releasesSummaryExpanded
        self.purchaseFilterBinding = purchaseFilterBinding
        _purchaseFilter = State(initialValue: purchaseFilterBinding.wrappedValue)
    }

    /// The scroll view's visible height, for centering the empty states in it.
    @Environment(\.sidebarViewport) private var viewport

    /// The film with its releases narrowed to `purchaseFilter`. Handed to the summary
    /// table through the environment so the table and the cards always show one set.
    /// Filtering on `purchased` alone keeps combo packs whole: `syncComboChildFields`
    /// locks a child's purchased flag to its parent's.
    private var filteredFilm: FilmSnapshot? {
        guard var film, purchaseFilter != .all else { return film }
        film.releases = film.releases.filter { purchaseFilter.includes($0.purchased) }
        return film
    }

    /// Whether the film has any disc release at all, filtered or not. Without one the
    /// filter picker is still drawn, so the placeholder sits where it always does, but
    /// disabled and with no segment selected.
    private var hasDiscReleases: Bool {
        film?.releases.contains { ReleaseFormat(rawValue: $0.format) != nil } ?? false
    }

    var body: some View {
        // Resolved once and passed down; see `releaseCardGroups`.
        let groups = releaseCardGroups
        let narrowedFilm = filteredFilm

        return RSBTopPinnedLayout {
            // Spacing matches the horizontal and bottom insets below, so the gaps between
            // cards and the gaps to those three edges are one measure. The top inset is
            // deliberately tighter: the content sits directly beneath the tab header,
            // which already supplies visual separation of its own.
            VStack(alignment: .leading, spacing: RSBCardChrome.sidebarInset) {
                purchaseFilterPicker
                // The card stack is one AppKit view (RSBCardStack) and stays mounted through an
                // empty result (zero height, the placeholder over it), so a filter or film
                // change re-points it rather than inserting it: SwiftUI re-measures the whole
                // tab each time it inserts an AppKit view.
                ZStack(alignment: .topLeading) {
                    if groups.isEmpty {
                        emptyState
                            .transition(OpacityTransition())
                    }
                    // `spacing: 0` because the summary block sets its own gaps explicitly
                    // rather than inheriting the outer stack's card spacing, which is far
                    // wider than the Details tab's module metrics that header is meant to
                    // match. With the summary table off this is the card stack alone.
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
            // With nothing to list, the stack fills the viewport so the placeholder can
            // center in it (see `emptyStackHeight`).
            .frame(height: groups.isEmpty ? emptyStackHeight : nil, alignment: .top)
            // Scoped to the filter, so only a filter change animates — a new film or an
            // edited release still swaps in on the first frame. Re-enables animation
            // explicitly for this subtree, past MainView's container-wide `animation = nil`;
            // it works only because the filter's @State lives inside the hosted tree (see
            // RTabReleases.body).
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
        // No refresh handler: the groups are derived, so they are correct on the first
        // frame and on every subsequent one. FilmSnapshot is a value type and
        // RightSidebar refreshes the environment snapshot on both .updated and
        // .releaseChanged before children observe the change, so no AppEventBus
        // subscription is needed here either.
    }

    /// The optional summary table and the "All Releases" title above the cards.
    @ViewBuilder
    private func summaryBlock(_ narrowedFilm: FilmSnapshot?) -> some View {
        // Scrolls with the cards because it is a sibling inside the same
        // scrolled VStack. Gated on a non-empty group set (by the callers) so the section's
        // own "No Releases Added" placeholder can never duplicate the tab's.
        if showReleasesSummaryTable {
            RSBReleasesSection(releasesExpanded: releasesSummaryExpanded,
                               mode: .releaseCard)
                .environment(\.sidebarFilm, narrowedFilm)
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
    }

    /// Titles the card stack when the summary table sits above it, so the two blocks
    /// read as separate modules rather than one run-on list. Drawn with the same shared
    /// builder as every other module title in the sidebar, which is what the note this
    /// replaces asked for by naming the four files to keep it in step with.
    private var allReleasesHeader: some View {
        RSBHelpers.moduleHeader(purchaseFilter.cardsTitle)
    }

    /// The stack's height when there is nothing to list: the viewport less the insets, so
    /// the content is exactly one viewport tall and does not scroll. The stack's 16 pt
    /// spacing above the placeholder and the 16 pt bottom inset below it make its region
    /// symmetric, so it centers between the picker and the viewport's bottom. Before the
    /// viewport is first measured (and outside a sidebar scroll view) it falls back to a
    /// modest fixed height.
    private var emptyStackHeight: CGFloat {
        max(80, (viewport?.height ?? 0) - 8 - RSBCardChrome.sidebarInset)
    }

    /// Full width at the top of the tab, at the standard control size, with the same insets as
    /// the Details tab's "Add Viewing Event" row.
    ///
    /// Bound through an optional so that, with no disc releases, it can show no segment
    /// selected; the stored filter is left as it was for the next film.
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
        // The filter can outlive a change of film (rememberReleasesFilter), so a film with no
        // disc releases (where the picker is disabled and shows no selection) must not
        // report the filter's narrower "No Purchased Releases".
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

/// One release, pre-resolved for display. Every derived string here mirrors the
/// corresponding column in `DiscReleasesTable.buildTableData` so the two presentations
/// cannot drift apart in what they report.
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
    /// The parsed release date, or nil when the stored value is empty or unreadable (the
    /// year badge then shows the stored text as it always has). Kept parsed rather than as
    /// finished text because its wording — "Released on" or "Releases on" — depends on the
    /// day the card is drawn, and the card model is built once per release, not per day.
    let releaseDate: ReleaseDateValue?
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

    /// Wash distinguishing an attached child half from its parent, the label color at this
    /// opacity. Also serves as the child's header fill, in place of a purchase tint.
    static let childWashOpacity: CGFloat = 0.035

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

    /// Diameter of the region lock's disc — the summary table's `IndicatorBadge` size — which
    /// also sets the badge row's height below.
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

    /// Card corner radius (continuous).
    static let cardCornerRadius: CGFloat = 8

    static let shadowOpacity: Double = 0.26
    static let shadowRadius: CGFloat = FieldEdgeTreatment.shadowRadius
    static let shadowOffsetY: CGFloat = FieldEdgeTreatment.shadowOffsetY
}

// MARK: - Card Body

/// One release's half of a card, as RSBCardBodyView draws it: the model, whether it hangs
/// under a combo-pack parent, and everything derived from the two — the header's colors, the
/// badge row's presence, and the glyph rows.
@MainActor
fileprivate struct RSBReleaseCardBody {
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
    fileprivate var isAttachedChild: Bool { attachedChildBanner != nil }

    /// Today, for the release-date wording. Read through CurrentDay so the card re-renders
    /// on the day a release comes out and "Releases on" becomes "Released on".
    fileprivate var today: Date { CurrentDay.shared.today }

    // MARK: Header
    // Format badge, studio, and purchase status on one horizontal plane, on a full-bleed
    // band. On a parent half the band is tinted by purchase status, and the color change
    // is itself the separation from the details below — no divider is needed. On an
    // attached child the band is left to the child wash showing through from behind, so
    // the two halves read as one card rather than two stacked ones.

    /// White on the dark tinted band. Only ever read on a parent half — a child names its
    /// relationship to the parent instead of carrying a studio — so it needs no untinted
    /// variant.
    fileprivate var titleColor: Color {
        model.studio.isEmpty ? Color.white.opacity(0.55) : .white
    }

    /// Same lookup as `ReleaseCardView.bandTint` (33_20): `model.format` carries the full
    /// format name that mapping is keyed on.
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
        // The full release date, last before the acquisition block. Only for a full date:
        // a year-only value says nothing the year badge does not. Suppressed on an
        // attached child for the same reason as the artwork note — a child's release
        // date is its parent's, stated on the parent half directly above.
        if !isAttachedChild, let releaseDate = model.releaseDate, !releaseDate.isYearOnly {
            glyphRow(RSBRowItem(symbol: "calendar",
                                text: RSBReleaseCard.releasePhrase(releaseDate, today: today),
                                italic: releaseDate.isUpcoming(today: today)))
        }
        return rows
    }

    /// Everything the card says about acquiring the release, below one divider.
    /// Suppressed entirely for combo-pack children, whose cost, amount spent, and
    /// purchase date are all recorded on the parent 4K release above. A purchased
    /// release fills this with what it cost and when; an unpurchased one with where
    /// it can be found, what it has been seen going for, and whether it is wanted.
    ///
    /// Gated on the LAYOUT fact — "a parent half is drawn directly above me" — not on
    /// the release's own child flag. The two are now provably the same thing (see
    /// `attachedChildBanner`), so this is the one that says what the suppression
    /// actually depends on: the figures are omitted because they are visible above,
    /// and this is the condition that means exactly that.
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
        // The wishlist flag rides in the trailing column beside market availability
        // when there is one, and takes the leading column itself when there is not,
        // rather than sitting alone in a second column with an empty first.
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

    /// The notes line. Wrapped lines align under the first line's text rather than under its
    /// glyph, because RSBGlyphRowView puts the text in its own column beside the glyph.
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

    fileprivate var acquisitionBlockIsEmpty: Bool {
        model.spendLine.isEmpty
            && model.purchaseLine.isEmpty
            && model.marketAvailability.isEmpty
            && model.lowestPriceLine.isEmpty
            && !model.isWishlisted
    }

    /// True when either badge has something to show. Guards the row so an otherwise empty
    /// HStack does not contribute its spacing to the details stack.
    fileprivate var hasBadgeRow: Bool {
        !model.releaseYear.isEmpty
            || model.regionIndicator != nil
            || !model.nationalOrigin.isEmpty
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
    /// Lets a glyph that stands taller above the baseline than the text overhang the row's top
    /// instead of pushing the row's baseline down, so its text sits where a plain glyph's would.
    /// Market availability's `cart.fill.badge.questionmark` (and the gift beside it) stand
    /// ½ pt higher than `cart.fill` at 2x, 1 pt at 1x, which set that line lower than the
    /// cost line it stands in for on an unpurchased release.
    var glyphOverhangs: Bool = false
}

/// A card's run of glyph rows (the acquisition divider splits a card into two): the row pool, laid out top to bottom at the details stack's
/// spacing, each row's frame rounded as SwiftUI rounds a stack's children (origin and bottom
/// edge to the window's pixels).
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
            // Framed by layout(), never by constraints. Left translating its frame into
            // constraints, every row and part joins the Auto Layout engine, and the hosting
            // view's constraint pass over the tab walks them all on each film change.
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
        // SwiftUI's own measures, unrounded: SwiftUI rounds the row's frame where it places
        // it, and the row rounds its parts the same way (see RSBGlyphRowView.layout).
        let text = italic ? Self.italicLayout : Self.textLayout
        let lines = max(1, (size.height / label.intrinsicContentSize.height).rounded())
        let textHeight = text.height + (lines - 1) * text.lineHeight
        let glyphLayout = glyph.layout
        // The taller of the two above the baseline sets it (unless the glyph overhangs); the
        // deeper below sets the height.
        let baseline = glyphOverhangs ? text.baseline : max(text.baseline, glyphLayout.baseline)
        let labelTop = baseline - text.baseline
        let glyphTop = baseline - glyph.heightAboveBaseline
        let height = max(labelTop + textHeight, baseline - glyphLayout.baseline + glyphLayout.height)
        return Metrics(labelSize: size, labelTop: labelTop, baseline: baseline, glyphTop: glyphTop, height: height)
    }

    func layout(x: CGFloat, width: CGFloat, baseline: CGFloat, rowHeight: CGFloat, scale: CGFloat, originY: CGFloat) {
        // Rounded where the window's pixels are: `originY` is the row's top in the window's
        // flipped space, so a part lands on the pixel SwiftUI's own row would put it on.
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
    /// By symbol and display scale: SwiftUI rounds a symbol's layout to the pixel, so at 1x
    /// some come out half a point taller above the baseline than at 2x (gift.fill, tv, …).
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

    /// The height and baseline SwiftUI lays the symbol out at on this view's display, which
    /// set the row's height. Before the view is in a window, the main screen's.
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

/// A view's height and first baseline as SwiftUI lays it out, unrounded, read once through a
/// Layout that records them. AppKit's own measures (an NSImage's size, a text field's line
/// height) are close but not SwiftUI's, and a row placed by them lands half a point off.
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

    /// At the display's scale: SwiftUI rounds a symbol's layout to the pixel, so at the
    /// renderer's default 1x every symbol measure comes back in whole points. (Text measures
    /// the same at 1x and 2x.)
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
/// What RSBGlyphRowListView does per card build, for `rsb-cards` (99.20): layout passes and
/// the seconds spent in them, and rows made.
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
// The whole card stack as one AppKit view: every group's plate, outline and shadow, each
// release's header band, badge row, dividers and glyph rows (RSBGlyphRowListView), from
// RSBReleaseCardBody's values. It replaced SwiftUI cards that drew the same thing pixel for
// pixel (`rsb-card-parity`, retired with them, compared the two at three widths, light and
// dark), for cost: about 30 → 11 ms a film change, and 16 → 4 ms to build a single card
// (Debug). Built in SwiftUI, each card cost 8–10 ms, two-thirds of it selectable text; AppKit
// leaves inside SwiftUI cards gained little, because SwiftUI re-measures the whole tab each
// time it inserts one.
//
// One acquisition per plate: a combo-pack parent and its attached child or children share it,
// producing the double-height card — or the triple-height one of a "Combo-pack (dual BD)"
// pack. The parent half opens with a format-tinted band; each child half carries a faint wash
// throughout and opens with a divider, since its meaning is inherited from the parent above.
// The edge follows the FilmSheet reorderable lists': an outline that wraps the top and fades
// out toward the bottom, with the lower edge carried by a shadow (see RSBCardChrome).
//
// Matching SwiftUI took a few rules, kept here for later changes: label frames are the text's
// width + 4 at x − 2, laid out left-aligned and placed by hand (a self-centering NSTextField
// starts the line between pixels); text and symbol heights come from SwiftUIVerticalMetrics at
// the display's scale; child frames round where the window's pixels are (PixelSnap); a view's
// own shadow goes through NSView.shadow (RSBViewShadow), a sublayer's takes SwiftUI's radius.
fileprivate struct RSBCardStack: NSViewRepresentable {
    let groups: [RSBReleaseCardGroup]
    /// Passed so the day changing updates the cards ("Releases on" becomes "Released on"), as
    /// the SwiftUI cards' read of CurrentDay did; the stack also keys its no-change check on it.
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
    /// The cards shown, top to bottom, with the group each one draws.
    private var visible: [(id: UUID, view: RSBCardGroupView)] = []
    /// Cards fading out after a filter change, still at their old frames, by group. A group
    /// that comes back before its card has gone takes the same card back, as SwiftUI does.
    private var leaving: [(id: UUID, view: RSBCardGroupView)] = []
    private var pool: [RSBCardGroupView] = []
    private var fadeToken = 0
    /// What the cards were last drawn from. The groups and the day are everything a card reads,
    /// so an update that repeats both (the summary table toggled, an edit elsewhere in the film,
    /// the tab rebuilt off-screen as a swipe neighbor) has nothing to change.
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

    /// `animated` is a filter change (the transaction RTabReleasesContent's `.animation`
    /// scopes to the filter); anything else — a new film, an edited release — swaps in at once.
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
        // SwiftUI's ForEach, by identity: a card that stays moves to its new place, a card that
        // goes fades out where it was, and one that comes fades in where it lands, all on the
        // filter's spring (`.smooth(duration: 0.3)`).
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

    /// The filter's spring: SwiftUI's `.smooth(duration: 0.3)` is a spring with a 0.3 s
    /// perceptual duration and no bounce, which is what this initializer takes.
    ///
    /// Started two display frames late. Core Animation times an animation from the frame it
    /// will be shown in, SwiftUI from its update, which reaches the screen two frames later;
    /// `releases-filter` films the same switch both ways, and undelayed the AppKit cards led
    /// SwiftUI's by 25–35 ms (two frames at 60 Hz) on the same curve.
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
    /// For `releases-filter`'s burst checks (99.56): cards shown, cards still fading out, the
    /// lowest opacity a shown card is drawn at, and shown cards that are hidden or transparent.
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

    /// Moved to a display of another scale, or into a window at all (SwiftUI sizes and lays
    /// out a new view before inserting it): every frame was rounded for other pixels, and the
    /// rows' symbol measures, so the stack's height, can differ by scale. Relayout everything
    /// and have SwiftUI ask for the height again.
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

/// A card symbol: FramesGlyphView's placement (SwiftUI's own for an Image at a font), with an
/// optional shadow under the drawn glyph, as `.shadow` puts one under an Image.
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

/// One release's half of a card: the header band, then the badge row, glyph rows and
/// dividers, as RSBReleaseCardBody lays them out.
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

    /// A new width re-wraps the rows and re-rounds every frame below: lay out again.
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
        // Every label is left-aligned and placed here, centered ones included: a text field
        // that centers its own text centers the text's fractional width, which starts the
        // line between pixels; SwiftUI rounds the text's frame to the pixel and draws from it.
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
            // The checkmark centers on its circle (as the summary table's symbolBadge ZStack does), the dashed circle on
            // the slot: the same center, rounded from different origins.
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
                // The two columns' HStack: equal halves, unless a badge's minimum (the year's
                // two 48 pt compartments, the pill's 116 pt) is wider than its half, when it
                // takes its minimum and the other column the rest — at a legacy scroller's width.
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
    /// Makes a tooltip's box the accessibility element for the glyph under it, named by the
    /// tooltip, as SwiftUI names an Image that carries `.help`; nil takes it out again.
    func describeForAccessibility(_ label: String?) {
        setAccessibilityElement(label != nil)
        setAccessibilityRole(label != nil ? .image : nil)
        setAccessibilityLabel(label)
    }
}

private extension RSBShapeView.Style {
    var isDashed: Bool { if case .stroke(_, true) = self { return true } else { return false } }
}

/// A SwiftUI `.shadow(color: .black.opacity(o), radius: r, y: dy)` for a whole view. AppKit owns
/// a layer-backed view's own layer and keeps its shadow in step with the view's `shadow`, so a
/// shadow set on that layer directly is overwritten and never drawn; this goes through the
/// view's property. (A shadow on a sublayer the view adds, as RSBShapeView's, is unaffected.)
enum RSBViewShadow {
    /// NSShadow's blur radius for a SwiftUI shadow radius, fit against SwiftUI's with `rsb-card-parity` (2 was
    /// the closest of 0.5–4 for the checkmark, the dashed circle and the region letter).
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
