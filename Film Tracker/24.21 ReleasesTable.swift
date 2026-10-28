// MARK: - ReleasesTable.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// RightSidebar's "Releases" tab, summary-table module. Displays all disc-based releases
// in a unified table above the release cards, when the corresponding preference is on.
//
// MAINTENANCE NOTE — DO NOT PRUNE `.standard`
// This table has two layouts (see ReleasesTableMode below). Only `.releaseCard` has a
// live call site: the summary table above the cards in the Releases tab. `.standard` —
// the full 22-column, horizontally scrolling layout — lost its only caller when this
// module moved out of the Details tab's stack, and RSBReleasesSection's `mode`
// default of `.standard` is likewise now unexercised.
//
// All of that is retained deliberately for potential future use. `.standard`, its
// column-width constants, its horizontal scrolling geometry, the module title it draws,
// and every branch reached only when `mode == .standard` are NOT dead code and must not
// be removed as such unless explicitly instructed. Reintroducing the layout should be a
// call-site change, nothing more.
//
// SHARED WITH THE RELEASE CARDS
// Everything this table and the cards below it must agree on — the region lock's mark and
// coloring, the composed video line, and the grouping and ordering of the release set — is
// defined once in RSBHelpers' "Releases Tab: Shared Derivations" section and used from
// both. Nothing in that list should be reimplemented here; what stays local is this
// table's own column geometry and cell chrome.

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
// This was previously split across two types — a `DiscReleasesTable` that added only
// the module title and forwarded both of its stored properties verbatim to a private
// `UnifiedReleaseTable` that did all the work. The wrapper carried no state, no
// environment, and no logic, so the two are merged here; `DiscReleasesTable` keeps its
// name and signature, which is what RSBReleasesSection (below) constructs.

// MARK: - Presentation Mode
/// Which of the table's two layouts to draw.
///
/// `.standard` is the original full-width, 22-column, horizontally scrolling table that
/// the "Details" tab used to host. It currently has no call site and is retained
/// intentionally — see the maintenance note at the top of this file before removing
/// anything that only `.standard` reaches.
///
/// `.releaseCard` is the condensed variant used above the cards in the "Releases" tab.
/// It keeps only the first five columns, does not scroll horizontally, drops the module
/// title, and stacks each combo-pack child directly beneath its parent. Everything it
/// omits is present in full on the cards immediately below it, so the table's job there
/// is purely at-a-glance summary.
enum ReleasesTableMode {
    case standard
    case releaseCard
}

// MARK: - Table Row Model
private extension ReleaseRow {
    /// The release year as the Year cell draws it: in the tertiary color while the release
    /// date is still ahead, so an unreleased disc reads as not yet in hand at a glance.
    ///
    /// Decided when the cell is drawn rather than when the row is built, against
    /// CurrentDay's `today`, which the reading view observes — so the year darkens on the day
    /// the release comes out without the table being rebuilt.
    @MainActor var yearText: Text {
        let upcoming = ReleaseDateValue(release.releaseDate, format: release.format)?
            .isUpcoming(today: CurrentDay.shared.today) ?? false
        return upcoming ? Text(releaseYear).foregroundStyle(.tertiary) : Text(releaseYear)
    }
}

