// MARK: - ImportProgress.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Manages background import progress tracking for ImportsView.swift

import SwiftUI
import CoreData

@MainActor
@Observable
final class ImportProgress: Loggable {
    nonisolated static let logTag = "[ImportProgress]"

    // Global singleton.
    static let shared = ImportProgress()

    // Completion status.
    enum CompletionStatus { case none; case success; case successWithErrors }

    // Import state tracking.
    var isImporting = false
    // True for 800ms after isImporting drops to false at completion.
    // Downstream UI reads (isImporting || isUILingering) so the button,
    // status label, and session list all stay locked until the progress
    // bar has had time to animate to 100% before anything unlocks.
    var isUILingering = false
    var completionStatus: CompletionStatus = .none
    var currentSessionID: UUID?
    var currentFile = 0
    var totalFiles = 0
    var successCount = 0
    var updatedCount = 0
    var duplicateCount = 0
    var notFoundCount = 0
    var errorFiles: [String] = []
    // Titles (the imported Film model's "name" field value) for items added, updated,
    // or skipped as duplicates during the active/most recent session. Persisted onto
    // ImportSession alongside the counts above and surfaced in ImportsView's per-card
    // "Details" popover.
    var addedTitles: [String] = []
    var updatedTitles: [String] = []
    var duplicateTitles: [String] = []
    // Captured once when an import starts so ActiveImportRow can display a stable date
    // string without calling Date() on every re-render during the high-frequency update
    // period. Set in the two didStart... delegate callbacks; cleared in reset().
    var importStartDate: Date?

    private weak var dataCoordinator: DataCoordinator?
    private weak var modelContext: NSManagedObjectContext?
    private var metaImporter: MetaImporter?
    private var ratingsImporter: RatingsImporter?
    var activeImportType: ImportsCategory?
    var lastCompletedImportType: ImportsCategory?
    
    private var glyphClearTask: Task<Void, Never>?
    
    // Throttle ALL updates (UI and database) to prevent hitching and menu dismissal.
    private var lastUIUpdateTime: Date = .distantPast
    private let minUIUpdateInterval: TimeInterval = 0.5 // 500ms between all updates
    private var pendingUIUpdateTask: Task<Void, Never>?
    
    // Track pending progress values to batch updates.
    private var pendingCurrentFile: Int?
    private var pendingSuccessCount: Int?
    private var pendingUpdatedCount: Int?
    private var pendingDuplicateCount: Int?
    private var pendingNotFoundCount: Int?
    private var pendingErrorFiles: [String]?
    private var pendingAddedTitles: [String]?
    private var pendingUpdatedTitles: [String]?
    private var pendingDuplicateTitles: [String]?

    // MARK: - Initialization
    // Private to enforce singleton usage — every consumer goes through `shared`.
    private init() {}

    // Allow modelContext to be attached; idempotent after first assignment.
    func attachContext(_ context: NSManagedObjectContext) {
        guard modelContext == nil else { return }
        self.modelContext = context
    }

    // Allow dataCoordinator to be attached; idempotent after first assignment.
    func attachCoordinator(_ coordinator: DataCoordinator) {
        guard dataCoordinator == nil else { return }
        self.dataCoordinator = coordinator
    }
    
    // MARK: - Context Resolution
    // Single canonical resolver used by all session-management methods.
    // Prefers the directly-attached modelContext; falls back to the coordinator's
    // main context, which is equivalent when both originate from the same container.
    private var resolvedContext: NSManagedObjectContext? {
        if let ctx = modelContext { return ctx }
        if let coordinator = dataCoordinator { return coordinator.persistentContainer.viewContext }
        return nil
    }
    
    // MARK: - View Tracking
    // Whether the Imports screen is on-screen. ImportsState owns this flag (MenuBar
    // and the toolbar menu read it there too); this is only a read-through so the
    // auto-clear behavior below has a single source of truth to consult.
    private var isViewingImports: Bool { ImportsState.shared.isViewingImports }

    // Called by ImportsView after it has updated ImportsState.isViewingImports.
    func viewingImportsDidChange(_ isViewing: Bool) {
        if isViewing {
            // Clear completion status immediately when user views the Imports page.
            if completionStatus != .none {
                clearCompletionStatus()
            }
            // Start auto-clear timer if glyph is showing.
            scheduleGlyphAutoClear()
        } else {
            // Cancel auto-clear if navigating away.
            glyphClearTask?.cancel()
            glyphClearTask = nil
        }
    }
    
