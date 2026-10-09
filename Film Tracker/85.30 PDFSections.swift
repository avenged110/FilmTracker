// MARK: - PDFSections.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The library PDF's two per-film detail sections: "Viewing History" and "Disc-based
// Releases".
//
// Layer three of the PDF stack described at the top of PDFCore.swift (85.00), beside
// LibraryPDFReport (85.20). Both sections here are ONE ROW PER FILM followed by that film's
// own detail rows, rather than the one-row-per-film summary the complete-library table is —
// which is the whole reason they exist: the summary table has a fixed sixteen columns and a
// film may have any number of viewings and any number of releases.
//
// # The shape both sections take
//
// `PDFTableRenderer` draws a flat list of rows; it has no concept of a nested group. The
// nesting is therefore expressed in the DATA, identically in both sections:
//
//   * A FILM ROW carries the index and the title, and is filled edge to edge in the
//     neutral gray. It is the only filled-across row either section draws, so a reader
//     scanning down the page sees the films as bands and everything between two bands as
//     belonging to the upper one.
//   * DETAIL ROWS leave the index and title columns empty and begin in the columns to
//     their right, which is the indent — the detail is physically inset from the title it
//     hangs off, at the width of the title column.
//   * A film with nothing to report still gets its film row, carrying the reason in place
//     of a count. Skipping it would leave the reader unable to tell "this film has no
//     releases" from "I lost my place".
//
// # What each section does NOT restate
//
// Film order comes from `LibraryPDFReport.ordered`, so a film sits at the same position in
// all three sections. The viewing entries come from `viewingHistoryEntries(from:)` in
// CalendarTable (24.14) — the same call the sidebar's own Viewing History table makes, so
// the paper copy cannot disagree with the screen about which viewings there are, what order
// they are in, or what gap is printed beside them. Release order and every derived release
// string come from the shared helpers in RSBHelpers (24.02) that the sidebar's releases
// table uses.

import AppKit
import Foundation

// MARK: - Shared Presentation

/// The conventions the two sections below share, so a reader moving between them is
/// reading one document rather than two reports that happen to be stapled together.
@MainActor
private enum FilmDetailStyle {
    /// The band drawn across a film row. The palette's neutral, which is the only shade in
    /// it that carries no meaning of its own — a film row is structure, not a data point,
    /// and must not read as a quality or purchase judgment.
    static let filmBand = PDFPalette.lightGray

    /// The stand-in for a field with nothing in it — the complete-library table's own
    /// placeholder, `PDFCellText.placeholder`.
    static let dash = PDFCellText.placeholder

    /// `text`, or the placeholder when it is blank.
    static func orDash(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? dash : text
    }

    /// A film row: the index and title, whatever else the section puts beside them, and
    /// the band drawn straight across `columnCount` columns.
    ///
    /// `values` names the remaining cells by column index rather than the row taking one
    /// fixed shape, because the two sections put different things in different places — a
    /// viewing count and a release count do not sit in the same column, and both now sit
    /// beside a release year.
    ///
    /// # Why the band has no internal rules
    ///
    /// Every cell after the index drops its vertical edges, so the band reads as ONE block
    /// from the title to the last column rather than as a row of mostly-empty cells. The
    /// values inside it do not move — the year and the count stay in the columns whose
    /// headers name them, and stay aligned with the detail rows below — but the rules that
    /// would divide them are gone, because on this row they divide nothing: a film row is
    /// a heading for what follows, not a record with fields of its own.
    ///
    /// The index keeps ALL four of its edges. It is the one cell on the band that is a
    /// value in its own column, and the rule after it is what separates the number from
    /// the heading it labels.
    static func filmRow(index: Int,
                        film: FilmSnapshot,
                        columnCount: Int,
                        values: [Int: String]) -> [PDFCell] {
        (0..<columnCount).map { column in
            switch column {
            // The rule across the top of the band is BLACK, the whole way across — the
            // boundary between one film and the next is the strongest line on the page.
            case 0:
                return PDFCell("\(index)", fill: filmBand, monospaced: true,
                               topRuleColor: PDFPalette.filmRule)
            case 1:
                return PDFCell(film.name, fill: filmBand, truncates: true,
                               borders: bandEdges(column, of: columnCount),
                               topRuleColor: PDFPalette.filmRule)
            default:
                return PDFCell(values[column] ?? "", fill: filmBand,
                               borders: bandEdges(column, of: columnCount),
                               topRuleColor: PDFPalette.filmRule)
            }
        }
    }

    /// A band cell's rules: the horizontals that close the band against its neighbors, plus
    /// the table's own right edge on the last column.
    private static func bandEdges(_ column: Int, of count: Int) -> PDFCellBorders {
        column == count - 1 ? [.top, .bottom, .right] : [.top, .bottom]
    }

    /// A cell in a column that runs UNBROKEN beneath a film's band — ruled on its sides
    /// only, so the column reads as one tall cell spanning the film's detail rows instead
    /// of being chopped into one box per row.
    ///
    /// `closing` is the last detail row of a film's run, which restores the bottom rule so
    /// the run closes against whatever follows it. See `PDFCell.borders`.
    static func continuation(_ text: String = "",
                             sides: PDFCellBorders = .sides,
                             closing: Bool) -> PDFCell {
        PDFCell(text, borders: closing ? sides.union(.bottom) : sides)
    }

    /// The leading cells of a detail row: the columns that carry nothing of their own.
    ///
    /// They are not merely unruled BETWEEN rows — they are unruled between each other too,
    /// so the region under a film's band is one open field rather than a grid of empty
    /// boxes. Only the table's own left edge and the rule that opens the first column with
    /// content in it survive, which is what makes the indent read as whitespace instead of
    /// as columns nobody filled in.
    static func indent(columns: Int, closing: Bool) -> [PDFCell] {
        (0..<columns).map { column in
            let sides: PDFCellBorders
            switch column {
            case 0:            sides = .left           // the table's own edge
            case columns - 1:  sides = .right          // opens the first column with content
            default:           sides = []
            }
            return continuation(sides: sides, closing: closing)
        }
    }

