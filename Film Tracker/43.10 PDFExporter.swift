// MARK: - PDFExporter.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Assembles the whole-library PDF: the complete-library table, followed by one sheet per
// ReportsView tab, in a single document.
//
// The document is built entirely from the shared PDF stack (PDFCore 88.00 / PDFTableRenderer
// 88.10 / LibraryPDFReport 88.20). The report sheets are the ones `ReportsPDFExporter`
// (27.50) builds — this file does not restate a single column of them, it just appends
// them.
//
// The whole document is landscape at the library table's type size: a reader paging
// through one report should not have to rotate it halfway. Those report sheets are written
// against a portrait page and rendered here at a different geometry — which is exactly
// what column widths being weights rather than points buys.

import AppKit
import Foundation

// MARK: - Section Selection

/// One selectable sheet of the library PDF.
///
/// The first three cases are the document's own per-film sections — the summary table
/// `LibraryPDFReport` draws, then the two detail sections in `PDFSections` (85.30). The two
/// after them map 1:1 onto a `ReportsCategory`, so the document's contents and the Export
/// tab's picker stay in step without either side restating the other's list.
///
/// DECLARATION ORDER IS DOCUMENT ORDER: `export` filters `allCases` rather than iterating
/// the caller's set, so the sheets come out in the order written here however the selection
/// was built. The three per-film sections lead, so a reader meets each film in the summary
/// table before meeting its viewings and its discs.
///
/// # What is NOT here
///
/// The Purchase and Expense Tracker, the Price Tracker and the Release Wishlist were cases
/// here until `discReleases` superseded all three. That section reports the same purchase
/// state, cost, amount spent, lowest price and both dates — per release, beside the disc
/// they belong to, rather than as three separately ranked lists of the same rows. Keeping
/// them would have printed every purchased release twice and every wishlist entry twice.
///
/// Their ReportsView TABS are untouched and still on screen; it is only their sheets in
/// this document that are gone, along with the section builders that served nothing else.
enum LibraryPDFSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case completeLibrary
    case viewingHistory
    case discReleases
    case hallOfFame
    case dataVisualizations

    var id: String { rawValue }

    /// The ReportsView tab this section is drawn from, or nil for a section this document
    /// builds itself.
    var reportsCategory: ReportsCategory? {
        switch self {
        case .completeLibrary:     return nil
        case .viewingHistory:      return nil
        case .discReleases:        return nil
        case .hallOfFame:          return .hallOfFame
        case .dataVisualizations:  return .dataVisualizations
        }
    }

    var displayName: String {
        switch self {
        case .completeLibrary: return "Complete Library"
        case .viewingHistory:  return ViewingHistoryPDFReport.sectionTitle
        case .discReleases:    return DiscReleasesPDFReport.sectionTitle
        default:               return reportsCategory?.displayName ?? ""
        }
    }

    static var all: Set<LibraryPDFSection> { Set(allCases) }
}

@MainActor
enum LibraryPDFExporter: Loggable {
    nonisolated static let logTag = "[LibraryPDFExporter]"

    /// The base filename, before `PDFFilename` appends a timestamp.
    static let filenameBase = "FilmTracker Library"

    // MARK: - Export

