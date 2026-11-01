// MARK: - ReleasesTable.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The summary table in RightSidebar's Releases tab, shown above the release cards when its preference is on.
// It lists all disc releases in one table.
//
// MAINTENANCE NOTE: DO NOT PRUNE `.standard`
// The table has two layouts (see ReleasesTableMode). Only `.releaseCard` has a live call site. `.standard`, the
// full 22-column horizontally scrolling layout, lost its caller when the module left the Details tab. It is kept on purpose,
// along with its column constants, scrolling geometry, module title, and every branch that only `.standard` reaches. Do not remove
// them as dead code without explicit instruction. Reintroducing the layout should be a call-site change only.
//
// SHARED WITH THE RELEASE CARDS
// The region lock, composed video line, and release grouping and ordering are defined once in RSBHelpers'
// "Releases Tab: Shared Derivations" section. Do not reimplement them here. This file owns only the table's own geometry and cell chrome.

import SwiftUI

// MARK: - Column Width Constants
// Edit a value here to resize that column everywhere it appears in the table.
// The Notes column is dynamic and managed separately via computeNotesColumnWidth().
private enum ColW {
    static let format:           CGFloat = 32   // Col  1 – Format badge (4K / BD / DVD)
    static let purchased:        CGFloat = 22   // Col  2 – Purchased indicator
    static let year:             CGFloat = 32   // Col  3 – Release year
    static let region:           CGFloat = 26   // Col  4 – Region lock badge
    static let studio:           CGFloat = 142  // Col  5 – Studio
    static let video:            CGFloat = 112  // Col  6 – Video codec / master type
    static let hdr:              CGFloat = 80   // Col  7 – HDR format
    static let aspectRatio:      CGFloat = 112  // Col  8 – Aspect ratio
    static let audio:            CGFloat = 136  // Col  9 – Audio format
    static let subtitles:        CGFloat = 28   // Col 10 – Subtitles indicator
    static let discs:            CGFloat = 52   // Col 11 – Disc count / replication type
    static let versions:         CGFloat = 180  // Col 12 – Versions included
    static let independence:     CGFloat = 78   // Col 13 – Independence / combo-pack
    static let artwork:          CGFloat = 28   // Col 14 – Artwork indicator
    static let remastered:       CGFloat = 28   // Col 15 – Remastered indicator
    static let cost:             CGFloat = 50   // Col 16 – Cost
    static let spent:            CGFloat = 50   // Col 17 – Amount spent
    static let purchaseDate:     CGFloat = 120  // Col 18 – Purchase date
    static let condition:        CGFloat = 54   // Col 19 – Condition
    static let country:          CGFloat = 82   // Col 20 – National origin
    static let baseRelease:      CGFloat = 56   // Col 21 – Base release year
    /// Floor for the Studio column in `.releaseCard` mode, where that column is flexible
    /// rather than fixed so it can absorb the sidebar's remaining width.
    static let compactStudioMinimum: CGFloat = 60
    // Col 22 (Notes) – see computeNotesColumnWidth(); collapses to 60 when empty, 280 when populated
}

// MARK: - Unified Disc Releases Table
// Accepts pre-filtered releases from RSBReleasesSection (which already filters to
// disc formats), avoiding a duplicate filter pass on every render.
//
// `DiscReleasesTable` is the one view for the table. RSBReleasesSection constructs it with the same name and signature.

// MARK: - Presentation Mode
/// Which of the table's two layouts to draw.
///
/// `.standard` is the full 22-column, horizontally scrolling table. It has no call site and is kept on purpose (see the header note).
///
/// `.releaseCard` is the condensed table above the cards. It shows the first five columns, does not scroll, has no module title,
/// and stacks each combo-pack child under its parent. The omitted fields appear on the cards below, so this table is a summary.
enum ReleasesTableMode {
    case standard
    case releaseCard
}

// MARK: - Table Row Model
private extension ReleaseRow {
    /// The release year, in the tertiary color while the release is still ahead. It is decided at draw time against
    /// CurrentDay's `today`, so the year changes on release day without a table rebuild.
    @MainActor var yearText: Text {
        let upcoming = ReleaseDateValue(release.releaseDate, format: release.format)?
            .isUpcoming(today: CurrentDay.shared.today) ?? false
        return upcoming ? Text(releaseYear).foregroundStyle(.tertiary) : Text(releaseYear)
    }
}

private struct ReleaseRow: Identifiable {
    // The release's own UUID, so ForEach can diff rows across recomputes.
    var id: UUID { release.id }
    let release: ReleaseSnapshot
    let studio: String
    let releaseYear: String
    let baseReleaseYear: String
    let purchased: Bool
    let regionLock: String        // Display region string
    let hasHDR: String
    let videoDisplay: String      // Combined video format + master type / scanning method
    let releaseAspectRatio: String
    let audio: String
    let hasSubtitles: String
    let discsDisplay: String      // Combined disc count + replication type suffix
    let includedVersions: String
    let independence: String
    let hasArtwork: String
    let isRemastered: String
    /// False for 4K rows until at least one 4K release in the set is remastered. Then all 4K rows show their status.
    /// Blu-ray and DVD rows always show.
    let showRemasteredIndicator: Bool
    let cost: String
    let amountSpent: String
    let purchaseDate: String
    let condition: String
    let nationalOrigin: String
    let notes: String
    /// True when this release is a combo-pack child. It is read only in `.releaseCard` mode, where it hides the purchased and studio cells
    /// (they repeat the parent above) and sets the badge's open-top outline. It also means the row above continues this stack.
    /// Orphans cannot occur, because grouping always places a child directly after its parent or a sibling (see `releasesGroupedByHierarchy`).
    /// The one residual is a parent dropped by the format filter, which can leave a cosmetic open top. That happens only with a corrupt backup.
    /// The reverse direction depends on order and is computed in `hasStackedBelow`.
    let isChild: Bool
    /// True when the next row is in the same stack, so this format badge's bottom edge is open. The next row is either this
    /// release's child or a sibling child of the same parent. The sibling case covers a "Combo-pack (dual BD)" pack, whose first
    /// Blu-ray has an open top and bottom. Only `.releaseCard` order guarantees this adjacency, so only that mode sets it.
    let hasStackedBelow: Bool
}