    /// `row` with every bare placeholder drawn in the secondary gray.
    ///
    /// A dash says a field was never filled in, which is a lesser fact than any value would
    /// have been, and a column of them in the primary black competed with the values around
    /// them for attention. Applied as a pass over the finished row rather than at each of
    /// the dozen sites that can produce a dash, so no site can forget. A cell that already
    /// chose a color keeps it.
    static func deemphasizingPlaceholders(_ row: [PDFCell]) -> [PDFCell] {
        row.map { cell in
            guard cell.text == dash, cell.textColor == nil else { return cell }
            var dimmed = cell
            dimmed.textColor = PDFPalette.secondaryText
            return dimmed
        }
    }

    /// `$12.34`, or the placeholder for a zero. A zero here is "nothing recorded", not
    /// "this cost nothing" — the field is unset until the user types a figure into it.
    static func money(_ amount: Double) -> String {
        amount == 0 ? dash : Fmt.dollars(amount)
    }

    /// `$12.34`, and `$0.00` for a zero — for a field whose zero is a real figure rather
    /// than an empty one. See `DiscReleasesPDFReport.money`.
    static func exactMoney(_ amount: Double) -> String {
        Fmt.dollars(amount)
    }

    /// A stored `yyyy.MM.dd` date as "November 4, 2025", or the placeholder when it is
    /// blank or unparseable. Goes through `formatDateString` — the app's one date
    /// presenter — so a value carrying a viewing-version code is handled here exactly as
    /// it is everywhere else.
    static func date(_ stored: String) -> String {
        stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? dash
            : formatDateString(stored)
    }
}

// MARK: - Viewing History Section

/// Every film in the library, each followed by its own viewing events.
///
/// The columns to the right of the title are exactly the sidebar's Viewing History table
/// (`CalendarTable`, 24.14) — date, days since the prior viewing, and the version watched —
/// because this section is that table, printed for the whole library at once.
@MainActor
enum ViewingHistoryPDFReport {
    /// The heading printed at the top of every page of this section.
    ///
    /// `nonisolated` because `LibraryPDFSection.displayName` — which names the Export tab's
    /// picker row from it, rather than spelling the title a second time — is reached from
    /// the Sendable enum's own nonisolated context.
    nonisolated static let sectionTitle = "Viewing History"

    // MARK: Column widths
    //
    // WEIGHTS, not points — `PDFTableRenderer` normalizes the set to the width of ONE PANE
    // before drawing (see `PDFTableColumn.width` and `PDFTableSection.columnsPerPage`).
    // They are written as points against a half-page pane — 720pt of content less the 14pt
    // gutter, halved, so 353pt — and sum to exactly that, which makes each value below its
    // real on-page width today.
    //
    // Every column but the title is measured against its longest value, which is what makes
    // the two-up layout worth having: nothing here grows, so a full-width table would spend
    // half the page on whitespace.

    private enum Width {
        /// The shared index width — the same column, at the same size, as the one the
        /// complete-library table and the Disc-based Releases section number their films
        /// with. Sized for a four-figure library; see `PDFColumnWidth.index`.
        static let index: CGFloat = PDFColumnWidth.index
        /// Elastic, and the column that pays for every other column's fit. Truncates rather
        /// than wraps — always, and not merely when a title is unreasonable: this column is
        /// now narrow enough that ordinary titles reach the end of it, and a wrapped title
        /// would grow the height of the film's band for no gain in identification. The year
        /// beside it is what settles an ambiguous truncation.
        static let title: CGFloat = 121
        /// The film's release year — four proportional digits.
        static let year: CGFloat = 20
        /// The viewing count, or the reason there is none — "No viewing history" is the
        /// longest thing it holds.
        static let count: CGFloat = 52
        /// A full date at its LONGEST — "September 30, 2044", not the "November 4, 2025"
        /// this column was first measured against. The month names are not the same width
        /// and neither are the day numbers, so sizing to a middling example left the widest
        /// real dates wrapping to a second line and growing their row.
        static let date: CGFloat = 63
        /// "1,234 days" at its widest.
        static let sincePrior: CGFloat = 34
        /// "Black-and-white", the longest version display name.
        static let version: CGFloat = 44
    }

    private enum Column {
        static let year = 2
        static let count = 3
        static let total = 7
        /// The columns that carry nothing on a detail row and so run unbroken beneath the
        /// band: the index, the title, the year, and the viewing count. All four describe
        /// the FILM, and a film does not change between two of its own viewings — ruling
        /// them once per viewing would divide a value that never varies.
        static let filmSpanning = 4
    }

    /// Two tables to a page. See `PDFTableSection.columnsPerPage`.
    private static let panesPerPage = 2

    // MARK: Section

    static func section(films: [FilmSnapshot]) -> PDFTableSection {
        let columns: [PDFTableColumn] = [
            PDFTableColumn("#", width: Width.index, alignment: .right,
                           headerAlignment: .center),
            PDFTableColumn("Title", width: Width.title, alignment: .left),
            // The year identifies the film, so it belongs beside the title and nowhere
            // else: two films may share a name, and the year is what tells them apart.
            PDFTableColumn("Year", width: Width.year, alignment: .center),
            PDFTableColumn("Viewings", width: Width.count, alignment: .center),
            // Right-aligned values under a CENTERED label. The dates are a column the eye
            // runs down, and ragged right edges break that; but "Viewing Date" pinned to
            // the right of its own column would read as though it belonged to "Since
            // Prior" beside it.
            PDFTableColumn("Viewing Date", width: Width.date, alignment: .right,
                           headerAlignment: .center),
            PDFTableColumn("Since Prior", width: Width.sincePrior, alignment: .right,
                           headerAlignment: .center),
            PDFTableColumn("Version", width: Width.version, alignment: .left),
        ]

        var rows: [[PDFCell]] = []
        // Each film's band plus its own viewings, so a pane never opens with viewing dates
        // whose film is on the pane before. See `PDFTableSection.keepTogether`.
        var blocks: [Range<Int>] = []
        for (position, film) in LibraryPDFReport.ordered(films).enumerated() {
            let entries = viewingHistoryEntries(from: film.calendarTable)
            let start = rows.count

            rows.append(FilmDetailStyle.filmRow(
                index: position + 1,
                film: film,
                columnCount: Column.total,
                values: [Column.year: film.releaseYear,
                         Column.count: summary(for: film, entries: entries)]))

            // Newest first, exactly as the sidebar lists them — `viewingHistoryEntries`
            // has already sorted and measured the gaps, so this loop only maps.
            for (offset, entry) in entries.enumerated() {
                let closing = offset == entries.count - 1
                rows.append(
                    FilmDetailStyle.indent(columns: Column.filmSpanning, closing: closing) + [
                        PDFCell(entry.formattedDate),
                        // The oldest viewing has no prior to measure against and comes back
                        // with an empty gap; it prints as the placeholder rather than as a
                        // blank cell, which would read as a value that failed to compute.
                        PDFCell(FilmDetailStyle.orDash(entry.daysSincePrior)),
                        PDFCell(FilmDetailStyle.orDash(
                            extractVersionCode(from: entry.original).displayName)),
                    ])
            }

            blocks.append(start..<rows.count)
        }

        return PDFTableSection(title: sectionTitle,
                               columns: columns,
                               columnsPerPage: panesPerPage,
                               keepTogether: blocks,
                               rows: rows)
    }

