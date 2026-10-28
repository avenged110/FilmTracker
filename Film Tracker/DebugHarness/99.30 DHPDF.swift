// MARK: - DHPDF.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Harness scenario for the complete-library PDF: `-FTDebugHarness library-pdf`.
//
// WHAT THIS PROVES
//
// The library table's cells are derived from a film by a dozen small rules, each with its
// own vocabulary, tier ordering, and fill. Reading them is not the same as knowing they
// fire — a mis-ordered tier or a fill attached to the wrong branch produces a document that
// still renders perfectly and is simply wrong about the library.
//
// So the scenario drives the REAL `LibraryPDFReport.section(films:)` over a corpus built to
// land on every branch of every rule, and asserts the exact text and the exact fill of the
// cells it produces. It then renders the section through the REAL `PDFTableRenderer` and
// reopens the result with PDFKit, which is what catches the things a cell assertion cannot:
// a document that paginates to zero pages, and a page that came out in the wrong
// orientation.
//
// The rendered document is left in the sandbox as `harness-scratch-library-pdf.pdf` so it
// can be opened and looked at.

#if DEBUG

import AppKit
import Foundation
import PDFKit

extension DebugHarness {

    static var pdfScenarios: [String] { ["library-pdf", "library-detail-sections", "reports-statistics", "pdf-timing"] }

    static func runPDFScenario(_ scenario: String,
                               coordinator: DataCoordinator) async -> HarnessScenarioResult? {
        switch scenario {
        case "library-pdf": return await libraryPDFScenario(coordinator: coordinator)
        case "library-detail-sections": return await libraryDetailSectionsScenario()
        case "pdf-timing": return await pdfTimingScenario()
        case "reports-statistics": return reportsStatisticsScenario(coordinator: coordinator)
        default:            return nil
        }
    }

    // MARK: - Scenario

