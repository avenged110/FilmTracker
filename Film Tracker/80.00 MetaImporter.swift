// MARK: - MetaImporter.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Handles file selection and orchestrates the metadata import workflow, parsing incoming
// files and writing results through DataCoordinator with batched progress updates to
// keep the UI responsive during large imports.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Progress Delegate Protocol
// Shared by both import delegates (see RatingsImporterProgressDelegate). Covers the
// pre-processing lifecycle that is identical for every import type: a session is
// created once the user has actually chosen something to import, and abandoned if
// the selection turns out to contain no work. Declaring these here rather than
// down-casting the delegate to its concrete ImportProgress type keeps the importers
// dependent only on the protocol they were handed.
@MainActor
protocol ImportSessionReporting: AnyObject {
    func createSession(for category: ImportsCategory)
    // Called instead of didStart…/didComplete… when an import ends before any item
    // is processed (picker dismissed, or nothing importable in the selection), so
    // ImportProgress can drop the active-type state it optimistically set.
    func importAbandonedBeforeStart()
}

@MainActor
protocol MetaImporterProgressDelegate: ImportSessionReporting {
    func didStartImporting(totalFiles: Int)
    // `title` is the value written to the imported Film model object's "name" field
    // for the item just processed (added, updated, or duplicate-skipped). It is `nil`
    // for failed items, since a title cannot be reliably extracted from a file that
    // failed to parse.
    func didUpdateProgress(currentFile: Int, success: Bool, failedFileName: String?,
        wasDuplicate: Bool, wasUpdated: Bool, title: String?)
    func didCompleteImporting()
}

@MainActor
final class MetaImporter: Loggable {
    nonisolated static let logTag = "[MetaImporter]"

    /// True while processSelection's off-main folder scan runs. See ImportProgress.beginImport.
    private(set) var isScanningSelection = false

    private var parser: MetaParser?
    private weak var dataCoordinator: DataCoordinator?
    private weak var progressDelegate: (any MetaImporterProgressDelegate)?
    private var isCanceled = false

    // Counters used only for the end-of-import summary log; the authoritative
    // per-item tallies shown in the UI are accumulated by ImportProgress from the
    // didUpdateProgress callbacks below.
    private var duplicateCount = 0
    private var updatedCount = 0

    init(dataCoordinator: DataCoordinator,
        progressDelegate: (any MetaImporterProgressDelegate)? = nil) {
        self.dataCoordinator = dataCoordinator
        self.progressDelegate = progressDelegate }

    // MARK: - Public Interface
    func beginImport() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let config = OpenPanelConfiguration(canChooseFiles: true,
                canChooseDirectories: true, allowsMultipleSelection: true,
                allowedContentTypes: [UTType(filenameExtension: "mp4")!,
                    UTType(filenameExtension: "m4v")!], title: nil,
                message: "Select Video Files or Folder", prompt: "Select")

            let selection = await OpenPanelPresenter.present(configuration: config,
                attachedTo: NSApp.keyWindow)
            guard case let .urls(urls) = selection, !urls.isEmpty else {
                self.progressDelegate?.importAbandonedBeforeStart()
                return }

