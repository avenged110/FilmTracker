// MARK: - DHPDFSections.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Harness scenario for the library PDF's two per-film detail sections:
// `-FTDebugHarness library-detail-sections`.
//
// WHAT THIS PROVES
//
// `ViewingHistoryPDFReport` and `DiscReleasesPDFReport` (85.30) both express a NESTED
// structure — a film, then its own detail rows — in a renderer that only draws a flat list.
// The nesting therefore lives entirely in how the rows are built: a film row filled edge to
// edge, detail rows with their two leading columns empty, and a strict count of detail rows
// per film. Every one of those is invisible to the compiler and every one of them still
// renders a perfectly clean-looking page when it is wrong. A film row that lost its fill, a
// release that emitted one row instead of two, or a detail row that drifted one column left
// all produce a document that opens fine and misattributes data.
//
// So the scenario drives the REAL section builders over a corpus shaped to land on every
// branch — both empty states of each section, a wishlist release, a combo pack, an
// unrecorded price — and asserts the row SHAPE (which rows exist, in what order, and which
// carry the band) as well as the cell text and fills. It then renders both sections through
// the REAL `PDFTableRenderer` and reopens the file with PDFKit, which is what catches a
// section that measures to zero pages or drops rows on the floor.
//
// The rendered document is left in the sandbox as `harness-scratch-detail-sections.pdf` so
// it can be opened and looked at.

#if DEBUG

import AppKit
import Foundation
import PDFKit

extension DebugHarness {

    // MARK: - Scenario