private struct ReleaseRow: Identifiable {
    // Stable ID derived from the release's own UUID so that ForEach can correctly
    // diff rows across recomputes rather than treating every render as a full replacement.
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
    /// False for 4K UHD rows when no 4K release in the current set is marked remastered.
    /// True for all Blu-ray and DVD rows, and for 4K rows once at least one 4K release
    /// is affirmatively remastered (at which point all 4K rows display their status).
    let showRemasteredIndicator: Bool
    let cost: String
    let amountSpent: String
    let purchaseDate: String
    let condition: String
    let nationalOrigin: String
    let notes: String
    /// True when this release hangs off a parent (a combo-pack child Blu-ray). Read only
    /// in `.releaseCard` mode, where it suppresses the purchased and studio cells — both
    /// would merely repeat the parent row directly above — and selects the badge's
    /// open-top outline.
    ///
    /// This also answers "does the row above continue my stack?", which used to be a
    /// separate `hasStackedAbove` field. The two differed only for an ORPHANED child — one
    /// naming a parent absent from the displayed set, which is a child with nothing above
    /// it to meet, so it needed a closed badge while keeping its cells suppressed. Orphans
    /// are now impossible by construction, and `.releaseCard` ordering
    /// (`releasesGroupedByHierarchy` flattened) always places a child immediately after
    /// either its parent or an earlier sibling of the same parent — so every child has a
    /// stack-mate directly above and the two fields carried identical values. See that
    /// function's "GROUP SHAPE" note, including the one residual it cannot rule out: a
    /// parent dropped by the format filter leaves its child drawing an open-topped badge
    /// that meets nothing, which is cosmetic and reachable only from a corrupt backup.
    ///
    /// The other direction is genuinely order-dependent and still computed; see
    /// `hasStackedBelow`.
    let isChild: Bool
    /// True when the row immediately below this one belongs to the same stack, so the
    /// format badge draws an open-bottom outline that meets the next row's open-top one.
    ///
    /// "Same stack" covers two adjacencies, not one: the next row is this release's own
    /// child, OR the next row is a *sibling* child of the same parent. The second case is
    /// what a "Combo-pack (dual BD)" pack introduces — its first Blu-ray child has an
    /// open top (it meets the parent above) and an open bottom (it meets its sibling
    /// below), leaving the badge with no closed edge at all. Naming the field for the
    /// adjacency rather than for the child relationship is what keeps that case
    /// expressible; the old `hasStackedChild` could only ever describe the parent's edge.
    ///
    /// Only ever true in `.releaseCard` mode, whose ordering is what guarantees the
    /// adjacency; `.standard` ordering makes no such promise, so it never sets this.
    let hasStackedBelow: Bool
}

struct DiscReleasesTable: View {
    // Deliberately reads no environment: this view's entire input is the
    // pre-filtered `releases` array passed down from RSBReleasesSection, which already
    // owns the `\.sidebarFilm` dependency and re-derives the array on film changes.
    // Declaring an unused `@Environment(\.sidebarFilm)` here only subscribed this
    // view to a value it never consulted.
    @Binding var isTableExpanded: Bool

    // Pre-filtered releases passed in from RSBReleasesSection.
    let releases: [ReleaseSnapshot]

    /// Defaults to `.standard`. That default is currently unexercised — the sole caller
    /// passes `.releaseCard` — and is retained deliberately; see this file's header note.
    var mode: ReleasesTableMode = .standard

    // The rows (and the scrolling layout's Notes width) are derived from `releases` in the
    // pass that draws them. They used to be cached in @State written from
    // onChange(initial:), which drew every new film twice — once with the previous film's
    // rows, then again once the handler replaced them — so the cache cost a full extra
    // pass to save a build that is one pass's worth of work. SwiftUI skips this body
    // entirely when `releases` and the binding are unchanged, so nothing is rebuilt on
    // unrelated renders either.

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
            // No module title here: the tab is already named "Releases" and the cards
            // below say what they are. No vertical padding either — the table is one
            // member of RTabReleases' stack, so its spacing above and below is set by
            // that stack's own top inset and spacing rather than baked in here, which is
            // what keeps the gaps identical whether or not this table is present.
            compactTable
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Compact Table (.releaseCard mode)