struct DiscReleasesTable: View {
    // Reads no environment. Its input is the pre-filtered `releases` array from RSBReleasesSection, which owns the `\.sidebarFilm` dependency.
    @Binding var isTableExpanded: Bool

    // Pre-filtered releases passed in from RSBReleasesSection.
    let releases: [ReleaseSnapshot]

    /// Defaults to `.standard`, which nothing uses at present. See the header note.
    var mode: ReleasesTableMode = .standard

    // The rows and the scrolling layout's Notes width are derived from `releases` in each draw pass. A cache would draw a new film twice.
    // SwiftUI skips this body when `releases` and the binding are unchanged.

    @ViewBuilder
    var body: some View {
        switch mode {
        case .standard:
            VStack(spacing: 6) {
                RSBHelpers.moduleHeader("Disc-based Releases")
                table
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .releaseCard:
            // No module title, since the tab is named "Releases" and the cards say what they are. No vertical padding either. The
            // RTabReleases stack sets the spacing, so the gaps match whether or not this table is shown.
            compactTable
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Compact Table (.releaseCard mode)

    /// The first five columns, without scrolling. The Studio column has no `maxWidth`, so it takes the width the four fixed columns leave.
    /// A fixed-width Studio column would overrun the sidebar and be clipped.
    private var compactTable: some View {
        CustomTable(
            buildTableData(from: releases),
            columns: [
                CustomTableColumn(
                    "", systemImage: ContentGlyphs.disc, minWidth: ColW.format, maxWidth: ColW.format, alignment: .center, cellPadding: 4),
                // Pur. and Reg. use cellPadding 0. CustomTable adds the padding outside the header label's frame, so the padding
                // widens the column without giving the label room. Dropping it from 2 to 0 frees 4 pt per column, and the labels keep
                // their width, so they cannot truncate. The data cells drop the matching 2 pt padding too. Their badges still have slack.
                // This applies only to this layout. `.standard` keeps 2 pt because it scrolls and is not width-starved.
                CustomTableColumn(
                    "Pur.", minWidth: ColW.purchased, maxWidth: ColW.purchased, alignment: .center, cellPadding: 0),
                CustomTableColumn(
                    "Year", minWidth: ColW.year, maxWidth: ColW.year, alignment: .center),
                CustomTableColumn(
                    "Reg.", minWidth: ColW.region, maxWidth: ColW.region, alignment: .center, cellPadding: 0),
                CustomTableColumn(
                    "Studio", minWidth: ColW.compactStudioMinimum)
            ],
            isExpanded: $isTableExpanded,
            allowHorizontalScroll: false,
            // Without scrolling, CustomTable adds a 2 pt `scrollCompensation` to the rows and drops the header to 2. contentPadding 8 brings the rows
            // back to a visual 10. The header overrides set the header to the same 10 / 8, so the columns line up with the headings.
            contentPadding: 8,
            headerLeadingPadding: 10,
            headerTrailingPadding: 8
        ) { row in
            // Format badge (col 1). No vertical padding, and a full-height frame, so stacked outlines meet at the row boundary.
            StackedFormatBadge(
                label: ReleaseFormat.badge(for: row.release.format),
                outlined: row.release.format == ReleaseFormat.uhd4K.rawValue || row.isChild,
                openBottom: row.hasStackedBelow,
                openTop: row.isChild)
            .allowsHitTesting(false)
            .frame(minWidth: ColW.format, maxWidth: ColW.format, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 4)

            // Purchased (col 2). Omitted for a child, whose purchase is on the parent row above.
            Group {
                if row.isChild {
                    Color.clear.frame(width: 16, height: 16)
                } else {
                    // Unpurchased releases use the card header's dashed-circle glyph in red, not the plain "xmark" the other indicators use.
                    purchasedIndicator(row.purchased)
                }
            }
            // No horizontal padding — matches this column's cellPadding: 0 above.
            .frame(minWidth: ColW.purchased, maxWidth: ColW.purchased, alignment: .center)
            .padding(.vertical, 2)

            // Year (col 3). A child shows only its base release year, since the parent above already states the pack's year. A blank cell is
            // used when there is no base year. A release not yet out uses the tertiary color (see `yearText`).
            CustomTableCell(row.isChild ? Text(row.baseReleaseYear) : row.yearText,
                            minWidth: ColW.year, maxWidth: ColW.year, alignment: .center)

            // Region (col 4)
            RegionCell(value: row.regionLock, format: row.release.format)
                // No horizontal padding — matches this column's cellPadding: 0 above.
                .frame(minWidth: ColW.region, maxWidth: ColW.region, alignment: .center)
                .padding(.vertical, 2)

            // Studio (col 5). Omitted for a child, since a combo pack has one studio.
            CustomTableCell(row.isChild ? "" : row.studio,
                            minWidth: ColW.compactStudioMinimum, maxWidth: .infinity)
        }
        // No Notes column here. This layout draws only the first five columns.
    }

    /// The table, kept in its own property so `body` stays simple for the type-checker despite the 22-column builder.
    private var table: some View {
        // Computed once per pass and captured.
        let notesColumnWidth = computeNotesColumnWidth(from: releases)
        return CustomTable(
            buildTableData(from: releases),
            columns: [
                CustomTableColumn(
                    "", systemImage: ContentGlyphs.disc, minWidth: ColW.format, maxWidth: ColW.format, alignment: .center, cellPadding: 4),
                CustomTableColumn(
                    "Pur.", minWidth: ColW.purchased, maxWidth: ColW.purchased, alignment: .center, cellPadding: 2),
                CustomTableColumn(
                    "Year", minWidth: ColW.year, maxWidth: ColW.year, alignment: .center),
                CustomTableColumn(
                    "Reg.", minWidth: ColW.region, maxWidth: ColW.region, alignment: .center, cellPadding: 2),
                CustomTableColumn(
                    "Studio", minWidth: ColW.studio, maxWidth: ColW.studio),
                CustomTableColumn(
                    "Video", minWidth: ColW.video, maxWidth: ColW.video),
                CustomTableColumn(
                    "HDR", minWidth: ColW.hdr, maxWidth: ColW.hdr),
                CustomTableColumn(
                    "Aspect Ratio", minWidth: ColW.aspectRatio, maxWidth: ColW.aspectRatio),
                CustomTableColumn(
                    "Audio", minWidth: ColW.audio, maxWidth: ColW.audio),
                CustomTableColumn(
                    "Subs", minWidth: ColW.subtitles, maxWidth: ColW.subtitles, alignment: .center, cellPadding: 2),
                CustomTableColumn(
                    "Discs", minWidth: ColW.discs, maxWidth: ColW.discs),
                CustomTableColumn(
                    "Versions Included", minWidth: ColW.versions, maxWidth: ColW.versions),
                CustomTableColumn(
                    "Independence", minWidth: ColW.independence, maxWidth: ColW.independence, alignment: .center),
                CustomTableColumn(
                    "Art", minWidth: ColW.artwork, maxWidth: ColW.artwork, alignment: .center, cellPadding: 2),
                CustomTableColumn(
                    "Rem.", minWidth: ColW.remastered, maxWidth: ColW.remastered, alignment: .center, cellPadding: 2),
                CustomTableColumn(
                    "Cost", minWidth: ColW.cost, maxWidth: ColW.cost, alignment: .trailing),
                CustomTableColumn(
                    "Spent", minWidth: ColW.spent, maxWidth: ColW.spent, alignment: .trailing),
                CustomTableColumn(
                    "Purchase Date", minWidth: ColW.purchaseDate, maxWidth: ColW.purchaseDate, alignment: .trailing),
                CustomTableColumn(
                    "Condition", minWidth: ColW.condition, maxWidth: ColW.condition, alignment: .center),
                CustomTableColumn(
                    "Country", minWidth: ColW.country, maxWidth: ColW.country, alignment: .center),
                CustomTableColumn(
                    "Base Rel.", minWidth: ColW.baseRelease, maxWidth: ColW.baseRelease, alignment: .center),
                CustomTableColumn(
                    "Notes", minWidth: notesColumnWidth, maxWidth: notesColumnWidth)
            ],
            isExpanded: $isTableExpanded,
            allowHorizontalScroll: true
        ) { row in
            // Format label column (col 1)
            Group {
                if row.release.format == ReleaseFormat.uhd4K.rawValue {
                    // 4K UHD: outlined badge for visual differentiation
                    Text(ReleaseFormat.uhd4K.badge)
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1)
                        )
                } else {
                    Text(ReleaseFormat.badge(for: row.release.format))
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .allowsHitTesting(false)
            .lineLimit(1)
            .frame(minWidth: ColW.format, maxWidth: ColW.format, alignment: .center)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)

            // Purchased column (col 2)
            purchasedIndicator(row.purchased)
                .frame(minWidth: ColW.purchased, maxWidth: ColW.purchased, alignment: .center)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)

            // Year (col 3). Tertiary while the release is not yet out (see `yearText`).
            CustomTableCell(row.yearText, minWidth: ColW.year, maxWidth: ColW.year, alignment: .center)

            // Region (col 4)
            RegionCell(value: row.regionLock, format: row.release.format)
                .frame(minWidth: ColW.region, maxWidth: ColW.region, alignment: .center)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)

            // Studio (col 5)
            CustomTableCell(row.studio, minWidth: ColW.studio, maxWidth: ColW.studio)

            // Video (col 6)
            CustomTableCell(row.videoDisplay, minWidth: ColW.video, maxWidth: ColW.video)

            // HDR (col 7)
            CustomTableCell(row.hasHDR, minWidth: ColW.hdr, maxWidth: ColW.hdr)

            // Aspect Ratio (col 8)
            CustomTableCell(row.releaseAspectRatio, minWidth: ColW.aspectRatio, maxWidth: ColW.aspectRatio)

            // Audio (col 9)
            CustomTableCell(row.audio, minWidth: ColW.audio, maxWidth: ColW.audio)

            // Subtitles (col 10)
            symbolBadge(row.hasSubtitles == "Yes" ? "checkmark" : "xmark",
                        row.hasSubtitles == "Yes" ? Preferences.green : Preferences.red)
            .frame(minWidth: ColW.subtitles, maxWidth: ColW.subtitles, alignment: .center)
            .padding(.horizontal, 2)
            .padding(.vertical, 2)

            // Discs (col 11)
            CustomTableCell(row.discsDisplay, minWidth: ColW.discs, maxWidth: ColW.discs)

            // Versions Included (col 12)
            CustomTableCell(row.includedVersions, minWidth: ColW.versions, maxWidth: ColW.versions, tooltip: row.includedVersions)

            // Independence (col 13)
            CustomTableCell(row.independence, minWidth: ColW.independence, maxWidth: ColW.independence, alignment: .center)

            // Artwork (col 14)
            ArtworkCell(value: row.hasArtwork)
                .frame(minWidth: ColW.artwork, maxWidth: ColW.artwork, alignment: .center)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)

            // Remastered (col 15). 4K rows show nothing until one 4K release is remastered. Then all 4K rows show their own status. Blu-ray and DVD always show.
            Group {
                if row.showRemasteredIndicator {
                    symbolBadge(row.isRemastered == "Yes" ? "checkmark" : "xmark",
                                row.isRemastered == "Yes" ? Preferences.green : Preferences.red)
                } else {
                    Color.clear
                        .frame(width: 16, height: 16)
                }
            }
            .frame(minWidth: ColW.remastered, maxWidth: ColW.remastered, alignment: .center)
            .padding(.horizontal, 2)
            .padding(.vertical, 2)

            CustomTableCell(row.cost, minWidth: ColW.cost, maxWidth: ColW.cost, alignment: .trailing)
            CustomTableCell(row.amountSpent, minWidth: ColW.spent, maxWidth: ColW.spent, alignment: .trailing)
            CustomTableCell(row.purchaseDate, minWidth: ColW.purchaseDate, maxWidth: ColW.purchaseDate, alignment: .trailing)
            CustomTableCell(row.condition, minWidth: ColW.condition, maxWidth: ColW.condition, alignment: .center)
            CustomTableCell(row.nationalOrigin, minWidth: ColW.country, maxWidth: ColW.country, alignment: .center)
            CustomTableCell(row.baseReleaseYear, minWidth: ColW.baseRelease, maxWidth: ColW.baseRelease, alignment: .center)
            CustomTableCell(row.notes, minWidth: notesColumnWidth, maxWidth: notesColumnWidth, tooltip: row.notes)
        }
    }

    // MARK: - Notes Column Width Helper

    private func computeNotesColumnWidth(from source: [ReleaseSnapshot]) -> CGFloat {
        let hasNotes = source.contains { !$0.notes.trimmingCharacters(in: .whitespaces).isEmpty }
        return hasNotes ? 280 : 60
    }

    // MARK: - Table Data Builder

    /// Artwork tags that `ArtworkCell` draws its own glyph for. They pass through verbatim, not into the "Yes*" bucket.
    /// This is a type-level constant, so it is not rebuilt for every row.
    private static let literalArtworkTags: Set<String> = [
        ReleaseArtwork.steelbook,
        ReleaseArtwork.yes,
        ReleaseArtwork.yesMultiPack,
        ReleaseArtwork.noMultiPack,
        ReleaseArtwork.yesComboPack,
        ReleaseArtwork.noComboPack
    ]

    private func buildTableData(from source: [ReleaseSnapshot]) -> [ReleaseRow] {
        // Whether any 4K release is remastered. This sets the Rem. column rule: all 4K rows stay blank until then.
        let any4KRemastered = source.contains { $0.format == ReleaseFormat.uhd4K.rawValue && $0.remastered }

        let ordered: [ReleaseSnapshot]
        switch mode {
        case .standard:
            // Unchanged: a flat sort across the whole set, with parents and children
            // falling wherever the four keys put them.
            ordered = source.sorted { releaseSortKeysPrecede($0, $1) ?? false }
        case .releaseCard:
            ordered = releasesGroupedByHierarchy(source).flatMap { $0 }
        }

        // Rows whose bottom edge is open, so the row below continues their stack. This is computed from the final order, so an outline
        // never claims an adjacency the layout lacks. Two adjacencies count: the next row is this release's child, or a sibling child of the same parent.
        // The second is the dual-BD case, so this cannot reduce to "has children". The top edge is `isChild`, read directly from the row.
        let idsWithStackedBelow: Set<UUID> = {
            guard mode == .releaseCard else { return [] }
            var below: Set<UUID> = []
            for (index, release) in ordered.enumerated() where index + 1 < ordered.count {
                let next = ordered[index + 1]
                let continues: Bool
                if next.parentReleaseID == release.id {
                    // Parent → its own child.
                    continues = true
                } else if let parentID = release.parentReleaseID {
                    // Child → the next sibling child of the same parent. The non-nil guard on the current row
                    // keeps two top-level releases (both nil) from being read as siblings.
                    continues = (next.parentReleaseID == parentID)
                } else {
                    continues = false
                }
                if continues { below.insert(release.id) }
            }
            return below
        }()

        return ordered
            .map { release in
                // Artwork display. Tags with a dedicated glyph pass through. Other affirmative variants, such as "Yes (Custom artwork)" or older database values,
                // collapse to "Yes*", which ArtworkCell draws as an amber qualified check. Anything else shows as its own text.
                //
                // This was written as a chain of six equality tests that each assigned
                // back the very constant they had just compared against, which is simply
                // "pass through" stated six times. Their only actual job was to reach the
                // `else` ahead of the `hasPrefix` catch below, so the three "Yes…" tags
                // among them would not be rewritten to "Yes*". Naming that set says so
                // directly, and — being built from the same `ReleaseArtwork` constants —
                // cannot fall out of step with the picker's vocabulary any more than the
                // chain could.
                let artworkDisplay: String
                if Self.literalArtworkTags.contains(release.hasArtwork) {
                    artworkDisplay = release.hasArtwork
                } else if release.hasArtwork.hasPrefix(ReleaseArtwork.yes) {
                    artworkDisplay = "Yes*"
                } else {
                    artworkDisplay = release.hasArtwork
                }

                // Region lock and the composed video line are both shared with the release
                // cards below this table — see RSBHelpers' shared-derivations section.
                let regionLock = RSBRegionIndicator.displayValue(release.regionLock,
                                                                 format: release.format)
                let videoDisplay = releaseVideoDisplay(for: release)

                // Combined discs display: "N" or "N (BD-R)"
                let discsDisplay: String
                if ReleaseReplicationType.isRecordable(release.replicationType) {
                    discsDisplay = "\(release.numberOfDiscs) (BD-R)"
                } else {
                    discsDisplay = "\(release.numberOfDiscs)"
                }

                // Purchase-conditional fields
                let isComboPack = ReleaseIndependence.isComboPack(release.independence)
                    && release.format != ReleaseFormat.uhd4K.rawValue
                let formattedCost: String
                let formattedAmountSpent: String
                let formattedPurchaseDate: String
                let formattedCondition: String

                if release.purchased {
                    if isComboPack {
                        // Currency fields are locked for combo-pack releases — their cost
                        // and amount spent are reported on the associated 4K UHD release.
                        // Display "–" rather than leaving the cells blank so these rows are
                        // visually distinguishable from releases with genuinely missing data.
                        formattedCost = "–"
                        formattedAmountSpent = "–"
                    } else {
                        formattedCost = Fmt.dollars(release.cost)
                        formattedAmountSpent = Fmt.dollars(release.amountSpent)
                    }
                    formattedPurchaseDate = release.purchaseDate.isEmpty ? "None provided" : formatDateString(release.purchaseDate)
                    formattedCondition = release.condition.isEmpty ? "" : release.condition.capitalized
                } else {
                    formattedCost = ""
                    formattedAmountSpent = ""
                    formattedPurchaseDate = ReleaseMarketAvailability.displayText(release.marketAvailability)
                    formattedCondition = ""
                }

                // Versions are displayed as a plain comma-separated list.
                // The column's tooltip handles truncation, so the count prefix is not needed.
                let includedVersions = release.includedVersions.joined(separator: ", ")

                // HDR: only meaningful for 4K UHD; always "N/A" for Blu-ray and DVD
                let hdrDisplay = release.format == ReleaseFormat.uhd4K.rawValue ? release.hasHDR : "N/A"

                // Notes: Blu-ray combo-pack releases with no notes show "–" to indicate
                // that notes are inherited from the parent 4K release, mirroring the
                // cost/spent placeholder convention used elsewhere in the table.
                let notesDisplay: String
                if release.format == ReleaseFormat.bluRay.rawValue
                    && ReleaseIndependence.isComboPack(release.independence)
                    && release.notes.trimmingCharacters(in: .whitespaces).isEmpty {
                    notesDisplay = "–"
                } else {
                    notesDisplay = release.notes
                }

                // Rem. column visibility for 4K UHD rows.
                let showRemastered: Bool
                if release.format == ReleaseFormat.uhd4K.rawValue {
                    showRemastered = any4KRemastered
                } else {
                    showRemastered = true
                }

                return ReleaseRow(
                    release: release,
                    studio: release.studio,
                    // Trimmed, as the release cards trim the same two fields
                    // (RSBReleaseCardBuilder.model). Both columns are centered, so a
                    // stored value carrying stray whitespace would center differently
                    // in the table than in the card describing the same release.
                    // The release date's year — ReleaseDateValue.yearText trims as well.
                    releaseYear: ReleaseDateValue.yearText(of: release.releaseDate, format: release.format),
                    baseReleaseYear: release.baseReleaseYear.trimmingCharacters(in: .whitespacesAndNewlines),
                    purchased: release.purchased,
                    regionLock: regionLock,
                    hasHDR: hdrDisplay,
                    videoDisplay: videoDisplay,
                    releaseAspectRatio: release.releaseAspectRatio.joined(separator: ", "),
                    audio: release.audio,
                    hasSubtitles: release.hasSubtitles ? "Yes" : "No",
                    discsDisplay: discsDisplay,
                    includedVersions: includedVersions,
                    independence: ReleaseIndependence.compactDisplay(release.independence),
                    hasArtwork: artworkDisplay,
                    isRemastered: release.remastered ? "Yes" : "No",
                    showRemasteredIndicator: showRemastered,
                    cost: formattedCost,
                    amountSpent: formattedAmountSpent,
                    purchaseDate: formattedPurchaseDate,
                    condition: formattedCondition,
                    nationalOrigin: release.nationalOrigin,
                    notes: notesDisplay,
                    isChild: release.isChild,
                    hasStackedBelow: idsWithStackedBelow.contains(release.id)
                )
            }
    }
}