    @MainActor
    static func libraryDetailSectionsScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "library-detail-sections")

        checkPickerPlumbing(&r)
        checkTwoUpFlow(&r)
        checkColumnFit(&r)

        let corpus = detailSectionsCorpus()
        checkViewingHistorySection(&r, films: corpus)
        checkDiscReleasesSection(&r, films: corpus)
        await checkRendered(&r, films: corpus)

        return r
    }

    // MARK: - Timing

    /// Times each phase of a library-scale export, so a main-thread stall can be located
    /// rather than guessed at.
    ///
    /// The whole PDF stack runs on the MainActor, and the export's ONLY suspension points
    /// are the `Task.yield()`s the exporter places between phases. Any phase that runs long
    /// enough between two of them freezes the UI for that long — and past a couple of
    /// seconds macOS shows the spinning cursor. This reports every phase's wall time as a
    /// metric, and fails only on the one thing that is actually a bug: a single synchronous
    /// stretch long enough to trip that indicator.
    ///
    /// Sized to the real library as of when this was written — roughly 1,400 films, 1,600
    /// releases and 10,000 viewings — so the numbers mean something.
    @MainActor
    static func pdfTimingScenario() async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "pdf-timing")
        let clock = ContinuousClock()

        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }

        // Every film has a release; every second one has a second; every fifth is a combo
        // pack. Viewings average seven, which is where the sidebar's calendar tables sit.
        let films = (1...1400).map { index -> FilmSnapshot in
            var film = makeSnapshot(
                name: "Timing Probe \(Fmt.padded(index, 4))",
                releaseYear: "\(1950 + index % 70)",
                calendarTable: viewingDates(count: 3 + index % 9))
            film.watched = true
            film.notes = index % 7 == 0 ? "An authored note of ordinary length for this film." : ""
            var releases = [ReleaseSnapshot(
                studio: "Warner Bros.", releaseDate: "\(2010 + index % 14)", purchased: true,
                format: ReleaseFormat.bluRay.rawValue,
                includedVersions: ["Theatrical"], releaseAspectRatio: ["2.39:1"],
                audioFormat: ReleaseAudioFormat.dtsHDMA, audioChannels: ReleaseAudioChannels.surround51,
                regionLock: ReleaseRegionRules.regionA, cost: 24.99, amountSpent: 19.99,
                purchaseDate: "2024.03.02", condition: "new")]
            if index % 2 == 0 {
                releases.append(ReleaseSnapshot(
                    studio: "Criterion", releaseDate: "\(2015 + index % 9)", wishlist: 1,
                    format: ReleaseFormat.uhd4K.rawValue, lowestPrice: 29.99,
                    lowestPriceDate: "2024.11.20"))
            }
            if index % 5 == 0 {
                let parent = UUID()
                releases.append(ReleaseSnapshot(
                    id: parent, studio: "Arrow Video", releaseDate: "2022", purchased: true,
                    format: ReleaseFormat.uhd4K.rawValue, independence: ReleaseIndependence.comboPack,
                    hasHDR: "HDR10", masterType: ReleaseMasterType.nativeFourK,
                    cost: 39.99, amountSpent: 34.99, purchaseDate: "2025.01.15", condition: "new"))
                releases.append(ReleaseSnapshot(
                    studio: "Arrow Video", releaseDate: "2022", purchased: true,
                    format: ReleaseFormat.bluRay.rawValue, independence: ReleaseIndependence.comboPack,
                    regionLock: ReleaseRegionRules.regionA, condition: "new",
                    parentReleaseID: parent))
            }
            film.releases = releases
            return film
        }
        r.metric("corpus/films", Double(films.count), "films")
        r.metric("corpus/releases", Double(films.reduce(0) { $0 + $1.releases.count }), "releases")
        r.metric("corpus/viewings", Double(films.reduce(0) { $0 + $1.calendarTable.count }), "viewings")

        let geometry = LibraryTableLayout.standard.geometry
        var longest: (phase: String, ms: Double) = ("", 0)
        // The longest gap between two suspensions during a cooperative draw — the stretch
        // the run loop actually experiences, and the number that decides whether the
        // system's spinning cursor appears.
        var longestStretch: Double = 0
        func timed<T>(_ phase: String, _ work: () -> T) -> T {
            let start = clock.now
            let value = work()
            let elapsed = ms(clock.now - start)
            r.metric("phase/\(phase)", elapsed, "ms")
            if elapsed > longest.ms { longest = (phase, elapsed) }
            return value
        }

        // MARK: Build
        let library = timed("build/complete-library") {
            LibraryPDFReport.section(films: films, layout: .standard)
        }
        let history = timed("build/viewing-history") { ViewingHistoryPDFReport.section(films: films) }
        let discs = timed("build/disc-releases") { DiscReleasesPDFReport.section(films: films) }
        r.metric("rows/complete-library", Double(library.rows.count), "rows")
        r.metric("rows/viewing-history", Double(history.rows.count), "rows")
        r.metric("rows/disc-releases", Double(discs.rows.count), "rows")

        // MARK: Measure
        let libraryMetrics = timed("measure/complete-library") {
            PDFTableRenderer.metrics(of: library, geometry: geometry)
        }
        let historyMetrics = timed("measure/viewing-history") {
            PDFTableRenderer.metrics(of: history, geometry: geometry)
        }
        let discMetrics = timed("measure/disc-releases") {
            PDFTableRenderer.metrics(of: discs, geometry: geometry)
        }
        r.metric("pages/complete-library", Double(libraryMetrics.pageCount), "pages")
        r.metric("pages/viewing-history", Double(historyMetrics.pageCount), "pages")
        r.metric("pages/disc-releases", Double(discMetrics.pageCount), "pages")

        // MARK: Draw
        let url = scratchURL("timing.pdf")
        try? FileManager.default.removeItem(at: url)
        var mediaBox = CGRect(origin: .zero, size: geometry.pageSize)
        if let consumer = CGDataConsumer(url: url as CFURL),
           let context = unsafe CGContext(consumer: consumer, mediaBox: &mediaBox, nil) {
            // Drawn through the cooperative path, so these phases now report WALL time
            // across their yields rather than one synchronous stretch — which is the point.
            // The longest single stretch between yields is what `longest-stretch` records.
            for (name, section, metrics) in [("complete-library", library, libraryMetrics),
                                             ("viewing-history", history, historyMetrics),
                                             ("disc-releases", discs, discMetrics)] {
                let start = clock.now
                try? await PDFTableRenderer.render(
                    section, into: context, geometry: geometry, metrics: metrics,
                    footer: { p, t in .single(page: p, total: t) })
                r.metric("phase/draw/\(name)", ms(clock.now - start), "ms")
            }
            context.closePDF()
        }

        // MARK: The whole thing, as the exporter runs it
        // `finish()` measures every sheet and draws every page in one call. Whatever the
        // phases above cost individually, THIS is the stretch the run loop actually sees.
        let wholeURL = scratchURL("timing-whole.pdf")
        try? FileManager.default.removeItem(at: wholeURL)
        if let consumer = CGDataConsumer(url: wholeURL as CFURL),
           let context = unsafe CGContext(consumer: consumer, mediaBox: &mediaBox, nil) {
            let builder = PDFDocumentBuilder(context: context)
            builder.add(library, geometry: geometry)
            builder.add(history, geometry: geometry)
            builder.add(discs, geometry: geometry)
            // A heartbeat on the same actor, asking to wake every few milliseconds. When
            // the export is between suspensions the main actor is busy and the wake is
            // delayed; the longest delay is exactly the longest stretch the run loop —
            // and therefore the user — went without a turn. This measures what the system
            // sees, not what the code intended.
            let gaps = HeartbeatGaps()
            let heartbeat = Task { @MainActor in
                var last = clock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(5))
                    let now = clock.now
                    gaps.record(ms(now - last))
                    last = now
                }
            }
            let start = clock.now
            let pages = (try? await builder.finish()) ?? 0
            let elapsed = ms(clock.now - start)
            heartbeat.cancel()
            longestStretch = max(longestStretch, gaps.longest)
            r.metric("finish/whole-document", elapsed, "ms")
            r.metric("finish/pages", Double(pages), "pages")
            r.metric("finish/longest-run-loop-gap", gaps.longest, "ms")
        }

        r.metric("longest-build-phase", longest.ms, "ms")
        r.metric("longest-stretch-between-yields", longestStretch, "ms")
        // The thing that is actually a bug. macOS shows the spinning cursor after the main
        // thread has been unresponsive for on the order of a second; a stretch a quarter of
        // that leaves ample margin for a slower machine and a larger library. The section
        // BUILD phases are not held to this — they run between the exporter's own yields
        // and are a fraction of the draw — but are reported above so a regression there is
        // visible too.
        r.check("no-stretch-long-enough-to-hang",
                longestStretch < 250,
                "longest stretch between yields during the draw: "
                    + "\(Fmt.fixed(longestStretch, 0))ms")
        r.check("timings-recorded", true, "longest build phase: \(longest.phase) at "
                    + "\(Fmt.fixed(longest.ms, 0))ms")
        return r
    }

    /// A mutable box the heartbeat task writes into. A class rather than a captured `var`
    /// because the task and the scenario both touch it from the MainActor and Swift's
    /// capture rules for an `inout`-adjacent local are stricter than the situation needs.
    @MainActor
    private final class HeartbeatGaps {
        private(set) var longest: Double = 0
        func record(_ gap: Double) { longest = max(longest, gap) }
    }

    // MARK: - Export Tab Plumbing

    /// The Export tab's "Include:" picker is a `ForEach` over `LibraryPDFSection.allCases`
    /// labeled by `displayName`, so a section reaches the user only if it is a case AND
    /// names itself. Neither is something the compiler checks — a case whose `displayName`
    /// fell through to the `reportsCategory?.displayName ?? ""` default would appear in the
    /// menu as a blank, selectable row.
    ///
    /// The ORDER matters too, and for a second reason: `LibraryPDFExporter.export` filters
    /// `allCases` rather than iterating the caller's set, so this list is also the order the
    /// sheets are bound into the document.
    @MainActor
    private static func checkPickerPlumbing(_ r: inout HarnessScenarioResult) {
        let names = LibraryPDFSection.allCases.map(\.displayName)
        r.check("picker-leading-three",
                Array(names.prefix(3)) == ["Complete Library",
                                           ViewingHistoryPDFReport.sectionTitle,
                                           DiscReleasesPDFReport.sectionTitle],
                "the picker's first three rows are \(names.prefix(3))")
        r.check("picker-no-blank-rows", names.allSatisfy { !$0.isEmpty },
                "a section would appear in the picker as a blank row: \(names)")

        // The two per-film detail sections belong to no ReportsView tab; reporting one
        // would send the exporter down the report-sheet path and draw the wrong table.
        r.check("picker-detail-sections-uncategorized",
                LibraryPDFSection.viewingHistory.reportsCategory == nil
                    && LibraryPDFSection.discReleases.reportsCategory == nil,
                "a detail section claims a ReportsView category")
    }

    // MARK: - Column Fit

    /// Guards the widths in both sections, which are sized to their longest expected value
    /// and are therefore only correct until someone edits one.
    ///
    /// A column that comes up half a point short does not truncate or error — it silently
    /// WRAPS, which grows the height of every row it lands on, and in a header band whose
    /// height is fixed it overflows into the rows above and below instead. Neither failure
    /// looks like a failure; both just make the page slightly wrong forever. The same guard
    /// the complete-library table carries, applied to the two sections that now sit beside
    /// it.
    @MainActor
    private static func checkColumnFit(_ r: inout HarnessScenarioResult) {
        let geometry = LibraryTableLayout.standard.geometry
        let headerFont = PDFFonts.font(size: geometry.headerFontSize, weight: .bold)
        let bodyFont = PDFFonts.font(size: geometry.fontSize, weight: .semibold)

        /// True when `text` occupies exactly one line in a cell `width` points wide.
        func fits(_ text: String, width: CGFloat, font: NSFont) -> Bool {
            let available = width - (geometry.cellPaddingX * 2)
            guard available > 0 else { return false }
            let wrapped = PDFDrawing.textHeight(text, width: available, font: font,
                                                lineSpacing: geometry.lineSpacing)
            let single = PDFDrawing.singleLineHeight(text, font: font,
                                                     lineSpacing: geometry.lineSpacing)
            return wrapped <= single + 0.5
        }

        /// Every header label in `section` — the column titles on the lower row, and the
        /// group titles on the upper row across whatever span each covers.
        func headerOverflows(_ section: PDFTableSection) -> [String] {
            var bad = section.columns.filter { !fits($0.title, width: $0.width, font: headerFont) }
                .map(\.title)
            for group in section.headerGroups {
                let span = section.columns[group.columns].reduce(CGFloat(0)) { $0 + $1.width }
                if !fits(group.title, width: span, font: headerFont) { bad.append(group.title) }
            }
            return bad
        }

        let history = ViewingHistoryPDFReport.section(films: [])
        let releases = DiscReleasesPDFReport.section(films: [])

        // A paired header's two words each get HALF the cell — see `PDFPairedText` — so
        // they are measured against that half rather than against the whole column.
        if let paired = releases.columns[11].pairedTitle {
            r.check("fit-paired-header",
                    fits(paired.leading, width: releases.columns[11].width / 2, font: headerFont)
                        && fits(paired.trailing, width: releases.columns[11].width / 2,
                                font: headerFont),
                    "'\(paired.plain)' does not fit as a balanced pair in a "
                        + "\(releases.columns[11].width)pt column")
        }

        r.check("fit-history-headers", headerOverflows(history).isEmpty,
                "wrapping in the Viewing History header band: \(headerOverflows(history))")
        r.check("fit-releases-headers", headerOverflows(releases).isEmpty,
                "wrapping in the Disc-based Releases header band: \(headerOverflows(releases))")

        // The longest date the Viewing Date column can ever be asked to print. September is
        // the longest month name, 30 the widest two-digit day at these figures, and 2044 a
        // year of four wide digits. The column was first sized against a middling example
        // and left the real worst case wrapping.
        r.check("fit-longest-viewing-date",
                fits("September 30, 2044", width: history.columns[4].width, font: bodyFont),
                "'September 30, 2044' wraps in a \(history.columns[4].width)pt Viewing Date column")

        // Four figures, in the fixed-width face both sections number their films in. A
        // wrapped index would grow the height of every row it landed on.
        let indexFont = PDFFonts.monospacedFont(size: geometry.fontSize, weight: .semibold)
        r.check("fit-four-figure-index",
                fits("4444", width: PDFColumnWidth.index, font: indexFont),
                "a four-figure index wraps in a \(PDFColumnWidth.index)pt column")

        // The widest strings the two reshuffled release columns can hold.
        // The widest VIDEO string, which is what the column is now sized by — every point
        // above it went to Notes.
        r.check("fit-widest-video",
                fits("HEVC (Upscaled), Dolby Vision", width: releases.columns[6].width,
                     font: bodyFont),
                "the widest video string wraps in a \(releases.columns[6].width)pt column")
        r.check("fit-widest-audio",
                fits("Dolby Digital 2.0 Mono", width: releases.columns[10].width, font: bodyFont),
                "the widest audio string wraps in a \(releases.columns[10].width)pt column")
        r.check("fit-abbreviated-last-seen",
                fits("Last seen: Sep 30, 2044", width: releases.columns[12].width, font: bodyFont),
                "the longest de-emphasized date wraps in a \(releases.columns[12].width)pt column")
        r.check("fit-region-abbreviation",
                fits("\(ReleaseRegionRules.regionB) (LL)", width: releases.columns[5].width,
                     font: bodyFont),
                "the abbreviated loosely-locked tag wraps in a "
                    + "\(releases.columns[5].width)pt column")
        // The Status column is merged down a release's pair, so a wrapped value is not a
        // fit failure so much as a legibility one — and it is the film band's own summary
        // that shares the column, not either of the release fields.
        r.check("fit-not-purchased",
                fits("Not purchased", width: releases.columns[2].width, font: bodyFont),
                "'Not purchased' wraps in a \(releases.columns[2].width)pt Status column")
        // Sized for three ratios and an ellipsis, past which the cell truncates.
        // Measured against the SPAN the value covers, not one of the two columns it is
        // built from — neither is a field on its own. See the column map in `Width`.
        let aspectSpan = releases.columns[7].width + releases.columns[8].width
        r.check("fit-three-aspect-ratios",
                fits("4.44:4, 4.44:4, 4.44:4", width: aspectSpan, font: bodyFont),
                "three aspect ratios do not fit a \(aspectSpan)pt span")
        // Likewise the two bottom-row fields, each of which spans two columns.
        let versionsSpan = releases.columns[6].width + releases.columns[7].width
        r.check("fit-versions-span-restored", versionsSpan == 120,
                "Versions Included spans \(versionsSpan)pt, not the 120pt it had")
        let packagingSpan = releases.columns[8].width + releases.columns[9].width
        r.check("fit-packaging-span-restored", packagingSpan == 103,
                "Packaging spans \(packagingSpan)pt, not the 103pt it had")
        // The longest format label, plus the indent that steps it under its film's title.
        r.check("fit-longest-format-label",
                fits("Blu-ray (included in combo-pack)",
                     width: releases.columns[1].width - 5, font: bodyFont),
                "the bundled-Blu-ray label does not fit a "
                    + "\(releases.columns[1].width)pt Title / Release column")
    }

    // MARK: - Two-Up Flow

    /// Drives `PDFTableRenderer`'s multi-pane pagination directly, over a section long
    /// enough to fill several panes.
    ///
    /// The section checks above work on row ARRAYS and so cannot see the flow at all — a
    /// `columnsPerPage` the renderer quietly ignored would leave every one of them passing
    /// while the document came out exactly as it had before. What has to hold is the
    /// reading order, and it is the same order a newspaper column has: down the first pane,
    /// then down the second, then over to a new page. Anything else makes a numbered index
    /// jump around the page.
    @MainActor
    private static func checkTwoUpFlow(_ r: inout HarnessScenarioResult) {
        let geometry = LibraryTableLayout.standard.geometry
        let rows = (1...400).map { [PDFCell("\($0)"), PDFCell("row \($0)")] }
        let section = PDFTableSection(
            title: "Flow Probe",
            columns: [PDFTableColumn("#", width: 1), PDFTableColumn("Value", width: 4)],
            columnsPerPage: 2,
            rows: rows)

        let metrics = PDFTableRenderer.metrics(of: section, geometry: geometry)
        let places = metrics.placements

        r.check("flow-placement-count", places.count == rows.count,
                "\(places.count) placements for \(rows.count) rows")
        guard places.count == rows.count else { return }

        // Reading order: (page, pane, y) never goes backwards.
        let monotonic = zip(places, places.dropFirst()).allSatisfy { previous, next in
            (previous.page, previous.pane, previous.y) < (next.page, next.pane, next.y)
        }
        r.check("flow-reading-order", monotonic,
                "a row is placed above or before the row that precedes it")

        // Both panes are actually used, and no third one is invented.
        let panes = Set(places.map(\.pane))
        r.check("flow-uses-both-panes", panes == [0, 1],
                "panes used: \(panes.sorted())")

        // Two-up must genuinely halve the page count against the same rows drawn full
        // width — that is the entire point of the layout, and the one claim a caller makes
        // by setting `columnsPerPage`.
        var singleUp = section
        singleUp.columnsPerPage = 1
        let singlePages = PDFTableRenderer.pageCount(of: singleUp, geometry: geometry)
        r.check("flow-halves-page-count",
                metrics.pageCount <= (singlePages + 1) / 2 && metrics.pageCount > 0,
                "\(metrics.pageCount) pages two-up against \(singlePages) full width")

        // Every pane starts below the title band and the header band, and no row is placed
        // into the footer's reserve.
        let top = geometry.margin + geometry.titleHeight + geometry.headerRowHeight
        let floor = geometry.pageSize.height - geometry.margin - geometry.footerReserve
        r.check("flow-within-page",
                places.allSatisfy { $0.y >= top - 0.001 && $0.y < floor },
                "a row is placed outside the page's content band")

        // MARK: Spans are never split
        // A merged cell with half its rows on one pane and half on the next is not
        // something a reader can interpret, so the flow treats the run as atomic.
        let paired = PDFTableSection(
            title: "Span Probe",
            columns: [PDFTableColumn("#", width: 1), PDFTableColumn("Value", width: 4)],
            columnsPerPage: 2,
            rows: (1...400).flatMap { index in
                [[PDFCell("\(index)", rowSpan: 2), PDFCell("first")],
                 [PDFCell(""), PDFCell("second")]]
            })
        let spanPlaces = PDFTableRenderer.metrics(of: paired, geometry: geometry).placements
        let split = stride(from: 0, to: spanPlaces.count - 1, by: 2).filter { index in
            spanPlaces[index].page != spanPlaces[index + 1].page
                || spanPlaces[index].pane != spanPlaces[index + 1].pane
        }
        r.check("flow-spans-unbroken", split.isEmpty,
                split.isEmpty ? "no merged pair was split across a pane or page"
                              : "\(split.count) merged pair(s) split at rows \(split.prefix(3))")
    }

    // MARK: - Viewing History

    @MainActor
    private static func checkViewingHistorySection(_ r: inout HarnessScenarioResult,
                                                   films: [FilmSnapshot]) {
        let section = ViewingHistoryPDFReport.section(films: films)

        r.check("vh-columns",
                section.columns.map(\.title)
                    == ["#", "Title", "Year", "Viewings", "Viewing Date", "Since Prior",
                        "Version"],
                "columns are \(section.columns.map(\.title))")
        r.check("vh-title", section.title == "Viewing History",
                "section title is '\(section.title)'")
        r.check("vh-two-up", section.columnsPerPage == 2,
                "the section declares \(section.columnsPerPage) pane(s) per page")

        // The index column is the SAME width as the complete-library table's. All three
        // per-film sections number the same films, and a reader moving between them must
        // meet the same column in the same place — which only holds because each section's
        // weights sum to its own content width. Asserted here because that is a convention,
        // not something the type system can enforce.
        r.check("vh-shared-index-width",
                section.columns[0].width == PDFColumnWidth.index
                    && LibraryTableLayout.standard.index == PDFColumnWidth.index,
                "index widths are \(section.columns[0].width) here against "
                    + "\(LibraryTableLayout.standard.index) in the library table")
        r.check("vh-widths-sum-to-pane",
                abs(section.columns.reduce(0) { $0 + $1.width }
                    - (LibraryTableLayout.standard.geometry.contentWidth
                       - LibraryTableLayout.standard.geometry.paneGutter) / 2) < 0.5,
                "column weights sum to \(section.columns.reduce(0) { $0 + $1.width }), which "
                    + "is not this section's pane width — the shared index width is then a "
                    + "different size here than elsewhere")

        // The dates are a column the eye runs down, so the VALUES are right-aligned; the
        // label is not, because a short header pinned to the right of its column reads as
        // though it belonged to the column beside it.
        let dateColumn = section.columns[4]
        r.check("vh-date-alignment",
                dateColumn.alignment == .right && dateColumn.resolvedHeaderAlignment == .center,
                "Viewing Date is \(dateColumn.alignment.rawValue) with a "
                    + "\(dateColumn.resolvedHeaderAlignment.rawValue) header")

        // Film order is the complete-library table's, so a reader carries a film's position
        // between sections. Asserted against the shared helper rather than against a
        // hand-written expectation, which would pass even if BOTH had drifted.
        let expectedOrder = LibraryPDFReport.ordered(films).map(\.name)
        let bandedTitles = section.rows.filter { $0[0].text != "" }.map { $0[1].text }
        r.check("vh-film-order", bandedTitles == expectedOrder,
                "film rows are \(bandedTitles)")

        // Every film row is filled ACROSS — the band is the only thing separating one
        // film's viewings from the next film's.
        let bands = section.rows.filter { $0[0].text != "" }
        r.check("vh-film-band",
                bands.allSatisfy { row in row.allSatisfy { sameFill($0.fill, PDFPalette.lightGray) } },
                "a film row is not filled across all seven columns")

        // …and the band has no internal vertical rules, so it reads as one block rather
        // than as a row of mostly-empty cells. The index keeps all four of its edges: it is
        // a value in its own column, and the rule after it separates the number from the
        // heading it labels.
        r.check("vh-band-is-one-block",
                bands.allSatisfy { row in
                    row[0].borders == .all
                        && row.dropFirst().dropLast().allSatisfy { $0.borders == [.top, .bottom] }
                        && row.last?.borders == [.top, .bottom, .right]
                },
                "a film band still carries internal column rules")

        // …and no detail row is, which is what keeps the bands readable as bands.
        let detailsUnbanded = section.rows
            .filter { $0[0].text == "" }
            .allSatisfy { row in row.allSatisfy { $0.fill == nil } }
        r.check("vh-detail-unbanded", detailsUnbanded,
                "a viewing row carries a fill; only film rows may")

        // The release year identifies the film and so appears on the FILM row only — a
        // year repeated beside every viewing would read as the year of that viewing.
        let yearsOnBands = section.rows.filter { $0[0].text != "" }.map { $0[2].text }
        r.check("vh-film-year", yearsOnBands.allSatisfy { $0 == "2000" },
                "film rows carry years \(yearsOnBands)")
        r.check("vh-no-year-on-details",
                section.rows.filter { $0[0].text == "" }.allSatisfy { $0[2].text.isEmpty },
                "a viewing row carries a release year")

        // MARK: Row shape
        // One film row plus one row per parsed viewing, in that order.
        guard let watched = filmBlock(in: section, title: "PDF VH Watched") else {
            r.check("vh-watched-present", false, "no block for the multi-viewing film")
            return
        }
        r.check("vh-watched-count", watched.film[3].text == "3",
                "viewing count reads '\(watched.film[3].text)'")
        r.check("vh-watched-rows", watched.details.count == 3,
                "expected 3 viewing rows, got \(watched.details.count)")

        // The four columns that describe the FILM — index, title, year, viewing count —
        // are one OPEN field beneath its band, not four unruled columns: the only verticals
        // left are the table's own left edge and the rule that opens the Viewing Date
        // column. A film does not change between two of its own viewings, and nothing in
        // this region carries a value, so every rule inside it divides nothing.
        let expected: [PDFCellBorders] = [.left, [], [], .right]
        let openField = watched.details.enumerated().allSatisfy { offset, row in
            let closing = offset == watched.details.count - 1
            return (0..<4).allSatisfy { column in
                row[column].borders == (closing ? expected[column].union(.bottom)
                                                : expected[column])
            }
        }
        r.check("vh-film-region-open", openField,
                "the region under a film band still carries rules: "
                    + "\(watched.details.map { row in (0..<4).map { row[$0].borders.rawValue } })")

        // The viewing columns are NOT merged — each viewing is its own record and must be
        // ruled off from the next.
        r.check("vh-viewing-columns-ruled",
                watched.details.allSatisfy { row in
                    row[4].borders == .all && row[5].borders == .all && row[6].borders == .all
                },
                "a viewing's own columns lost their rules")

        // Newest first, and the "since prior" gaps measured against the NEXT-OLDER
        // viewing — both inherited from `viewingHistoryEntries`, which the sidebar's own
        // table calls. 2026.03.01 → 2026.02.01 is 28 days; 2026.02.01 → 2026.01.01 is 31.
        let dates = watched.details.map { $0[4].text }
        r.check("vh-newest-first",
                dates == ["March 1, 2026", "February 1, 2026", "January 1, 2026"],
                "viewing dates are \(dates)")
        let gaps = watched.details.map { $0[5].text }
        r.check("vh-since-prior", gaps == ["28 days", "31 days", "\u{2013}"],
                "since-prior column is \(gaps)")

        // The version code rides on the stored entry and is read with the same call the
        // sidebar's detailed table uses; an entry with no code prints the placeholder.
        // Compared against `ViewingVersion`'s OWN display names rather than against typed
        // literals — the apostrophe in "Director's Cut" is a punctuation choice this file
        // must not get a second vote on.
        let versions = watched.details.map { $0[6].text }
        r.check("vh-versions",
                versions == [ViewingVersion.theatrical.displayName,
                             "\u{2013}",
                             ViewingVersion.directorsCut.displayName],
                "version column is \(versions)")

        // MARK: The two empty states
        // "Unwatched" and "No viewing history" are DIFFERENT facts and the section must
        // not collapse them: the first says the user has never watched the film, the
        // second that they have but did not record when.
        if let unwatched = filmBlock(in: section, title: "PDF VH Unwatched") {
            r.check("vh-unwatched-text", unwatched.film[3].text == "Unwatched",
                    "reads '\(unwatched.film[3].text)'")
            r.check("vh-unwatched-rows", unwatched.details.isEmpty,
                    "an unwatched film emitted \(unwatched.details.count) viewing rows")
        } else {
            r.check("vh-unwatched-present", false, "no block for the unwatched film")
        }

        if let unrecorded = filmBlock(in: section, title: "PDF VH No History") {
            r.check("vh-no-history-text", unrecorded.film[3].text == "No viewing history",
                    "reads '\(unrecorded.film[3].text)'")
        } else {
            r.check("vh-no-history-present", false, "no block for the watched-but-undated film")
        }
    }

    // MARK: - Disc-based Releases

    @MainActor
    private static func checkDiscReleasesSection(_ r: inout HarnessScenarioResult,
                                                 films: [FilmSnapshot]) {
        let section = DiscReleasesPDFReport.section(films: films)

        // The header band is TWO rows that mirror a release's two rows: the group titles
        // are the upper row and the column titles the lower one. That mirroring is the
        // whole reason the body cells carry no inline labels, so it is asserted rather than
        // left to the eye.
        r.check("dr-header-lower-row",
                section.columns.map(\.title)
                    == ["#", "Title / Release", "Status", "Condition", "Provenance",
                        "Region Lock", "Versions Included", "", "Packaging", "", "Audio",
                        "Cost / Spent", "Date of Purchase"],
                "lower header row is \(section.columns.map(\.title))")
        r.check("dr-header-upper-row",
                section.headerGroups.map(\.title)
                    == ["Release Date", "Studio", "Video", "Aspect Ratio", "Notes"],
                "upper header row is \(section.headerGroups.map(\.title))")
        // Studio banners the Provenance/Region Lock pair; Aspect Ratio and Notes each
        // banner the columns their own row spans. The region after Studio is four columns
        // that are NOT fields — the two body rows divide it at different points, and every
        // field there is a span over one or two of them.
        r.check("dr-header-group-spans",
                section.headerGroups.map(\.columns) == [3..<4, 4..<6, 6..<7, 7..<9, 9..<13],
                "header groups span \(section.headerGroups.map(\.columns))")
        // Both bottom-row labels straddle a boundary the top row draws, so each is merged
        // across two header cells by dropping the rule between them — and the rule BETWEEN
        // the two labels survives, or they would read as one field.
        r.check("dr-bottom-headers-merged",
                section.columns[6].headerBorders == [.top, .bottom, .left]
                    && section.columns[7].headerBorders == [.top, .bottom, .right]
                    && section.columns[8].headerBorders == [.top, .bottom, .left]
                    && section.columns[9].headerBorders == [.top, .bottom, .right],
                "the bottom header row is divided at the top row's boundaries")

        // The four banners over left-aligned values are left-aligned too, so each label
        // starts where the field it names starts.
        r.check("dr-banner-alignment",
                section.headerGroups.map(\.alignment) == [.center, .left, .left, .left, .left],
                "banner alignments are \(section.headerGroups.map { $0.alignment.rawValue })")

        // Provenance is centered like the tag columns around it; Date of Purchase is
        // right-aligned so the dates line up on their year down the page.
        r.check("dr-column-alignment",
                section.columns[4].alignment == .center
                    && section.columns[12].alignment == .right,
                "Provenance is \(section.columns[4].alignment.rawValue), Date of Purchase "
                    + "is \(section.columns[12].alignment.rawValue)")

        // The money header sits on the same axis as the values beneath it, which is the
        // point of pairing it — one vertical rule of slashes from the header down.
        r.check("dr-paired-header",
                section.columns[11].pairedTitle?.plain == "Cost / Spent",
                "the money header is not a balanced pair")

        // Full release dates print as "yyyy.MM.dd", the film's own date too; a year-only
        // release keeps its bare year.
        let dated = makeSnapshot(name: "PDF Dated Film", releaseYear: "2014", releaseDate: "2014-05-02",
                                 releases: [
                                    ReleaseSnapshot(releaseDate: "2016.03.01", baseReleaseYear: "1977",
                                                    purchased: true, format: "Blu-ray"),
                                    ReleaseSnapshot(releaseDate: "2018", format: "Blu-ray"),
                                    ReleaseSnapshot(releaseDate: "2019.11.05", format: "DVD")])
        let datedSection = DiscReleasesPDFReport.section(films: [dated])
        let datedRows = datedSection.rows
        r.check("dr-film-full-date", datedRows.first?[3].text == "2014.05.02",
                "film band reads '\(datedRows.first?[3].text ?? "")'")
        // Each release is a specification row then a provenance row; the date is on the first.
        let specRows = Array(datedRows.dropFirst()).enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let datedYears = Set(specRows.map { $0[3].text })
        r.check("dr-release-dates", datedYears == ["2016.03.01 (1977)", "2018", "2019.11.05"],
                "release date cells read \(datedYears)")
        // The two widths this column pair was resized to: "Not purchased" and the widest
        // date each on one line inside the standard padding.
        let geometry = PDFPageGeometry.landscapeLetter
        let face = PDFFonts.font(size: geometry.fontSize, weight: .semibold)
        func fits(_ text: String, column: Int) -> Bool {
            (text as NSString).size(withAttributes: [.font: face]).width
                <= section.columns[column].width - geometry.cellPaddingX * 2
        }
        r.check("dr-status-fits", fits("Not purchased", column: 2), "'Not purchased' wraps")
        r.check("dr-release-date-fits", fits("2016.03.01 (1977)", column: 3), "the widest date wraps")
        r.check("dr-widths-sum", abs(section.columns.reduce(0) { $0 + $1.width } - 720) < 0.001,
                "column widths sum to \(section.columns.reduce(0) { $0 + $1.width })")

        r.check("dr-single-pane", section.columnsPerPage == 1,
                "this section has an elastic Notes column and must stay full width")

        // The shared index width, and the convention that makes it shared — see the same
        // pair of checks on the Viewing History section.
        r.check("dr-shared-index-width",
                section.columns[0].width == PDFColumnWidth.index,
                "index width is \(section.columns[0].width) against "
                    + "\(PDFColumnWidth.index)")
        r.check("dr-widths-sum-to-content",
                abs(section.columns.reduce(0) { $0 + $1.width }
                    - LibraryTableLayout.standard.geometry.contentWidth) < 0.5,
                "column weights sum to \(section.columns.reduce(0) { $0 + $1.width }) against "
                    + "a \(LibraryTableLayout.standard.geometry.contentWidth)pt content width")

        let expectedOrder = LibraryPDFReport.ordered(films).map(\.name)
        let bands = section.rows.filter { $0[0].text != "" }
        r.check("dr-film-order", bands.map { $0[1].text } == expectedOrder,
                "film rows are \(bands.map { $0[1].text })")

        // The band is one block from the title to the last column — no internal rules.
        r.check("dr-band-is-one-block",
                bands.allSatisfy { row in
                    row[0].borders == .all
                        && row.dropFirst().dropLast().allSatisfy { $0.borders == [.top, .bottom] }
                        && row.last?.borders == [.top, .bottom, .right]
                },
                "a film band still carries internal column rules")

        // The film's own release year prints in the same column its releases print theirs
        // in — a release's "2016 (1977)" carries this very figure in the parentheses.
        r.check("dr-film-year", bands.allSatisfy { $0[3].text == "2000" },
                "film rows carry years \(bands.map { $0[3].text })")

        // MARK: Empty state
        if let none = filmBlock(in: section, title: "PDF VH Unwatched") {
            r.check("dr-no-releases-text", none.film[2].text == "No releases",
                    "reads '\(none.film[2].text)'")
            r.check("dr-no-releases-rows", none.details.isEmpty,
                    "a film with no releases emitted \(none.details.count) detail rows")
        } else {
            r.check("dr-no-releases-present", false, "no block for the film with no releases")
        }

        // MARK: Two rows per release, in hierarchy order
        guard let combo = filmBlock(in: section, title: "PDF DR Combo") else {
            r.check("dr-combo-present", false, "no block for the combo-pack film")
            return
        }
        // One purchase, one box: the pair counts ONCE.
        r.check("dr-combo-summary", combo.film[2].text == "1 release",
                "reads '\(combo.film[2].text)'")
        r.check("dr-combo-rows", combo.details.count == 4,
                "expected 2 releases x 2 rows, got \(combo.details.count)")

        guard combo.details.count == 4 else { return }

        let spec = combo.details[0]
        let prov = combo.details[1]

        // MARK: Merges — the combo-pack record
        // The pair is one purchase, so the fields that describe the PURCHASE rather than
        // the disc are drawn once and merged down: Status across all four rows, Studio
        // across three (leaving the child's provenance row for Provenance and Region Lock),
        // and the parent's Year across its two (displacing its Condition, which the child
        // reports). Studio, packaging and notes still describe the sub-columns beneath or
        // beside them and merge across.
        let childSpec = combo.details[2]
        let childProv = combo.details[3]
        r.check("dr-merges",
                spec[1].rowSpan == 2                       // format, parent
                    && spec[2].rowSpan == 4                // status, the whole pair
                    && spec[3].rowSpan == 2                // parent's year
                    && spec[4].rowSpan == 3 && spec[4].columnSpan == 2   // studio
                    && spec[7].columnSpan == 2             // aspect ratio
                    && spec[9].columnSpan == 4             // notes
                    && prov[6].columnSpan == 2             // versions included
                    && prov[8].columnSpan == 2             // packaging
                    && childSpec[1].rowSpan == 2,          // format, child
                "spans are status=\(spec[2].rowSpan)x, year=\(spec[3].rowSpan)x, "
                    + "studio=\(spec[4].rowSpan)x\(spec[4].columnSpan), "
                    + "aspect=x\(spec[7].columnSpan), notes=x\(spec[9].columnSpan)")
        r.check("dr-merge-placeholders",
                spec.count == 13 && prov.count == 13
                    && [5, 8, 10, 11, 12].allSatisfy { spec[$0].text.isEmpty }
                    // Parent's provenance row: condition, provenance and region are all
                    // covered by the year and studio merged down from above.
                    && [1, 2, 3, 4, 5, 7, 9].allSatisfy { prov[$0].text.isEmpty }
                    // Child's specification row: status and studio covered from above.
                    && [2, 4, 5].allSatisfy { childSpec[$0].text.isEmpty },
                "a covered cell carries text the renderer will not draw")

        // The child's provenance row carries the pair's cataloguing detail — the parent's
        // own row said nothing a 4K disc could add.
        r.check("dr-child-carries-provenance",
                childProv[3].text == "New" && childProv[4].text == "United States"
                    && childProv[5].text == "Region A",
                "child provenance row reads \(childProv[3...5].map(\.text))")
        // The child's own year prints because it carries a base year — and prints ONLY the
        // base year, in its parentheses, since the release year it shares with the parent
        // is printed directly above. Purchased, so it takes one row and the child's
        // Condition keeps the other.
        r.check("dr-child-year-with-base",
                childSpec[3].text == "(1977)" && childSpec[3].rowSpan == 1,
                "child year cell reads '\(childSpec[3].text)' spanning \(childSpec[3].rowSpan)")
        // With a base year on the child, the parent's year stops at its own two rows.
        r.check("dr-parent-year-reach-with-base", spec[3].rowSpan == 2,
                "parent year spans \(spec[3].rowSpan) rows")

        // MARK: Rule weights
        // Three weights of horizontal rule: black across the top of a film's band, the
        // darker gray across the top of each release (from the trailing edge of the index
        // column), and the ordinary border everywhere else — including between a parent
        // and its child, which are one release.
        r.check("dr-film-rule",
                bands.allSatisfy { row in row.allSatisfy { $0.topRuleColor == PDFPalette.filmRule } },
                "a film band's top rule is not black the whole way across")
        // The combo is the FIRST release of its film, so its top edge is the band's bottom
        // and it takes no rule of its own — the black film rule above already divides it.
        r.check("dr-first-release-unruled",
                spec.allSatisfy { $0.topRuleColor == nil }
                    && prov.allSatisfy { $0.topRuleColor == nil }
                    && childSpec.allSatisfy { $0.topRuleColor == nil },
                "a film's first release (or its child) must not carry a release rule")
        // The rule proper is asserted on a SECOND release — the Mixed film's wishlisted
        // Blu-ray — where it runs from the index column across the specification row only.
        if let mixedForRule = filmBlock(in: section, title: "PDF DR Mixed"),
           mixedForRule.details.count >= 4 {
            let secondSpec = mixedForRule.details[2]
            let secondProv = mixedForRule.details[3]
            r.check("dr-release-rule",
                    secondSpec[0].topRuleColor == nil
                        && secondSpec.dropFirst().allSatisfy { $0.topRuleColor == PDFPalette.releaseRule }
                        && secondProv.allSatisfy { $0.topRuleColor == nil },
                    "the release rule must run from the index column across a later "
                        + "release's first row only")
        } else {
            r.check("dr-release-rule", false, "no Mixed block with a second release to rule")
        }

        // MARK: De-emphasis of the unremarkable
        // A single plain ratio and a theatrical-only version list are the defaults restated;
        // more than one ratio, an open-matte ratio, or any other cut is the reason to read
        // the cell.
        r.check("dr-single-ratio-secondary",
                spec[7].textColor == PDFPalette.secondaryText,
                "a lone plain ratio is not de-emphasized")
        r.check("dr-two-versions-primary", prov[6].textColor == nil,
                "a two-cut version list must stay primary")
        r.check("dr-theatrical-only-secondary",
                childProv[6].text == "Theatrical" && childProv[6].textColor == PDFPalette.secondaryText,
                "a theatrical-only version list is not de-emphasized")
        // Placeholders, wherever they land, are secondary too.
        r.check("dr-placeholders-secondary",
                childSpec[9].text == "\u{2013}" && childSpec[9].textColor == PDFPalette.secondaryText,
                "a placeholder dash is drawn in the primary color")

        let badges = [spec[1], combo.details[2][1]]
        r.check("dr-parent-first", badges[0].text == "4K UHD",
                "first release row reads '\(badges[0].text)'")
        // Hyphenated, matching the stored vocabulary the packaging column prints.
        r.check("dr-child-labeled",
                badges[1].text == "Blu-ray (included in combo-pack)",
                "child release row reads '\(badges[1].text)'")
        // Stepped in under the film title in the same column, and the bundled disc stepped
        // in again under the box it came in.
        r.check("dr-format-indented",
                badges[0].indent > 0 && badges[1].indent > badges[0].indent,
                "format indents are \(badges.map(\.indent)); the child must step in further")
        r.check("dr-4k-inverted",
                sameFill(badges[0].fill, PDFPalette.veryDarkGray)
                    && badges[0].fillIsOpaque
                    && badges[0].textColor == PDFPalette.invertedText,
                "the 4K badge is \(fillName(badges[0].fill)), opaque=\(badges[0].fillIsOpaque)")
        r.check("dr-combo-child-tint",
                sameFill(badges[1].fill, PDFPalette.veryDarkBlue) && !badges[1].fillIsOpaque,
                "the bundled Blu-ray badge is \(fillName(badges[1].fill))")

        // The index column runs unbroken beneath the band: only the LAST release's
        // provenance row closes it.
        r.check("dr-index-contiguous",
                combo.details[0][0].borders == .sides
                    && combo.details[1][0].borders == .sides
                    && combo.details[2][0].borders == .sides
                    && combo.details[3][0].borders == [.left, .right, .bottom],
                "index-column borders are \(combo.details.map { $0[0].borders.rawValue })")

        // MARK: Field placement after the reshuffle
        r.check("dr-years", spec[3].text == "2016 (1977)",
                "year cell reads '\(spec[3].text)'")
        r.check("dr-video-hdr", spec[6].text.contains("HDR10"),
                "video cell reads '\(spec[6].text)'")
        r.check("dr-versions-under-video", prov[6].text == "Theatrical, Extended",
                "versions cell reads '\(prov[6].text)'")
        r.check("dr-packaging-under-aspect",
                prov[8].text == "Combo-pack, Steelbook, 2 discs",
                "packaging cell reads '\(prov[8].text)'")
        r.check("dr-audio-on-provenance-row", prov[10].text == "DTS-HD MA 5.1",
                "audio cell reads '\(prov[10].text)'")

        // MARK: De-emphasis
        // The provenance row's cataloguing detail sits in the secondary gray so the eye can
        // run down the specification rows and drop into it only when it wants the detail.
        r.check("dr-provenance-row-secondary",
                [childProv[3], childProv[4], prov[8], childProv[8]]
                    .allSatisfy { $0.textColor == PDFPalette.secondaryText },
                "condition/provenance/packaging are not de-emphasized")
        // …but a FLAGGED region keeps the primary color, or the gray would take back what
        // the orange fill gives.
        r.check("dr-region-unflagged-secondary",
                childProv[5].fill == nil && childProv[5].textColor == PDFPalette.secondaryText,
                "an unflagged region lock is not de-emphasized")

        // On 4K only the CODEC is secondary — the master type and HDR flavor are what vary
        // and what a reader is looking for, so they stay primary.
        r.check("dr-4k-video-codec-only",
                spec[6].textColor == nil
                    && spec[6].highlights.count == 1
                    && spec[6].highlights[0].text == ReleaseVideoFormat.hevc
                    && spec[6].highlights[0].color == PDFPalette.secondaryText,
                "the 4K video cell must gray its codec alone, not the whole string")
        // On Blu-ray and DVD the whole string is secondary: the codec is fixed by the
        // format in practice, so the cell confirms rather than informs.
        r.check("dr-2k-video-secondary",
                combo.details[2][6].textColor == PDFPalette.secondaryText
                    && combo.details[2][6].highlights.isEmpty,
                "the Blu-ray video cell is not de-emphasized wholesale")
        // The aspect column truncates rather than wrapping — it is sized for three ratios
        // and an ellipsis, and every point it gave up went to Notes.
        r.check("dr-aspect-truncates", spec[7].truncates,
                "the aspect column wraps, which grows the row it lands on")

        // MARK: The 4K region default and the Region A case
        // A standalone 4K has no region coding and reads Region Free by default — see the
        // Mixed film below, whose 4K is standalone. On the combo record that cell is
        // covered, so the default is asserted there rather than here.
        let childRegion = childProv[5]
        r.check("dr-region-a-unfilled",
                childRegion.text == "Region A" && childRegion.fill == nil,
                "a Region A disc plays here and must not be flagged: "
                    + "'\(childRegion.text)' / \(fillName(childRegion.fill))")

        // MARK: Purchase standings
        guard let mixed = filmBlock(in: section, title: "PDF DR Mixed") else {
            r.check("dr-mixed-present", false, "no block for the mixed-standing film")
            return
        }
        let standings = stride(from: 0, to: mixed.details.count, by: 2)
            .map { mixed.details[$0][2] }
        r.check("dr-status-text",
                standings.map(\.text) == ["Purchased", "Wishlist #3", "Not purchased"],
                "status column is \(standings.map(\.text))")
        r.check("dr-status-fills",
                standings.count == 3
                    && sameFill(standings[0].fill, PDFPalette.green)
                    && sameFill(standings[1].fill, PDFPalette.darkGold)
                    && sameFill(standings[2].fill, PDFPalette.red),
                "status fills are \(standings.map { fillName($0.fill) })")
        r.check("dr-status-spans-pair", standings.allSatisfy { $0.rowSpan == 2 },
                "status cells span \(standings.map(\.rowSpan))")

        // MARK: Region B is flagged; Region B (LL) is not
        let wishlistProv = mixed.details[3]
        r.check("dr-region-b-flagged",
                wishlistProv[5].text == "Region B"
                    && sameFill(wishlistProv[5].fill, PDFPalette.lightOrange),
                "a plain Region B disc must be flagged: '\(wishlistProv[5].text)' / "
                    + "\(fillName(wishlistProv[5].fill))")
        let looseProv = mixed.details[5]
        r.check("dr-region-loose-abbreviated",
                looseProv[5].text == "Region B (LL)" && looseProv[5].fill == nil,
                "a loosely-locked disc plays and must be abbreviated, not flagged: "
                    + "'\(looseProv[5].text)' / \(fillName(looseProv[5].fill))")

        // MARK: Money and dates
        // A purchase is a balanced pair, so the slash falls in the same place on every row.
        let purchased = mixed.details[1]
        r.check("dr-purchased-money",
                purchased[11].paired?.leading == "$49.99"
                    && purchased[11].paired?.trailing == "$39.99"
                    && purchased[11].text == "$49.99 / $39.99"
                    && purchased[11].textColor == nil,
                "money cell reads '\(purchased[11].text)', paired=\(purchased[11].paired != nil)")
        r.check("dr-purchased-date",
                purchased[12].text == "February 10, 2025" && purchased[12].textColor == nil
                    && purchased[12].alignment == nil,
                "date cell reads '\(purchased[12].text)'")

        // An unpurchased release reports the lowest price alone, prefixed, de-emphasized,
        // and NOT paired — there is no relation for a single figure to be aligned on.
        r.check("dr-wishlist-money",
                wishlistProv[11].text == "Lowest: $14.99"
                    && wishlistProv[11].paired == nil
                    && wishlistProv[11].alignment == .left
                    && wishlistProv[11].textColor == PDFPalette.secondaryText,
                "an unpurchased release must report the lowest price alone and in the "
                    + "secondary gray, not '\(wishlistProv[11].text)'")
        // Abbreviated, with no trailing period, and left-aligned: it is a sentence, not a
        // date, and pinned right its prefix would move on every row.
        r.check("dr-wishlist-date",
                wishlistProv[12].text == "Last seen: Mar 2, 2024"
                    && wishlistProv[12].alignment == .left
                    && wishlistProv[12].textColor == PDFPalette.secondaryText,
                "date cell reads '\(wishlistProv[12].text)'")
        r.check("dr-abbreviated-may", looseProv[12].text == "Last seen: May 4, 2023",
                "date cell reads '\(looseProv[12].text)'")

        // A bundled Blu-ray's money is the parent's, and both cells say so rather than
        // dashing out as though the fields were never filled.
        r.check("dr-combo-child-money",
                childProv[11].text == "(Combo-pack)"
                    && childProv[12].text == "(Combo-pack)"
                    && childProv[11].paired == nil
                    // Both left-aligned, so the one remark reads across the two cells.
                    && childProv[11].alignment == .left
                    && childProv[12].alignment == .left
                    && childProv[11].textColor == PDFPalette.secondaryText,
                "the bundled Blu-ray's money cells read '\(childProv[11].text)' / "
                    + "'\(childProv[12].text)'")

        // A purchase with a recorded cost but nothing spent reads $0.00, not a dash: on a
        // disc the user owns, a zero paid is a figure, and the app's own card reports it so.
        if let gift = filmBlock(in: section, title: "PDF DR Gift") {
            r.check("dr-zero-spent-is-a-figure",
                    gift.details[1][11].paired?.trailing == "$0.00",
                    "a purchased release with nothing spent reads "
                        + "'\(gift.details[1][11].text)'")
            // Purchased and standalone: the year keeps to its row and Condition has the one
            // beneath it.
            r.check("dr-purchased-year-stack",
                    gift.details[0][3].rowSpan == 1 && gift.details[1][3].text == "New",
                    "year spans \(gift.details[0][3].rowSpan), condition reads "
                        + "'\(gift.details[1][3].text)'")
            // An open-matte ratio is the one framing choice that changes what the viewer
            // sees, and stays primary.
            r.check("dr-open-matte-primary",
                    gift.details[0][7].text.contains("Open matte") && gift.details[0][7].textColor == nil,
                    "an open-matte ratio was de-emphasized: '\(gift.details[0][7].text)'")
        } else {
            r.check("dr-gift-present", false, "no block for the nothing-spent film")
        }

        // MARK: The year stack on unpurchased records
        // An unpurchased release has no Condition to print, so its year takes that row too.
        r.check("dr-unpurchased-year-stack",
                mixed.details[2][3].rowSpan == 2 && mixed.details[3][3].text.isEmpty,
                "unpurchased year spans \(mixed.details[2][3].rowSpan); condition cell "
                    + "reads '\(mixed.details[3][3].text)'")
        // On a combo pack with no base year on the child, the parent's year reaches all
        // the way down: three rows when purchased (the child's Condition needs its row),
        // four when not.
        if let plain = filmBlock(in: section, title: "PDF DR Combo Plain") {
            r.check("dr-combo-purchased-no-base-reach",
                    plain.details[0][3].rowSpan == 3
                        && plain.details[2][3].text.isEmpty
                        && plain.details[3][3].text == "Good",
                    "parent year spans \(plain.details[0][3].rowSpan); child cells read "
                        + "'\(plain.details[2][3].text)' / '\(plain.details[3][3].text)'")
        } else {
            r.check("dr-combo-plain-present", false, "no block for the purchased no-base combo")
        }
        if let wanted = filmBlock(in: section, title: "PDF DR Combo Wanted") {
            r.check("dr-combo-unpurchased-no-base-reach",
                    wanted.details[0][3].rowSpan == 4
                        && wanted.details[1][3].text.isEmpty
                        && wanted.details[2][3].text.isEmpty
                        && wanted.details[3][3].text.isEmpty,
                    "parent year spans \(wanted.details[0][3].rowSpan) rows")
            r.check("dr-combo-unpurchased-status", wanted.details[0][2].rowSpan == 4,
                    "status spans \(wanted.details[0][2].rowSpan) rows")
        } else {
            r.check("dr-combo-wanted-present", false, "no block for the unpurchased combo")
        }

        // Condition still describes a disc in hand, so an unpurchased release leaves it
        // BLANK — not dashed, which would claim the field was merely unfilled.
        r.check("dr-condition-purchased-only",
                purchased[3].text == "\u{2013}" && wishlistProv[3].text.isEmpty
                    && looseProv[3].text.isEmpty,
                "condition cells are '\(purchased[3].text)', '\(wishlistProv[3].text)', "
                    + "'\(looseProv[3].text)'")
    }

    // MARK: - Render

    /// Draws both sections for real and reads the file back.
    ///
    /// Everything above works on the row arrays, which cannot catch a section that lays out
    /// to nothing — a width set that normalizes to zero, or a row taller than the page, both
    /// produce a valid empty document rather than an error.
    @MainActor
    private static func checkRendered(_ r: inout HarnessScenarioResult, films: [FilmSnapshot]) async {
        let geometry = LibraryTableLayout.standard.geometry
        let url = scratchURL("detail-sections.pdf")
        try? FileManager.default.removeItem(at: url)

        var mediaBox = CGRect(origin: .zero, size: geometry.pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = unsafe CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            r.check("render-context", false, "could not open a PDF context at \(url.path)")
            return
        }

        let builder = PDFDocumentBuilder(context: context)
        builder.add(ViewingHistoryPDFReport.section(films: films), geometry: geometry)
        builder.add(DiscReleasesPDFReport.section(films: films), geometry: geometry)
        let pages = (try? await builder.finish()) ?? 0

        guard let document = PDFDocument(url: url) else {
            r.check("render-readable", false, "PDFKit could not open the rendered file")
            return
        }
        r.check("render-readable", document.pageCount == pages && pages >= 2,
                "\(document.pageCount) pages (builder reported \(pages)) at \(url.path)")

        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }.joined()
        r.check("render-section-titles",
                text.contains(ViewingHistoryPDFReport.sectionTitle)
                    && text.contains(DiscReleasesPDFReport.sectionTitle),
                "one of the two section headings is missing from the drawn text")

        // Every film reaches the page in BOTH sections — the cheapest end-to-end check
        // that a block is not being laid out off the bottom of the page and lost.
        let missing = films.map(\.name).filter { name in
            text.components(separatedBy: name).count - 1 < 2
        }
        r.check("render-films-twice", missing.isEmpty,
                missing.isEmpty ? "all \(films.count) films appear in both sections"
                                : "appearing fewer than twice: \(missing)")

        await checkTwoUpRender(&r, geometry: geometry)
    }

    /// Renders a Viewing History section long enough to wrap panes and pages, so the
    /// two-up layout can be LOOKED at rather than only counted.
    ///
    /// The corpus above is five films — enough to prove every rule about what a row says,
    /// and nowhere near enough to fill a pane. This draws a library-sized one into
    /// `harness-scratch-viewing-history-wide.pdf` and asserts the only things a page count
    /// can tell you: that the wrap happened at all, and that no film was lost in it.
    @MainActor
    private static func checkTwoUpRender(_ r: inout HarnessScenarioResult,
                                         geometry: PDFPageGeometry) async {
        // Titles are numbered so their order on the page is readable at a glance: a wrap
        // that ran across the page before it ran down it would be obvious immediately.
        let films = (1...140).map { index -> FilmSnapshot in
            var film = makeSnapshot(
                name: "Two-Up Probe \(Fmt.padded(index, 3))",
                releaseYear: "\(1970 + index % 50)",
                // Every third film carries viewings, so the section has the ragged block
                // heights a real library has rather than a uniform row per film.
                calendarTable: index % 3 == 0 ? viewingDates(count: 1 + index % 4) : [])
            film.watched = index % 3 == 0
            return film
        }

        let section = ViewingHistoryPDFReport.section(films: films)
        let url = scratchURL("viewing-history-wide.pdf")
        try? FileManager.default.removeItem(at: url)

        var mediaBox = CGRect(origin: .zero, size: geometry.pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = unsafe CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            r.check("two-up-context", false, "could not open a PDF context at \(url.path)")
            return
        }
        let builder = PDFDocumentBuilder(context: context)
        builder.add(section, geometry: geometry)
        let pages = (try? await builder.finish()) ?? 0

        guard let document = PDFDocument(url: url) else {
            r.check("two-up-readable", false, "PDFKit could not open the wide render")
            return
        }
        r.check("two-up-readable", document.pageCount == pages,
                "\(document.pageCount) pages at \(url.path)")

        let metrics = PDFTableRenderer.metrics(of: section, geometry: geometry)
        r.check("two-up-wraps", Set(metrics.placements.map(\.pane)) == [0, 1],
                "a \(films.count)-film section did not reach its second pane")

        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }.joined()
        let lost = films.map(\.name).filter { !text.contains($0) }
        r.check("two-up-keeps-every-film", lost.isEmpty,
                lost.isEmpty ? "all \(films.count) films survived the wrap"
                             : "lost in the wrap: \(lost.prefix(5))")

        // No film's viewings are stranded on a different pane from the band that names
        // them. A pane opening with unattributed dates is the specific failure two-up makes
        // twice as likely, and the reason `keepTogether` exists.
        let split = section.keepTogether.filter { block in
            let first = metrics.placements[block.lowerBound]
            return block.contains { metrics.placements[$0].page != first.page
                                 || metrics.placements[$0].pane != first.pane }
        }
        r.check("two-up-blocks-unbroken", split.isEmpty,
                split.isEmpty ? "every film's band and viewings share a pane"
                              : "\(split.count) film block(s) split, first at row "
                                  + "\(split[0].lowerBound)")
        r.check("two-up-blocks-declared", section.keepTogether.count == films.count,
                "\(section.keepTogether.count) blocks declared for \(films.count) films")
    }

    // MARK: - Block Extraction

    /// One film's rows: the banded film row, and the detail rows that hang off it.
    ///
    /// The blocks are recovered from the flat row list exactly the way a READER recovers
    /// them — a row with an index is a new film, and everything after it belongs to that
    /// film until the next indexed row. Asserting against blocks found this way is what
    /// makes the tests above tests of the structure rather than of an offset the corpus
    /// happens to produce.
    private static func filmBlock(in section: PDFTableSection,
                                  title: String) -> (film: [PDFCell], details: [[PDFCell]])? {
        guard let start = section.rows.firstIndex(where: {
            $0[0].text != "" && $0[1].text == title
        }) else { return nil }

        var end = start + 1
        while end < section.rows.count, section.rows[end][0].text == "" { end += 1 }
        return (section.rows[start], Array(section.rows[(start + 1)..<end]))
    }

    // MARK: - Corpus

    /// Films shaped to land on every branch of both sections. Deliberately ONE corpus for
    /// the two: both sections list the same library, and running them over the same films
    /// is what lets the order check above compare them against a common expectation.
    @MainActor
    private static func detailSectionsCorpus() -> [FilmSnapshot] {
        var films: [FilmSnapshot] = []

        // Three viewings, newest first once sorted, with and without version codes — and
        // no releases at all, which is also the Disc-based Releases section's empty state.
        films.append(makeSnapshot(
            name: "PDF VH Watched",
            calendarTable: ["2026.01.01.DC", "2026.03.01.TH", "2026.02.01"]))

        // Never watched, nothing to list, no releases.
        films.append(makeSnapshot(name: "PDF VH Unwatched"))

        // Marked watched, but with no dated entries — the OTHER empty state.
        var unrecorded = makeSnapshot(name: "PDF VH No History")
        unrecorded.watched = true
        films.append(unrecorded)

        // A 4K parent with its bundled Blu-ray child.
        let parentID = UUID()
        var combo = makeSnapshot(name: "PDF DR Combo")
        combo.watched = true
        combo.releases = [
            ReleaseSnapshot(
                id: parentID, studio: "Twentieth Century Fox", releaseDate: "2016",
                baseReleaseYear: "1977", purchased: true,
                format: ReleaseFormat.uhd4K.rawValue,
                includedVersions: ["Theatrical", "Extended"],
                independence: ReleaseIndependence.comboPack,
                videoFormat: ReleaseVideoFormat.hevc,
                releaseAspectRatio: ["2.39:1"],
                audioFormat: ReleaseAudioFormat.dtsHDMA,
                audioChannels: ReleaseAudioChannels.surround51,
                numberOfDiscs: 2, hasArtwork: ReleaseArtwork.steelbook,
                nationalOrigin: "United States",
                replicationType: ReleaseReplicationType.pressed,
                hasHDR: "HDR10", masterType: ReleaseMasterType.nativeFourK,
                cost: 34.99, amountSpent: 29.99, purchaseDate: "2025.11.04",
                lowestPrice: 22.49, lowestPriceDate: "2025.07.12",
                condition: "new", notes: "Slipcover intact."),
            ReleaseSnapshot(
                studio: "Twentieth Century Fox", releaseDate: "2016",
                baseReleaseYear: "1977", purchased: true,
                format: ReleaseFormat.bluRay.rawValue,
                includedVersions: ["Theatrical"],
                independence: ReleaseIndependence.comboPack,
                videoFormat: ReleaseVideoFormat.avc,
                releaseAspectRatio: ["2.39:1"],
                audioFormat: ReleaseAudioFormat.dtsHDMA,
                audioChannels: ReleaseAudioChannels.surround51,
                // Mirrors the parent, as `FSTabReleases` keeps a child's origin in step —
                // the merged record reads the pair's provenance off the child's row.
                nationalOrigin: "United States",
                // The real stored tag, not a bare letter: the section reads this field
                // through the same vocabulary the sidebar's region badge does, and a value
                // outside it would exercise the fallback rather than the Region A case.
                regionLock: ReleaseRegionRules.regionA, condition: "new",
                parentReleaseID: parentID),
        ]
        films.append(combo)

        // The three purchase standings on one film, in the order the format sort puts them:
        // 4K purchased, Blu-ray wishlisted, Blu-ray neither. The two Blu-rays also carry
        // the two region-lock cases that must be told apart — a plain Region B, which does
        // not play here and is flagged, and a loosely-locked one, which does and is not —
        // and the two ends of the month-abbreviation rule, March and the unshortenable May.
        var mixed = makeSnapshot(name: "PDF DR Mixed")
        mixed.watched = true
        mixed.releases = [
            ReleaseSnapshot(studio: "Criterion", releaseDate: "2021", purchased: true,
                            format: ReleaseFormat.uhd4K.rawValue,
                            cost: 49.99, amountSpent: 39.99, purchaseDate: "2025.02.10"),
            ReleaseSnapshot(studio: "Arrow", releaseDate: "2019", wishlist: 3,
                            format: ReleaseFormat.bluRay.rawValue,
                            regionLock: ReleaseRegionRules.regionB,
                            cost: 24.99, lowestPrice: 14.99, lowestPriceDate: "2024.03.02"),
            ReleaseSnapshot(studio: "Second Sight", releaseDate: "2018",
                            format: ReleaseFormat.bluRay.rawValue,
                            regionLock: ReleaseRegionRules.looselyLockedTag,
                            lowestPrice: 21.00, lowestPriceDate: "2023.05.04"),
        ]
        films.append(mixed)

        // A purchase with a recorded cost and nothing spent — the one case where a zero in
        // the Amount Spent field is a real figure rather than an empty one.
        var gift = makeSnapshot(name: "PDF DR Gift")
        gift.watched = true
        gift.releases = [
            ReleaseSnapshot(studio: "Shout Factory", releaseDate: "2022", purchased: true,
                            format: ReleaseFormat.bluRay.rawValue,
                            releaseAspectRatio: ["1.85:1 \(AspectRatioVocabulary.openMatteQualifier)"],
                            regionLock: ReleaseRegionRules.regionA,
                            cost: 39.99, amountSpent: 0, purchaseDate: "2024.12.25",
                            condition: "new"),
        ]
        films.append(gift)

        // A purchased combo pack whose child has NO base year: the parent's year reaches
        // down three rows, stopping short of the child's Condition.
        let plainParent = UUID()
        var plain = makeSnapshot(name: "PDF DR Combo Plain")
        plain.watched = true
        plain.releases = [
            ReleaseSnapshot(id: plainParent, studio: "Arrow Video", releaseDate: "2018",
                            purchased: true, format: ReleaseFormat.uhd4K.rawValue,
                            independence: ReleaseIndependence.comboPack,
                            cost: 29.99, amountSpent: 29.99, purchaseDate: "2024.06.01",
                            condition: "good"),
            ReleaseSnapshot(studio: "Arrow Video", releaseDate: "2018", purchased: true,
                            format: ReleaseFormat.bluRay.rawValue,
                            independence: ReleaseIndependence.comboPack,
                            regionLock: ReleaseRegionRules.regionA, condition: "good",
                            parentReleaseID: plainParent),
        ]
        films.append(plain)

        // The same, unpurchased: nothing beneath the year has anything to say, and it
        // reaches all four rows.
        let wantedParent = UUID()
        var wanted = makeSnapshot(name: "PDF DR Combo Wanted")
        wanted.watched = true
        wanted.releases = [
            ReleaseSnapshot(id: wantedParent, studio: "Kino Lorber", releaseDate: "2023",
                            wishlist: 2, format: ReleaseFormat.uhd4K.rawValue,
                            independence: ReleaseIndependence.comboPack, lowestPrice: 24.99),
            ReleaseSnapshot(studio: "Kino Lorber", releaseDate: "2023",
                            format: ReleaseFormat.bluRay.rawValue,
                            independence: ReleaseIndependence.comboPack,
                            regionLock: ReleaseRegionRules.regionA,
                            parentReleaseID: wantedParent),
        ]
        films.append(wanted)

        return films
    }
}

#endif