    @MainActor
    private static func libraryPDFScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "library-pdf")

        let corpus = libraryPDFCorpus()
        let section = LibraryPDFReport.section(films: corpus.map(\.film))

        r.check("row-count", section.rows.count == corpus.count,
                "section produced \(section.rows.count) rows for \(corpus.count) films")
        r.check("column-count", section.columns.count == 16,
                "expected 16 columns, got \(section.columns.count)")
        r.check("header-groups", section.headerGroups.count == 2,
                "the two purchased-disc columns each need a group banner over their "
                    + "value and audio sub-column; got \(section.headerGroups.count)")
        // "rf" alone does not say whose. The tool's name rides in the same header cell and
        // WRAPS onto a second line, the way "Aspect Ratio" and "Cust. Edit" do — not as a
        // group banner, which would rule a divider between the two words.
        r.check("hb-rf-header",
                section.columns[11].title == "HB rf"
                    && !section.headerGroups.contains { $0.columns.contains(11) },
                "the rf column's header is '\(section.columns[11].title)'")
        // Spelled out rather than abbreviated to "Chr.", which cost the reader a decoding
        // step to save one point.
        r.check("color-header", section.columns[13].title == "Color",
                "the chroma column's header is '\(section.columns[13].title)'")

        // The section is sorted by name, so find each expectation's row by its title
        // rather than assuming the corpus order survived.
        let titleColumn = 1
        for expectation in corpus {
            guard let row = section.rows.first(where: { $0[titleColumn].text == expectation.film.name })
            else {
                r.check("row-present-\(expectation.film.name)", false, "no row for this film")
                continue
            }
            for (column, expected) in expectation.cells {
                let actual = row[column.index]
                let label = "\(expectation.film.name)/\(column.label)"
                r.check("\(label)-text", actual.text == expected.text,
                        "expected '\(expected.text)', got '\(actual.text)'")
                r.check("\(label)-fill", sameFill(actual.fill, expected.fill),
                        "expected \(fillName(expected.fill)), got \(fillName(actual.fill))")
            }
        }

        // MARK: Studio names
        // A studio is a proper noun inside a sentence, not part of the sentence, so it is
        // italicized in place. Italics rather than a color, because color in this document
        // already means something else.
        func notesCell(_ title: String) -> PDFCell? {
            section.rows.first { $0[PDFColumn.title.rawValue].text == title }?
                .map { $0 }[PDFColumn.notes.rawValue]
        }

        if let studios = notesCell("PDF Notes Double Dip Studios") {
            let italics = studios.highlights.filter(\.italic).map(\.text).sorted()
            r.check("studio-names-italic",
                    italics == ["Lionsgate Films", "Shout Factory"],
                    "italic runs are \(italics)")
            // Every italic run must actually be IN the text, or the highlight colors
            // nothing and the check above is asserting a dead value.
            r.check("studio-italics-present",
                    italics.allSatisfy { studios.text.contains($0) },
                    "an italic run names a studio that is not in '\(studios.text)'")
        } else {
            r.check("studio-row-present", false, "no row for the double-dip film")
        }

        // A year is not a name and is not italicized — the double-dip note falls back to
        // years when the studios do not tell the copies apart.
        if let years = notesCell("PDF Notes Double Dip Years") {
            r.check("years-not-italic", years.highlights.filter(\.italic).isEmpty,
                    "a year label was italicized as though it were a studio")
        }

        // MARK: Studio abbreviation under truncation
        // The short form is used only when the full one would not fit, so an ordinary cell
        // still prints the studio's real name.
        if let studios = notesCell("PDF Notes Double Dip Studios") {
            r.check("studios-unabbreviated-when-they-fit",
                    studios.text.contains("Lionsgate Films"),
                    "a cell with room to spare abbreviated anyway: '\(studios.text)'")
        }
        if let crowded = notesCell("PDF Notes Crowded Studios") {
            // LGF and SF, from the table the RightSidebar's "Source for Viewing" field
            // abbreviates with — one table, so a studio reads the same in both places.
            r.check("studios-abbreviated-when-crowded",
                    crowded.text.contains("\(ReleaseStudio.abbreviated("Lionsgate Films"))/"
                                          + ReleaseStudio.abbreviated("Shout Factory")),
                    "an over-long cell did not fall back to the short studio forms: "
                        + "'\(crowded.text)'")
            r.check("crowded-studio-italics",
                    crowded.highlights.filter(\.italic).map(\.text).sorted() == ["LGF", "SF"],
                    "the italic runs must name the studios AS DRAWN, not as stored: "
                        + "\(crowded.highlights.filter(\.italic).map(\.text))")
        } else {
            r.check("crowded-studio-row-present", false, "no row for the crowded-notes film")
        }

        // MARK: Region-lock emphasis
        // The Notes column is a comma-joined list of a dozen unrelated facts, and one of
        // them says a disc on the shelf will not play. It is colored so it can be found at
        // this type size without a column of its own — and the LOOSE form is deliberately
        // not, because a bypass exists and that disc does play. Coloring the reassuring
        // case in the same red as the blocking one would train the reader to ignore both.
        //
        // A substring match cannot tell the two apart ("Loosely Region B locked" contains
        // "Region B locked"), which is exactly why this is asserted rather than assumed.
        func notesHighlights(_ title: String) -> [PDFTextHighlight]? {
            section.rows.first { $0[PDFColumn.title.rawValue].text == title }?
                .map { $0 }[PDFColumn.notes.rawValue].highlights
        }

        if let hard = notesHighlights("PDF Notes Region B") {
            r.check("region-lock-emphasized",
                    hard.count == 1 && hard[0].color == PDFPalette.red
                        && hard[0].text == "Region B locked",
                    "the blocking region note carries \(hard.count) highlight(s)")
        } else {
            r.check("region-lock-row-present", false, "no row for the hard-locked film")
        }
        if let loose = notesHighlights("PDF Notes Region B Loose") {
            r.check("loose-region-lock-not-emphasized", loose.isEmpty,
                    "a loosely-locked disc plays and must not be flagged red")
        } else {
            r.check("loose-region-lock-row-present", false, "no row for the loosely-locked film")
        }

        // Index column numbers the sorted order, 1-based and gapless.
        let indices = section.rows.map { $0[0].text }
        r.check("index-sequence", indices == (1...section.rows.count).map(String.init),
                "index column is \(indices.prefix(5))…")

        // Render for real, then read the document back.
        let url = scratchURL("library-pdf.pdf")
        try? FileManager.default.removeItem(at: url)

        var mediaBox = CGRect(origin: .zero, size: LibraryTableLayout.standard.geometry.pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = unsafe CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            r.check("context-created", false, "could not open a PDF context at \(url.path)")
            return r
        }

        try? await PDFTableRenderer.render(section, into: context, geometry: LibraryTableLayout.standard.geometry)
        // A second section at the PORTRAIT geometry. The assembled export no longer mixes
        // orientations, but the renderer's per-page media box still must handle it — so it
        // is exercised here rather than assumed.
        try? await PDFTableRenderer.render(
            PDFTableSection(title: "Portrait Probe",
                            columns: [PDFTableColumn("A", width: 1), PDFTableColumn("B", width: 1)],
                            textRows: [["a", "b"]]),
            into: context, geometry: .portraitLetter)
        context.closePDF()

        guard let document = PDFDocument(url: url) else {
            r.check("document-readable", false, "PDFKit could not open the rendered file")
            return r
        }
        r.check("document-readable", true, "\(document.pageCount) pages at \(url.path)")
        r.check("page-count", document.pageCount >= 2,
                "expected the library table plus a portrait probe page, got \(document.pageCount)")

        if let first = document.page(at: 0) {
            let bounds = first.bounds(for: .mediaBox)
            r.check("library-page-landscape", bounds.width > bounds.height,
                    "first page is \(Int(bounds.width))x\(Int(bounds.height))")
        }
        if let last = document.page(at: document.pageCount - 1) {
            let bounds = last.bounds(for: .mediaBox)
            r.check("report-page-portrait", bounds.height > bounds.width,
                    "last page is \(Int(bounds.width))x\(Int(bounds.height))")
        }

        // Every film's title must survive into the drawn text — the cheapest end-to-end
        // check that rows are not being clipped away by a layout mistake.
        let drawn = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined()
        // The truncation case is excluded by construction: it is the one title that must
        // NOT survive into the drawn text intact.
        let missing = corpus.map(\.film.name)
            .filter { $0 != longTitle && !drawn.contains($0) }
        r.check("titles-drawn", missing.isEmpty,
                missing.isEmpty ? "all \(corpus.count - 1) untruncated titles present"
                                : "missing from the rendered text: \(missing)")

        // Truncation must actually happen, and must be the ELLIPSIS kind rather than a
        // silent clip — and the full title must not appear, which is what would happen if
        // the cell quietly wrapped instead.
        r.check("title-truncated", !drawn.contains(longTitle),
                "the over-long title was drawn in full — the cell wrapped instead of truncating")
        // Truncated, not dropped: the leading words must still be on the page. (The
        // ellipsis GLYPH is drawn — confirmed visually — but does not survive PDF text
        // extraction, so it is deliberately not what this asserts.)
        r.check("title-truncation-keeps-prefix", drawn.contains(String(longTitle.prefix(24))),
                "the truncated title's opening words are not on the page")

        // A truncating cell occupies one line however long its text is. Measured on a
        // section of many such rows, so wrapping would visibly cost pages — comparing a
        // single row proves nothing, since one extra line rarely crosses a page boundary.
        let geometry = LibraryTableLayout.standard.geometry
        if let longRow = section.rows.first(where: { $0[1].text == longTitle }) {
            var truncating = section
            truncating.rows = Array(repeating: longRow, count: 60)
            var wrapping = truncating
            wrapping.rows = truncating.rows.map { row in
                var copy = row
                copy[1].truncates = false
                return copy
            }
            let truncatedPages = PDFTableRenderer.pageCount(of: truncating, geometry: geometry)
            let wrappedPages = PDFTableRenderer.pageCount(of: wrapping, geometry: geometry)
            r.check("title-truncation-saves-height", truncatedPages < wrappedPages,
                    "60 over-long titles: \(truncatedPages) pages truncating vs "
                        + "\(wrappedPages) wrapping — truncation is not limiting row height")
        } else {
            r.check("title-truncation-row-present", false, "the truncation case is missing")
        }

        checkHallOfFameSection(&r)

        // MARK: Column fit
        // Guards the widths in LibraryTableLayout, which are sized to their widest literal
        // and are therefore only correct until someone edits one. A column that comes up
        // half a point short does not truncate or error — it silently wraps ("Hybri/d"),
        // which also grows the height of every row it lands on.
        checkColumnFit(&r, section: section)

        // MARK: End-to-end
        // Everything above proves the library SECTION. This drives the real exporter,
        // which is the only thing that exercises the report sheets appended after it —
        // and the only thing that proves the assembled document actually reaches disk.
        let corpusFilms = corpus.map(\.film)
        coordinator.importFilms(corpusFilms)

        // Rank a handful so the assembled document actually contains a Hall of Fame sheet.
        // The ranking lives in MemoryStore's own ordering, not in the snapshot's
        // hofPosition, so it has to be established through the coordinator.
        let ranked = corpusFilms.prefix(6).map(\.id)
        for id in ranked { _ = coordinator.memoryStoreForTesting.addToHallOfFame(id) }
        coordinator.refreshFilms()

        let folder = scratchURL("library-pdf-export")
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        do {
            let exported = try await LibraryPDFExporter.export(dataCoordinator: coordinator,
                                                               destinationFolder: folder)
            r.check("export-file-written",
                    FileManager.default.fileExists(atPath: exported.path),
                    "wrote \(exported.lastPathComponent)")
            // Rendered inside the container and moved out whole — nothing left staged.
            let stagingLeft = ExportStaging.rootURL.flatMap {
                try? FileManager.default.contentsOfDirectory(atPath: $0.path(percentEncoded: false)) } ?? []
            r.check("export-staging-cleared", stagingLeft.isEmpty,
                    stagingLeft.isEmpty ? "" : "still staged: \(stagingLeft)")

            if let assembled = PDFDocument(url: exported) {
                r.check("export-page-count", assembled.pageCount > document.pageCount - 1,
                        "assembled document is \(assembled.pageCount) pages against "
                            + "\(document.pageCount - 1) for the library table alone")

                let text = (0..<assembled.pageCount)
                    .compactMap { assembled.page(at: $0)?.string }.joined()
                // Two report sheets remain, and both must be present: Data Visualizations
                // always has something to say about a non-empty library, and the corpus is
                // ranked above so the Hall of Fame does too.
                r.check("export-includes-hall-of-fame",
                        text.contains(ReportsCategory.hallOfFame.displayName),
                        "the Hall of Fame sheet is missing from the assembled document")
                r.check("export-includes-statistics",
                        text.contains(ReportsCategory.dataVisualizations.displayName),
                        "the statistics sheet is missing from the assembled document")
                r.check("export-includes-library-table",
                        text.contains(LibraryTableLayout.standard.sectionTitle),
                        "the library table's own title is missing")

                // The three superseded sheets must be GONE, not merely skipped for want of
                // data — the corpus above has priced purchases and would have produced a
                // tracker sheet under the old section list. Asserted by their headings,
                // because that is what a reader would see if one came back — each page's
                // first line, not its whole text, since the rendered Data Visualizations
                // page names the Release Wishlist report in a card's caption.
                let headings = (0..<assembled.pageCount).compactMap {
                    assembled.page(at: $0)?.string?.split(separator: "\n").first.map(String.init)
                }
                let superseded = [ReportsCategory.costTracker, .priceTracker, .releaseWishlist]
                    .map(\.displayName).filter { name in headings.contains { $0.hasPrefix(name) } }
                r.check("export-omits-superseded-sheets", superseded.isEmpty,
                        superseded.isEmpty
                            ? "the trackers and the wishlist are absent, as intended"
                            : "a superseded sheet is still printed: \(superseded)")
                r.check("export-section-list",
                        LibraryPDFSection.allCases.map(\.rawValue)
                            == ["completeLibrary", "viewingHistory", "discReleases",
                                "hallOfFame", "dataVisualizations"],
                        "the document's section list is "
                            + "\(LibraryPDFSection.allCases.map(\.rawValue))")

                // Every page of an assembled document carries BOTH counts, and the
                // document count must run to the real page total — the reason the builder
                // measures every section before drawing any of them.
                let footersComplete = (0..<assembled.pageCount).allSatisfy { index in
                    guard let page = assembled.page(at: index)?.string else { return false }
                    return page.contains("Section page") && page.contains("Document page")
                }
                r.check("export-footers-labeled", footersComplete,
                        "a page is missing one of the two labeled page counts")

                // The production stamp is on every page, and is the SAME stamp on each — a
                // render slow enough to cross a minute boundary must not date two pages
                // differently.
                let stampsPresent = (0..<assembled.pageCount).allSatisfy {
                    assembled.page(at: $0)?.string?.contains("Report produced on") ?? false
                }
                r.check("export-footer-timestamp", stampsPresent,
                        "a page is missing the production timestamp")

                let last = assembled.page(at: assembled.pageCount - 1)?.string ?? ""
                r.check("export-document-total",
                        last.contains("Document page \(assembled.pageCount) of \(assembled.pageCount)"),
                        "the final page does not close the document count")

                // Every page is the library table's page, in both size and orientation.
                let uniform = (0..<assembled.pageCount).allSatisfy { index in
                    guard let bounds = assembled.page(at: index)?.bounds(for: .mediaBox)
                    else { return false }
                    return bounds.width > bounds.height
                }
                r.check("export-all-landscape", uniform,
                        "the appended report sheets do not match the library table's page")
            } else {
                r.check("export-readable", false, "PDFKit could not open \(exported.path)")
            }
        } catch {
            r.check("export-succeeded", false, "\(error)")
        }

        // Leave the sandbox library as it was found. Deleting the films drops their
        // ranking with them.
        _ = coordinator.memoryStoreForTesting.deleteFilms(ids: Set(corpusFilms.map(\.id)))
        coordinator.refreshFilms()

        return r
    }

    // MARK: - Hall of Fame Section

    /// Drives the Hall of Fame section's two new rules: the position banding and the
    /// purchase-standing column.
    @MainActor
    private static func checkHallOfFameSection(_ r: inout HarnessScenarioResult) {
        func entry(_ position: Int,
                   _ purchase: HallOfFamePurchase,
                   upgrade: ReleaseFormat? = nil,
                   version: String = "",
                   rating: Int = 5) -> HallOfFameFilm {
            HallOfFameFilm(id: UUID(), position: position, name: "HOF \(position)",
                           releaseYear: "1999", userRating: rating, purchase: purchase,
                           upgrade: upgrade, version: version)
        }

        let films = [
            entry(1,  .purchased(.uhd4K)),
            entry(2,  .purchased(.bluRay), upgrade: .uhd4K),
            entry(3,  .purchased(.dvd), upgrade: .bluRay),
            entry(4,  .available(.uhd4K), upgrade: .uhd4K),
            entry(5,  .available(.bluRay), upgrade: .bluRay),
            entry(6,  .available(.dvd), upgrade: .dvd),
            entry(7,  .unavailable),
            // Band boundaries: 25 closes the first block, 26 opens the second, 51 the third.
            entry(25, .unavailable),
            entry(26, .unavailable),
            entry(51, .unavailable),
            // Notes composition and the three called-out ratings.
            entry(60, .purchased(.uhd4K), version: "Director\u{2019}s Cut", rating: 10),
            entry(61, .purchased(.bluRay), upgrade: .uhd4K, version: "Extended", rating: 9),
            entry(62, .purchased(.uhd4K), rating: 8),
            entry(63, .purchased(.uhd4K), rating: 7),
            entry(64, .purchased(.uhd4K), rating: 0),
        ]

        let data = ReportsExportData(category: .hallOfFame,
                                     hallOfFameFilms: films)
        guard case let .table(section)? = ReportsPDFExporter.sheet(for: data) else {
            r.check("hof-section-built", false, "the Hall of Fame section came back nil")
            return
        }

        let titles = section.columns.map(\.title)
        r.check("hof-column-order",
                titles == ["Position", "Title", "Year", "Rating", "Purchased", "Notes"],
                "columns are \(titles)")

        // Purchase standing: text and the complete-library shade it borrows.
        let expected: [(Int, String, NSColor)] = [
            (0, "4K", PDFPalette.paleGreen),
            (1, "BD", PDFPalette.green),
            (2, "DVD", PDFPalette.lightGray),
            // Unowned reduces to two marks; the Notes column names what is available.
            (3, "—", PDFPalette.red),
            (4, "—", PDFPalette.red),
            (5, "—", PDFPalette.red),
            (6, "Not Available", PDFPalette.red),
        ]
        for (row, text, fill) in expected {
            let cell = section.rows[row][4]
            r.check("hof-purchased-text-\(row)", cell.text == text,
                    "expected '\(text)', got '\(cell.text)'")
            r.check("hof-purchased-fill-\(row)", sameFill(cell.fill, fill),
                    "expected \(fillName(fill)), got \(fillName(cell.fill))")
        }

        // Notes: upgrade reporting, version reporting, and the shared list casing.
        let notes: [(Int, String)] = [
            (0, ""),                                    // owned at the top of the ladder
            (1, "4K UHD available"),                    // Blu-ray owned, 4K exists
            (2, "Blu-ray available"),                   // DVD owned, ladder picks Blu-ray
            (5, "DVD available"),                       // nothing owned, only a DVD exists
            (6, ""),                                    // nothing exists at all
            (10, "Director\u{2019}s Cut"),               // version alone
            (11, "Extended, 4K UHD available"),         // both, trailing item lowercased
        ]
        for (row, text) in notes {
            r.check("hof-notes-\(row)", section.rows[row][5].text == text,
                    "expected '\(text)', got '\(section.rows[row][5].text)'")
        }

        // Ratings: only the top three scores are tinted.
        let ratings: [(Int, String, NSColor?)] = [
            (10, "10", PDFPalette.darkGreen),
            (11, "9", PDFPalette.darkGold),
            (12, "8", PDFPalette.lightBlue),
            (13, "7", nil),
            (14, "—", nil),
        ]
        for (row, text, fill) in ratings {
            let cell = section.rows[row][3]
            r.check("hof-rating-text-\(row)", cell.text == text,
                    "expected '\(text)', got '\(cell.text)'")
            r.check("hof-rating-fill-\(row)", sameFill(cell.fill, fill),
                    "expected \(fillName(fill)), got \(fillName(cell.fill))")
        }

        // Banding: one color per block of 25, and the boundary lands between 25 and 26.
        func band(_ row: Int) -> NSColor? { section.rows[row][0].fill }
        r.check("hof-band-same-block", sameFill(band(0), band(7)),
                "positions 1 and 25 must share a band color")
        r.check("hof-band-boundary", !sameFill(band(7), band(8)),
                "positions 25 and 26 must fall in different bands")
        r.check("hof-band-next-boundary", !sameFill(band(8), band(9)),
                "positions 26 and 51 must fall in different bands")
        // The cycle must not walk the spectrum: adjacent blocks land on hues far enough
        // apart to tell apart at a glance.
        let firstTwo = [PDFPalette.bandHue(0), PDFPalette.bandHue(1)].compactMap {
            $0.usingColorSpace(.deviceRGB)?.hueComponent
        }
        if firstTwo.count == 2 {
            let separation = min(abs(firstTwo[0] - firstTwo[1]),
                                 1 - abs(firstTwo[0] - firstTwo[1]))
            r.check("hof-band-hue-separation", separation > 0.15,
                    "adjacent band hues are \(Fmt.fixed(separation, 3)) apart")
        }
        r.check("hof-band-from-palette",
                section.rows.allSatisfy { row in
                    PDFPalette.bandHues.contains { $0 == row[0].fill }
                },
                "a position fill came from outside the band palette")
    }

    // MARK: - Column Fit

    /// Asserts that every column designed to hold ONE line actually does, at the layout's
    /// real on-page widths.
    ///
    /// Title and Notes are excluded: they are the table's two elastic columns and wrapping
    /// is what they are for. The aspect column is checked against the values it is sized
    /// for rather than against every row, because its open-matte tags are longer than any
    /// width worth spending on them and wrap by design.
    @MainActor
    private static func checkColumnFit(_ r: inout HarnessScenarioResult,
                                       section: PDFTableSection) {
        let geometry = LibraryTableLayout.standard.geometry
        let body = PDFFonts.font(size: geometry.fontSize, weight: .semibold)
        let mono = PDFFonts.monospacedFont(size: geometry.fontSize, weight: .semibold)
        let header = PDFFonts.font(size: geometry.headerFontSize, weight: .bold)
        let padding = geometry.cellPaddingX * 2

        // The renderer normalizes the column set to the content width before drawing, so
        // the same scale is applied here rather than trusting the raw values to be points.
        let declared = section.columns.reduce(0) { $0 + $1.width }
        let scale = declared > 0 ? geometry.contentWidth / declared : 1
        func width(_ index: Int) -> CGFloat { section.columns[index].width * scale }

        func fits(_ text: String, _ font: NSFont, _ available: CGFloat) -> Bool {
            guard !text.isEmpty else { return true }
            let measured = NSAttributedString(string: text, attributes: [.font: font]).size().width
            return measured <= available - padding
        }

        // Single-line value columns. Title (1), Notes (9) and Aspect (12) are excluded.
        let singleLine = [0, 2, 3, 4, 5, 6, 7, 8, 10, 11, 13, 14, 15]
        for column in singleLine {
            let available = width(column)
            let offenders = section.rows.compactMap { row -> String? in
                fits(row[column].text, row[column].monospaced ? mono : body, available)
                    ? nil : row[column].text
            }
            r.check("fit-values-\(section.columns[column].title)-\(column)",
                    offenders.isEmpty,
                    offenders.isEmpty
                        ? "\(section.columns[column].title) fits in \(Fmt.fixed(available, 1))pt"
                        : "wraps at \(Fmt.fixed(available, 1))pt: \(Set(offenders))")
        }

        // The widest index this library could reach, rather than the widest it holds today.
        r.check("fit-index-four-digits", fits("8888", mono, width(0)),
                "the index column must hold four fixed-width digits without wrapping")

        // The aspect column's three competitors for its width.
        for value in ["Hybrid", "2.39:1"] {
            r.check("fit-aspect-\(value)", fits(value, body, width(12)),
                    "'\(value)' does not fit the aspect column")
        }
        r.check("fit-aspect-header", fits("Aspect", header, width(12)),
                "the 'Aspect' header line does not fit its column")

        // The chroma column is sized to the wider of the only two strings it can hold.
        r.check("fit-chroma-header", fits("Chr.", header, width(13)),
                "the 'Chr.' header does not fit its column")
        r.check("fit-chroma-value", fits("B&W", body, width(13)),
                "'B&W' does not fit the chroma column")

        // Sub-column headers sit on their own single row and must fit outright — against
        // the group's OWN header split, which is deliberately not the body columns' widths
        // (see PDFHeaderGroup.headerWeights). Measuring them against the body widths would
        // report a failure the rendered page does not have.
        for group in section.headerGroups {
            let members = Array(group.columns)
            let span = members.reduce(CGFloat(0)) { $0 + width($1) }
            let weights = group.headerWeights ?? members.map { section.columns[$0].width }
            let weightTotal = weights.reduce(0, +)
            for (offset, column) in members.enumerated() {
                let available = weightTotal > 0 ? weights[offset] / weightTotal * span : width(column)
                r.check("fit-header-\(section.columns[column].title)-\(column)",
                        fits(section.columns[column].title, header, available),
                        "the '\(section.columns[column].title)' sub-header does not fit "
                            + "\(Fmt.fixed(available, 1))pt")
            }
            // The split must still tile the span exactly, or the header row and the data
            // below it stop lining up.
            let laidOut = weightTotal > 0
                ? weights.map { $0 / weightTotal * span }.reduce(0, +)
                : span
            r.check("header-split-tiles-span-\(group.title)", abs(laidOut - span) < 0.01,
                    "sub-headers cover \(Fmt.fixed(laidOut, 2))pt of a "
                        + "\(Fmt.fixed(span, 2))pt span")
        }

        // A group banner spans its members and must clear their combined width.
        for group in section.headerGroups {
            let span = group.columns.reduce(CGFloat(0)) { $0 + width($1) }
            r.check("fit-banner-\(group.title)", fits(group.title, header, span),
                    "'\(group.title)' does not fit the \(Fmt.fixed(span, 1))pt it spans")
        }
    }

    // MARK: - Expectations

    /// The columns this scenario asserts on, by index and by name.
    private enum PDFColumn: Int {
        case title = 1
        case year = 2
        case source = 3
        case disc2K = 4
        case audio2K = 5
        case disc4K = 6
        case audio4K = 7
        case subs = 8
        case notes = 9
        case discs = 10
        case rf = 11
        case aspect = 12
        case chroma = 13
        case customEdit = 14
        case lastWatched = 15

        var index: Int { rawValue }
        var label: String {
            switch self {
            case .title: return "title"
            case .year: return "year"
            case .source: return "source"
            case .disc2K: return "disc2K"
            case .audio2K: return "audio2K"
            case .disc4K: return "disc4K"
            case .audio4K: return "audio4K"
            case .subs: return "subs"
            case .notes: return "notes"
            case .discs: return "discs"
            case .rf: return "rf"
            case .aspect: return "aspect"
            case .chroma: return "chroma"
            case .customEdit: return "customEdit"
            case .lastWatched: return "lastWatched"
            }
        }
    }

    /// A title far past what the column can hold, so the renderer must truncate it.
    /// Deliberately made of many short words: a title that could not be BROKEN would
    /// prove nothing, since a single long word is clipped either way.
    private static let longTitle =
        "PDF Title Truncation Case With A Great Many Words In It So That No Column Of Any "
        + "Reasonable Width Could Ever Hope To Contain The Whole Of It On One Single Line"

    private struct PDFExpectation {
        let film: FilmSnapshot
        let cells: [(PDFColumn, PDFCell)]
    }


    // MARK: - Reports Statistics Scenario

    /// Pins the population each Data Visualizations percentage is a share OF, and the
    /// determinism of the tracker orderings the PDF prints.
    ///
    /// Every check here failed before the corresponding fix. Three of the statistics
    /// divided a count of one thing by a count of another:
    ///
    ///   • the audio-channel breakdown counts a combo pack's child disc (it has its own
    ///     mix) but was divided by `totalPurchasedReleases`, which counts top-level
    ///     releases only — so the shares could sum past 100%;
    ///   • "Missing artwork" counts FILMS but was divided by a count of RELEASES;
    ///   • "Lossy Blu-ray audio" counts FILMS but was divided by a count of top-level
    ///     4K/Blu-ray RELEASES, which is not even a superset of its numerator.
    ///
    /// The corpus is built so each of those three denominators is a DIFFERENT number from
    /// the one previously used — a corpus where they coincide would pass either way and
    /// prove nothing.
    @MainActor
    private static func reportsStatisticsScenario(
        coordinator: DataCoordinator
    ) -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "reports-statistics")

        // A 4K combo pack: one purchase, two discs, each with its own audio mix. The child
        // carries the lossy track, so it is the child alone that puts this film in the
        // lossy tally — the case the old release-counting denominator could not contain.
        let comboParentID = UUID()
        let comboFilm = makeSnapshot(name: "Stats Combo", releases: [
            ReleaseSnapshot(id: comboParentID, purchased: true,
                            format: ReleaseFormat.uhd4K.rawValue,
                            audioFormat: ReleaseAudioFormat.dtsHDMA,
                            audioChannels: ReleaseAudioChannels.surround71,
                            hasArtwork: "No",
                            cost: 30, purchaseDate: "2024-03-02"),
            ReleaseSnapshot(purchased: true,
                            format: ReleaseFormat.bluRay.rawValue,
                            audioFormat: ReleaseAudioFormat.dolbyDigital,
                            audioChannels: ReleaseAudioChannels.surround51,
                            hasArtwork: "Yes",
                            cost: 0, purchaseDate: "2024-03-02",
                            parentReleaseID: comboParentID),
        ])

        // Two separate purchases of one film — this is what makes the film count and the
        // release count diverge.
        let twoDiscFilm = makeSnapshot(name: "Stats Two Discs", releases: [
            ReleaseSnapshot(purchased: true, format: ReleaseFormat.bluRay.rawValue,
                            audioFormat: ReleaseAudioFormat.dtsHDMA,
                            audioChannels: ReleaseAudioChannels.surround51,
                            hasArtwork: "Yes", cost: 20, purchaseDate: "2024-03-02"),
            // Carries a channel tag of its own, which is what makes the audio-tagged
            // population (4) differ from the purchased top-level population (3). Without
            // that divergence the two denominators coincide and the check below would pass
            // against the old, wrong one.
            ReleaseSnapshot(purchased: true, format: ReleaseFormat.dvd.rawValue,
                            audioFormat: ReleaseAudioFormat.dolbyDigital,
                            audioChannels: ReleaseAudioChannels.stereo20,
                            hasArtwork: "Yes", cost: 10, purchaseDate: "2024-07-09"),
        ])

        // A purchase with no cost recorded. It counts as a purchase everywhere, but must be
        // excluded from the cost average — which is the difference between averaging over
        // `cost > 0` and averaging over every purchased release.
        let freeFilm = makeSnapshot(name: "Stats No Cost", releases: [
            ReleaseSnapshot(purchased: true, format: ReleaseFormat.bluRay.rawValue,
                            audioFormat: ReleaseAudioFormat.dtsHDMA,
                            audioChannels: ReleaseAudioChannels.surround71,
                            hasArtwork: "Yes", cost: 0, purchaseDate: "2024-07-09"),
        ])

        // No releases at all: present in `totalFilms`, absent from every purchase-side
        // population, which is what the film-level denominators must exclude.
        let digitalOnlyFilm = makeSnapshot(name: "Stats Digital Only")

        let films = [comboFilm, twoDiscFilm, freeFilm, digitalOnlyFilm]
        let stats = LibraryStatistics(films: films)

        // MARK: Populations

        r.check("purchased-releases-excludes-combo-child",
                stats.totalPurchasedReleases == 4,
                "totalPurchasedReleases = \(stats.totalPurchasedReleases), expected 4 "
                + "(combo parent, two discs, one costless disc; the combo child is not its "
                + "own purchase)")

        r.check("audio-denominator-includes-combo-child",
                stats.audioChannelDenominator == 5,
                "audioChannelDenominator = \(stats.audioChannelDenominator), expected 5 "
                + "(7.1 parent, 5.1 combo child, 5.1 disc, 2.0 DVD, 7.1 costless disc) — "
                + "strictly MORE than the four top-level purchases, because the combo "
                + "child carries a mix of its own. Dividing by totalPurchasedReleases here "
                + "asks five discs to be shares of four.")

        // The tallied rows must fit inside the population they are drawn from. This is the
        // statement the bug violated, and it subsumes a per-row "no share above 100%"
        // check: if the rows sum to no more than the denominator, no single row can exceed
        // it either.
        let channelRows = stats.audioChannelDistribution
            .filter { $0.0 != "---" && $0.0 != "Object-based mixes" }
        let channelTotal = channelRows.reduce(0) { $0 + $1.1 }
        r.check("audio-rows-fit-denominator",
                channelTotal <= stats.audioChannelDenominator,
                "channel rows total \(channelTotal) against a denominator of "
                + "\(stats.audioChannelDenominator)")

        // MARK: Film-count numerators over film-count denominators

        // One film (the combo) has a purchased release with artwork missing.
        r.check("missing-artwork-films", stats.missingReleaseArtwork == 1,
                "\(stats.missingReleaseArtwork) film(s), expected 1")

        // The combo's CHILD Blu-ray is the lossy one, so the film counts. Two films have a
        // 4K or Blu-ray release. The old denominator counted top-level 4K/BD releases — 3
        // here — and would have reported 33%.
        r.check("lossy-audio-over-films-with-hd-discs",
                stats.lossyBDAudio == 1 && stats.lossyBDAudioPercent == 33,
                "\(stats.lossyBDAudio) film(s), \(stats.lossyBDAudioPercent)% "
                + "— expected 1 and 33% (1 of the 3 films holding a 4K/Blu-ray release)")

        // MARK: One year aggregation

        let byTable = Dictionary(uniqueKeysWithValues: stats.purchaseYearTable.map { ($0.year, $0.count) })
        r.check("year-buckets-correct", byTable["2024"] == 4,
                "2024 = \(byTable["2024"].map(String.init) ?? "nil"), expected 4")

        // MARK: One average cost

        // $30, $20 and $10 are the three COSTED purchases. The fourth purchase has no cost
        // recorded and must not drag the average down to $15, which is what averaging over
        // every purchased release rather than over `cost > 0` would produce. So the average
        // is $20, and the $20 and $10 discs are the two at or below it. This is the single
        // number the display string and the at-or-below column both now come from; they
        // were computed separately, from two identical filters, before.
        r.check("average-cost-single-definition", stats.averageCost == "$20.00",
                "averageCost = \(stats.averageCost), expected $20.00")
        r.check("at-or-below-average-uses-that-average",
                stats.purchaseYearTable.first(where: { $0.year == "2024" })?.atOrBelowAverageCount == 2,
                "at-or-below = "
                + "\(stats.purchaseYearTable.first(where: { $0.year == "2024" })?.atOrBelowAverageCount.description ?? "nil")"
                + ", expected 2 ($20 and $10 against a $20 average)")

        // MARK: Format breakdown

        // Bucketed per FILM, not per release, and in the format ladder's order: a film with
        // a purchased 4K lands in the 4K row whatever else it owns; "Blu-ray only" is a
        // film with a purchased Blu-ray and no purchased 4K; "DVD only" has neither. So
        // the combo film is the 4K row, the two-disc film and the free film are the Blu-ray
        // row (the two-disc film's DVD is overlap, not a DVD-only film), and the DVD row is
        // empty. Row labels are the display strings the on-screen table and PDF print.
        r.check("format-breakdown-order",
                stats.formatBreakdown.map(\.format) == ["Purchased \(ReleaseFormat.uhd4K.rawValue)",
                                                        "Purchased \(ReleaseFormat.bluRay.rawValue) only",
                                                        "Purchased \(ReleaseFormat.dvd.rawValue) only"],
                "formats: \(stats.formatBreakdown.map(\.format))")
        r.check("format-breakdown-counts",
                stats.formatBreakdown.map(\.count) == [1, 2, 0],
                "counts: \(stats.formatBreakdown.map(\.count)) — one 4K film, two Blu-ray-only "
                + "films, no DVD-only film; the combo child is not a purchase of its own")
        // Average cost samples each bucket's own purchased top-level releases of that
        // format: $30 for the 4K; $20 for the Blu-ray row (the costless disc contributes no
        // sample); nothing for the empty DVD row.
        r.check("format-breakdown-average-costs",
                stats.formatBreakdown.map(\.avgCost) == ["$30.00", "$20.00", "—"],
                "average costs: \(stats.formatBreakdown.map(\.avgCost))")

        // MARK: Tracker ordering is total, and so reproducible

        // `costTrackerRows` derives its rows from `getAllFilms()`, which is
        // `Array(films.values)` over a Dictionary and therefore hands them over in no
        // particular order. Two of the three purchases here share a purchase date, so only
        // the title tiebreak can make the resulting order the same twice.
        //
        // This used to drive `LibraryPDFExporter.exportData(for: .costTracker, …)`, because
        // the property under test was that the EXPORT applied a total order. That sheet is
        // gone — the Disc-based Releases section supersedes it — so the check now drives
        // the rule where it still ships: the pair `ReportTrackers` calls to fill the
        // on-screen tab. The rule is the same one and the corpus still pins it; what is no
        // longer covered, because it no longer exists, is a PDF that depended on it.
        func sortedCostRows(_ films: [FilmSnapshot]) -> [ReleaseData] {
            ReleaseData.sorted(ReleaseData.costTrackerRows(films: films),
                               using: ReleaseData.costTrackerDefaultSort)
        }

        let forward = sortedCostRows(films)
        let reversed = sortedCostRows(films.reversed())
        r.check("cost-tracker-order-is-input-independent",
                !forward.isEmpty && forward.map(\.releaseID) == reversed.map(\.releaseID),
                "forward \(forward.map(\.filmTitle)) vs reversed \(reversed.map(\.filmTitle))")

        // Three rows, not four: the costless purchase has neither a cost nor an amount
        // spent, and the tracker's whole subject is money, so it is correctly absent.
        r.check("cost-tracker-orders-newest-purchase-first",
                forward.map(\.purchaseDate) == ["2024-07-09", "2024-03-02", "2024-03-02"],
                "dates: \(forward.map(\.purchaseDate))")

        // The tie is broken by gallery-style title order, not by arrival order.
        r.check("cost-tracker-breaks-ties-by-title",
                forward.map(\.filmTitle)
                    == ["Stats Two Discs", "Stats Combo", "Stats Two Discs"],
                "rows: \(forward.map(\.filmTitle))")

        // The tracker date columns read the spelling the Releases tab actually writes
        // (`yyyy.MM.dd`), not only the legacy dash form — they used to print the stored
        // dot string raw.
        let trackerRow = { (purchase: String, lowest: String) in
            ReleaseData(releaseID: UUID(), filmID: UUID(), filmTitle: "Row", filmSortName: "",
                        cost: 1, amountSpent: 1, lowestPrice: 1, purchaseDate: purchase,
                        lowestPriceDate: lowest, studio: "", condition: "", notes: "")
        }
        let dotRow = trackerRow("2024.05.01", "2023.06.09")
        r.check("tracker-dates-read-stored-dot-form",
                dotRow.purchaseDateFormatted == "May 1, 2024"
                    && dotRow.lowestPriceDateFormatted == "June 9, 2023",
                "\(dotRow.purchaseDateFormatted) / \(dotRow.lowestPriceDateFormatted)")
        let otherRow = trackerRow("2024-05-01", "")
        r.check("tracker-dates-keep-dash-and-blank",
                otherRow.purchaseDateFormatted == "May 1, 2024" && otherRow.lowestPriceDateFormatted == "—",
                "\(otherRow.purchaseDateFormatted) / \(otherRow.lowestPriceDateFormatted)")

        // The Title header sorts as the gallery's Title sort does: sort name over name,
        // articles stripped, numbers last, then year, both directions exact reverses.
        let titleRow = { (title: String, sortName: String, year: String) in
            ReleaseData(releaseID: UUID(), filmID: UUID(), filmTitle: title, filmSortName: sortName,
                        filmYear: year, cost: 1, amountSpent: 1, lowestPrice: 0, purchaseDate: "",
                        lowestPriceDate: "", studio: "", condition: "", notes: "")
        }
        let titled = [titleRow("10 Things", "", "1999"), titleRow("The Zebra", "", "2001"),
                      titleRow("Mango", "Apple", "2002"), titleRow("Blob", "", "1988"),
                      titleRow("Blob", "", "1958")]
        let byTitle = ReleaseData.comparators(forHeaderSort: [(key: "filmTitle", ascending: true)])
        let ascending = ReleaseData.sorted(titled, using: byTitle).map { "\($0.filmTitle) \($0.titleSort.year)" }
        let descending = ReleaseData.sorted(titled, using: ReleaseData.comparators(
            forHeaderSort: [(key: "filmTitle", ascending: false)])).map { "\($0.filmTitle) \($0.titleSort.year)" }
        let expected = ["Mango 2002", "Blob 1958", "Blob 1988", "The Zebra 2001", "10 Things 1999"]
        r.check("tracker-title-sort-matches-gallery",
                ascending == expected && descending == expected.reversed()
                    && ReleaseData.headerSort(for: byTitle).first?.key == "filmTitle",
                "ascending \(ascending), descending \(descending)")

        return r
    }

    // MARK: - Corpus

    /// One film per rule branch, each named for the branch it pins down.
    @MainActor
    private static func libraryPDFCorpus() -> [PDFExpectation] {
        func film(_ name: String, _ mutate: (inout FilmSnapshot) -> Void) -> FilmSnapshot {
            var snapshot = makeSnapshot(name: name)
            mutate(&snapshot)
            return snapshot
        }

        var out: [PDFExpectation] = []

        // MARK: Digital source
        out.append(PDFExpectation(
            film: film("PDF Source BD") { $0.digitalSource = FilmDigitalSource.blurayDisc },
            cells: [(.source, PDFCell("BD", fill: PDFPalette.green))]))
        out.append(PDFExpectation(
            film: film("PDF Source RemBD") {
                $0.digitalSource = FilmDigitalSource.compose(
                    source: FilmDigitalSource.blurayDisc, remastered: true)
            },
            cells: [(.source, PDFCell("remaster", fill: PDFPalette.paleGreen))]))
        out.append(PDFExpectation(
            film: film("PDF Source DVD") { $0.digitalSource = FilmDigitalSource.dvd },
            cells: [(.source, PDFCell("DVD", fill: PDFPalette.red))]))
        out.append(PDFExpectation(
            film: film("PDF Source 1080p") { $0.digitalSource = FilmDigitalSource.download1080p },
            cells: [(.source, PDFCell("1080p", fill: PDFPalette.darkGreen))]))
        out.append(PDFExpectation(
            film: film("PDF Source 720p") { $0.digitalSource = FilmDigitalSource.download720p },
            cells: [(.source, PDFCell("720p", fill: PDFPalette.darkGreen))]))
        out.append(PDFExpectation(
            film: film("PDF Source 480p") { $0.digitalSource = FilmDigitalSource.download480p },
            cells: [(.source, PDFCell("480p", fill: PDFPalette.red))]))
        out.append(PDFExpectation(
            film: film("PDF Source Unset") { _ in },
            cells: [(.source, PDFCell("", fill: PDFPalette.red))]))

        // MARK: Purchased non-4K, with the tier order under test
        out.append(PDFExpectation(
            film: film("PDF Disc BD") {
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.bluRay.rawValue,
                                               audioFormat: ReleaseAudioFormat.dtsHDMA,
                                               audioChannels: ReleaseAudioChannels.surround51)]
            },
            cells: [(.disc2K, PDFCell("BD", fill: PDFPalette.green)),
                    (.audio2K, PDFCell("5.1", fill: PDFPalette.green))]))
        out.append(PDFExpectation(
            film: film("PDF Disc RemBD Over BD") {
                // The plain Blu-ray is listed first and is the newer pressing, so only the
                // tier ranking can put the remastered one in the cell.
                $0.releases = [
                    ReleaseSnapshot(releaseDate: "2020", purchased: true,
                                    format: ReleaseFormat.bluRay.rawValue,
                                    audioFormat: ReleaseAudioFormat.dolbyDigital,
                                    audioChannels: ReleaseAudioChannels.stereo20),
                    ReleaseSnapshot(releaseDate: "2008", purchased: true,
                                    format: ReleaseFormat.bluRay.rawValue,
                                    audioFormat: ReleaseAudioFormat.dolbyAtmos,
                                    audioChannels: ReleaseAudioChannels.surround71,
                                    remastered: true),
                ]
            },
            cells: [(.disc2K, PDFCell("remaster", fill: PDFPalette.paleGreen)),
                    // Atmos is object-based, so the audio cell qualifies rather than affirms.
                    (.audio2K, PDFCell("7.1", fill: PDFPalette.paleGreen))]))
        out.append(PDFExpectation(
            film: film("PDF Disc BD Over DVD") {
                $0.releases = [
                    ReleaseSnapshot(purchased: true, format: ReleaseFormat.dvd.rawValue,
                                    audioChannels: ReleaseAudioChannels.stereo20,
                                    remastered: true),
                    ReleaseSnapshot(purchased: true, format: ReleaseFormat.bluRay.rawValue,
                                    audioChannels: ReleaseAudioChannels.surround51),
                ]
            },
            cells: [(.disc2K, PDFCell("BD", fill: PDFPalette.green)),
                    (.audio2K, PDFCell("5.1", fill: PDFPalette.green))]))
        out.append(PDFExpectation(
            film: film("PDF Disc DVD") {
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.dvd.rawValue,
                                               audioChannels: ReleaseAudioChannels.surround51)]
            },
            cells: [(.disc2K, PDFCell("DVD", fill: PDFPalette.lightGray))]))
        out.append(PDFExpectation(
            // A remastered DVD reads "remaster" too — the light gray is what says DVD.
            film: film("PDF Disc RemDVD") {
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.dvd.rawValue,
                                               remastered: true)]
            },
            cells: [(.disc2K, PDFCell("remaster", fill: PDFPalette.lightGray))]))
        // No non-4K release on record at all: nothing to buy, so NEITHER sub-column of the
        // Blu-ray group takes the red that means "available and unbought".
        out.append(PDFExpectation(
            film: film("PDF Disc None") { _ in },
            cells: [(.disc2K, PDFCell("")),
                    (.audio2K, PDFCell(""))]))
        // An unpurchased DVD is something to buy: the group goes back to red, even though
        // the Disc cell's own text reports only Blu-rays.
        out.append(PDFExpectation(
            film: film("PDF Disc DVD Unpurchased") {
                $0.releases = [ReleaseSnapshot(format: ReleaseFormat.dvd.rawValue)]
            },
            cells: [(.disc2K, PDFCell("", fill: PDFPalette.red)),
                    (.audio2K, PDFCell("", fill: PDFPalette.red))]))
        // An unpurchased Blu-ray must NOT fill the purchased column as though it were
        // owned — it reports the standing option instead, exactly as the 4K column does.
        out.append(PDFExpectation(
            film: film("PDF Disc Unpurchased") {
                $0.releases = [ReleaseSnapshot(format: ReleaseFormat.bluRay.rawValue,
                                               audioChannels: ReleaseAudioChannels.surround51)]
            },
            cells: [(.disc2K, PDFCell("available", fill: PDFPalette.red))]))
        // A single foreign unpurchased Blu-ray names itself an import.
        out.append(PDFExpectation(
            film: film("PDF Disc Unpurchased Import") {
                $0.releases = [ReleaseSnapshot(format: ReleaseFormat.bluRay.rawValue,
                                               nationalOrigin: "Germany")]
            },
            cells: [(.disc2K, PDFCell("import", fill: PDFPalette.red))]))
        // Out of print outranks the import qualifier: the disc cannot simply be bought.
        out.append(PDFExpectation(
            film: film("PDF Disc Unpurchased OOP") {
                $0.releases = [ReleaseSnapshot(
                    format: ReleaseFormat.bluRay.rawValue,
                    nationalOrigin: "Germany",
                    marketAvailability: [ReleaseMarketAvailability.outOfPrint, ReleaseMarketAvailability.exorbitant])]
            },
            cells: [(.disc2K, PDFCell("OOP", fill: PDFPalette.red))]))
        // MARK: Purchased 4K
        out.append(PDFExpectation(
            film: film("PDF 4K Native") {
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.uhd4K.rawValue,
                                               audioFormat: ReleaseAudioFormat.dtsHDMA,
                                               audioChannels: ReleaseAudioChannels.surround71,
                                               masterType: ReleaseMasterType.nativeFourK)]
            },
            cells: [(.disc4K, PDFCell("native", fill: PDFPalette.lightBlue)),
                    (.audio4K, PDFCell("7.1", fill: PDFPalette.green))]))
        out.append(PDFExpectation(
            film: film("PDF 4K Upscaled") {
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.uhd4K.rawValue,
                                               audioFormat: ReleaseAudioFormat.dtsX,
                                               audioChannels: ReleaseAudioChannels.surround71,
                                               masterType: ReleaseMasterType.upscaled)]
            },
            cells: [(.disc4K, PDFCell("upscaled", fill: PDFPalette.purple)),
                    (.audio4K, PDFCell("7.1", fill: PDFPalette.paleGreen))]))
        out.append(PDFExpectation(
            film: film("PDF 4K Native Over Upscaled") {
                $0.releases = [
                    ReleaseSnapshot(releaseDate: "2023", purchased: true,
                                    format: ReleaseFormat.uhd4K.rawValue,
                                    audioChannels: ReleaseAudioChannels.stereo20,
                                    masterType: ReleaseMasterType.upscaled),
                    ReleaseSnapshot(releaseDate: "2017", purchased: true,
                                    format: ReleaseFormat.uhd4K.rawValue,
                                    audioChannels: ReleaseAudioChannels.surround51,
                                    masterType: ReleaseMasterType.nativeFourK),
                ]
            },
            cells: [(.disc4K, PDFCell("native", fill: PDFPalette.lightBlue)),
                    (.audio4K, PDFCell("5.1", fill: PDFPalette.green))]))
        out.append(PDFExpectation(
            film: film("PDF 4K Available") {
                $0.releases = [ReleaseSnapshot(format: ReleaseFormat.uhd4K.rawValue,
                                               masterType: ReleaseMasterType.nativeFourK)]
            },
            cells: [(.disc4K, PDFCell("available", fill: PDFPalette.red)),
                    (.audio4K, PDFCell("", fill: PDFPalette.red))]))
        // Nothing to buy is not a gap: no 4K release at all takes NO fill, where a 4K
        // release nobody bought takes red.
        out.append(PDFExpectation(
            film: film("PDF 4K None") { _ in },
            cells: [(.disc4K, PDFCell("")), (.audio4K, PDFCell(""))]))

        // MARK: Subtitles
        out.append(PDFExpectation(
            film: film("PDF Subs Yes") { $0.subtitles = FilmSubtitles.yes },
            cells: [(.subs, PDFCell("yes", fill: PDFPalette.green))]))
        out.append(PDFExpectation(
            film: film("PDF Subs Disc") { $0.subtitles = FilmSubtitles.onDiscOnly },
            cells: [(.subs, PDFCell("disc", fill: PDFPalette.darkGold))]))
        out.append(PDFExpectation(
            film: film("PDF Subs No") { $0.subtitles = FilmSubtitles.no },
            cells: [(.subs, PDFCell("", fill: PDFPalette.red))]))
        out.append(PDFExpectation(
            film: film("PDF Subs Unset") { _ in },
            cells: [(.subs, PDFCell("", fill: PDFPalette.red))]))

        // MARK: Disc count — a combo pack and its children must not double-count
        let parentID = UUID()
        out.append(PDFExpectation(
            film: film("PDF Discs Pack") {
                $0.releases = [
                    ReleaseSnapshot(id: parentID, purchased: true,
                                    format: ReleaseFormat.bluRay.rawValue,
                                    numberOfDiscs: 3,
                                    childReleaseIDs: [UUID()]),
                    ReleaseSnapshot(purchased: true, format: ReleaseFormat.dvd.rawValue,
                                    numberOfDiscs: 2, parentReleaseID: parentID),
                    ReleaseSnapshot(purchased: true, format: ReleaseFormat.dvd.rawValue,
                                    numberOfDiscs: 1),
                ]
            },
            cells: [(.discs, PDFCell("4", fill: PDFPalette.green)),
                    // Owned but never encoded — the rf column turns red even though the
                    // rest of the row is tinted green.
                    (.rf, PDFCell("", fill: PDFPalette.red))]))

        // MARK: RF, aspect ratio, chroma, last watched
        out.append(PDFExpectation(
            film: film("PDF RF Set") { $0.libraryHBRFValue = 18 },
            cells: [(.rf, PDFCell("18"))]))
        out.append(PDFExpectation(
            film: film("PDF RF Unset") { _ in }, cells: [(.rf, PDFCell("\u{2013}"))]))

        out.append(PDFExpectation(
            film: film("PDF Aspect Narrow") { $0.aspectRatio = "1.37:1" },
            cells: [(.aspect, PDFCell("1.37:1", fill: PDFPalette.veryDarkGold))]))
        out.append(PDFExpectation(
            film: film("PDF Aspect Boundary Low") { $0.aspectRatio = "1.60:1" },
            cells: [(.aspect, PDFCell("1.60:1", fill: PDFPalette.veryDarkGreen))]))
        out.append(PDFExpectation(
            film: film("PDF Aspect Open Matte") { $0.aspectRatio = "1.85:1 (Open matte)" },
            cells: [(.aspect, PDFCell("1.85:1", fill: PDFPalette.veryDarkGreen)),
                    // The qualifier moves out of the column and into Notes.
                    (.notes, PDFCell("Open matte"))]))
        out.append(PDFExpectation(
            film: film("PDF Aspect Boundary High") { $0.aspectRatio = "2.00:1" },
            cells: [(.aspect, PDFCell("2.00:1", fill: PDFPalette.veryDarkBlue))]))
        out.append(PDFExpectation(
            film: film("PDF Aspect Wide") { $0.aspectRatio = "2.39:1" },
            cells: [(.aspect, PDFCell("2.39:1", fill: PDFPalette.veryDarkBlue))]))
        out.append(PDFExpectation(
            film: film("PDF Aspect Hybrid") { $0.aspectRatio = "Hybrid" },
            cells: [(.aspect, PDFCell("Hybrid", fill: PDFPalette.veryDarkPurple))]))
        out.append(PDFExpectation(
            film: film("PDF Aspect Unset") { _ in }, cells: [(.aspect, PDFCell(""))]))

        out.append(PDFExpectation(
            film: film("PDF Chroma Color") { $0.color = true },
            cells: [(.chroma, PDFCell("", fill: PDFPalette.seafoam))]))
        out.append(PDFExpectation(
            film: film("PDF Chroma BW") { $0.color = false },
            cells: [(.chroma, PDFCell("B&W", fill: PDFPalette.lightGray))]))

        out.append(PDFExpectation(
            film: film("PDF Watched Dated") { $0.lastWatched = "2025.07.21" },
            cells: [(.lastWatched, PDFCell("Jul 21, 2025"))]))
        out.append(PDFExpectation(
            // A stored viewing-version code must not defeat the parse.
            film: film("PDF Watched Versioned") { $0.lastWatched = "2026.01.24.TH" },
            cells: [(.lastWatched, PDFCell("Jan 24, 2026"))]))
        out.append(PDFExpectation(
            film: film("PDF Watched Never") { _ in },
            cells: [(.lastWatched, PDFCell("\u{2013}"))]))

        out.append(PDFExpectation(
            // Open matte on a NARROW ratio still bands by the stripped value.
            film: film("PDF Aspect Open Matte Narrow") { $0.aspectRatio = "1.33:1 (Open matte)" },
            cells: [(.aspect, PDFCell("1.33:1", fill: PDFPalette.veryDarkGold)),
                    (.notes, PDFCell("Open matte"))]))

        // MARK: Title truncation
        out.append(PDFExpectation(
            film: film(longTitle) { _ in },
            cells: [(.title, PDFCell(longTitle, truncates: true))]))

        // MARK: Custom edit
        out.append(PDFExpectation(
            film: film("PDF Edit Yes") { $0.edited = true },
            cells: [(.customEdit, PDFCell("yes", fill: PDFPalette.brown))]))
        out.append(PDFExpectation(
            film: film("PDF Edit No") { $0.edited = false },
            cells: [(.customEdit, PDFCell(""))]))

        // MARK: Ownership tint across the film-level columns
        out.append(PDFExpectation(
            film: film("PDF Tint BluRay") {
                $0.libraryHBRFValue = 20
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.bluRay.rawValue,
                                               numberOfDiscs: 1)]
            },
            cells: [(.title, PDFCell("PDF Tint BluRay", fill: PDFPalette.green)),
                    (.year, PDFCell("2000", fill: PDFPalette.green)),
                    (.notes, PDFCell("", fill: PDFPalette.green)),
                    (.discs, PDFCell("1", fill: PDFPalette.green)),
                    (.rf, PDFCell("20", fill: PDFPalette.green))]))
        out.append(PDFExpectation(
            // 4K wins the tint even when the only other disc is a DVD.
            film: film("PDF Tint FourK") {
                $0.releases = [
                    ReleaseSnapshot(purchased: true, format: ReleaseFormat.dvd.rawValue),
                    ReleaseSnapshot(purchased: true, format: ReleaseFormat.uhd4K.rawValue,
                                    masterType: ReleaseMasterType.nativeFourK),
                ]
            },
            cells: [(.title, PDFCell("PDF Tint FourK", fill: PDFPalette.green))]))
        out.append(PDFExpectation(
            film: film("PDF Tint DVD Only") {
                $0.libraryHBRFValue = 22
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.dvd.rawValue)]
            },
            cells: [(.title, PDFCell("PDF Tint DVD Only", fill: PDFPalette.lightGray)),
                    (.year, PDFCell("2000", fill: PDFPalette.lightGray)),
                    (.rf, PDFCell("22", fill: PDFPalette.lightGray))]))
        out.append(PDFExpectation(
            // Nothing bought — the film-level columns stay neutral rather than turning red.
            film: film("PDF Tint Unowned") { $0.libraryHBRFValue = 21 },
            cells: [(.title, PDFCell("PDF Tint Unowned")),
                    (.year, PDFCell("2000")),
                    (.discs, PDFCell("")),
                    (.rf, PDFCell("21"))]))
        out.append(PDFExpectation(
            // Unowned AND unencoded is a non-event, not a gap: no red.
            film: film("PDF Tint Unowned No RF") { _ in },
            cells: [(.rf, PDFCell("\u{2013}"))]))

        // MARK: Notes accumulation
        out.append(PDFExpectation(
            film: film("PDF Notes Steelbook Only") {
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.bluRay.rawValue,
                                               hasArtwork: ReleaseArtwork.steelbook)]
            },
            cells: [(.notes, PDFCell("Steelbook", fill: PDFPalette.green))]))
        out.append(PDFExpectation(
            film: film("PDF Notes Authored Plus Steelbook") {
                $0.notes = "Import from Germany"
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.bluRay.rawValue,
                                               hasArtwork: ReleaseArtwork.steelbook)]
            },
            // The authored note now TRAILS every derived item, verbatim.
            cells: [(.notes, PDFCell("Steelbook, Import from Germany", fill: PDFPalette.green))]))
        out.append(PDFExpectation(
            // An UNPURCHASED steelbook is not on the shelf and must not be reported.
            film: film("PDF Notes Steelbook Unpurchased") {
                $0.releases = [ReleaseSnapshot(format: ReleaseFormat.bluRay.rawValue,
                                               hasArtwork: ReleaseArtwork.steelbook)]
            },
            cells: [(.notes, PDFCell(""))]))

        // MARK: Notes — derived items

        // Two purchased Blu-rays from different studios: named by studio.
        out.append(PDFExpectation(
            film: film("PDF Notes Double Dip Studios") {
                $0.releases = [
                    ReleaseSnapshot(studio: "Lionsgate Films", releaseDate: "2011",
                                    purchased: true, format: ReleaseFormat.bluRay.rawValue),
                    ReleaseSnapshot(studio: "Shout Factory", releaseDate: "2018",
                                    purchased: true, format: ReleaseFormat.bluRay.rawValue),
                ]
            },
            cells: [(.notes, PDFCell("Lionsgate Films/Shout Factory 2K releases",
                                     fill: PDFPalette.green))]))
        // Same studio twice: the YEAR is the only thing that tells the copies apart.
        out.append(PDFExpectation(
            film: film("PDF Notes Double Dip Years") {
                $0.releases = [
                    ReleaseSnapshot(studio: "Arrow Video", releaseDate: "2011",
                                    purchased: true, format: ReleaseFormat.bluRay.rawValue),
                    ReleaseSnapshot(studio: "Arrow Video", releaseDate: "2018",
                                    purchased: true, format: ReleaseFormat.bluRay.rawValue),
                ]
            },
            cells: [(.notes, PDFCell("2011/2018 2K releases", fill: PDFPalette.green))]))
        // Same studio AND same year: two copies of one release, which the note would only
        // describe as "2017/2017". Suppressed entirely.
        out.append(PDFExpectation(
            film: film("PDF Notes Double Dip Same Year") {
                $0.releases = [
                    ReleaseSnapshot(studio: "Arrow Video", releaseDate: "2017",
                                    purchased: true, format: ReleaseFormat.bluRay.rawValue),
                    ReleaseSnapshot(studio: "Arrow Video", releaseDate: "2017",
                                    purchased: true, format: ReleaseFormat.bluRay.rawValue),
                ]
            },
            cells: [(.notes, PDFCell("", fill: PDFPalette.green))]))

        // Every purchased disc Region B locked — the note LEADS the cell.
        out.append(PDFExpectation(
            film: film("PDF Notes Region B") {
                $0.notes = "Fine transfer"
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.bluRay.rawValue,
                                               regionLock: ReleaseRegionRules.regionB)]
            },
            // The authored note keeps its own case wherever it lands.
            cells: [(.notes, PDFCell("Region B locked, Fine transfer", fill: PDFPalette.green))]))
        out.append(PDFExpectation(
            film: film("PDF Notes Region B Loose") {
                $0.releases = [ReleaseSnapshot(
                    purchased: true, format: ReleaseFormat.bluRay.rawValue,
                    regionLock: ReleaseRegionRules.looselyLockedTag)]
            },
            cells: [(.notes, PDFCell("Loosely Region B locked", fill: PDFPalette.green))]))
        // A second, Region A copy does NOT excuse the locked one: one unplayable disc on
        // the shelf is still worth reporting.
        out.append(PDFExpectation(
            film: film("PDF Notes Region B Mixed") {
                $0.releases = [
                    ReleaseSnapshot(studio: "Arrow Video", releaseDate: "2011",
                                    purchased: true, format: ReleaseFormat.uhd4K.rawValue,
                                    regionLock: ReleaseRegionRules.regionB),
                    ReleaseSnapshot(studio: "Criterion", releaseDate: "2018",
                                    purchased: true, format: ReleaseFormat.bluRay.rawValue,
                                    regionLock: ReleaseRegionRules.regionA),
                ]
            },
            cells: [(.notes, PDFCell("Region B locked", fill: PDFPalette.green))]))

        // MARK: Digital version
        // Which cut the user's copy is, and which OTHER cuts their discs would give them.
        // Nothing else in the table reports either.

        // A theatrical copy prints NOTHING — it is the default every film is assumed to be
        // — and that suppresses the disc clause with it, however many cuts the disc holds.
        out.append(PDFExpectation(
            film: film("PDF Version Theatrical") {
                $0.digitalVersion = ViewingVersion.theatrical.rawValue
                $0.releases = [ReleaseSnapshot(
                    purchased: true, format: ReleaseFormat.bluRay.rawValue,
                    includedVersions: [ViewingVersion.theatrical.displayName,
                                       ViewingVersion.extended.displayName])]
            },
            cells: [(.notes, PDFCell("", fill: PDFPalette.green))]))

        // A non-theatrical copy names itself, lowercased by the list convention.
        out.append(PDFExpectation(
            film: film("PDF Version Extended Alone") {
                $0.digitalVersion = ViewingVersion.extended.rawValue
            },
            cells: [(.notes, PDFCell("\u{201C}Extended\u{201D} version"))]))

        // …and names what the disc adds, and on which format.
        out.append(PDFExpectation(
            film: film("PDF Version Extended Plus 2K") {
                $0.digitalVersion = ViewingVersion.extended.rawValue
                $0.releases = [ReleaseSnapshot(
                    purchased: true, format: ReleaseFormat.bluRay.rawValue,
                    includedVersions: [ViewingVersion.theatrical.displayName,
                                       ViewingVersion.extended.displayName])]
            },
            // The cut already named is not repeated.
            cells: [(.notes, PDFCell(
                "\u{201C}Extended\u{201D} version, also includes \u{201C}Theatrical\u{201D} version in 2K",
                fill: PDFPalette.green))]))

        // One cut on BOTH formats is one clause, not two.
        out.append(PDFExpectation(
            film: film("PDF Version Extended Plus Both") {
                $0.digitalVersion = ViewingVersion.extended.rawValue
                $0.releases = [
                    ReleaseSnapshot(purchased: true, format: ReleaseFormat.bluRay.rawValue,
                                    includedVersions: [ViewingVersion.theatrical.displayName]),
                    ReleaseSnapshot(purchased: true, format: ReleaseFormat.uhd4K.rawValue,
                                    includedVersions: [ViewingVersion.theatrical.displayName]),
                ]
            },
            cells: [(.notes, PDFCell(
                "\u{201C}Extended\u{201D} version, also includes \u{201C}Theatrical\u{201D} version in 2K and 4K",
                fill: PDFPalette.green))]))

        // Two cuts on the same disc share a clause and read in the app's own menu order.
        out.append(PDFExpectation(
            film: film("PDF Version Two Extras") {
                $0.digitalVersion = ViewingVersion.extended.rawValue
                $0.releases = [ReleaseSnapshot(
                    purchased: true, format: ReleaseFormat.uhd4K.rawValue,
                    includedVersions: [ViewingVersion.directorsCut.displayName,
                                       ViewingVersion.theatrical.displayName])]
            },
            // Plural, because the clause names two cuts.
            cells: [(.notes, PDFCell(
                "\u{201C}Extended\u{201D} version, also includes \u{201C}Theatrical\u{201D} and "
                    + "\u{201C}\(ViewingVersion.directorsCut.displayName)\u{201D} versions in 4K",
                fill: PDFPalette.green))]))

        // An UNPURCHASED disc's contents are not on the shelf and are not reported.
        out.append(PDFExpectation(
            film: film("PDF Version Unpurchased Disc") {
                $0.digitalVersion = ViewingVersion.extended.rawValue
                $0.releases = [ReleaseSnapshot(
                    format: ReleaseFormat.bluRay.rawValue,
                    includedVersions: [ViewingVersion.theatrical.displayName])]
            },
            cells: [(.notes, PDFCell("\u{201C}Extended\u{201D} version"))]))

        // The one version whose stored name ARRIVES quoted — "\"The Final Cut\"" — must
        // not end up nested inside a second pair.
        out.append(PDFExpectation(
            film: film("PDF Version Final Cut") {
                $0.digitalVersion = ViewingVersion.finalCut.rawValue
            },
            cells: [(.notes, PDFCell("\u{201C}The Final Cut\u{201D} version"))]))

        // A double dip whose cell ALSO carries a long authored note, so the full studio
        // names push it past the column and the short forms are used instead.
        out.append(PDFExpectation(
            film: film("PDF Notes Crowded Studios") {
                $0.notes = "A deliberately long authored note whose only job is to push "
                    + "this cell past the width of the Notes column so the studio names "
                    + "have to fall back to their abbreviated forms."
                $0.releases = [
                    ReleaseSnapshot(studio: "Lionsgate Films", releaseDate: "2011",
                                    purchased: true, format: ReleaseFormat.bluRay.rawValue),
                    ReleaseSnapshot(studio: "Shout Factory", releaseDate: "2018",
                                    purchased: true, format: ReleaseFormat.bluRay.rawValue),
                ]
            },
            cells: []))

        // Origin, as the demonym the RightSidebar prints.
        out.append(PDFExpectation(
            film: film("PDF Notes Import") {
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.bluRay.rawValue,
                                               nationalOrigin: "Germany")]
            },
            cells: [(.notes, PDFCell("German import", fill: PDFPalette.green))]))
        // A domestic release is not an import and says nothing.
        out.append(PDFExpectation(
            film: film("PDF Notes Domestic") {
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.bluRay.rawValue,
                                               nationalOrigin: "United States")]
            },
            cells: [(.notes, PDFCell("", fill: PDFPalette.green))]))

        out.append(PDFExpectation(
            film: film("PDF Notes Missing Artwork") {
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.bluRay.rawValue,
                                               hasArtwork: ReleaseArtwork.no)]
            },
            cells: [(.notes, PDFCell("Missing artwork", fill: PDFPalette.green))]))

        // MARK: Object-based formats reported into Notes
        out.append(PDFExpectation(
            film: film("PDF Notes Atmos") {
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.bluRay.rawValue,
                                               audioFormat: ReleaseAudioFormat.dolbyAtmos,
                                               audioChannels: ReleaseAudioChannels.surround71)]
            },
            // Case PRESERVED even in trailing position — "atmos" is not what it is called.
            cells: [(.notes, PDFCell("Atmos", fill: PDFPalette.green)),
                    (.audio2K, PDFCell("7.1", fill: PDFPalette.paleGreen))]))
        out.append(PDFExpectation(
            film: film("PDF Notes DTSX After Authored") {
                $0.notes = "Region B"
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.uhd4K.rawValue,
                                               audioFormat: ReleaseAudioFormat.dtsX,
                                               audioChannels: ReleaseAudioChannels.surround71,
                                               masterType: ReleaseMasterType.nativeFourK)]
            },
            cells: [(.notes, PDFCell("DTS:X, Region B", fill: PDFPalette.green))]))
        out.append(PDFExpectation(
            // The same format on both discs is reported once, not twice.
            film: film("PDF Notes Atmos Both Discs") {
                $0.releases = [
                    ReleaseSnapshot(purchased: true, format: ReleaseFormat.bluRay.rawValue,
                                    audioFormat: ReleaseAudioFormat.dolbyAtmos,
                                    audioChannels: ReleaseAudioChannels.surround71),
                    ReleaseSnapshot(purchased: true, format: ReleaseFormat.uhd4K.rawValue,
                                    audioFormat: ReleaseAudioFormat.dolbyAtmos,
                                    audioChannels: ReleaseAudioChannels.surround71,
                                    masterType: ReleaseMasterType.nativeFourK),
                ]
            },
            cells: [(.notes, PDFCell("Atmos", fill: PDFPalette.green))]))
        out.append(PDFExpectation(
            // Every derived class at once, in column order after the authored note.
            film: film("PDF Notes Everything") {
                $0.notes = "Import"
                $0.aspectRatio = "1.78:1 (Open matte)"
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.bluRay.rawValue,
                                               audioFormat: ReleaseAudioFormat.dtsX,
                                               audioChannels: ReleaseAudioChannels.surround71,
                                               hasArtwork: ReleaseArtwork.steelbook)]
            },
            cells: [(.notes, PDFCell("Steelbook, open matte, DTS:X, Import",
                                     fill: PDFPalette.green)),
                    (.aspect, PDFCell("1.78:1", fill: PDFPalette.veryDarkGreen))]))

        // MARK: Purchase history
        // Dated, priced, condition-tagged purchases across three years, so the per-year
        // purchase aggregation (`purchaseYearTable`, which the Purchases by Year chart draws)
        // has something to aggregate; the checks below read its rows directly.
        for (index, year) in ["2023", "2024", "2025"].enumerated() {
            for copy in 0..<3 {
                out.append(PDFExpectation(
                    film: film("PDF Purchase \(year)-\(copy)") {
                        $0.releases = [ReleaseSnapshot(
                            purchased: true, format: ReleaseFormat.bluRay.rawValue,
                            cost: Double(10 + copy * 10 + index),
                            purchaseDate: "\(year)-0\(copy + 1)-15",
                            condition: copy == 0 ? ReleaseCondition.used : ReleaseCondition.new)]
                    },
                    cells: []))
            }
        }

        // MARK: Audio label
        out.append(PDFExpectation(
            film: film("PDF Audio Mono") {
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.bluRay.rawValue,
                                               audioChannels: ReleaseAudioChannels.mono20)]
            },
            // Mono prints as a bare "2.0" like any other stereo-count track; the DARK
            // green is the only thing that reports the mix.
            cells: [(.audio2K, PDFCell("2.0", fill: PDFPalette.darkGreen))]))

        // A purchased disc whose channel field was never filled in. The cell must not
        // borrow the affirmative green a real discrete track earns — blank-over-green is
        // indistinguishable from a good track that simply printed nothing.
        out.append(PDFExpectation(
            film: film("PDF Audio Unrecorded") {
                $0.releases = [ReleaseSnapshot(purchased: true,
                                               format: ReleaseFormat.bluRay.rawValue,
                                               audioChannels: "")]
            },
            cells: [(.audio2K, PDFCell(""))]))

        return out
    }

    // MARK: - Fill Comparison

    @MainActor
    static func sameFill(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return l == r
        default: return false
        }
    }

    /// A palette shade's NAME, so a failure reads "expected green, got paleGreen" rather
    /// than printing two sets of near-identical component values.
    @MainActor
    static func fillName(_ color: NSColor?) -> String {
        guard let color else { return "no fill" }
        let named: [(String, NSColor)] = [
            ("green", PDFPalette.green), ("paleGreen", PDFPalette.paleGreen),
            ("darkGreen", PDFPalette.darkGreen), ("red", PDFPalette.red),
            ("lightGray", PDFPalette.lightGray), ("lightBlue", PDFPalette.lightBlue),
            ("purple", PDFPalette.purple), ("darkGold", PDFPalette.darkGold),
            ("seafoam", PDFPalette.seafoam), ("brown", PDFPalette.brown),
            ("veryDarkGold", PDFPalette.veryDarkGold),
            ("veryDarkGreen", PDFPalette.veryDarkGreen),
            ("veryDarkBlue", PDFPalette.veryDarkBlue),
            ("veryDarkPurple", PDFPalette.veryDarkPurple),
        ]
        return named.first { $0.1 == color }?.0 ?? "\(color)"
    }
}

#endif