// MARK: - Stacked Format Badge (.releaseCard mode)
/// The format label with an optional 1 pt outline. A standalone 4K release gets the standard rounded badge. A parent and its child
/// get outlines with the shared edge open, both running the full row height. They meet at the row boundary and read as one tall rectangle.
private struct StackedFormatBadge: View {
    let label: String
    let outlined: Bool
    let openBottom: Bool
    let openTop: Bool

    /// True when this badge participates in a stacked pair and so must run edge to edge.
    private var isStacked: Bool { openBottom || openTop }

    /// One fixed width for every stacked badge, so the pair's sides line up. Natural widths differ slightly for "4K" and "BD", and centering
    /// would misalign the outlines. The width fits the widest stacked label at 11 pt bold, with 4 pt on each side.
    private static let stackedWidth: CGFloat = 26

    /// How far the closed edge sits in from the row boundary, so the outline hugs the text as the standard badge does. This is
    /// (22 − 15) / 2, from CustomTable's 22 pt row and a badge about 15 pt tall (11 pt bold text plus 1 pt vertical padding).
    private static let closedEdgeInset: CGFloat = 3.5

    /// How far each side is pulled in from the frame's edge, applied to all three stack positions so the sides stay collinear. The outline
    /// is 1 pt narrower per side, to match the standard badge's tighter fit. Narrowing the frame instead would also narrow the text's centering box.
    private static let sideInset: CGFloat = 1

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .bold))
            .lineLimit(1)
            .fixedSize()
            .modifier(StackedBadgeFrame(isStacked: isStacked, width: Self.stackedWidth))
            .overlay { outline }
    }

    @ViewBuilder
    private var outline: some View {
        if outlined {
            if isStacked {
                // The shape spans the full row height and insets its own closed edge. Only the open edge reaches the boundary.
                StackedBadgeOutline(openTop: openTop,
                                    openBottom: openBottom,
                                    closedInset: Self.closedEdgeInset,
                                    sideInset: Self.sideInset)
                    .stroke(Color.primary.opacity(0.55), lineWidth: 1)
            } else {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1)
            }
        }
    }
}