    // MARK: Summary

    /// What the film row says in place of a viewing count.
    ///
    /// The two empty states are NOT the same thing and the section says which one it is:
    /// a film the user has never marked watched is "Unwatched", while a film that IS marked
    /// watched but carries no dated entries has a viewing history that simply was not
    /// recorded. Reading `watched` rather than inferring from the entry count is what keeps
    /// those apart.
    private static func summary(for film: FilmSnapshot,
                                entries: [ViewingHistoryEntry]) -> String {
        if !entries.isEmpty { return "\(entries.count)" }
        return film.watched ? "No viewing history" : "Unwatched"
    }
}

// MARK: - Disc-based Releases Section

/// Every film in the library, each followed by its own disc releases, two rows per release.
///
/// # Why two rows
///
/// A release carries sixteen fields worth printing and the page has room for eight columns
/// at a legible type size. Splitting one release across two rows rather than shrinking the
/// type is the trade this section makes: the FIRST row is the release's specification —
/// what the disc is — and the SECOND is its provenance, packaging and cost — where it came
/// from and what it cost. The header band names the first row's fields; the second row's
/// cells carry their own inline labels, because a value sitting under a header that names a
/// different field is worse than no header at all.
///
/// # Combo packs
///
/// Releases are listed in `releasesGroupedByHierarchy` order, which is the sidebar's
/// releases table order: a parent immediately followed by its bundled children. A child's
/// Release cell says so in words, so the pairing survives a page break that separates it
/// from its parent.
@MainActor
enum DiscReleasesPDFReport {
    /// The heading printed at the top of every page of this section.
    ///
    /// `nonisolated` because `LibraryPDFSection.displayName` — which names the Export tab's
    /// picker row from it, rather than spelling the title a second time — is reached from
    /// the Sendable enum's own nonisolated context.
    nonisolated static let sectionTitle = "Disc-based Releases"

    // MARK: Column widths
    //
    // Weights against the FULL content width — this section has an elastic Notes field and
    // a two-row release record, so it has no whitespace to recover by splitting the page.
    // They sum to exactly 720pt (792pt landscape less two 36pt margins), which is what
    // makes each value below its real on-page width and lets `PDFColumnWidth.index` mean
    // the same thing here as it does in the complete-library table.
    //
    // Each is measured against the longest of the FOUR things sharing it: its two fields
    // and its two header labels.

    private enum Width {
        /// The shared index column. See `PDFColumnWidth.index`.
        static let index: CGFloat = PDFColumnWidth.index
        /// The film title on a film row, the indented format on a release row. Truncates.
        static let title: CGFloat = 109
        /// "Not purchased" on one line — the widest thing this column holds now that
        /// Condition has moved out of it. It used to wrap, which on a cell merged down the
        /// pair is not a fit problem so much as a legibility one.
        static let status: CGFloat = 48
        /// Sized by its "Year of Release" HEADER rather than by either field — "2016
        /// (1977)" and "Like new" are both shorter, and a header that wrapped to two lines
        /// would overflow the band's fixed height.
        static let year: CGFloat = 44
        /// A country name, under a "Provenance" header.
        static let provenance: CGFloat = 44
        /// "Region B (LL)" — the loosely-locked tag abbreviated. Spelled in full it is more
        /// than half again this wide, and it is the only region value that needs shortening.
        static let regionLock: CGFloat = 42

        // MARK: The decoupled region
        //
        // Four columns, none of which is a field on its own: the two body rows divide this
        // span at DIFFERENT points, and these are the pieces both divisions are built from.
        //
        //   top row:     |‹———— Video ————›|‹—— Aspect Ratio ——›|‹—————— Notes ——————
        //   bottom row:  |‹—— Versions Included ——›|‹—— Packaging ——›|‹— Audio — …
        //   columns:     |    video   | vTail | aTail |   pTail    |
        //
        // Every field is one column or a `columnSpan` over two of them — see
        // `specificationRow` and `provenanceRow`. The alternative was sizing each row's
        // fields to the other's boundaries, which is how Versions Included came to be cut
        // down when only Video was meant to shrink.

        /// Video alone, sized by the widest string the vocabulary can build:
        /// "HEVC (Upscaled), Dolby Vision" (75.9pt of text).
        static let video: CGFloat = 84
        /// The rest of Versions Included, which keeps the full 120pt it had.
        static let versionsTail: CGFloat = 36
        /// The rest of Aspect Ratio, which holds three ratios and an ellipsis at 66pt
        /// because it TRUNCATES rather than wrapping. Three is the practical ceiling on a
        /// release anyone needs to read off a page.
        static let aspectTail: CGFloat = 30
        /// The rest of Packaging, which keeps the full 103pt it had, and the leading column
        /// of the Notes span. Every point freed by shrinking Video lands here, which is why
        /// Aspect Ratio and Notes both moved left without either losing width.
        static let packagingTail: CGFloat = 73

        /// The widest audio string the vocabulary can build: "Dolby Digital 2.0 Mono".
        static let audio: CGFloat = 64
        /// "$1,234.99 / $1,234.99" as a balanced pair, or "Lowest: $34.99".
        static let money: CGFloat = 55
        /// The longest form either field takes, which is the DE-EMPHASIZED one:
        /// "Last seen: Sep 30, 2044" is wider than the plain "September 30, 2044" a
        /// purchase date prints, because the prefix costs more than the abbreviation saves.
        static let date: CGFloat = 72
    }

