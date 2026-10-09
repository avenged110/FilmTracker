// MARK: - ReportExporter.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Turns one ReportsView tab into the PDF sheet that reports it.
//
// This file no longer contains any PDF machinery. Page geometry, fonts, the fill palette,
// the drawing primitives, and the paginated table renderer all live in the shared stack
// described at the top of PDFCore.swift (88.00), which the whole-library export in
// LibraryPDFExporter.swift (43.10) draws from as well.
//
// What remains here is the part that is genuinely about REPORTS: the column set and row
// content for each of the five tabs. `sheet(for:)` is internal to the module precisely so
// the library export can append these same five sheets to its own document without
// restating a single column width.

import AppKit
import Foundation
import SwiftUI

// MARK: - Reports PDF Exporter
@MainActor
enum ReportsPDFExporter {
    // MARK: - Section Building

    /// The sheet one report tab's data becomes, or `nil` when that tab has nothing to say.
    ///
    /// Returning `nil` rather than throwing is what lets the library export skip an empty
    /// tab and keep going, rather than printing a heading over an empty table.
    ///
    /// Hall of Fame is one table. Data Visualizations is a STACK of drawn blocks — the
    /// tab's own page in print form — which is why this vends a `PDFSheet` rather than a
    /// section.
    static func sheet(for data: ReportsExportData) -> PDFSheet? {
        switch data.category {
        case .hallOfFame:
            guard let films = data.hallOfFameFilms, !films.isEmpty else { return nil }
            return .table(hallOfFameSection(films: films, title: data.category.displayName))
        case .dataVisualizations:
            guard let visualizations = data.visualizations else { return nil }
            let stack = dataVisualizationsSheet(visualizations: visualizations, title: data.category.displayName)
            guard !stack.blocks.isEmpty else { return nil }
            return .stack(stack)
        // The Purchase and Expense Tracker, the Price Tracker and the Release Wishlist were
        // sheets here until the library PDF's own Disc-based Releases section superseded all
        // three — see `LibraryPDFSection`. Their section builders are gone with them; these
        // cases are listed rather than folded into a `default` so that adding a sixth
        // ReportsCategory still fails the build here.
        case .costTracker, .priceTracker, .releaseWishlist:
            return nil
        }
    }

    // MARK: - Hall of Fame

    private static func hallOfFameSection(
        films: [HallOfFameFilm],
        title: String
    ) -> PDFTableSection {
        // The four narrow columns hold short badges and are sized alike so the block reads
        // as one unit; Title keeps what a name needs and Notes takes the rest.
        //
        // The narrow four are all `narrowBadgeWidth`, which is set by the widest badge any
        // of them has to print — "Not Available", in Purchased. They used to be 0.04–0.045
        // and wrapped it onto two lines, which grew the height of the whole row.
        //
        // Title has been trimmed twice, from a round 0.26 to 0.234 and now by a further
        // 10% to 0.211. Both trims, and what the narrow columns' widening did not take,
        // went to Notes — the one column here that genuinely runs long.
        let columns = [
            // Values centered, matching the header: both sit over the same band of color
            // beneath them, and a centered rank reads as "labeling the row" rather than as
            // a right-aligned number inviting comparison against its neighbors.
            PDFTableColumn("Position",  width: narrowBadgeWidth, alignment: .center,
                           headerAlignment: .center),
            PDFTableColumn("Title",     width: 0.211, alignment: .left),
            PDFTableColumn("Year",      width: narrowBadgeWidth, alignment: .center),
            PDFTableColumn("Rating",    width: narrowBadgeWidth, alignment: .center),
            PDFTableColumn("Purchased", width: narrowBadgeWidth, alignment: .center),
            PDFTableColumn("Notes",     width: 0.565, alignment: .left),
        ]

        let rows = films.map { film -> [PDFCell] in
            [
                PDFCell("\(film.position)", fill: positionBandFill(film.position)),
                PDFCell(film.name, truncates: true),
                PDFCell(film.releaseYear.isEmpty ? "—" : film.releaseYear),
                ratingCell(film.userRating),
                purchasedCell(film.purchase),
                PDFCell(hallOfFameNotes(film), alignment: .left),
            ]
        }

        return PDFTableSection(title: title, columns: columns, rows: rows)
    }

    /// The shared width of the Hall of Fame's four narrow columns.
    ///
    /// Sized to the widest single value any of them prints — "Not Available" in the
    /// Purchased column, which measures 33pt at this table's 5pt body face and so needs
    /// 39pt with the 3pt cell padding on each side. Against the landscape content width
    /// (792pt less two 36pt margins, so 720pt) that is 0.054; 0.056 is that with a little
    /// slack, since a column one point short wraps the badge and grows the whole row.
    private static let narrowBadgeWidth: CGFloat = 0.056

    /// How many positions share one band color.
    private static let hallOfFameBandSize = 25

    /// The fill for a position, banded into blocks of twenty-five.
    ///
    /// The color carries no meaning of its own — it is there so a reader working through a
    /// two-hundred-entry ranking can see at a glance which quarter-hundred they are in, and
    /// so a printed page pulled from the middle still says where it sits. Positions are
    /// 1-based, so the first block is 1...25.
    private static func positionBandFill(_ position: Int) -> NSColor {
        PDFPalette.bandHue((max(1, position) - 1) / hallOfFameBandSize)
    }