/// Applies either the stacked badge's fixed, full-row-height frame or the standard
/// badge's natural padding. Split into a ViewModifier so both branches produce the same
/// concrete type, keeping the badge's `body` a single expression.
private struct StackedBadgeFrame: ViewModifier {
    let isStacked: Bool
    let width: CGFloat

    // Explicit @ViewBuilder: ViewModifier.body is not an implicit builder context, so
    // the two branches below would otherwise have to resolve to one type.
    @ViewBuilder
    func body(content: Content) -> some View {
        if isStacked {
            // Two frames, because no single `frame` overload combines a fixed width with a flexible height. The inner fixes the width,
            // and the outer grows to the full row height so the open edge reaches the boundary.
            content
                .frame(width: width)
                .frame(maxHeight: .infinity)
        } else {
            content
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
        }
    }
}

/// A rounded rectangle with one or both horizontal edges removed. Each closed edge is inset half a point so a 1 pt stroke fits inside the frame.
/// Each open edge sits flush with the boundary, so the neighboring row's outline continues it.
///
/// Three shapes, one per stack position:
///   • open bottom only: the parent at the top, rounded top.
///   • open top only: the last child, rounded bottom.
///   • both open: a middle child, which only a "Combo-pack (dual BD)" pack has (its first Blu-ray). It has no corners and is
///     two full-height verticals that carry the sides past this row.
private struct StackedBadgeOutline: Shape {
    let openTop: Bool
    let openBottom: Bool
    /// Distance from the frame's closed edge to the drawn edge.
    let closedInset: CGFloat
    /// Distance from each of the frame's vertical edges to the drawn side. Applied to
    /// `left`/`right`, which every branch below shares, so all three stack positions
    /// narrow by the same amount and stay collinear.
    let sideInset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 1, rect.height > 1 else { return path }