    private enum Column {
        static let status = 2
        static let year = 3
        /// Video, and the leading half of Versions Included.
        static let video = 6
        /// The trailing half of Versions Included, and the leading half of Aspect Ratio.
        static let versionsTail = 7
        /// The trailing half of Aspect Ratio, and the leading half of Packaging.
        static let aspectTail = 8
        /// The trailing half of Packaging, and the leading column of the Notes span.
        static let packagingTail = 9
        static let total = 13
        /// The Studio banner covers Provenance and Region Lock.
        static let studioSpan = 4..<6
        /// The Aspect Ratio banner covers the two columns its value spans.
        static let aspectSpan = 7..<9
        /// The Notes banner covers Packaging's tail, Audio, Cost / Spent and Date.
        static let notesSpan = 9..<13
    }

    /// How far a release's format is stepped in under its film's title. Enough to read as
    /// subordinate at this type size, not so far that the longest format label stops
    /// fitting. See `PDFCell.indent`.
    private static let formatIndent: CGFloat = 5

    /// A release's TOP row — the disc's specification. These are the upper header row, and
    /// the three ungrouped columns before them (`#`, Title / Release, Status) carry one
    /// label each across both header rows because they mean one thing on both body rows.
    ///
    /// The four banners over columns whose values are left-aligned are left-aligned too, so
    /// each label starts where the field it names starts.
    private static let specificationHeaders: [(title: String,
                                               columns: Range<Int>,
                                               alignment: NSTextAlignment)] =
        [("Year of Release", 3..<4,             .center),
         ("Studio",          Column.studioSpan, .left),
         ("Video",           6..<7,             .left),
         ("Aspect Ratio",    Column.aspectSpan, .left),
         ("Notes",           Column.notesSpan,  .left)]

    // MARK: Section

    static func section(films: [FilmSnapshot]) -> PDFTableSection {
        // The BOTTOM header row is each column's own title; the top row is contributed by
        // the header groups above. That is what puts a label over each of a release's two
        // rows: the reader reads straight down from "Studio" to a studio and from "Region
        // Lock" to a region, and no cell has to carry its own label.
        var columns: [PDFTableColumn] = [
            PDFTableColumn("#", width: Width.index, alignment: .right,
                           headerAlignment: .center),
            PDFTableColumn("Title / Release", width: Width.title, alignment: .left),
            PDFTableColumn("Status", width: Width.status, alignment: .center),
            PDFTableColumn("Condition", width: Width.year, alignment: .center),
            PDFTableColumn("Provenance", width: Width.provenance, alignment: .center),
            PDFTableColumn("Region Lock", width: Width.regionLock, alignment: .center),
            PDFTableColumn("Versions Included", width: Width.video, alignment: .left),
            PDFTableColumn("", width: Width.versionsTail, alignment: .left),
            PDFTableColumn("Packaging", width: Width.aspectTail, alignment: .left),
            PDFTableColumn("", width: Width.packagingTail, alignment: .left),
            PDFTableColumn("Audio", width: Width.audio, alignment: .left),
            PDFTableColumn("Cost / Spent", width: Width.money, alignment: .center),
            PDFTableColumn("Date of Purchase", width: Width.date, alignment: .right),
        ]

        // The bottom header row divides this span at different points from the top one, so
        // its two labels each straddle a boundary the top row draws. Dropping the rule
        // between the header cells is what merges each label into the one field it names —
        // "Versions Included" across its 120pt, "Packaging" across its 103pt.
        columns[Column.video].headerBorders = [.top, .bottom, .left]
        columns[Column.versionsTail].headerBorders = [.top, .bottom, .right]
        columns[Column.aspectTail].headerBorders = [.top, .bottom, .left]
        columns[Column.packagingTail].headerBorders = [.top, .bottom, .right]

        // The header sits on the same axis as the values beneath it — see `PDFPairedText`.
        columns[11].pairedTitle = PDFPairedText("Cost", "Spent")

        let groups = specificationHeaders.map {
            var group = PDFHeaderGroup($0.title, columns: $0.columns)
            group.alignment = $0.alignment
            return group
        }

        var rows: [[PDFCell]] = []
        // Each film's band plus its own releases — a page must not open with release rows
        // whose film is named on the page before. See `PDFTableSection.keepTogether`.
        var blocks: [Range<Int>] = []
        for (position, film) in LibraryPDFReport.ordered(films).enumerated() {
            let start = rows.count

            // The sidebar's catalog ordering: parent, then its bundled children, then the
            // next release — kept as GROUPS, because a combo pack is drawn as one record.
            // Children are KEPT — a combo pack's Blu-ray is a real disc the user owns, and
            // this section is a catalog of discs.
            let groups = releasesGroupedByHierarchy(film.releases)

            rows.append(FilmDetailStyle.filmRow(
                index: position + 1,
                film: film,
                columnCount: Column.total,
                values: [
                    // A combo pack counts ONCE. It is one purchase, one box and one shelf
                    // slot; the bundled disc is part of it, not a second acquisition.
                    Column.status: groups.isEmpty
                        ? "No releases"
                        : "\(groups.count) release\(groups.count == 1 ? "" : "s")",
                    // The film's own year, in the column its releases print THEIR years in
                    // — the base year in a release's "2016 (1977)" is this same figure, so
                    // the column reads consistently from the band down.
                    Column.year: film.releaseYear,
                ]))

            for (groupOffset, group) in groups.enumerated() {
                let lastGroup = groupOffset == groups.count - 1
                let children = Array(group.dropFirst())
                let parentPlacement: Placement = children.isEmpty
                    ? .standalone
                    : .comboParent(childCount: children.count,
                                   firstChildHasBaseYear: hasBaseYear(children[0]))

                // The rule across the top of each RELEASE — the darker gray, from the
                // trailing edge of the index column across — so a film's releases are
                // divided from one another more firmly than a release's two rows are, and
                // less firmly than one film is from the next. A child is NOT a new release
                // and takes no rule of its own; nor does the FIRST release, whose top edge
                // is the band's bottom — that boundary is already the black rule above the
                // band, and a second weight directly beneath it would only compete with it.
                let specification = specificationRow(group[0], placement: parentPlacement)
                rows.append(groupOffset == 0 ? specification : releaseRule(specification))
                rows.append(provenanceRow(group[0], placement: parentPlacement,
                                          closing: lastGroup && children.isEmpty))

                for (childOffset, child) in children.enumerated() {
                    let placement = Placement.comboChild(isFirst: childOffset == 0)
                    rows.append(specificationRow(child, placement: placement))
                    rows.append(provenanceRow(child, placement: placement,
                                              closing: lastGroup && childOffset == children.count - 1))
                }
            }

            blocks.append(start..<rows.count)
        }

        return PDFTableSection(title: sectionTitle,
                               columns: columns,
                               headerGroups: groups,
                               keepTogether: blocks,
                               rows: rows)
    }