    /// The rating, with the top three scores called out by fill.
    ///
    /// Only 10, 9 and 8 are tinted: the Hall of Fame is already a list of favorites, so
    /// coloring every rating would be coloring everything. These are the complete-library
    /// table's own dark shades, which is what keeps one palette across the document.
    private static func ratingCell(_ rating: Int) -> PDFCell {
        guard rating > 0 else { return PDFCell("—") }
        let fill: NSColor?
        switch rating {
        case 10: fill = PDFPalette.darkGreen
        case 9:  fill = PDFPalette.darkGold
        // The complete-library table's own light blue — the same shade a purchased NATIVE
        // 4K release uses there (see `fourKDiscCell` in LibraryPDFReport.swift), reused here
        // rather than the aspect-ratio column's dark blue family, which is that column's own
        // and not meant to be borrowed.
        case 8:  fill = PDFPalette.lightBlue
        default: fill = nil
        }
        return PDFCell("\(rating)", fill: fill)
    }

    /// The purchase standing as a short badge.
    ///
    /// The fills are the complete-library table's own shades, so the same fact reads the
    /// same way in both sections: pale green qualifies a 4K purchase, green affirms a
    /// Blu-ray, light gray is the DVD-tier fallback, and red covers anything unowned.
    ///
    /// WHAT IS AVAILABLE is deliberately not spelled out here — the Notes column reports it
    /// as "<format> available", and this column is a quarter of the width it would need to
    /// say "Available on Blu-ray". So the unowned states reduce to two marks: an em dash
    /// when a disc exists to be bought (Notes names it), and "Not Available" when none
    /// does — which is what `narrowBadgeWidth` is sized to hold on one line.
    private static func purchasedCell(_ purchase: HallOfFamePurchase) -> PDFCell {
        switch purchase {
        case .purchased(.uhd4K):  return PDFCell("4K", fill: PDFPalette.paleGreen)
        case .purchased(.bluRay): return PDFCell("BD", fill: PDFPalette.green)
        case .purchased(.dvd):    return PDFCell("DVD", fill: PDFPalette.lightGray)
        case .available:          return PDFCell("—", fill: PDFPalette.red)
        case .unavailable:        return PDFCell("Not Available", fill: PDFPalette.red)
        }
    }

    /// The Notes column: the film's cut, and the upgrade it has yet to buy.
    ///
    /// Same list discipline as the complete-library table's Notes — first item capitalized,
    /// the rest lowercase, comma separated — so the two sections read alike. Neither item is
    /// a fixed field: a theatrical cut and a film already owned in the best format available
    /// both contribute nothing, which is the common case and correctly leaves the cell
    /// empty.
    private static func hallOfFameNotes(_ film: HallOfFameFilm) -> String {
        var items: [PDFNoteList.Item] = []
        if !film.version.isEmpty { items.append(PDFNoteList.Item(film.version)) }
        if let upgrade = film.upgrade {
            items.append(PDFNoteList.Item("\(upgrade.rawValue) available"))
        }
        // Through the shared joiner, which is the same one the complete-library table's
        // Notes column uses — so "read alike" is one implementation rather than two.
        return PDFNoteList.joined(items)
    }

    // MARK: - Data Visualizations

    /// The tab's own page, drawn (see `visualizationBlocks`). The Purchase Statistics and
    /// Library Overview tables that once led the sheet are gone: every figure they carried
    /// is on the page.
    private static func dataVisualizationsSheet(visualizations: DVDataset, title: String) -> PDFSectionStack {
        PDFSectionStack(title: title,
                        blocks: visualizationBlocks(visualizations),
                        blockBackdrop: visualizationBackdrop)
    }

    // MARK: The rendered page

    /// The Data Visualizations page as vector drawings, one per block of `DVPrintLayout`,
    /// each laid out at that layout's width and scaled onto the page by the stack. The tab's
    /// own section builders draw them (built for print, see DVBuild), as paths and glyphs
    /// rather than pixels, so the charts and text stay sharp at any zoom and the text is
    /// selectable.
    private static func visualizationBlocks(_ dataset: DVDataset) -> [PDFDrawnBlock] {
        DVPrintLayout.blocks(for: dataset, showInfoComplete: Preferences.showInfoComplete).compactMap { block in
            var height: CGFloat = 0
            inLightAppearance { height = block.height(DVPrintLayout.width) }
            guard height > 0 else { return nil }
            return PDFDrawnBlock(size: CGSize(width: DVPrintLayout.width, height: height)) { context in
                inLightAppearance { DVPrintLayout.draw(block, in: context) }
            }
        }
    }

    /// The system colors the cards are drawn in resolve against the current drawing
    /// appearance, not SwiftUI's color scheme alone; a Dark Mode Mac would otherwise print
    /// dark cards onto white paper.
    private static func inLightAppearance(_ body: () -> Void) {
        if let aqua = NSAppearance(named: .aqua) {
            aqua.performAsCurrentDrawingAppearance(body)
        } else {
            body()
        }
    }

    /// The light-mode gray the tab's cards sit on, so the white cards read as cards on
    /// white paper.
    private static let visualizationBackdrop = NSColor(white: 0.925, alpha: 1)
}