        let left = rect.minX + sideInset + 0.5
        let right = rect.maxX - sideInset - 0.5
        let top = openTop ? rect.minY : rect.minY + closedInset + 0.5
        let bottom = openBottom ? rect.maxY : rect.maxY - closedInset - 0.5
        guard bottom > top, right > left else { return path }
        // Clamp so a short row can never produce a corner arc larger than the box.
        let radius = min(3, (right - left) / 2, (bottom - top) / 2)

        if openTop && openBottom {
            // Middle of the stack: two full-height lines as separate subpaths, so the stroke never closes across the top or bottom.
            path.move(to: CGPoint(x: left, y: top))
            path.addLine(to: CGPoint(x: left, y: bottom))
            path.move(to: CGPoint(x: right, y: top))
            path.addLine(to: CGPoint(x: right, y: bottom))
        } else if openTop {
            // Sides plus a rounded bottom.
            path.move(to: CGPoint(x: left, y: top))
            path.addLine(to: CGPoint(x: left, y: bottom - radius))
            path.addQuadCurve(to: CGPoint(x: left + radius, y: bottom),
                              control: CGPoint(x: left, y: bottom))
            path.addLine(to: CGPoint(x: right - radius, y: bottom))
            path.addQuadCurve(to: CGPoint(x: right, y: bottom - radius),
                              control: CGPoint(x: right, y: bottom))
            path.addLine(to: CGPoint(x: right, y: top))
        } else {
            // Sides plus a rounded top (the open-bottom parent case).
            path.move(to: CGPoint(x: left, y: bottom))
            path.addLine(to: CGPoint(x: left, y: top + radius))
            path.addQuadCurve(to: CGPoint(x: left + radius, y: top),
                              control: CGPoint(x: left, y: top))
            path.addLine(to: CGPoint(x: right - radius, y: top))
            path.addQuadCurve(to: CGPoint(x: right, y: top + radius),
                              control: CGPoint(x: right, y: top))
            path.addLine(to: CGPoint(x: right, y: bottom))
        }
        return path
    }
}