    // MARK: Placement

    /// Where a release sits in its combo-pack group, which decides which of its cells are
    /// drawn and which are covered by a merge from the parent above.
    ///
    /// # The combo-pack record
    ///
    /// A 4K parent and its bundled Blu-ray are one purchase, and the fields that describe
    /// the PURCHASE rather than the disc are the same for both: purchased or not, the studio
    /// that pressed the box, the country it was pressed in. Printing each twice — once per
    /// disc — was duplication a reader had to check was duplication. So across the four rows
    /// of a pair, each such field is drawn ONCE and merged down:
    ///
    ///   * Status spans all four rows, centered between the two discs it applies to.
    ///   * Studio spans three — the parent's two rows and the child's first — leaving the
    ///     child's last row to carry Provenance and Region Lock. A 4K disc has no region
    ///     coding, so the parent's own provenance row said nothing the child's does not.
    ///   * The parent's Year of Release spans its two rows, displacing its Condition cell;
    ///     a disc's condition is the box's condition, and the child reports it.
    ///   * The child's Year of Release prints only when it carries a base year of its own.
    ///     Absent one, it is implicitly the parent's and is left blank rather than repeated.
    ///
    /// A second bundled Blu-ray (a dual-BD pack) is rare and is drawn as an ordinary pair
    /// beneath the first, still under the one Status cell: the rectangle a merge covers
    /// cannot skip the first child's Provenance row to reach the second child's Studio.
    private enum Placement {
        case standalone
        case comboParent(childCount: Int, firstChildHasBaseYear: Bool)
        case comboChild(isFirst: Bool)

        var isChild: Bool {
            if case .comboChild = self { return true }
            return false
        }
    }