    /// Builds the complete library PDF and writes it into `destinationFolder`.
    ///
    /// - Parameters:
    ///   - dataCoordinator: The live in-memory store every section is derived from. All
    ///     reads are `MemoryStore` dictionary copies, so this is a synchronous snapshot of
    ///     the library with no I/O and no `ModelContext` access.
    ///   - destinationFolder: A security-scoped folder URL, as returned by
    ///     `OpenPanelPresenter`.
    ///   - sections: The sheets to include, in `LibraryPDFSection.allCases` order regardless
    ///     of how the set was built. An empty selection is an error, not an empty document.
    ///   - progress: Called on the MainActor with 0…1 as sections are built and drawn.
    /// - Returns: The URL of the delivered file. Its name carries a numeral (` 1`, ` 2`, …)
    ///   when the timestamped name was already taken in `destinationFolder`.
    ///
    /// Async so the caller's progress bar can actually advance: building a section is
    /// synchronous, but the loop suspends between them, which both lets the UI paint and
    /// gives `Task.checkCancellation()` a place to take effect.
    static func export(
        dataCoordinator: DataCoordinator,
        destinationFolder: URL,
        sections: Set<LibraryPDFSection> = LibraryPDFSection.all,
        layout: LibraryTableLayout = .standard,
        progress: ((Double) -> Void)? = nil
    ) async throws -> URL {
        let ordered = LibraryPDFSection.allCases.filter { sections.contains($0) }
        guard !ordered.isEmpty else { throw PDFExportError.noDataToExport }

        let films = dataCoordinator.getAllFilms()
        guard !films.isEmpty else { throw PDFExportError.noDataToExport }

        progress?(0.0)

        // The document is drawn into a private `ExportStaging` directory inside the sandbox
        // container and moved to `destinationFolder` only once it is complete. A cancel or a
        // failure partway — when CoreGraphics would finalize whatever had been drawn into a
        // plausible-looking but truncated PDF — is cleaned up entirely inside the container,
        // and nothing in the user's folder is ever created, replaced or removed for it.
        let stagingDirectory = try ExportStaging.makeDirectory()
        defer { ExportStaging.discard(stagingDirectory) }

        let filename = PDFFilename.timestamped(base: filenameBase)
        let stagedURL = stagingDirectory.appendingPathComponent(filename)

        let (added, pageCount) = try await render(
            films: films, ordered: ordered, dataCoordinator: dataCoordinator,
            layout: layout, into: stagedURL, progress: progress)

        // `false` here means the URL is not security-scoped, NOT that access was denied —
        // a folder the process can already reach returns false and is perfectly writable.
        // Balancing the stop against what start actually reported (the same shape
        // `ExportViewModel.startExport` uses) lets a real write failure surface as itself
        // rather than being pre-empted by a scope check that was never the problem.
        let scoped = destinationFolder.startAccessingSecurityScopedResource()
        defer { if scoped { destinationFolder.stopAccessingSecurityScopedResource() } }

        // Takes the first free name — never replaces a file already there. Off the main
        // actor: to another volume this is a copy, which a slow drive would hold the UI on.
        let destinationURL = try await Task.detached(priority: .utility) {
            try ExportStaging.deliver(stagedURL, into: destinationFolder, as: filename)
        }.value
        progress?(1.0)

        Self.log("Library PDF written: \(films.count) films, \(added) of \(ordered.count) selected section(s), \(pageCount) pages → '\(destinationURL.lastPathComponent)'")
        return destinationURL
    }

    /// Draws the selected sections into a new PDF at `url`. Returns how many sections were
    /// drawn and the document's page count.
    ///
    /// A function of its own so the `CGContext` and its data consumer are released — and the
    /// file closed — before the caller moves it: a move to another volume is a copy, and a
    /// copy of a file still open for writing could miss its last bytes.
    private static func render(
        films: [FilmSnapshot],
        ordered: [LibraryPDFSection],
        dataCoordinator: DataCoordinator,
        layout: LibraryTableLayout,
        into url: URL,
        progress: ((Double) -> Void)?
    ) async throws -> (added: Int, pageCount: Int) {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw PDFExportError.pdfCreationFailed
        }