// MARK: - Circular Indicator Badge
// Each colored circle indicator here (purchased, subtitles, remastered, artwork, and region badges) is a 14 pt filled circle
// with a white, drop-shadowed glyph or character. The 16 pt Color.clear placeholders elsewhere hold a cell's footprint open.
// This one definition sets the circle diameter, shadow, and label color.
/// Not `private`: RTabReleases (24.20) reuses it, scaled up, for the card purchase glyph (see `symbolBadge`).
struct IndicatorBadge<Label: View>: View {
    let color: Color
    /// Lettering color. Defaults to white, which is what every saturated fill needs; the
    /// white-filled region badges pass black.
    let ink: Color
    /// Whether the lettering carries a drop shadow. White-on-saturated needs one to hold
    /// its edges; black-on-white does not, and a shadow there only muddies the glyph.
    let inkNeedsShadow: Bool
    /// Circle diameter. Defaults to this table's 14pt; RTabReleases passes a larger value
    /// to match its card chrome while drawing the identical badge.
    let diameter: CGFloat
    /// Drop shadow for the circle alone. Nil (the default) draws none. It goes on the `Circle`, not the whole ZStack, so the label's
    /// shadow is not doubled. RTabReleases uses it for the card's checkmark fill without changing the label shadow.
    let circleShadow: (opacity: Double, radius: CGFloat, offsetY: CGFloat)?
    let label: () -> Label