    private func scheduleGlyphAutoClear() {
        // Cancel any existing timer.
        glyphClearTask?.cancel()
        
        // Only schedule if we have a completion status to clear.
        guard completionStatus != .none, isViewingImports else { return }
        
        glyphClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, isViewingImports, !isImporting else { return }
            Self.log("Auto-clearing completion status after 5 seconds")
            completionStatus = .none
        }
    }

    // MARK: - Begin Import
    func beginImport(of type: ImportsCategory) {
        guard let coordinator = dataCoordinator else { return }
        // A metadata import still scanning its selection, or a ratings import still parsing
        // its file, has not reported a start, so the import button is not locked yet.
        // Starting another here would reset this object under it and run two imports into
        // one session.
        if metaImporter?.isScanningSelection == true || ratingsImporter?.isParsingSelection == true {
            log("Import request ignored: the previous selection is still being read")
            return
        }
        reset()
        self.activeImportType = type

        switch type {
        case .metadata:
            let importer = MetaImporter(dataCoordinator: coordinator,
                progressDelegate: self)
            self.metaImporter = importer
            importer.beginImport()
        case .ratings:
            let importer = RatingsImporter(dataCoordinator: coordinator)
            importer.progressDelegate = self
            self.ratingsImporter = importer
            importer.beginImport() } }

    // MARK: - Session Management
    // Create a session after successful file selection.
    func createSession(for category: ImportsCategory) {
        guard let context = resolvedContext else {
            log("Failed to create import session: No context available")
            return
        }

        let session = ImportSession(importType: category.rawValue,
            isCompleted: false, isCanceled: false)
        context.insert(session)
        
        do {
            try context.save()
            currentSessionID = session.id
            Self.log("Created import session: \(session.id)")
        } catch {
            log("Failed to create import session: \(error)") } }

    // Called by an importer that ends before any item is processed — the file
    // picker was dismissed, or the selection held nothing importable. No session
    // exists yet in either case (importers create one only once they have work),
    // so this just releases the active-type state that beginImport optimistically
    // set, which would otherwise stay stale until the next import.
    func importAbandonedBeforeStart() {
        activeImportType = nil }

    // MARK: - Cancel Import
    func cancelImport() {
        // Dispatch cancellation to the underlying importer (if any), then perform
        // shared teardown regardless of which importer was active.
        if activeImportType == .metadata, let importer = metaImporter {
            Task {
                await importer.cancelImport()
                finalizeCancellation() }
        } else if activeImportType == .ratings, let importer = ratingsImporter {
            Task {
                await importer.cancelImport()
                finalizeCancellation() }
        } else {
            finalizeCancellation() } }

    // Shared teardown after any cancel path.
    private func finalizeCancellation() {
        updateSessionAsCanceled()
        isImporting = false
        isUILingering = false
        activeImportType = nil }

    // Shared fetch-by-ID used by all three session-persistence methods below.
    // Centralizing this removes three copies of the same descriptor-construction
    // and context-resolution boilerplate; each call site keeps its own do/catch
    // so error logging stays specific to what was being attempted.
    private func fetchCurrentSession(context: NSManagedObjectContext) throws -> ImportSession? {
        guard let sessionID = currentSessionID else { return nil }
        let descriptor = ImportSession.request(.equals("id", sessionID))
        return try context.fetch(descriptor).first
    }

    // Writes the counts/titles common to all three persistence paths.
    // `zeroSuccessAndUpdated` mirrors the cancellation-only behavior of the
    // original updateSessionAsCanceled: success/updated counts and their title
    // arrays are cleared (work-in-progress that didn't complete isn't counted
    // as a success), while error/duplicate/notFound data — which reflects real
    // outcomes already observed — is preserved exactly as before.
    private func writeSessionCounts(_ session: ImportSession, zeroSuccessAndUpdated: Bool) {
        session.totalItems = totalFiles
        session.errorCount = errorFiles.count
        session.errorFileNames = errorFiles
        session.duplicateCount = duplicateCount
        session.duplicateTitles = duplicateTitles
        session.notFoundCount = notFoundCount
        if zeroSuccessAndUpdated {
            session.successCount = 0
            session.updatedCount = 0
            session.addedTitles = []
            session.updatedTitles = []
        } else {
            session.successCount = successCount
            session.updatedCount = updatedCount
            session.addedTitles = addedTitles
            session.updatedTitles = updatedTitles
        }
    }

    private func updateSessionAsCanceled() {
        guard let context = resolvedContext else { return }
        do {
            if let session = try fetchCurrentSession(context: context) {
                session.isCanceled = true
                session.isCompleted = false
                writeSessionCounts(session, zeroSuccessAndUpdated: true)
                try context.save()
                Self.log("Session marked as canceled: processed \(currentFile) of \(totalFiles) items") }
        } catch { log("Failed to update session as canceled: \(error)") } }

    private func updateSessionProgress() {
        guard let context = resolvedContext else { return }
        do {
            if let session = try fetchCurrentSession(context: context) {
                writeSessionCounts(session, zeroSuccessAndUpdated: false)
                try context.save() }
        } catch { log("Failed to update session progress: \(error)") } }

    private func completeSession() {
        guard let context = resolvedContext else { return }
        do {
            if let session = try fetchCurrentSession(context: context) {
                session.isCompleted = true
                writeSessionCounts(session, zeroSuccessAndUpdated: false)
                try context.save()
                Self.log("Session completed: \(successCount) imported, \(updatedCount) updated, \(errorFiles.count) errors") }
        } catch { log("Failed to complete session: \(error)") } }

    // MARK: - Completion Status
    func clearCompletionStatus() {
        completionStatus = .none
        glyphClearTask?.cancel()
        glyphClearTask = nil
    }

    func reset() {
        isImporting = false
        isUILingering = false
        completionStatus = .none
        currentSessionID = nil
        totalFiles = 0
        resetTallies()
        metaImporter = nil
        ratingsImporter = nil
        activeImportType = nil
        importStartDate = nil
        glyphClearTask?.cancel()
        glyphClearTask = nil
        
        // Cancel any pending UI updates.
        pendingUIUpdateTask?.cancel()
        pendingUIUpdateTask = nil
        clearPendingState()
    }

    /// Zeroes the live tallies a run accumulates. Shared by `reset()` and `beginRun`.
    private func resetTallies() {
        currentFile = 0
        successCount = 0
        updatedCount = 0
        duplicateCount = 0
        notFoundCount = 0
        errorFiles.removeAll()
        addedTitles.removeAll()
        updatedTitles.removeAll()
        duplicateTitles.removeAll()
    }

    /// The start of a run. Metadata and ratings imports begin identically.
    private func beginRun(totalItems: Int) {
        isImporting = true
        totalFiles = totalItems
        resetTallies()
        importStartDate = Date()
        lastUIUpdateTime = Date() // Reset throttle timer.
        updateSessionProgress()
    }

    /// Drops every pending slot without applying it.
    private func clearPendingState() {
        pendingCurrentFile = nil
        pendingSuccessCount = nil
        pendingUpdatedCount = nil
        pendingDuplicateCount = nil
        pendingNotFoundCount = nil
        pendingErrorFiles = nil
        pendingAddedTitles = nil
        pendingUpdatedTitles = nil
        pendingDuplicateTitles = nil
    }
    
    // MARK: - Pending State Flush
    // Applies all accumulated pending values to the live @Observable properties
    // and clears the pending slots. Called both from the throttled update path
    // and immediately at completion/cancellation.
    private func flushPendingState() {
        if let current = pendingCurrentFile { currentFile = current }
        if let success = pendingSuccessCount { successCount = success }
        if let updated = pendingUpdatedCount { updatedCount = updated }
        if let duplicate = pendingDuplicateCount { duplicateCount = duplicate }
        if let notFound = pendingNotFoundCount { notFoundCount = notFound }
        if let errors = pendingErrorFiles { errorFiles = errors }
        if let added = pendingAddedTitles { addedTitles = added }
        if let updatedT = pendingUpdatedTitles { updatedTitles = updatedT }
        if let duplicateT = pendingDuplicateTitles { duplicateTitles = duplicateT }
        clearPendingState()
    }
    
    // MARK: - Completion Finalization
    // Shared logic for both metadata and ratings import completion.
    // Cancels any pending throttled update, flushes remaining pending state,
    // then waits 200ms for layout to settle before committing final status.
    private func flushAndFinalize() {
        pendingUIUpdateTask?.cancel()
        flushPendingState()
        
        Task { @MainActor in
            // Brief delay to let any in-flight SwiftUI layout pass complete
            // before transitioning the import row to its completed state.
            try? await Task.sleep(for: .milliseconds(200))

            self.isImporting = false
            // Lock the rest of the UI (button, status label, session list) for
            // 800ms so they all clear in sync with the progress bar reaching 100%.
            self.isUILingering = true
            self.lastCompletedImportType = self.activeImportType
            // For ratings imports, "not found" items are not processing errors,
            // so completion status only reflects actual errorFiles entries.
            self.completionStatus = self.errorFiles.isEmpty ? .success : .successWithErrors
            self.completeSession()
            
            if self.isViewingImports {
                self.scheduleGlyphAutoClear()
            }
            
            try? await Task.sleep(for: .milliseconds(800))
            self.isUILingering = false
            self.activeImportType = nil
        }
    }
    
    // MARK: - Throttled UI Update Helper
    // Schedules a throttled UI and database update, batching all @Observable
    // property writes to at most one flush per 500ms. This prevents UI hitching
    // and spurious menu dismissals during large imports.
    private func scheduleThrottledUpdate() {
        // Cancel any pending update.
        pendingUIUpdateTask?.cancel()
        
        pendingUIUpdateTask = Task { @MainActor in
            // Calculate wait time based on last update.
            let now = Date()
            let timeSinceLastUpdate = now.timeIntervalSince(lastUIUpdateTime)
            let waitTime = max(0, minUIUpdateInterval - timeSinceLastUpdate)
            
            if waitTime > 0 {
                try? await Task.sleep(for: .seconds(waitTime))
            }
            
            guard !Task.isCancelled else { return }
            
            // Apply all pending values atomically.
            flushPendingState()
            
            // Persist progress to the database (non-UI operation).
            updateSessionProgress()
            
            lastUIUpdateTime = Date()
        }
    }
}