            await self.processSelection(urls) } }

    func cancelImport() async {
        Self.log("Import canceled by user")
        isCanceled = true
        if let parser = parser { await parser.rollbackPendingImports() }
        parser = nil }

    // MARK: - File Processing
    private func processSelection(_ urls: [URL]) async {
        guard let coordinator = dataCoordinator else { return }
        isCanceled = false

        // Collect all valid video files. Off the main actor: a chosen folder is walked
        // recursively (when subfolder scanning is on), which on a large or network volume
        // can take a noticeable time.
        // While it runs, nothing marks the import as started yet (didStartImporting needs
        // the file count), so ImportProgress.beginImport reads isScanningSelection to refuse
        // a second import — the window the scan used to close by blocking the main thread.
        let scanSubfolders = Preferences.importScanSubfolders
        isScanningSelection = true
        let videoFiles = await Task.detached(priority: .userInitiated) {
            Self.collectVideoFiles(in: urls, scanSubfolders: scanSubfolders)
        }.value
        isScanningSelection = false
        // The session is created only now, once the selection is known to contain at
        // least one importable file. Creating it earlier (before this scan) left a
        // permanently unfinished, all-zero session card behind whenever the user
        // picked a folder with no MP4/M4V files in it.
        guard !videoFiles.isEmpty else {
            progressDelegate?.importAbandonedBeforeStart()
            return }
        progressDelegate?.createSession(for: .metadata)

        // Initialize
        parser = MetaParser()
        duplicateCount = 0
        updatedCount = 0

        progressDelegate?.didStartImporting(totalFiles: videoFiles.count)
        let allowUpdates = Preferences.allowUpdatesForDuplicateImports
        
        let parserRef = parser

        // Fetch the existing library ONCE for the duration of this import batch,
        // rather than letting FilmComparison.existingFilm pull a fresh copy out of
        // MemoryStore on every file. Library titles/years don't change mid-import,
        // so reusing this snapshot for all files in the loop below is safe and
        // avoids an O(files × libraryCount) cost on large imports.
        let existingLibraryFilms = coordinator.getAllFilms()

        // Process files with batched progress updates
        for (index, fileURL) in videoFiles.enumerated() {
            if isCanceled {
                Self.log("Import canceled")
                break
            }
            
            // Yield to UI thread every 5 files to prevent blocking
            if index % 5 == 0 {
                await Task.yield()
            }

            // Parse file
            let result = await parserRef?.parseFile(fileURL)
            
            guard case .success = result else {
                // Report errors immediately
                progressDelegate?.didUpdateProgress(currentFile: index + 1, success: false,
                    failedFileName: fileURL.lastPathComponent, wasDuplicate: false,
                    wasUpdated: false, title: nil)
                continue
            }

            // Get parsed film
            guard let pendingFilms = parserRef?.getPendingFilms(),
                  let newFilm = pendingFilms.last else { continue }
            
            // Check for duplicate using FilmComparison so that the fuzzy-matching
            // preference (Preferences.fuzzyImportMatching) is honored consistently
            // with the ratings import path. A plain == comparison silently bypasses
            // fuzzy matching even when the user has enabled it.
            let matchedFilmID = FilmComparison.existingFilm(
                matchingTitle: newFilm.name,
                year: newFilm.releaseYear,
                in: existingLibraryFilms)?.id

            var itemWasUpdated = false
            // Set when the new file's artwork is handed to the existing entry below,
            // which means the extracted poster file must be kept rather than deleted.
            var posterWasPropagated = false

            if let existingID = matchedFilmID {
                // Duplicate found
                if allowUpdates, var existing = coordinator.getFilm(existingID) {
                    var fieldCount = updateExistingFilm(&existing, with: newFilm)
                    // Propagate poster if the existing entry has none but the new file
                    // contains artwork. The poster file is already on disk at this point;
                    // skip cleanup below so it is retained.
                    if !newFilm.posterUID.isEmpty && existing.posterUID.isEmpty {
                        existing.posterUID = newFilm.posterUID
                        posterWasPropagated = true
                        // Keeps a cancel's rollback from deleting the file this film now uses.
                        parserRef?.adoptPoster(newFilm.posterUID)
                        fieldCount += 1
                        Self.log("UPDATE: posterUID propagated from new import to existing entry")
                    }
                    if fieldCount > 0 {
                        Self.log("UPDATED \(fieldCount) field(s) for '\(newFilm.name)'")
                        // Stamp lastModified so the film appears in "Recently Updated".
                        existing.lastModified = StorageDateFormatters.timestamp.format(Date())
                        // Persist the mutated snapshot immediately via coordinator.
                        await coordinator.updateFilm(existing)
                        updatedCount += 1
                        itemWasUpdated = true
                    } else {
                        // Matched but no fields differed — true duplicate skip
                        duplicateCount += 1
                    }
                } else {
                    // Updates disabled or couldn't retrieve film — duplicate skip
                    duplicateCount += 1
                }

                // Remove duplicate from pending queue. Only clean up the poster file
                // if it was NOT handed to the existing entry just above.
                parserRef?.removeLastPendingFilm()
                if !newFilm.posterUID.isEmpty && !posterWasPropagated,
                   let folderURL = Preferences.posterImagesFolderURL {
                    let posterURL = folderURL.appendingPathComponent("\(newFilm.posterUID).jpg")
                    try? FileManager.default.removeItem(at: posterURL)
                }
            }

            // A second file of a film already queued earlier in THIS import (an .mp4 and an
            // .m4v of the same title, say). `existingLibraryFilms` predates the import, so
            // without this both copies were committed as separate films. The earlier file
            // wins; this one is skipped as a duplicate, exactly like a library match with
            // updates disabled.
            var matchedPendingFilm = false
            if matchedFilmID == nil,
               FilmComparison.existingFilm(matchingTitle: newFilm.name, year: newFilm.releaseYear,
                                           in: Array(pendingFilms.dropLast())) != nil {
                matchedPendingFilm = true
                duplicateCount += 1
                parserRef?.removeLastPendingFilm()
                if !newFilm.posterUID.isEmpty, let folderURL = Preferences.posterImagesFolderURL {
                    let posterURL = folderURL.appendingPathComponent("\(newFilm.posterUID).jpg")
                    try? FileManager.default.removeItem(at: posterURL)
                }
            }
            let wasDuplicate = matchedFilmID != nil || matchedPendingFilm

            progressDelegate?.didUpdateProgress(
                currentFile: index + 1,
                success: !wasDuplicate,
                failedFileName: nil,
                wasDuplicate: wasDuplicate,
                wasUpdated: itemWasUpdated,
                title: newFilm.name)
        }
        
        await finishImport()
    }

    // MARK: - Field Comparison for Updates
    /// Applies fields from a parsed FilmSnapshot to an existing in-memory FilmSnapshot,
    /// recording how many fields changed. The caller must follow up with
    /// coordinator.updateFilm(_:) to persist via the background context.
    @discardableResult
    private func updateExistingFilm(_ existing: inout FilmSnapshot, with new: FilmSnapshot) -> Int {
        var fieldsUpdated = 0

        // Local helper capturing `existing`/`fieldsUpdated` by reference (both are
        // local to this call, so the non-escaping capture is safe under Swift 6
        // strict concurrency). Each field is written through exactly once, which
        // removes the copy/paste risk of the field list previously being spelled
        // out as 23 nearly identical if-blocks (e.g. a stray field name typo
        // silently comparing/writing the wrong property).
        // `showValue: false` reproduces the original behavior for list-valued
        // fields, which logged only "UPDATE: <field>" without dumping full
        // array contents (cast/director lists can be long); scalar fields keep
        // logging their old/new values as before.
        func update<T: Equatable>(_ keyPath: WritableKeyPath<FilmSnapshot, T>, _ name: String,
            showValue: Bool = true) {
            let oldValue = existing[keyPath: keyPath]
            let newValue = new[keyPath: keyPath]
            guard oldValue != newValue else { return }
            if showValue {
                Self.log("UPDATE: \(name) '\(oldValue)' → '\(newValue)'")
            } else {
                Self.log("UPDATE: \(name)")
            }
            existing[keyPath: keyPath] = newValue
            fieldsUpdated += 1
        }

        // Field list is identical to the original hand-written comparisons —
        // same 22 fields, same order, same "only these fields count toward an
        // update" semantics (posterUID is intentionally handled separately by
        // the caller, exactly as before).
        update(\.aspectRatio, "aspectRatio")
        update(\.digitalSource, "digitalSource")
        update(\.digitalVersion, "digitalVersion")
        update(\.subtitles, "subtitles")
        update(\.color, "color")
        update(\.edited, "edited")
        update(\.frameRate, "frameRate")
        update(\.comments, "comments")
        update(\.genre, "genre")
        update(\.releaseDate, "releaseDate")
        update(\.descriptionText, "descriptionText", showValue: false)
        update(\.rating, "rating")
        update(\.studio, "studio")
        update(\.cast, "cast", showValue: false)
        update(\.directors, "directors", showValue: false)
        update(\.producers, "producers", showValue: false)
        update(\.executiveProducers, "executiveProducers", showValue: false)
        update(\.screenwriters, "screenwriters", showValue: false)
        update(\.encodingTool, "encodingTool", showValue: false)
        update(\.libraryHBRFValue, "libraryHBRFValue")
        update(\.composer, "composer", showValue: false)
        update(\.sortName, "sortName")

        return fieldsUpdated }

    private nonisolated static func collectVideoFiles(in urls: [URL], scanSubfolders: Bool) -> [URL] {
        var videoFiles: [URL] = []
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            if url.isExistingDirectory {
                videoFiles.append(contentsOf: scanDirectory(url, scanSubfolders: scanSubfolders))
            } else if isValidVideoFile(url) { videoFiles.append(url) } }
        return videoFiles }

    private nonisolated static func scanDirectory(_ url: URL, scanSubfolders: Bool) -> [URL] {
        var files: [URL] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: scanSubfolders ? [] : [.skipsSubdirectoryDescendants]) else { return files }

        for case let fileURL as URL in enumerator {
            if isValidVideoFile(fileURL) { files.append(fileURL) } }
        return files }

    private nonisolated static func isValidVideoFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "mp4" || ext == "m4v" }

    // MARK: - Import Lifecycle
    private func finishImport() async {
        guard let parser = parser, let coordinator = dataCoordinator else { return }
        
        let pendingFilms = parser.getPendingFilms()
        Self.log("Committing \(pendingFilms.count) new films...")

        // Applied to memory now; the database write runs in the background, and a
        // failure there rolls the films back out and raises the persistence alert.
        coordinator.importFilms(pendingFilms)
        Self.log("Committed \(pendingFilms.count) new imports")

        // Add posters to cache
        let posterUIDs = pendingFilms.compactMap { film -> String? in
            guard !film.posterUID.isEmpty else { return nil }
            return film.posterUID
        }
        if !posterUIDs.isEmpty {
            // PosterCache.addPosters() already logs its own start/progress/
            // completion bookends (with duration) for this exact operation —
            // no separate log needed here to avoid restating the same count.
            await PosterCache.shared.addPosters(posterUIDs)
        }

        if updatedCount > 0 { Self.log("Updated \(updatedCount) existing film(s)") }
        if duplicateCount > 0 { Self.log("Skipped \(duplicateCount) duplicate(s)") }

        parser.clearPendingFilms()
        
        try? await Task.sleep(for: .milliseconds(100))

        // Don't reload all 1300+ films. DataCoordinator.importFilms()
        // already added new films to MemoryStore. The view will refresh
        // naturally from @Published properties in DataCoordinator.
        // (Removed: await coordinator.loadFilmsImmediate())
        
        Self.log("Import complete - new films already in memory")

        progressDelegate?.didCompleteImporting()
        self.parser = nil
    }
}