    /// The first five columns only, non-scrolling. The Studio column is deliberately
    /// given no `maxWidth` so it absorbs whatever width is left over after the four
    /// fixed columns; with horizontal scrolling off, a fixed 142pt Studio column would
    /// overrun the 300pt sidebar and simply be clipped.
    private var compactTable: some View {
        CustomTable(
            buildTableData(from: releases),
            columns: [
                CustomTableColumn(
                    "", systemImage: "opticaldisc.fill", minWidth: ColW.format, maxWidth: ColW.format, alignment: .center, cellPadding: 4),
                // MARK: Zero cellPadding on Pur. and Reg.
                // CustomTable applies cellPadding OUTSIDE the header label's own
                // minWidth/maxWidth frame (see CustomTable.headerRow), so those points
                // widen the column's footprint without giving the label a single point
                // more room to render in. "Pur." and "Reg." are the two narrowest text
                // headers in this layout and already sit within a few points of their
                // column widths, which is why the widths themselves cannot come down —
                // but the padding around them is pure surplus and can.
                //
                // Dropping it from 2 to 0 takes 4pt off each column's total width while
                // leaving the labels exactly the width they have today, so neither can
                // begin to truncate as a result of this change. The data cells below
                // shed their matching .padding(.horizontal, 2) so header and content
                // stay on the same geometry; their 16pt badges keep 3pt (Pur.) and 5pt
                // (Reg.) of slack inside the column frame, so nothing crowds there
                // either. Both columns' text neighbors carry the default 8pt
                // cellPadding, so the gutter between headings never falls below 8pt.
                //
                // Scoped to this layout on purpose — the `.standard` column list below
                // keeps its 2pt, since it scrolls horizontally and is not width-starved.
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
            // The scrolling layout puts both the header and the data rows at a leading
            // inset of 10. With horizontal scrolling off, CustomTable instead adds its
            // 2pt `scrollCompensation` to the rows (10 + 2 = 12) and drops the header to
            // that 2 alone. Reducing contentPadding to 8 restores the rows to a visual
            // 10, and the header overrides restore the header to the same 10 / trailing 8
            // the rows sit at — so this table's columns line up with their headings and
            // with the standard mode's geometry.
            contentPadding: 8,
            headerLeadingPadding: 10,
            headerTrailingPadding: 8
        ) { row in
            // Format badge (col 1). No vertical padding, and a full-height frame, so a
            // stacked parent/child pair's outlines meet exactly at the row boundary.
            StackedFormatBadge(
                label: ReleaseFormat.badge(for: row.release.format),
                outlined: row.release.format == ReleaseFormat.uhd4K.rawValue || row.isChild,
                openBottom: row.hasStackedBelow,
                openTop: row.isChild)
            .allowsHitTesting(false)
            .frame(minWidth: ColW.format, maxWidth: ColW.format, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 4)

            // Purchased (col 2) — omitted for a child, whose purchase is recorded on the
            // parent row directly above it.
            Group {
                if row.isChild {
                    Color.clear.frame(width: 16, height: 16)
                } else {
                    // Unpurchased releases draw the same dashed-circle glyph as the
                    // release card's header badge, in the same red — not the plain
                    // "xmark" the other indicator columns still use.
                    purchasedIndicator(row.purchased)
                }
            }
            // No horizontal padding — matches this column's cellPadding: 0 above.
            .frame(minWidth: ColW.purchased, maxWidth: ColW.purchased, alignment: .center)
            .padding(.vertical, 2)

            // Year (col 3) — a child reports its base release year, and only when it
            // actually carries one. Its own release year is the combo pack's, already
            // stated on the parent row directly above, so repeating it would say nothing;
            // a base release year is the one date a child can contribute that the parent
            // does not. With neither, the cell is left blank rather than filled with a
            // duplicate.
            //
            // A release not yet out has its year in the tertiary color; see `yearText`.
            CustomTableCell(row.isChild ? Text(row.baseReleaseYear) : row.yearText,
                            minWidth: ColW.year, maxWidth: ColW.year, alignment: .center)

            // Region (col 4)
            RegionCell(value: row.regionLock, format: row.release.format)
                // No horizontal padding — matches this column's cellPadding: 0 above.
                .frame(minWidth: ColW.region, maxWidth: ColW.region, alignment: .center)
                .padding(.vertical, 2)

            // Studio (col 5) — likewise omitted for a child; a combo pack has one studio.
            CustomTableCell(row.isChild ? "" : row.studio,
                            minWidth: ColW.compactStudioMinimum, maxWidth: .infinity)
        }
        // No Notes width here, unlike the scrolling layout below: this layout draws
        // only the first five columns and has no Notes column at all.
    }

    /// The table itself, kept in its own property so `body` stays a trivial
    /// expression for the type-checker despite the 22-column builder below.
    private var table: some View {
        // Computed once per pass and captured, not re-derived per row.
        let notesColumnWidth = computeNotesColumnWidth(from: releases)
        return CustomTable(
            buildTableData(from: releases),
            columns: [
                CustomTableColumn(
                    "", systemImage: "opticaldisc.fill", minWidth: ColW.format, maxWidth: ColW.format, alignment: .center, cellPadding: 4),
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

            // Year (col 3) — tertiary while the release is not yet out; see `yearText`.
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

            // Remastered (col 15)
            // For 4K UHD rows the indicator is suppressed until at least one 4K release
            // in the set is marked remastered; once that threshold is met, all 4K rows
            // display their individual status.  Blu-ray and DVD rows always show.
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

    /// Artwork tags that `ArtworkCell` draws a dedicated glyph for, and which therefore
    /// reach it verbatim rather than being folded into the qualified "Yes*" bucket. Held
    /// as a type-level constant rather than built inside the per-release mapping below,
    /// where it would allocate a fresh Set for every row on every rebuild.
    private static let literalArtworkTags: Set<String> = [
        ReleaseArtwork.steelbook,
        ReleaseArtwork.yes,
        ReleaseArtwork.yesMultiPack,
        ReleaseArtwork.noMultiPack,
        ReleaseArtwork.yesComboPack,
        ReleaseArtwork.noComboPack
    ]

    private func buildTableData(from source: [ReleaseSnapshot]) -> [ReleaseRow] {
        // Determine whether any 4K UHD release in this set is affirmatively remastered.
        // This drives the Rem. column visibility rule: all 4K rows are blank until the
        // threshold is met, then all 4K rows show their individual remaster status.
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

        // Which rows have their BOTTOM edge open, i.e. the row below continues their stack.
        // Computed off the final order rather than inferred per-row from `childReleaseIDs`,
        // so the outline can never claim an adjacency the layout does not actually have.
        //
        // Two adjacencies count as continuing a stack: the next row is this release's own
        // child, or the next row is a sibling child of the same parent. The second is what
        // "Combo-pack (dual BD)" introduces — its first Blu-ray is met from above by the
        // parent and from below by its sibling — and it is why this cannot be reduced to
        // "has children".
        //
        // Only this direction is computed. The TOP edge used to be accumulated alongside it
        // as a separate `hasStackedAbove` set, which was needed only to tell an orphaned
        // child (a child with nothing above it to meet) from an ordinary one. Orphans are
        // now impossible by construction, and this ordering places every child immediately
        // after its parent or an earlier sibling, so "the row above continues my stack" is
        // exactly `isChild` and is read directly from the row.
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
                    // Child → the next sibling child of the same parent. Guarding on the
                    // CURRENT row's parentReleaseID being non-nil is what stops two
                    // top-level releases — which both carry nil — from being read as
                    // siblings of one another and welded into a stack.
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
                // Artwork display. Every tag `ArtworkCell` draws a dedicated glyph for is
                // passed through untouched; any OTHER affirmative variant — the picker's
                // "Yes (Custom artwork)", "Yes (Incorrect release)", or a value from an
                // older database — collapses to "Yes*", which that cell renders as the
                // amber "affirmative but qualified" check. Anything else passes through
                // to be shown as its own text.
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
/// The format label with its optional 1pt outline. A standalone 4K release gets the same
/// compact rounded badge the standard table draws. A parent with its child on the next row
/// gets an outline with its bottom edge open, and the child gets one with its top edge
/// open; both run the full height of their row, so the two meet flush at the row boundary
/// and read as a single tall rectangle spanning the pair — the effect the cards achieve
/// with one shared plate, without needing an outline that can span rows.
private struct StackedFormatBadge: View {
    let label: String
    let outlined: Bool
    let openBottom: Bool
    let openTop: Bool

    /// True when this badge participates in a stacked pair and so must run edge to edge.
    private var isStacked: Bool { openBottom || openTop }

    /// A single fixed width for every stacked badge. Left to size themselves naturally,
    /// "4K" and "BD" measure a fraction of a point apart, and — being center-aligned in
    /// the column — their outlines' left edges then fail to line up by half that
    /// difference. One shared width makes the pair's sides exactly collinear. Set wide
    /// enough to clear the widest stacked label at 11pt bold with the standard mode's
    /// 4pt of breathing room on each side.
    private static let stackedWidth: CGFloat = 26

    /// How far the closed edge sits in from the row boundary, which is what keeps the
    /// outline hugging the text as tightly as the standard mode's badge does rather than
    /// stretching to the full row height. Derived from CustomTable's 22pt row against a
    /// badge whose visual height matches the standard badge's (11pt bold text plus its
    /// 1pt vertical padding, ≈15pt): (22 − 15) / 2.
    private static let closedEdgeInset: CGFloat = 3.5

    /// How far each vertical side sits in from the frame's own edge, applied to all
    /// three stack positions (open-bottom parent, both-open middle child, open-top last
    /// child) so their sides stay collinear. `stackedWidth` is sized to hold the label
    /// itself; the standard mode's badge hugs its text more tightly than that, so the
    /// drawn outline is pulled in 1pt per side — 2pt narrower overall — to match it.
    /// Kept separate from `stackedWidth` deliberately: narrowing the frame instead would
    /// narrow the text's centering box along with the outline, so the pair's labels and
    /// their sides would no longer be guaranteed to line up.
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
                // The shape spans the full row height; it insets its own closed edge, so
                // only the open edge actually reaches the row boundary and meets its
                // neighbor's.
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
            // Two frames rather than one: there is no `frame` overload combining a fixed
            // `width` with a flexible `maxHeight`. The inner fixes the width, the outer
            // grows to the full row height so the outline's open edge reaches the row
            // boundary exactly.
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

/// A rounded rectangle with one or both horizontal edges removed. The path is inset by
/// half a point on every closed edge so a 1pt centered stroke lands fully inside the
/// frame; each open edge is left flush with the frame boundary so the neighboring row's
/// outline continues it without a seam.
///
/// Three shapes, one per position in a stack:
///   • open bottom only — the parent at the top of the stack: rounded top, open below.
///   • open top only    — the last child: open above, rounded bottom.
///   • both open        — a *middle* child, which only a "Combo-pack (dual BD)" pack
///     produces: the first of two Blu-rays, meeting the parent above and its sibling
///     below. It has no closed edge and therefore no corners at all, reducing to two
///     bare full-height verticals that carry the stack's sides past this row.
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
            // Middle of the stack: two full-height lines, drawn as separate subpaths so
            // the stroke never closes across the top or bottom. Both run the frame's full
            // height (top == rect.minY, bottom == rect.maxY here), so they meet the
            // outlines above and below flush at both row boundaries.
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
// Every colored circular indicator in this table (purchased, subtitles, remastered,
// artwork, and the lettered/numbered region badges) is the same 14pt filled circle
// with a white, drop-shadowed glyph or character centered in it. (The 16pt figures
// elsewhere in this file are the Color.clear placeholders that hold a cell's footprint
// open — deliberately a shade larger than the badge, and not the badge itself.)
// That ZStack was
// written out verbatim eight times; it now lives here once, so the circle diameter,
// shadow, and label color are defined in a single place.
/// Not `private`: RTabReleases (24_20) reuses this verbatim, scaled up, for the release
/// cards' purchase-status glyph — see the note on `symbolBadge` below.
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
    /// Drop shadow for the circular fill ALONE — nil (the default, and every table call
    /// site) draws none. This is deliberately applied to the `Circle` itself rather than
    /// to the composed badge: a shadow on the whole ZStack would pick up the label's own
    /// already-shadowed silhouette and cast a second, blurrier shadow behind that shadow,
    /// visibly changing how the label's shadow reads. Keeping the two shadows on separate
    /// layers is what lets RTabReleases give its card-header checkmark badge a shadow
    /// around the fill without disturbing the label shadow above, which must stay exactly
    /// what `inkNeedsShadow` alone already produces.
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
/// `@MainActor` is required because `IndicatorBadge` conforms to `View`, and Swift 6
/// infers main-actor isolation for the whole type (including its initializer) from
/// that conformance. A file-scope function is nonisolated by default, so constructing
/// the badge from one would be a cross-actor call. Every caller — the row builder in
/// `DiscReleasesTable`, `RegionCell`, and `ArtworkCell` — is itself main-actor
/// isolated for exactly the same reason, so this annotation costs nothing at any call
/// site and simply states the isolation these helpers already operate under.
/// Not `private`: RTabReleases (24_20) calls this directly for its release cards' purchase
/// glyph, so that badge is the exact same view as this table's — not a lookalike built
/// from the same constants — just drawn at a larger `diameter`. The glyph's own font size
/// is derived from `diameter` at this table's own ratio (8pt glyph in a 14pt circle) so
/// scaling one scales the other.
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
/// The character's size and weight come from `RSBRegionBadge.characterFont`, shared with
/// `RSBIndicatorView` on the release cards. That constant exists precisely to hold the two
/// renderers together — both draw into the same 14pt circle, so a difference of even a
/// point makes one of them sit visibly large in its disc and read as off-center beside the
/// other, which is what happened when this site carried 11pt and split its weight by state.
/// Reading the constant is what makes that guarantee structural; restating its value here
/// in a literal (with a comment asserting the two agree) left it to be maintained by hand,
/// which is the arrangement the drift happened under.
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
// The table's drawing of an `RSBRegionIndicator`. Which mark a stored region resolves to,
// and how a playable disc is colored versus a locked one, are shared with the release cards
// below this table — see `RSBRegionIndicator` / `RSBRegionBadge` in RSBHelpers. Both used
// to be written out in full here and again in RTabReleases, with a comment on each telling
// the reader to keep them in step.
//
// What stays here is this context's own chrome: the cell centers itself in a fixed column,
// and its globe and raw-value fallback take the adaptive label color, since they sit on the
// row background rather than on the cards' opaque gray pill.
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
// Moved here from RTabDetails.swift when the releases module left the "Details" tab:
// this wrapper's only consumer is the "Releases" tab, which prepends it above its cards
// when Preferences.showReleasesSummaryTable is enabled (see RTabReleases). Keeping it
// beside the table it feeds keeps the two from drifting.
//
// RightSidebar is the single source of truth: it handles both .updated and
// .releaseChanged events and refreshes the environment snapshot before any child view
// sees the event. RSBReleasesSection therefore derives its filtered releases from the
// environment film value in its body, avoiding the race condition that arose when both
// RightSidebar and this view subscribed to the same AppEventBus event simultaneously
// (the sibling onReceive fired before the environment propagation completed).
struct RSBReleasesSection: View {
    @Environment(\.sidebarFilm) private var film: FilmSnapshot?

    var releasesExpanded: Binding<Bool>

    /// Which of DiscReleasesTable's two layouts to draw. `.standard` remains the default
    /// even though every current call site passes `.releaseCard`; see this file's header
    /// maintenance note.
    var mode: ReleasesTableMode = .standard

    var body: some View {
        // Derived in the pass rather than cached in @State from onChange(initial:), which
        // drew each new film twice (first with the previous film's releases). Filtering is
        // a single pass over a handful of releases, and DiscReleasesTable's own body is
        // skipped by SwiftUI whenever the filtered array comes out equal.
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
        // Membership is decided by `ReleaseFormat` — a format string this build does not
        // recognize is excluded — which is exactly the test `RSBReleaseCardBuilder.buildGroups`
        // applies to build the cards below this table. Sharing the single expression is what
        // makes "the table and the cards draw the same release set" structural rather than
        // two constructions that happen to agree.
        //
        // This replaces the former `FilmSnapshot.releases4K + releases2K + releasesSD`
        // accessors (since deleted), which cost three filter passes plus three
        // `sorted { $0.dateAdded < $1.dateAdded }` passes whose ordering
        // was then discarded: `buildTableData` regroups through `releasesGroupedByHierarchy`
        // (`.releaseCard`) or re-sorts flat (`.standard`), so nothing downstream can observe
        // the order this arrives in. The card builder documents the same conclusion for its
        // own copy of this filter.
        return film.releases.filter { ReleaseFormat(rawValue: $0.format) != nil }
    }
}