// MARK: - MetaImporter Progress Delegate
extension ImportProgress: MetaImporterProgressDelegate {
    func didStartImporting(totalFiles: Int) {
        beginRun(totalItems: totalFiles)
    }

    func didUpdateProgress(currentFile: Int, success: Bool, failedFileName: String?,
        wasDuplicate: Bool, wasUpdated: Bool, title: String?) {
        // Accumulate into pending state — do not write @Observable properties directly.
        // All writes are batched and applied via scheduleThrottledUpdate to prevent
        // UI hitching and spurious menu dismissals during large imports.
        pendingCurrentFile = currentFile
        
        if !success, let fileName = failedFileName {
            var errors = pendingErrorFiles ?? errorFiles
            errors.append(fileName)
            pendingErrorFiles = errors
        } else if wasDuplicate {
            if wasUpdated {
                pendingUpdatedCount = (pendingUpdatedCount ?? updatedCount) + 1
                if let title {
                    var titles = pendingUpdatedTitles ?? updatedTitles
                    titles.append(title)
                    pendingUpdatedTitles = titles
                }
            } else {
                pendingDuplicateCount = (pendingDuplicateCount ?? duplicateCount) + 1
                if let title {
                    var titles = pendingDuplicateTitles ?? duplicateTitles
                    titles.append(title)
                    pendingDuplicateTitles = titles
                }
            }
        } else if success {
            pendingSuccessCount = (pendingSuccessCount ?? successCount) + 1
            if let title {
                var titles = pendingAddedTitles ?? addedTitles
                titles.append(title)
                pendingAddedTitles = titles
            }
        }
        
        scheduleThrottledUpdate()
    }

