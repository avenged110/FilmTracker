// MARK: - ReleasesTable.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// The summary table in RightSidebar's Releases tab, shown above the release cards when
/// Preferences.showReleasesSummaryTable is on. One row per disc release: format, purchased, year, region, and studio. The cards
/// below carry every other field, so the table stays a summary. It does not scroll, has no module title, and stacks each
/// combo-pack child under its parent.
///
/// SHARED WITH THE RELEASE CARDS
/// The region lock and release grouping and ordering are defined once in RSBHelpers'
/// "Releases Tab: Shared Derivations" section. Do not reimplement them here. This file owns only the table's own geometry and cell chrome.

import SwiftUI

// MARK: - Column Widths
/// Edit a value here to resize that column. Studio is flexible and takes the width the other four leave.
private enum ColW {
    static let format:    CGFloat = 32   /// Format badge (4K / BD / DVD)
    static let purchased: CGFloat = 22   /// Purchased indicator
    static let year:      CGFloat = 32   /// Release year
    static let region:    CGFloat = 26   /// Region lock badge
    /// Floor for the flexible Studio column.
    static let studioMinimum: CGFloat = 60
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
    /// The release's own UUID, so ForEach can diff rows across recomputes.
    var id: UUID { release.id }
    let release: ReleaseSnapshot
    let releaseYear: String
    let baseReleaseYear: String
    let regionLock: String        /// Display region string
    /// True when this release is a combo-pack child. It hides the purchased and studio cells (they repeat the parent above)
    /// and sets the badge's open-top outline. It also means the row above continues this stack.
    /// Orphans cannot occur, because grouping always places a child directly after its parent or a sibling (see `releasesGroupedByHierarchy`).
    /// The one residual is a parent dropped by the format filter, which can leave a cosmetic open top. That happens only with a corrupt backup.
    /// The reverse direction depends on order and is computed in `hasStackedBelow`.
    let isChild: Bool
    /// True when the next row is in the same stack, so this format badge's bottom edge is open. The next row is either this
    /// release's child or a sibling child of the same parent. The sibling case covers a "Combo-pack (dual BD)" pack, whose first
    /// Blu-ray has an open top and bottom.
    let hasStackedBelow: Bool
}

// MARK: - Disc Releases Table
struct DiscReleasesTable: View {
    /// Reads no environment. Its input is the pre-filtered `releases` array from RSBReleasesSection, which owns the `\.sidebarFilm` dependency.
    @Binding var isTableExpanded: Bool

    /// Pre-filtered releases passed in from RSBReleasesSection.
    let releases: [ReleaseSnapshot]

