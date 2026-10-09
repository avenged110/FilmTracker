// MARK: - RatingsImporter.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Handles file selection and orchestrates ratings import workflow.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Ratings Progress Delegate Protocol
@MainActor
protocol RatingsImporterProgressDelegate: ImportSessionReporting {
    func didStartRatingsImport(totalRatings: Int)
    func didUpdateRatingsProgress(currentRating: Int, imported: Int, updated: Int,
        notFound: Int, duplicateSkipped: Int)
    // `addedTitles`/`updatedTitles`/`duplicateTitles` hold the matched Film "name" field
    // values for items in each respective category, for display in ImportsView's
    // per-card "Details" popover.
    func didCompleteRatingsImport(imported: Int, updated: Int, notFound: Int,
        duplicateSkipped: Int, addedTitles: [String], updatedTitles: [String],
        duplicateTitles: [String])
}

// MARK: - Matching Value Types
// The subset of a library film's fields the matching loop needs. Extracted from
// the FilmSnapshot array once, up front, so the detached matching task works
// purely with immutable Sendable values and never touches MemoryStore.
private struct FilmRow: Sendable {
    let id: UUID
    let name: String
    let alternateTitles: [String]
    let year: String
    let existingRating: Int
}

// One matching strategy: which titles of a film an incoming rating may match
// against. Two are used, in order — primary name first, then alternate titles
// for whatever the first pass could not place.
private struct MatchPass: Sendable {
    // Appears in the debug log's "Source:" line.
    let label: String
    // Exact-match index: title → films carrying that title. An array because
    // multiple films could theoretically share a title; in practice k ≈ 1.
    let index: [String: [FilmRow]]
    // Whether a film's title is a fuzzy (Levenshtein) match for the incoming
    // rating's title under this pass. Used only when `index` misses and the
    // fuzzy-matching preference is on.
    let matchesFuzzily: @Sendable (FilmRow, String) -> Bool
    // True for the pass that matches on alternate titles, which logs the matched
    // film's alternate-title list alongside its name.
    let logsAlternateTitles: Bool
}

@MainActor
final class RatingsImporter: Loggable {
    nonisolated static let logTag = "[RatingsImporter]"

    private weak var dataCoordinator: DataCoordinator?
    weak var progressDelegate: (any RatingsImporterProgressDelegate)?
    private var isCanceled = false

    // Batch updates every 500ms to prevent scroll hitching
    private var pendingUpdates: [(UUID, Int)] = []
    private var updateBatchTask: Task<Void, Never>?
    private let updateBatchInterval: TimeInterval = 0.5

    init(dataCoordinator: DataCoordinator) { self.dataCoordinator = dataCoordinator }

    // MARK: - Public Interface
    // Presents a file picker and begins the import process.
    func beginImport() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let config = OpenPanelConfiguration(canChooseFiles: true,
                canChooseDirectories: false, allowsMultipleSelection: false,
                allowedContentTypes: [UTType.html], title: nil,
                message: "Select a Blu-ray.com Ratings HTML File", prompt: "Select")

            let selection = await OpenPanelPresenter.present(configuration: config, attachedTo: NSApp.keyWindow)

            guard case let .urls(urls) = selection, let url = urls.first else {
                self.progressDelegate?.importAbandonedBeforeStart()
                return }

            // Reset cancelation flag.
            self.isCanceled = false

            // Create session only after successful file selection.
            self.progressDelegate?.createSession(for: .ratings)