    /// Whether a release carries a base year of its own — the one thing that gives a
    /// bundled Blu-ray a Year cell separate from its parent's.
    private static func hasBaseYear(_ release: ReleaseSnapshot) -> Bool {
        !release.baseReleaseYear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `row` with the darker release rule across its top, from the trailing edge of the
    /// index column across. The index column's own rules are left alone: that column runs
    /// unbroken beneath the band and is not divided between releases.
    private static func releaseRule(_ row: [PDFCell]) -> [PDFCell] {
        row.enumerated().map { column, cell in
            guard column > 0 else { return cell }
            var ruled = cell
            ruled.topRuleColor = PDFPalette.releaseRule
            return ruled
        }
    }

    // MARK: Row one — what the disc is

    private static func specificationRow(_ release: ReleaseSnapshot,
                                         placement: Placement) -> [PDFCell] {
        let format = ReleaseFormat(rawValue: release.format)

        // HDR is meaningful only on 4K UHD; on the other formats the field is noise, so it
        // is appended only where it says something — matching the sidebar table, which
        // prints "N/A" in a column it has to fill and this one does not.
        var video = releaseVideoDisplay(for: release)
        if format == .uhd4K, !release.hasHDR.isEmpty {
            video += ", \(release.hasHDR)"
        }

        // The cells a merge from above may own instead — see `Placement` and `yearCell`.
        let statusCell: PDFCell
        let studioCell: PDFCell
        switch placement {
        case .standalone:
            statusCell = PDFCell(status(release), fill: statusTint(release), rowSpan: 2)
            studioCell = PDFCell(FilmDetailStyle.orDash(release.studio), alignment: .left,
                                 truncates: true, columnSpan: 2)
        case let .comboParent(childCount, _):
            // One standing for the whole box, centered down every row of it.
            statusCell = PDFCell(status(release), fill: statusTint(release),
                                 rowSpan: 2 * (1 + childCount))
            // Down to the first child's specification row, leaving its provenance row
            // for the fields the parent has no version of.
            studioCell = PDFCell(FilmDetailStyle.orDash(release.studio), alignment: .left,
                                 truncates: true, rowSpan: 3, columnSpan: 2)
        case let .comboChild(isFirst):
            // Covered by the parent's Status.
            statusCell = PDFCell("")
            // The first child's cell is covered by the parent's Studio; a later child's is
            // outside that rectangle and draws its own.
            studioCell = isFirst
                ? PDFCell("")
                : PDFCell(FilmDetailStyle.orDash(release.studio), alignment: .left,
                          truncates: true, columnSpan: 2)
        }

        return FilmDetailStyle.deemphasizingPlaceholders([
            // Never `closing`: the provenance row always follows this one.
            FilmDetailStyle.continuation(closing: false),
            formatBadge(release, format: format, placement: placement),
            statusCell,
            yearCell(release, placement: placement),
            studioCell,
            PDFCell(""),
            videoCell(video, release: release, format: format),
            // Truncates, and the span is sized for three ratios and an ellipsis. A release
            // listing more than that is describing a box set, and the fourth ratio is worth
            // less than the width it would take from Notes on every row.
            aspectCell(release),
            PDFCell(""),
            // Notes take the whole width of the four columns below them. It is the one
            // field with no upper bound on its length, and the width is what keeps it from
            // wrapping into a row three lines tall.
            PDFCell(FilmDetailStyle.orDash(release.notes), columnSpan: 4),
            PDFCell(""),
            PDFCell(""),
            PDFCell(""),
        ])
    }

    // MARK: The year stack

    /// The Year of Release cell, and how far down it reaches.
    ///
    /// The column below it holds Condition, and Condition is only ever printed for a disc
    /// the user OWNS — an unpurchased release has no disc to be in any condition. So on an
    /// unpurchased record the Condition cell is not merely blank but structurally empty,
    /// and the year takes its place: merged down over it, centered between the two rows.
    ///
    /// On a combo-pack record the same reasoning runs across the whole four-row stack. The
    /// parent's year spans its own two rows regardless (its Condition is the child's to
    /// report). Below that, the child has a Year cell of its own only when it carries a
    /// base year — a bundled Blu-ray shares its parent's release year by construction, so
    /// that is the one fact that would differ. Absent one, the parent's year keeps going:
    /// to three rows on a purchased pack (the child's Condition still needs its row) and
    /// to all four on an unpurchased one, where nothing beneath it has anything to say.
    ///
    /// A child that DOES carry a base year prints only that, in its parentheses — "(2010)"
    /// — because the release year it would otherwise repeat is printed directly above it.
    /// That cell, too, spans down over its Condition when the pack is unpurchased.
    private static func yearCell(_ release: ReleaseSnapshot, placement: Placement) -> PDFCell {
        // Rows the cell reaches BELOW its own row's Condition slot, on its own record.
        let ownStack = release.purchased ? 1 : 2

        switch placement {
        case .standalone:
            return PDFCell(years(release), rowSpan: ownStack)

        case let .comboParent(_, firstChildHasBaseYear):
            // Always its own two rows; then, when the first child has no year of its own,
            // on down through the child's specification row and — unpurchased — its
            // Condition row as well.
            let reach = firstChildHasBaseYear ? 2 : 2 + ownStack
            return PDFCell(years(release), rowSpan: reach)

        case .comboChild:
            // Covered by the parent's reach unless this disc has a base year of its own.
            guard hasBaseYear(release) else { return PDFCell("") }
            let base = release.baseReleaseYear.trimmingCharacters(in: .whitespacesAndNewlines)
            return PDFCell("(\(base))", rowSpan: ownStack)
        }
    }

    // MARK: Row two — where it came from and what it cost

    private static func provenanceRow(_ release: ReleaseSnapshot,
                                      placement: Placement,
                                      closing: Bool) -> [PDFCell] {
        let region = regionLock(release)

        // On a combo parent, Condition is covered by the Year merged down from above, and
        // Provenance and Region Lock by the Studio — the child's row carries all three for
        // the pair. See `Placement`.
        let parentCovered: Bool
        if case .comboParent = placement { parentCovered = true } else { parentCovered = false }
        // …and on ANY unpurchased record the Condition cell is covered by the year above it
        // (see `yearCell`), including a child's, and a child's whose parent's year reaches
        // down this far. A cell the renderer will never draw must still be present, and
        // must be empty.
        let conditionCovered = parentCovered || !release.purchased

        // The provenance row is SECONDARY to the specification above it, and reads that
        // way: these are cataloguing detail — what state the disc is in, where it was
        // pressed, what it is packaged in — rather than what the disc IS. The gray lets the
        // eye run down the specification rows and drop into this one only when it wants
        // the detail, which is the reading order the two-row record is for.
        //
        // Condition describes a disc the user HOLDS. On something not yet bought there is
        // no disc to be in any condition, so the cell is blank rather than dashed — a dash
        // would claim the field was left unfilled.
        let conditionCell = conditionCovered ? PDFCell("") : PDFCell(
            FilmDetailStyle.orDash(release.condition.capitalized),
            textColor: PDFPalette.secondaryText)
        let provenanceCell = parentCovered ? PDFCell("") : PDFCell(
            FilmDetailStyle.orDash(release.nationalOrigin), textColor: PDFPalette.secondaryText)
        // The one exception to the gray: a FLAGGED region keeps the primary color. The
        // orange fill exists to catch the eye, and graying the text on it would take back
        // with one hand what the fill gives with the other.
        let regionCell = parentCovered ? PDFCell("") : PDFCell(
            region.text, fill: region.fill,
            textColor: region.fill == nil ? PDFPalette.secondaryText : nil)

        return FilmDetailStyle.deemphasizingPlaceholders([
            FilmDetailStyle.continuation(closing: closing),
            // Covered by the format and status cells merged down from the row above; the
            // renderer draws nothing here. Present so the row is the full column count.
            PDFCell(""),
            PDFCell(""),
            conditionCell,
            provenanceCell,
            regionCell,
            // Versions and Packaging each span two columns, and each straddles a boundary
            // the row above draws — see the column map in `Width`.
            versionsCell(release),
            PDFCell(""),
            PDFCell(FilmDetailStyle.orDash(packaging(release)), columnSpan: 2,
                    textColor: PDFPalette.secondaryText),
            PDFCell(""),
            PDFCell(FilmDetailStyle.orDash(release.audio)),
            money(release),
            purchaseDate(release),
        ])
    }

    // MARK: Aspect ratio and versions

    /// The aspect ratios, de-emphasized when they are the unremarkable case.
    ///
    /// One plain ratio is what nearly every disc has and says nothing a reader is scanning
    /// for. What IS worth finding is a disc that carries MORE than one — a box set, or a
    /// film presented in two framings — or a single ratio qualified as open matte, which
    /// is the one framing choice that changes what the viewer actually sees. Those keep
    /// the primary color; everything else drops back.
    private static func aspectCell(_ release: ReleaseSnapshot) -> PDFCell {
        let ratios = release.releaseAspectRatio
        let notable = ratios.count > 1 || ratios.contains {
            $0.localizedCaseInsensitiveContains(AspectRatioVocabulary.openMatteQualifier)
        }
        return PDFCell(FilmDetailStyle.orDash(ratios.joined(separator: ", ")),
                       truncates: true, columnSpan: 2,
                       textColor: notable ? nil : PDFPalette.secondaryText)
    }

    /// The versions included, de-emphasized when the disc carries ONLY the theatrical cut.
    ///
    /// The theatrical cut is what every disc is assumed to carry until it says otherwise,
    /// so a list that is exactly that is the default restated. Anything more — a second
    /// cut, or a single cut that is not the theatrical — is the reason to read the cell.
    private static func versionsCell(_ release: ReleaseSnapshot) -> PDFCell {
        let versions = release.includedVersions
        let onlyTheatrical = versions == [ViewingVersion.theatrical.displayName]
        return PDFCell(FilmDetailStyle.orDash(versions.joined(separator: ", ")),
                       columnSpan: 2,
                       textColor: onlyTheatrical ? PDFPalette.secondaryText : nil)
    }

    // MARK: Video

    /// The Video cell, and which part of it is de-emphasized.
    ///
    /// On Blu-ray and DVD the whole string is secondary: the codec is fixed by the format
    /// in practice, so the cell confirms rather than informs. On 4K UHD only the CODEC is —
    /// what actually varies there, and what a reader is looking for, is the master type and
    /// the HDR flavor beside it, and those stay in the primary color so they can be found.
    ///
    /// The split is done with a highlight rather than by building two cells, because the
    /// three parts are one comma-joined value and splitting them would put a column rule
    /// through the middle of it.
    private static func videoCell(_ video: String,
                                  release: ReleaseSnapshot,
                                  format: ReleaseFormat?) -> PDFCell {
        let text = FilmDetailStyle.orDash(video)
        guard format == .uhd4K else {
            return PDFCell(text, textColor: PDFPalette.secondaryText)
        }

        // The codec as `releaseVideoDisplay` resolved it — including the HEVC default a 4K
        // release with an empty field takes — so the highlight matches what was drawn
        // rather than what was stored.
        let codec = release.videoFormat.isEmpty ? ReleaseVideoFormat.hevc : release.videoFormat
        return PDFCell(text, highlights: [PDFTextHighlight(codec,
                                                           color: PDFPalette.secondaryText)])
    }

    // MARK: Region

    /// The region tag as it prints, and the fill it earns.
    ///
    /// # The abbreviation
    ///
    /// "Region B (Loosely-locked)" is half again wider than every other value this column
    /// holds, and sizing the column to it would take that width from Notes on every row of
    /// the section to serve one tag. "(LL)" is the qualifier reduced to its initials, which
    /// is legible beside the unqualified "Region B" directly above or below it.
    ///
    /// # The fill
    ///
    /// A PLAIN Region B disc is the one a reader needs to notice: it does not play on this
    /// library's hardware and has no recorded bypass. Region B (LL) does play, so it takes
    /// no fill — the whole point of the loosely-locked tag is that the lock is not a
    /// problem, and coloring both would flag the case that is fine alongside the case that
    /// is not.
    private static func regionLock(_ release: ReleaseSnapshot) -> (text: String, fill: NSColor?) {
        let stored = RSBRegionIndicator.displayValue(release.regionLock, format: release.format)
        if stored == ReleaseRegionRules.looselyLockedTag {
            return ("\(ReleaseRegionRules.regionB) (LL)", nil)
        }
        if stored == ReleaseRegionRules.regionB {
            return (stored, PDFPalette.lightOrange)
        }
        return (FilmDetailStyle.orDash(stored), nil)
    }

    // MARK: Release identity

    /// The format cell — drawn across BOTH of a release's rows.
    ///
    /// The format is not a property of the specification row or of the provenance row; it
    /// is what the two rows are jointly about. Merging it says so, and together with the
    /// Status cell beside it brackets each release so the reader sees where one ends and
    /// the next begins without counting rows. Its `rowSpan` also makes the pair atomic, so
    /// a release can no longer be split across a page break — see `PDFCell.rowSpan`.
    private static func formatBadge(_ release: ReleaseSnapshot,
                                    format: ReleaseFormat?,
                                    placement: Placement) -> PDFCell {
        let inverted = format == .uhd4K
        return PDFCell(releaseLabel(release),
                       fill: formatTint(release, format: format),
                       truncates: true,
                       rowSpan: 2,
                       // Stepped in under the film title in the same column, and a bundled
                       // disc stepped in again under the box it came in. Two levels of the
                       // same indent, so the hierarchy reads as an outline.
                       indent: formatIndent * (placement.isChild ? 2 : 1),
                       textColor: inverted ? PDFPalette.invertedText : nil,
                       fillIsOpaque: inverted)
    }

    /// What the Release cell says: the format, plus the fact of being a bundled child.
    ///
    /// The child note is spelled out rather than conveyed by position, because pagination
    /// can put a child on a different page from the parent it hangs off — and a lone
    /// "Blu-ray" row on a fresh page with its money columns deferring elsewhere would
    /// otherwise look like a record someone forgot to finish.
    private static func releaseLabel(_ release: ReleaseSnapshot) -> String {
        // "combo-pack" hyphenated, matching `ReleaseIndependence.comboPack` — the stored
        // vocabulary's own spelling, which the packaging column and the money note beside
        // this one both print.
        release.isChild ? "\(release.format) (included in combo-pack)" : release.format
    }

    /// The format's shade — a FOUR-step ladder that is this column's alone.
    ///
    /// Deliberately not borrowed from the complete-library table's green/red family: that
    /// family means purchased/unpurchased, and in this section the Status column beside
    /// this one already says that. Sharing the shades would have had two adjacent columns
    /// making what looks like the same claim about different things.
    ///
    /// The 4K UHD cell INVERTS — opaque dark gray with white type — rather than taking a
    /// fourth wash. It is the top of the ladder, and an inverted cell is the only mark on
    /// these pages that reads as a rank rather than as one more category.
    ///
    /// The two Blu-ray shades separate a disc bought on its own from one that arrived
    /// inside a combo pack, which is the distinction a reader of this section actually
    /// needs: the bundled copy has no price of its own and no independent purchase, so it
    /// must not be mistaken for a second acquisition.
    private static func formatTint(_ release: ReleaseSnapshot,
                                   format: ReleaseFormat?) -> NSColor? {
        switch format {
        case .uhd4K:  return PDFPalette.veryDarkGray
        case .bluRay: return release.isChild ? PDFPalette.veryDarkBlue : PDFPalette.lightBlue
        case .dvd:    return PDFPalette.lightGray
        case nil:     return nil
        }
    }

    // MARK: Purchase status

    /// "Purchased", a wishlist position, or "Not purchased".
    ///
    /// A wishlist entry is a THIRD state, not a shade of unpurchased: the user has ranked
    /// it, and the rank is the useful thing to print. It is reported only for a release
    /// that has not been bought — a `wishlist` value surviving on a purchased release is
    /// stale bookkeeping, not a claim the reader should see.
    private static func status(_ release: ReleaseSnapshot) -> String {
        if release.purchased { return "Purchased" }
        if release.wishlist >= 1 { return "Wishlist #\(release.wishlist)" }
        return "Not purchased"
    }

    /// Green for owned, dark gold for wanted, red for neither — the same three readings
    /// the complete-library table's purchase columns give.
    private static func statusTint(_ release: ReleaseSnapshot) -> NSColor {
        if release.purchased { return PDFPalette.green }
        if release.wishlist >= 1 { return PDFPalette.darkGold }
        return PDFPalette.red
    }

    // MARK: Years

    /// "2016 (1977)" — the pressing's year, with the film's original release year behind
    /// it when the two differ. Both trimmed, as the sidebar trims them, so a stored value
    /// carrying stray whitespace centers the same way in both.
    private static func years(_ release: ReleaseSnapshot) -> String {
        let year = release.releaseYear.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = release.baseReleaseYear.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == year { return FilmDetailStyle.orDash(year) }
        return year.isEmpty ? "(\(base))" : "\(year) (\(base))"
    }

    // MARK: Packaging

    /// How the disc is packaged: the pack type, the case, the disc count, and whether the
    /// media is pressed or burned.
    ///
    /// Assembled from four separate stored fields because none of them is "packaging" on
    /// its own, and each is too narrow to earn a column of its own on this page. Only the
    /// parts that say something are printed — a standalone, pressed, single-disc release
    /// with no artwork tag reduces to "1 disc", which is the whole truth about it.
    private static func packaging(_ release: ReleaseSnapshot) -> String {
        var parts: [String] = []

        // The pack type, in its full form — this cell has room for "Combo-pack (dual BD)"
        // where the sidebar's 78pt column does not, so it does NOT go through
        // `compactDisplay`, whose whole purpose is that column's width.
        if release.independence != ReleaseIndependence.standalone,
           !release.independence.isEmpty {
            parts.append(release.independence)
        }

        // A steelbook is the one artwork tag that describes the CASE rather than the
        // printing on it, which is what makes it packaging. The "Yes"/"No" tags answer a
        // different question and belong to the artwork column, not here.
        if release.hasArtwork == ReleaseArtwork.steelbook {
            parts.append(ReleaseArtwork.steelbook)
        }

        parts.append("\(release.numberOfDiscs) disc\(release.numberOfDiscs == 1 ? "" : "s")")

        if ReleaseReplicationType.isRecordable(release.replicationType) {
            parts.append("recordable")
        }

        // Joined verbatim rather than through `PDFNoteList`: every part here is already
        // cased the way it must be printed — the pack type and "Steelbook" are stored
        // vocabulary terms, and the other two are written above in the case they read in —
        // so the case transform that convention applies would only be something to undo.
        return parts.joined(separator: ", ")
    }

    // MARK: Money and dates

    /// The purchase figures, or the lowest price seen — never both.
    ///
    /// The two are mutually exclusive by construction: a release the user OWNS reports what
    /// it listed at and what they actually paid, and one they do not own reports the lowest
    /// price they have seen it at. Printing a lowest price beside an amount spent would be
    /// claiming a floor on something already bought, and a cost beside a lowest price would
    /// be quoting list on something never acquired.
    ///
    /// The purchase pair is drawn as a BALANCED PAIR — see `PDFPairedText` — so the slash
    /// falls in the same place on every row and the two figures can be compared down the
    /// column without re-reading. The single-value forms are ordinary centered cells: there
    /// is no relation for them to be aligned on.
    ///
    /// The wishlist figure keeps its "Lowest:" prefix even though the column can only show
    /// one thing at a time, because the prefix is what separates it from the pairs above
    /// and below it at a glance; and it is drawn in the secondary gray, because a price on
    /// something the user does not own is a note about the market rather than a record of
    /// their library. The purchase pair, which IS such a record, is not.
    private static func money(_ release: ReleaseSnapshot) -> PDFCell {
        if let inherited = comboPackNote(release) { return inherited }
        guard release.purchased else {
            guard release.lowestPrice != 0 else { return PDFCell(FilmDetailStyle.dash) }
            // Left-aligned, like the "Last seen" note beside it: it is a labeled sentence,
            // not a figure, and centering it would move its prefix on every row.
            return PDFCell("Lowest: \(FilmDetailStyle.money(release.lowestPrice))",
                           alignment: .left, textColor: PDFPalette.secondaryText)
        }

        // A purchase with a recorded cost but nothing spent reads "$0.00", not a dash: on a
        // disc the user owns, a zero paid is a FIGURE — a gift, a freebie, a trade — and
        // the app's own release card reports it that way. The dash is reserved for a field
        // nobody filled in, which on a purchased release is only credible when neither
        // figure was recorded at all.
        let spent = release.cost == 0
            ? FilmDetailStyle.money(release.amountSpent)
            : FilmDetailStyle.exactMoney(release.amountSpent)
        return PDFCell(paired: PDFPairedText(FilmDetailStyle.money(release.cost), spent))
    }

    /// When the disc was bought, or when the lowest price was seen — matching whichever
    /// figures `money` printed.
    ///
    /// A purchase date takes the column's right alignment, so the dates line up on their
    /// year down the page. A "Last seen" note does not: it is a sentence, not a date, and
    /// pinned to the right edge it would put its prefix in a different place on every row.
    private static func purchaseDate(_ release: ReleaseSnapshot) -> PDFCell {
        if let inherited = comboPackNote(release) { return inherited }
        guard release.purchased else {
            let seen = release.lowestPriceDate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seen.isEmpty else { return PDFCell(FilmDetailStyle.dash) }
            return PDFCell("Last seen: \(PDFCellText.abbreviatedDate(seen))", alignment: .left,
                           textColor: PDFPalette.secondaryText)
        }
        return PDFCell(FilmDetailStyle.date(release.purchaseDate))
    }

    /// The stand-in both money columns print for a bundled Blu-ray.
    ///
    /// A combo pack is ONE acquisition at one price, recorded on the 4K parent. The bundled
    /// disc beneath it has no figures of its own — and a dash there would say the fields
    /// were left unfilled, when in fact they are filled in a row above. Naming the reason
    /// is shorter than the reader working it out, and the secondary gray marks it as an
    /// explanation rather than as data.
    ///
    /// Left-aligned in BOTH columns, like every other prose value in this pair — the
    /// "Lowest:" figure and the "Last seen" date. What is right-aligned here is a DATE and
    /// what is centered is a balanced pair of figures; a parenthetical is neither, and it
    /// reads as one remark across the two cells only if the two start in the same place.
    private static func comboPackNote(_ release: ReleaseSnapshot) -> PDFCell? {
        guard release.isChild else { return nil }
        return PDFCell("(\(ReleaseIndependence.comboPack))", alignment: .left,
                       textColor: PDFPalette.secondaryText)
    }
}