    init(color: Color,
         ink: Color = .white,
         inkNeedsShadow: Bool = true,
         diameter: CGFloat = 14,
         circleShadow: (opacity: Double, radius: CGFloat, offsetY: CGFloat)? = nil,
         @ViewBuilder label: @escaping () -> Label) {
        self.color = color
        self.ink = ink
        self.inkNeedsShadow = inkNeedsShadow
        self.diameter = diameter
        self.circleShadow = circleShadow
        self.label = label
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
                .shadow(color: circleShadow.map { .black.opacity($0.opacity) } ?? .clear,
                        radius: circleShadow?.radius ?? 0,
                        x: 0,
                        y: circleShadow?.offsetY ?? 0)
            label()
                .foregroundStyle(ink)
                .shadow(color: inkNeedsShadow ? Color.black.opacity(0.5) : .clear,
                        radius: 0.5, x: 0, y: 0.5)
        }
    }
}

/// The Purchased column's indicator. Purchased draws the usual filled-circle checkmark
/// badge; unpurchased draws the bare "circle.dashed" glyph in `.primary`, sized to the
/// same 14pt diameter as the checkmark badge's circular fill so the two states read as
/// the same size (that glyph is already a circle, so a second one behind it would be
/// redundant). `.primary` rather than a fixed color: this glyph sits directly on the
/// table's own row background, which follows the system appearance, unlike the release
/// card's opaque tinted band.
@MainActor
private func purchasedIndicator(_ purchased: Bool) -> some View {
    Group {
        if purchased {
            symbolBadge("checkmark", Preferences.green)
        } else {
            Image(systemName: "circle.dashed")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }
}

/// SF Symbol variant of `IndicatorBadge`. `weight` is `.bold` for the check/cross
/// indicators and `.regular` for the Steelbook book glyph, matching the prior
/// per-site font declarations exactly.
///
/// `@MainActor` because `IndicatorBadge` is a main-actor `View`, and its initializer inherits that isolation. Every caller is main-actor isolated too.
/// Not `private`: RTabReleases (24.20) calls this for its card purchase glyph, so the badge is the same view at a larger `diameter`.
/// The glyph size scales with `diameter` at this table's ratio (8 pt glyph in a 14 pt circle).
@MainActor
func symbolBadge(_ systemName: String,
                 _ color: Color,
                 weight: Font.Weight = .bold,
                 diameter: CGFloat = 14,
                 circleShadow: (opacity: Double, radius: CGFloat, offsetY: CGFloat)? = nil) -> some View {
    IndicatorBadge(color: color, diameter: diameter, circleShadow: circleShadow) {
        Image(systemName: systemName)
            .font(.system(size: diameter * 8 / 14, weight: weight))
    }
}

/// Single-character variant of `IndicatorBadge`, used for the region letters/digits.
/// `@MainActor` for the same reason as `symbolBadge` above.
///
/// The character's font comes from `RSBRegionBadge.characterFont`, shared with `RSBIndicatorView` on the release cards. Both draw into a
/// 14 pt circle, so one shared constant keeps them the same size. A literal copy would need manual upkeep.
@MainActor
private func characterBadge(_ label: String,
                            _ color: Color,
                            ink: Color = .white,
                            inkNeedsShadow: Bool = true) -> some View {
    IndicatorBadge(color: color, ink: ink, inkNeedsShadow: inkNeedsShadow) {
        Text(label)
            .font(RSBRegionBadge.characterFont)
    }
}

// MARK: - Region Cell Component
// Draws an `RSBRegionIndicator`. The mark selection and playable-versus-locked colors come from `RSBRegionIndicator` and `RSBRegionBadge`
// in RSBHelpers, shared with the cards. What stays here is the cell's own chrome. It centers in a fixed column, and its globe and raw
// fallback use the adaptive label color, since they sit on the row background rather than the cards' opaque pill.
private struct RegionCell: View {
    /// The display region — 4K UHD's empty-means-Region-Free default is already applied by
    /// `buildTableData`.
    let value: String
    /// Only the format is needed, to tell DVD's numbered regions from the lettered scheme.
    let format: String

    var body: some View {
        switch RSBRegionIndicator.resolve(value, format: format) {
        case let .character(label, playable):
            // The circle comes from the shared `IndicatorBadge`, so the region disc matches
            // every other colored indicator in this table in size and shadow.
            characterBadge(label,
                           RSBRegionBadge.fill(playable: playable),
                           ink: RSBRegionBadge.ink(playable: playable),
                           inkNeedsShadow: RSBRegionBadge.inkNeedsShadow(playable: playable))
                .frame(maxWidth: .infinity, alignment: .center)
        case .globe:
            Image(systemName: "globe")
                .foregroundStyle(.primary)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, alignment: .center)
        case let .raw(stored):
            Text(stored)
                .font(.system(size: 10))
                .frame(maxWidth: .infinity, alignment: .center)
        case nil:
            // Nothing recorded. Holds a badge-sized footprint rather than collapsing —
            // the same idiom the Purchased column uses for a suppressed child cell — so
            // the row keeps its height regardless of what the other cells contain.
            Color.clear
                .frame(width: 16, height: 16)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: - Artwork Cell Component
private struct ArtworkCell: View {
    let value: String

    var body: some View {
        switch value {
        case ReleaseArtwork.steelbook:
            // The book glyph is the one badge drawn at regular weight.
            symbolBadge("book.fill", .blue, weight: .regular)
                .frame(maxWidth: .infinity, alignment: .center)
        case _ where ReleaseArtwork.affirmativeTags.contains(value):
            symbolBadge("checkmark", Preferences.green)
                .frame(maxWidth: .infinity, alignment: .center)
        case _ where ReleaseArtwork.negativeTags.contains(value):
            symbolBadge("xmark", Preferences.red)
                .frame(maxWidth: .infinity, alignment: .center)
        case "Yes*":
            // Set by buildTableData for any other "Yes…" variant: affirmative, but
            // qualified, so it takes the amber treatment rather than green.
            symbolBadge("checkmark", Preferences.orange)
                .frame(maxWidth: .infinity, alignment: .center)
        default:
            Text(value == "Not Applicable" ? "N/A" : value)
                .font(.system(size: 10))
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}


// MARK: - Releases Section
// The Releases tab's table wrapper. The tab prepends it above the cards when Preferences.showReleasesSummaryTable is on (see RTabReleases).
//
// RightSidebar is the single source of truth. It handles .updated and .releaseChanged and refreshes the environment snapshot before children
// see the event. This view derives its releases from that environment value. Subscribing here too raced: the sibling onReceive could fire
// before the environment updated.
struct RSBReleasesSection: View {
    @Environment(\.sidebarFilm) private var film: FilmSnapshot?

    var releasesExpanded: Binding<Bool>

    /// Which of DiscReleasesTable's two layouts to draw. `.standard` stays the default, though every call site passes `.releaseCard`. See the header note.
    var mode: ReleasesTableMode = .standard

    var body: some View {
        // Derived each pass, not cached, since a cache would draw each new film twice. Filtering is one cheap pass, and SwiftUI
        // skips DiscReleasesTable when the array is unchanged.
        let releases = discReleases(of: film)
        VStack(spacing: 8) {
            if !releases.isEmpty {
                DiscReleasesTable(isTableExpanded: releasesExpanded,
                                  releases: releases,
                                  mode: mode)
            } else {
                Text("No Releases Added")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }
        }
    }

    private func discReleases(of film: FilmSnapshot?) -> [ReleaseSnapshot] {
        guard let film = film else { return [] }
        // Same membership test as `RSBReleaseCardBuilder.buildGroups`, so the table and the cards below draw the same release set.
        // The former releases4K/2K/SD accessors did three filter and sort passes. Their ordering was discarded, since buildTableData
        // regroups or re-sorts, so nothing downstream sees the input order.
        return film.releases.filter { ReleaseFormat(rawValue: $0.format) != nil }
    }
}