    /// The rows are derived from `releases` in each draw pass. A cache would draw a new film twice. SwiftUI skips this body when
    /// `releases` and the binding are unchanged.
    var body: some View {
        /// No vertical padding: the RTabReleases stack sets the spacing, so the gaps match whether or not this table is shown.
        CustomTable(
            buildTableData(from: releases),
            columns: [
                CustomTableColumn(
                    "", systemImage: ContentGlyphs.disc, minWidth: ColW.format, maxWidth: ColW.format, alignment: .center, cellPadding: 4),
                /// Pur. and Reg. use cellPadding 0. CustomTable adds the padding outside the header label's frame, so the padding
                /// widens the column without giving the label room. Dropping it from 2 to 0 frees 4 pt per column, and the labels keep
                /// their width, so they cannot truncate. The data cells drop the matching 2 pt padding too. Their badges still have slack.
                CustomTableColumn(
                    "Pur.", minWidth: ColW.purchased, maxWidth: ColW.purchased, alignment: .center, cellPadding: 0),
                CustomTableColumn(
                    "Year", minWidth: ColW.year, maxWidth: ColW.year, alignment: .center),
                CustomTableColumn(
                    "Reg.", minWidth: ColW.region, maxWidth: ColW.region, alignment: .center, cellPadding: 0),
                /// No `maxWidth`, so Studio takes the width the four fixed columns leave. A fixed width would overrun the sidebar and be clipped.
                CustomTableColumn(
                    "Studio", minWidth: ColW.studioMinimum)
            ],
            isExpanded: $isTableExpanded,
            allowHorizontalScroll: false,
            /// Without scrolling, CustomTable adds a 2 pt `scrollCompensation` to the rows and drops the header to 2. contentPadding 8 brings the rows
            /// back to a visual 10. The header overrides set the header to the same 10 / 8, so the columns line up with the headings.
            contentPadding: 8,
            headerLeadingPadding: 10,
            headerTrailingPadding: 8
        ) { row in
            /// Format badge. No vertical padding, and a full-height frame, so stacked outlines meet at the row boundary.
            StackedFormatBadge(
                label: ReleaseFormat.badge(for: row.release.format),
                outlined: row.release.format == ReleaseFormat.uhd4K.rawValue || row.isChild,
                openBottom: row.hasStackedBelow,
                openTop: row.isChild)
            .allowsHitTesting(false)
            .frame(minWidth: ColW.format, maxWidth: ColW.format, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 4)

            /// Purchased. Omitted for a child, whose purchase is on the parent row above.
            Group {
                if row.isChild {
                    Color.clear.frame(width: 16, height: 16)
                } else {
                    purchasedIndicator(row.release.purchased)
                }
            }
            /// No horizontal padding — matches this column's cellPadding: 0 above.
            .frame(minWidth: ColW.purchased, maxWidth: ColW.purchased, alignment: .center)
            .padding(.vertical, 2)

            /// Year. A child shows only its base release year, since the parent above already states the pack's year. A blank cell is
            /// used when there is no base year. A release not yet out uses the tertiary color (see `yearText`).
            CustomTableCell(row.isChild ? Text(row.baseReleaseYear) : row.yearText,
                            minWidth: ColW.year, maxWidth: ColW.year, alignment: .center)

            /// Region
            RegionCell(value: row.regionLock, format: row.release.format)
                /// No horizontal padding — matches this column's cellPadding: 0 above.
                .frame(minWidth: ColW.region, maxWidth: ColW.region, alignment: .center)
                .padding(.vertical, 2)

            /// Studio. Omitted for a child, since a combo pack has one studio.
            CustomTableCell(row.isChild ? "" : row.release.studio,
                            minWidth: ColW.studioMinimum, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Table Data Builder
    private func buildTableData(from source: [ReleaseSnapshot]) -> [ReleaseRow] {
        let ordered = releasesGroupedByHierarchy(source).flatMap { $0 }

        /// Rows whose bottom edge is open, so the row below continues their stack. This is computed from the final order, so an outline
        /// never claims an adjacency the layout lacks. Two adjacencies count: the next row is this release's child, or a sibling child of the same parent.
        /// The second is the dual-BD case, so this cannot reduce to "has children". The top edge is `isChild`, read directly from the row.
        var idsWithStackedBelow: Set<UUID> = []
        for (index, release) in ordered.enumerated() where index + 1 < ordered.count {
            let next = ordered[index + 1]
            let continues: Bool
            if next.parentReleaseID == release.id {
                /// Parent → its own child.
                continues = true
            } else if let parentID = release.parentReleaseID {
                /// Child → the next sibling child of the same parent. The non-nil guard on the current row
                /// keeps two top-level releases (both nil) from being read as siblings.
                continues = (next.parentReleaseID == parentID)
            } else {
                continues = false
            }
            if continues { idsWithStackedBelow.insert(release.id) }
        }

        return ordered.map { release in
            ReleaseRow(
                release: release,
                /// The release date's year — ReleaseDateValue.yearText trims.
                releaseYear: ReleaseDateValue.yearText(of: release.releaseDate, format: release.format),
                /// Trimmed, as the release cards trim it (RSBReleaseCardBuilder.model). The column is centered, so stray
                /// whitespace would center differently here than in the card describing the same release.
                baseReleaseYear: release.baseReleaseYear.trimmingCharacters(in: .whitespacesAndNewlines),
                /// Shared with the release cards below this table — see RSBHelpers' shared-derivations section.
                regionLock: RSBRegionIndicator.displayValue(release.regionLock, format: release.format),
                isChild: release.isChild,
                hasStackedBelow: idsWithStackedBelow.contains(release.id)
            )
        }
    }
}

// MARK: - Stacked Format Badge
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
                /// The shape spans the full row height and insets its own closed edge. Only the open edge reaches the boundary.
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

    /// Explicit @ViewBuilder: ViewModifier.body is not an implicit builder context, so
    /// the two branches below would otherwise have to resolve to one type.
    @ViewBuilder
    func body(content: Content) -> some View {
        if isStacked {
            /// Two frames, because no single `frame` overload combines a fixed width with a flexible height. The inner fixes the width,
            /// and the outer grows to the full row height so the open edge reaches the boundary.
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
        /// Clamp so a short row can never produce a corner arc larger than the box.
        let radius = min(3, (right - left) / 2, (bottom - top) / 2)

        if openTop && openBottom {
            /// Middle of the stack: two full-height lines as separate subpaths, so the stroke never closes across the top or bottom.
            path.move(to: CGPoint(x: left, y: top))
            path.addLine(to: CGPoint(x: left, y: bottom))
            path.move(to: CGPoint(x: right, y: top))
            path.addLine(to: CGPoint(x: right, y: bottom))
        } else if openTop {
            /// Sides plus a rounded bottom.
            path.move(to: CGPoint(x: left, y: top))
            path.addLine(to: CGPoint(x: left, y: bottom - radius))
            path.addQuadCurve(to: CGPoint(x: left + radius, y: bottom),
                              control: CGPoint(x: left, y: bottom))
            path.addLine(to: CGPoint(x: right - radius, y: bottom))
            path.addQuadCurve(to: CGPoint(x: right, y: bottom - radius),
                              control: CGPoint(x: right, y: bottom))
            path.addLine(to: CGPoint(x: right, y: top))
        } else {
            /// Sides plus a rounded top (the open-bottom parent case).
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

// MARK: - Circular Indicator Badges
/// Each colored circle indicator here (purchased and region badges) is UtilityKit's
/// `GlyphBadge` at its defaults: a 14 pt filled circle with a white, drop-shadowed glyph or character. The 16 pt
/// Color.clear placeholders elsewhere hold a cell's footprint open.

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
            GlyphBadge(systemName: "checkmark", color: Preferences.green)
        } else {
            Image(systemName: "circle.dashed")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Region Cell Component
/// Draws an `RSBRegionIndicator`. The mark selection and playable-versus-locked colors come from `RSBRegionIndicator` and `RSBRegionBadge`
/// in RSBHelpers, shared with the cards. What stays here is the cell's own chrome. It centers in a fixed column, and its globe and raw
/// fallback use the adaptive label color, since they sit on the row background rather than the cards' opaque pill.
private struct RegionCell: View {
    /// The display region — 4K UHD's empty-means-Region-Free default is already applied by
    /// `buildTableData`.
    let value: String
    /// Only the format is needed, to tell DVD's numbered regions from the lettered scheme.
    let format: String

    var body: some View {
        switch RSBRegionIndicator.resolve(value, format: format) {
        case let .character(label, playable):
            /// The shared `GlyphBadge`, so the region disc matches every other colored
            /// indicator in this table in size and shadow.
            GlyphBadge(character: label,
                       color: RSBRegionBadge.fill(playable: playable),
                       ink: RSBRegionBadge.ink(playable: playable),
                       font: RSBRegionBadge.characterFont,
                       inkShadow: RSBRegionBadge.inkNeedsShadow(playable: playable) ? .ink : nil)
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
            /// Nothing recorded. Holds a badge-sized footprint rather than collapsing —
            /// the same idiom the Purchased column uses for a suppressed child cell — so
            /// the row keeps its height regardless of what the other cells contain.
            Color.clear
                .frame(width: 16, height: 16)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: - Releases Section
/// The Releases tab's table wrapper. The tab prepends it above the cards when Preferences.showReleasesSummaryTable is on (see RTabReleases).
///
/// RightSidebar is the single source of truth. It handles .updated and .releaseChanged and refreshes the environment snapshot before children
/// see the event. This view derives its releases from that environment value. Subscribing here too raced: the sibling onReceive could fire
/// before the environment updated.
struct RSBReleasesSection: View {
    @Environment(\.sidebarFilm) private var film: FilmSnapshot?

    var releasesExpanded: Binding<Bool>

    var body: some View {
        /// Derived each pass, not cached, since a cache would draw each new film twice. Filtering is one cheap pass, and SwiftUI
        /// skips DiscReleasesTable when the array is unchanged.
        let releases = discReleases(of: film)
        VStack(spacing: 8) {
            if !releases.isEmpty {
                DiscReleasesTable(isTableExpanded: releasesExpanded,
                                  releases: releases)
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
        /// Same membership test as `RSBReleaseCardBuilder.buildGroups`, so the table and the cards below draw the same release set.
        /// The former releases4K/2K/SD accessors did three filter and sort passes. Their ordering was discarded, since buildTableData
        /// regroups, so nothing downstream sees the input order.
        return film.releases.filter { ReleaseFormat(rawValue: $0.format) != nil }
    }
}