            await self.processFile(url) } }

    // Cancel the ongoing import.
    func cancelImport() async {
        Self.log("Ratings import canceled by user")
        isCanceled = true

        // Cancel batch update task
        updateBatchTask?.cancel()
        updateBatchTask = nil
    }

    // Reports a completion carrying no results. Used for every path that ends the
    // import without a usable outcome — unreadable/unrecognized file or empty file —
    // so the UI unlocks and the session is closed out identically in each case.
    //
    // NOT for cancellation. ImportProgress.cancelImport already closes a canceled
    // import out (finalizeCancellation: session marked canceled, UI unlocked). Reporting
    // a completion on top of that ran flushAndFinalize as well — twice, once from the
    // loop and once after it — which showed the canceled import with the success glyph
    // and re-saved its session as completed.
    private func reportEmptyCompletion() {
        progressDelegate?.didCompleteRatingsImport(imported: 0, updated: 0,
            notFound: 0, duplicateSkipped: 0, addedTitles: [], updatedTitles: [],
            duplicateTitles: [])
    }

    // MARK: - File Processing
    private func processFile(_ url: URL) async {
        guard let coordinator = dataCoordinator else { return }
        Self.log("Starting ratings import from: \(url.lastPathComponent)")

        // Initialize parser and parse file - keep parser local to this MainActor function
        let parser = RatingsParser()

        guard let parsedRatings = await parser.parseFile(url) else {
            Self.log("ERROR: Failed to read or validate ratings file")
            // Report completion with zero results to clear the UI.
            reportEmptyCompletion()
            return
        }

        if parsedRatings.isEmpty {
            Self.log("WARNING: Ratings file was valid but contained no recognizable entries")
            reportEmptyCompletion()
            return
        }

        Self.log("Successfully parsed \(parsedRatings.count) ratings from file")

        // Check if import was canceled during parsing.
        if isCanceled {
            Self.log("Import canceled after parsing - aborting")
            return }

        // Notify delegate that import is starting with total count.
        progressDelegate?.didStartRatingsImport(totalRatings: parsedRatings.count)

        // Get preference values on MainActor.
        let allowUpdates = Preferences.allowUpdatesForDuplicateRatings
        let useFuzzyMatching = Preferences.fuzzyImportMatching
        let useFuzzyYearMatching = Preferences.fuzzyImportYearMatching

        // Get all films and extract immutable data
        let allFilms = coordinator.getAllFilms()

        if allFilms.isEmpty {
            Self.log("ERROR: No films found in memory store")
            reportEmptyCompletion()
            return }

        // Extract immutable film data for comparison.
        // Includes alternateTitle for the secondary matching pass.
        let filmData: [FilmRow] = allFilms.map { film in
            FilmRow(id: film.id, name: film.name, alternateTitles: film.alternateTitle,
                year: film.releaseYear, existingRating: film.userRating)
        }

        Self.log("Processing \(parsedRatings.count) ratings against \(filmData.count) films in library")

        // Clear pending updates
        pendingUpdates.removeAll()

        // Start the batch update task
        startBatchUpdateTask()

        // Process ratings in a detached task to avoid blocking the UI
        // Capture only immutable values to avoid concurrency issues
        let ratingsToProcess = parsedRatings // Immutable copy
        let debugLogging = Preferences.importRatingsDebugLogging // Capture debug flag

        let (finalImportedCount, finalUpdatedCount, finalNotFoundCount, finalDuplicateSkippedCount,
             finalAddedTitles, finalUpdatedTitles, finalDuplicateTitles) =
            await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return (0, 0, 0, 0, [String](), [String](), [String]()) }

            var localCurrentRating = 0
            var localImportedCount = 0      // New ratings applied (no prior rating)
            var localUpdatedCount = 0        // Existing ratings changed
            var localNotFoundCount = 0       // Not in library
            var localDuplicateSkippedCount = 0 // Matched but skipped (same rating or updates disabled)

            // Titles (Film "name" field values) for items in each category, matched
            // during either pass below. Surfaced in ImportsView's Details popover.
            var localAddedTitles: [String] = []
            var localUpdatedTitles: [String] = []
            var localDuplicateTitles: [String] = []

            // Build local updates array - avoid MainActor calls in hot loop
            var localUpdates: [(UUID, Int)] = []

            // Shared cancellation check used by both the first and second
            // matching passes below. On cancellation it flushes any locally
            // buffered rating updates (so work already matched isn't silently
            // discarded) and tears down the batch-update task. The UI and session
            // are closed out by the cancel itself — see reportEmptyCompletion.
            // Returns true if the caller should stop processing immediately.
            func checkCancellationAndTeardownIfNeeded(logSuffix: String) async -> Bool {
                let canceled = await MainActor.run { self.isCanceled }
                guard canceled else { return false }
                if !localUpdates.isEmpty {
                    let updatesToSync = localUpdates
                    await MainActor.run { self.pendingUpdates.append(contentsOf: updatesToSync) }
                }
                await MainActor.run {
                    Self.log("Import loop terminated due to cancelation\(logSuffix)")
                    self.updateBatchTask?.cancel()
                    self.updateBatchTask = nil
                }
                return true
            }

            // --- Matching passes ---
            // Pass 1 matches an incoming rating against each film's primary name;
            // pass 2 re-tries whatever pass 1 could not place against the films'
            // alternate titles. Both use an exact-match dictionary first (O(1) on
            // title, O(k) on year where k ≈ 1), falling back to a linear Levenshtein
            // scan only when the dictionary misses AND fuzzy matching is enabled —
            // that scan cannot be dictionary-optimized.
            var filmsByName: [String: [FilmRow]] = [:]
            for f in filmData { filmsByName[f.name, default: []].append(f) }

            var filmsByAltTitle: [String: [FilmRow]] = [:]
            for f in filmData {
                for alt in f.alternateTitles { filmsByAltTitle[alt, default: []].append(f) }
            }

            let namePass = MatchPass(
                label: "primary name",
                index: filmsByName,
                matchesFuzzily: { FilmTitleComparison.titlesAreSimilar($0.name, $1) },
                logsAlternateTitles: false)
            let altTitlePass = MatchPass(
                label: "alternateTitle",
                index: filmsByAltTitle,
                matchesFuzzily: { film, title in
                    film.alternateTitles.contains {
                        FilmTitleComparison.titlesAreSimilar($0, title) } },
                logsAlternateTitles: true)

            // Locates the library film an incoming rating belongs to under the given
            // pass, returning the match and whether it required fuzzy title matching.
            func findMatch(for rating: ParsedRating,
                using pass: MatchPass) -> (film: FilmRow, wasFuzzy: Bool)? {
                if let candidates = pass.index[rating.title],
                   let exactMatch = candidates.first(where: {
                       FilmComparison.yearsMatch($0.year, rating.year,
                           allowFuzzy: useFuzzyYearMatching) }) {
                    return (exactMatch, false)
                }
                guard useFuzzyMatching else { return nil }
                if let fuzzyMatch = filmData.first(where: { film in
                    FilmComparison.yearsMatch(film.year, rating.year,
                        allowFuzzy: useFuzzyYearMatching)
                        && pass.matchesFuzzily(film, rating.title)
                }) {
                    return (fuzzyMatch, true)
                }
                return nil
            }

            // Applies a matched rating: queues the film's new rating when it should
            // change, otherwise counts it as a skip. Identical for both passes; only
            // the log's "Source:" line differs.
            func recordMatch(_ match: (film: FilmRow, wasFuzzy: Bool),
                for rating: ParsedRating, pass: MatchPass) async {
                let film = match.film
                let existingRating = film.existingRating
                // Existing rating present and either unchanged or locked by the
                // "update existing ratings" preference — nothing to write.
                if existingRating != 0 && !(allowUpdates && existingRating != rating.rating) {
                    localDuplicateSkippedCount += 1
                    localDuplicateTitles.append(film.name)
                    return
                }

                localUpdates.append((film.id, rating.rating))
                if existingRating != 0 {
                    localUpdatedCount += 1
                    localUpdatedTitles.append(film.name)
                } else {
                    localImportedCount += 1
                    localAddedTitles.append(film.name)
                }

                guard debugLogging else { return }
                let matchType = match.wasFuzzy ? "FUZZY MATCH" : "EXACT MATCH"
                let altSuffix = pass.logsAlternateTitles
                    ? " [alt: '\(film.alternateTitles.isEmpty ? "(none)" : film.alternateTitles.joined(separator: ", "))']"
                    : ""
                let ratingState = existingRating != 0
                    ? "existing rating: \(existingRating)" : "no existing rating"
                let action = existingRating != 0
                    ? "Rating will be UPDATED from \(existingRating) to \(rating.rating)"
                    : "Rating will be APPLIED"
                await MainActor.run {
                    Self.log("FILM MATCHED - \(matchType)")
                    Self.log("Source: ratings import (\(pass.label))")
                    Self.log("Input: '\(rating.title)' (\(rating.year)) - rating: \(rating.rating)")
                    Self.log("Matched: '\(film.name)'\(altSuffix) (\(film.year)) - \(ratingState)")
                    Self.log("ACTION: \(action)")
                    Self.log("---")
                }
            }

            // FIRST PASS: Match against primary film names
            // Anything unmatched here is retried against alternate titles below.
            var unmatchedRatings: [ParsedRating] = []
            for rating in ratingsToProcess {
                localCurrentRating += 1

                if let match = findMatch(for: rating, using: namePass) {
                    await recordMatch(match, for: rating, pass: namePass)
                } else {
                    unmatchedRatings.append(rating)
                }

                // Sync local updates to MainActor every 100 ratings to keep batch size reasonable
                if localCurrentRating % 100 == 0 && !localUpdates.isEmpty {
                    // Create immutable copy to avoid concurrency issues
                    let updatesToSync = localUpdates
                    localUpdates.removeAll()

                    await MainActor.run {
                        self.pendingUpdates.append(contentsOf: updatesToSync)
                    }
                }

                // Check cancellation and update progress every 50 ratings.
                // Cancellation is checked here rather than per-rating to avoid hundreds
                // of MainActor hops; response time remains well under 1 second.
                if localCurrentRating % 50 == 0 {
                    if await checkCancellationAndTeardownIfNeeded(logSuffix: "") {
                        return (0, 0, 0, 0, [String](), [String](), [String]())
                    }

                    let currentCount = localCurrentRating
                    let importedCount = localImportedCount
                    let updatedCount = localUpdatedCount
                    let notFoundCount = localNotFoundCount
                    let dupSkipCount = localDuplicateSkippedCount

                    await MainActor.run {
                        self.progressDelegate?.didUpdateRatingsProgress(
                            currentRating: currentCount,
                            imported: importedCount,
                            updated: updatedCount,
                            notFound: notFoundCount,
                            duplicateSkipped: dupSkipCount
                        )
                    }

                    // Yield to allow UI updates
                    await Task.yield()
                }
            }

            // SECOND PASS: Try matching unmatched ratings against alternateTitle
            if !unmatchedRatings.isEmpty {
                if debugLogging {
                    // Capture immutable count
                    let unmatchedCount = unmatchedRatings.count
                    await MainActor.run {
                        Self.log("---")
                        Self.log("SECOND PASS: Attempting to match \(unmatchedCount) unmatched ratings using alternateTitle field")
                        Self.log("---")
                    }
                }

                var secondPassCount = 0
                for rating in unmatchedRatings {
                    secondPassCount += 1

                    // Check cancellation periodically (every 50 ratings), same as first pass.
                    if secondPassCount % 50 == 0 {
                        if await checkCancellationAndTeardownIfNeeded(logSuffix: " during second pass") {
                            return (0, 0, 0, 0, [String](), [String](), [String]())
                        }
                    }

                    if let match = findMatch(for: rating, using: altTitlePass) {
                        await recordMatch(match, for: rating, pass: altTitlePass)
                    } else {
                        // Still no match found even with alternateTitle
                        localNotFoundCount += 1

                        if debugLogging {
                            await MainActor.run {
                                Self.log("NO MATCH FOUND")
                                Self.log("Source: ratings import (tried both name and alternateTitle)")
                                Self.log("Input: '\(rating.title)' (\(rating.year)) - rating: \(rating.rating)")
                                Self.log("ACTION: Rating DISCARDED (no matching film in library)")
                                Self.log("---")
                            }
                        }
                    }
                }
            }

            // Sync any remaining local updates to MainActor
            if !localUpdates.isEmpty {
                // Create immutable copy to avoid concurrency issues
                let updatesToSync = localUpdates

                await MainActor.run {
                    self.pendingUpdates.append(contentsOf: updatesToSync)
                }
            }

            return (localImportedCount, localUpdatedCount, localNotFoundCount, localDuplicateSkippedCount,
                localAddedTitles, localUpdatedTitles, localDuplicateTitles)
        }.value

        // Cancel batch task and flush any remaining updates
        updateBatchTask?.cancel()
        updateBatchTask = nil
        await flushPendingUpdates()

        // Check if import was canceled before final event.
        if isCanceled {
            Self.log("Import canceled before completion event - aborting")
            return }

        // Give SwiftData time (300ms) to complete all operations.
        try? await Task.sleep(for: .milliseconds(300))

        // applyImportedRatingUpdate already mutates MemoryStore and fires AppEventBus
        // events per-film; a full reloadFilms() is not needed and would re-sort/re-filter
        // all films unnecessarily. The view refreshes naturally from @Published properties.
        progressDelegate?.didCompleteRatingsImport(
            imported: finalImportedCount,
            updated: finalUpdatedCount,
            notFound: finalNotFoundCount,
            duplicateSkipped: finalDuplicateSkippedCount,
            addedTitles: finalAddedTitles,
            updatedTitles: finalUpdatedTitles,
            duplicateTitles: finalDuplicateTitles)

        Self.log("Import summary: \(finalImportedCount) imported, \(finalUpdatedCount) updated, \(finalNotFoundCount) not found, \(finalDuplicateSkippedCount) skipped") }

    // MARK: - Batch Update Management
    private func startBatchUpdateTask() {
        updateBatchTask?.cancel()

        updateBatchTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(updateBatchInterval))

                guard !Task.isCancelled else { break }

                await self.flushPendingUpdates()
            }
        }
    }

    private func flushPendingUpdates() async {
        guard !pendingUpdates.isEmpty, let coordinator = dataCoordinator else { return }

        let updates = pendingUpdates
        pendingUpdates.removeAll()

        Self.log("Flushing \(updates.count) batched rating updates...")

        // Delegate the whole batch to DataCoordinator, which applies every mutation to the
        // MemoryStore Films and dispatches ONE background transaction via DataManager.
        // No Film objects are accessed here — the importer works purely with IDs and values.
        coordinator.applyImportedRatingUpdates(
            updates.map { (filmID: $0.0, rating: $0.1) })
    }
}