    func didCompleteImporting() {
        flushAndFinalize()
    }
}

// MARK: - RatingsImporter Progress Delegate
extension ImportProgress: RatingsImporterProgressDelegate {
    func didStartRatingsImport(totalRatings: Int) {
        beginRun(totalItems: totalRatings)
    }
    
    func didUpdateRatingsProgress(currentRating: Int, imported: Int, updated: Int,
        notFound: Int, duplicateSkipped: Int) {
        // Accumulate into pending state — do not write @Observable properties directly.
        pendingCurrentFile = currentRating
        pendingSuccessCount = imported
        pendingUpdatedCount = updated
        pendingNotFoundCount = notFound
        pendingDuplicateCount = duplicateSkipped
        scheduleThrottledUpdate()
    }

    func didCompleteRatingsImport(imported: Int, updated: Int, notFound: Int,
        duplicateSkipped: Int, addedTitles: [String], updatedTitles: [String],
        duplicateTitles: [String]) {
        // Apply final authoritative totals from the importer before flushing,
        // since the ratings importer passes absolute values (not deltas).
        pendingSuccessCount = imported
        pendingUpdatedCount = updated
        pendingNotFoundCount = notFound
        pendingDuplicateCount = duplicateSkipped
        pendingAddedTitles = addedTitles
        pendingUpdatedTitles = updatedTitles
        pendingDuplicateTitles = duplicateTitles
        flushAndFinalize()
    }
}