        // The context's media box is only the DEFAULT — every page the renderer starts
        // declares its own — but every page in this document is the library table's size,
        // so the default and the per-page boxes agree.
        var mediaBox = CGRect(origin: .zero, size: layout.geometry.pageSize)
        guard let context = unsafe CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFExportError.pdfCreationFailed
        }

        // Built rather than rendered directly: the footers name a DOCUMENT-wide page total,
        // which is not knowable until every section has been measured — so the builder
        // measures them all, then draws. It closes the context on finish().
        let builder = PDFDocumentBuilder(context: context)

        // The build loop is budgeted 0…`buildShare`, and finish() — which measures and
        // draws every collected sheet, suspending between pages — the rest. The split
        // follows the wall time: on a library-sized export, building the sections is a
        // small fraction of the whole and drawing the pages is nearly all of it, so a bar
        // that gave the build the lion's share sat at ninety percent for most of the run.
        var added = 0
        for (index, section) in ordered.enumerated() {
            try Task.checkCancellation()

            // The three per-film sections share the library table's geometry — they are
            // built against the same landscape page and are meant to be read as one
            // document with it.
            switch section {
            case .completeLibrary:
                builder.add(LibraryPDFReport.section(films: films, layout: layout),
                            geometry: layout.geometry)
                added += 1
            case .viewingHistory:
                builder.add(ViewingHistoryPDFReport.section(films: films),
                            geometry: layout.geometry)
                added += 1
            case .discReleases:
                builder.add(DiscReleasesPDFReport.section(films: films),
                            geometry: layout.geometry)
                added += 1
            default:
                // Every remaining case names a ReportsView tab. Handled in one arm rather
                // than one per case because the binding the body needs — the category — is
                // DERIVED from the case, not given by it, so an arm each would restate the
                // same six lines six times.
                //
                // A tab with nothing to report is SKIPPED rather than rendered as an empty
                // table — `ReportsPDFExporter.sheet(for:)` returns nil for exactly that
                // case, which is why it reports emptiness that way rather than throwing.
                if let category = section.reportsCategory,
                   let sheet = ReportsPDFExporter.sheet(
                    for: exportData(for: category, dataCoordinator: dataCoordinator,
                                    films: films)) {
                    // The LIBRARY TABLE'S geometry: inside this document the report
                    // sections match the table they follow, in
                    // orientation and in type size. The sections are geometry-independent
                    // (column widths are weights), which is what allows it. Taken from the
                    // caller's `layout` rather than from `.standard`, so a non-default
                    // layout cannot leave the appended sheets on a different page size
                    // from the table and the context's own media box.
                    builder.add(sheet, geometry: layout.geometry)
                    added += 1
                }
            }

            progress?(Double(index + 1) / Double(ordered.count) * Self.buildShare)
            await Task.yield()
        }

        guard added > 0 else { throw PDFExportError.noDataToExport }
        try Task.checkCancellation()

        // Cooperative from here on: `finish` suspends after every page and while measuring,
        // so the run loop turns, the bar advances page by page, and a Cancel is honored
        // mid-document — see `PDFDocumentBuilder.finish`. A cancellation propagates out of
        // here as `CancellationError`, and the caller's staging `defer` removes the partial
        // file.
        let pageCount = try await builder.finish { fraction in
            progress?(Self.buildShare + (1 - Self.buildShare) * fraction)
        }
        return (added, pageCount)
    }

    /// The share of the progress bar the section-building loop occupies; `finish` has the
    /// rest. See the note above the loop.
    private static let buildShare = 0.15

    // MARK: - Report Sheets

    /// Rebuilds a tab's export payload from the store.
    ///
    /// Deliberately NOT read from `ReportsState.shared`: that cache is only populated once
    /// the user has visited the tab in question, so sourcing from it would silently drop
    /// whole sheets out of the document depending on where the user had browsed this
    /// session.
    ///
    /// Each payload is built by calling the tab's OWN row builder rather than by restating
    /// its rules here. This file used to carry a private reimplementation of all four —
    /// same predicates, same field mapping, separately maintained — and they had already
    /// drifted apart on ordering (see `ReleaseData.sorted`). The builders now live beside
    /// the models they produce (`ReleaseData`, `HallOfFameFilm`, `WishlistRelease`) and
    /// have exactly one definition each.
    /// Internal rather than private so the debug harness can assert on the payload this
    /// builds — in particular that the tracker sheets come out in a reproducible order.
    /// Driving the real builder is the point: a harness that restated the ordering rule
    /// would pass against an exporter that had stopped applying it.
    static func exportData(
        for category: ReportsCategory,
        dataCoordinator: DataCoordinator,
        films: [FilmSnapshot]
    ) -> ReportsExportData {
        switch category {
        // The three superseded tabs no longer reach this document — see the note on
        // `LibraryPDFSection`. Listed explicitly rather than folded into a `default` so
        // that adding a sixth ReportsCategory still fails the build here, which is the
        // check that kept this switch and the picker in step in the first place.
        case .costTracker, .priceTracker, .releaseWishlist:
            return ReportsExportData(category: category,
                                     hallOfFameFilms: nil)

        case .hallOfFame:
            return ReportsExportData(
                category: category,
                hallOfFameFilms: HallOfFameFilm.rows(
                    films: dataCoordinator.getHallOfFameFilms()))

        case .dataVisualizations:
            // The tab's cached pass lends its parsed viewing histories, when there is one,
            // so only films whose history changed since are parsed again.
            return ReportsExportData(
                category: category, hallOfFameFilms: nil,
                visualizations: DVDataset(
                    films: films,
                    previousRecords: ReportsState.shared.cachedVisualizations?.viewingRecords ?? [],
                    showInfoComplete: Preferences.showInfoComplete))
        }
    }
}
