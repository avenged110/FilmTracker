// MARK: - SettingsManager.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Manages synchronization between UserDefaults (runtime) and database (backup/restore).
// All database operations are routed through DataCoordinator/DataManager abstraction.

import Foundation
import SwiftData
import Combine

@MainActor
final class SettingsManager: Loggable {
    nonisolated static let logTag = "[SettingsManager]"
    
    // MARK: - Properties
    private weak var dataCoordinator: DataCoordinator?
    private var cancellables = Set<AnyCancellable>()

    // Debounce interval for database writes (5 seconds)
    private let debounceInterval: TimeInterval = 5.0

    /// The in-flight debounce. Owned explicitly (rather than left to Combine's
    /// `.debounce` operator) so that `flushPendingSync()` can cancel the pending wait
    /// and perform the write immediately at quit. Combine offers no way to force a
    /// debounced value out early, which is precisely why a preference changed within
    /// the debounce window of a quit never reached SettingsObject at all — leaving the
    /// next export/backup carrying the stale value, and a restore from it silently
    /// reverting the setting.
    private var debounceTask: Task<Void, Never>?

    /// True when a `preferencesChanged` event has been observed but not yet written
    /// through to the database. Checked by `flushPendingSync()` so the quit path does
    /// no work in the overwhelmingly common case where nothing changed.
    private var hasPendingChanges: Bool = false

    /// The last snapshot successfully written. Preference writes already pass through
    /// `Preferences.setIfChanged`, but `preferencesChanged` is also posted by bulk resets
    /// and by high-frequency state such as `viewSortStates`, so the same blob can be
    /// presented repeatedly. Comparing against it skips the fetch/encode/save round trip
    /// on the main context when nothing actually differs.
    private var lastSynced: SettingsSnapshot?

    // MARK: - Initialization
    init(dataCoordinator: DataCoordinator) {
        self.dataCoordinator = dataCoordinator
        setupObservers()
    }
    
    // NOTE: No explicit deinit needed. AnyCancellable automatically cancels its
    // upstream subscription when deallocated, so `cancellables` cleans up on its own.
    // A previous version used `Task { @MainActor in cancellables.removeAll() }` here,
    // but deinit is nonisolated — the fire-and-forget Task would access instance storage
    // after deallocation had begun, risking a crash on a dangling pointer.
    
    // MARK: - Observers
    private func setupObservers() {
        // Observe settings changes via AppEventBus. The debounce itself is applied in
        // scheduleDebouncedSync() rather than by a Combine operator — see debounceTask.
        AppEventBus.shared.viewEvents
            .filter { event in
                if case .preferencesChanged = event { return true }
                return false
            }
            .sink { [weak self] _ in
                self?.scheduleDebouncedSync()
                // Hosted here because this observer is installed unconditionally
                // (activateSettingsObserver), unlike the lazily built SmartLists.
                self?.dataCoordinator?.handleDefaultRotationThresholdChangeIfNeeded()
            }
            .store(in: &cancellables)
    }

    /// Restarts the debounce window. The last change in a burst wins, exactly as the
    /// previous `.debounce(for:scheduler:)` operator behaved.
    private func scheduleDebouncedSync() {
        hasPendingChanges = true
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.debounceInterval))
            guard !Task.isCancelled else { return }
            self.debounceTask = nil
            await self.syncToDatabase()
        }
    }

    /// Forces any pending debounced sync out immediately.
    ///
    /// Called from the application's single guaranteed quit path
    /// (FilmTrackerApp.applicationShouldTerminate), mirroring the existing
    /// `flushSmartListState()` treatment of the rotation baseline — and for the same
    /// reason: both are debounced writes that would otherwise be lost on a quit inside
    /// their window. Awaited there BEFORE `prepareForShutdown()`, since this writes via
    /// `saveSettings` on the main context rather than through `trackOperation` (which
    /// silently discards work once shutdown has been signaled).
    func flushPendingSync() async {
        debounceTask?.cancel()
        debounceTask = nil
        guard hasPendingChanges else { return }
        Self.log("Flushing pending settings sync before shutdown")
        await syncToDatabase()
    }

    /// Writes the current Preferences to the database now, whether or not a change was
    /// observed. For a reader that must see every setting (an export): many Settings
    /// controls write through @AppStorage without posting preferencesChanged, so
    /// `hasPendingChanges` alone misses them. syncToDatabase skips the write when nothing
    /// changed since the last one, so this costs nothing when there is nothing to write.
    func syncNow() async {
        debounceTask?.cancel()
        debounceTask = nil
        await syncToDatabase()
    }

    // MARK: - Synchronization
    
    /// Sync current UserDefaults values to the database
    func syncToDatabase() async {
        guard let dataCoordinator = dataCoordinator else {
            Self.log("ERROR: DataCoordinator is nil, cannot sync")
            return
        }

        // Create SettingsSnapshot from current Preferences
        let snapshot = createSnapshotFromPreferences()

        // Skip the write entirely when nothing has actually changed since the last
        // successful sync (lastSyncDate aside — see hasSameSettings).
        if let lastSynced, lastSynced.hasSameSettings(as: snapshot) {
            hasPendingChanges = false
            Self.log("Settings unchanged since last sync — write skipped")
            return
        }

        Self.log("Syncing settings to database...")

        do {
            // Save via DataCoordinator
            try await dataCoordinator.saveSettings(snapshot)

            lastSynced = snapshot
            hasPendingChanges = false
            Self.log("Settings synced successfully")
        } catch {
            // Deliberately leaves hasPendingChanges set so a later flush retries.
            Self.log("ERROR: Failed to sync settings: \(error.localizedDescription)")
        }
    }
    
    /// Loads settings from the database and applies every stored preference to
    /// UserDefaults. Used after a restore, which replaces the user's settings wholesale.
    func loadFromDatabase() async throws {
        guard let dataCoordinator = dataCoordinator else {
            Self.log("ERROR: DataCoordinator is nil, cannot load")
            return
        }
        
        Self.log("Loading settings from database...")
        
        let snapshot = try await dataCoordinator.loadSettings()
        applySnapshotToPreferences(snapshot)

        // A restore rewrites Preferences wholesale. Drop the baseline so the next
        // sync is never skipped as "unchanged" against one captured before the
        // restore — the database and UserDefaults have both moved underneath it.
        lastSynced = nil

        Self.log("Settings loaded successfully")
    }
    
    // MARK: - Conversion: Preferences → SettingsSnapshot
    
    /// Creates a SettingsSnapshot from current Preferences (UserDefaults) values
    private func createSnapshotFromPreferences() -> SettingsSnapshot {
        // Encode the consolidated view-sort-states dictionary as a JSON string.
        // The dictionary maps view-identifier keys (e.g. "allFilms", "recents.recentlyViewed",
        // "smartList.filteredLibrary") to three-element [String] arrays encoding each view's
        // sort option, filter options, and sort direction. Stored in selectedSortOptionsJSON
        // so the backup XML attribute name is unchanged from prior versions.
        let sortOptionsJSON: String? = {
            if let jsonData = try? JSONEncoder().encode(Preferences.viewSortStates),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return jsonString
            }
            return nil
        }()
        
        let duplicatePairsJSON: String? = {
            if let jsonData = try? JSONEncoder().encode(Preferences.ignoredDuplicatePairs),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return jsonString
            }
            return nil
        }()
        
        return SettingsSnapshot(
            snapshotID: SettingsObject.singletonID,
            version: SettingsObject.currentVersion,
            lastSyncDate: Date(),
            // General Preferences
            confirmGalleryDelete: Preferences.confirmGalleryDelete,
            confirmListEdits: Preferences.confirmListEdits,
            listEditScope: Preferences.listEditScope.rawValue,
            confirmReleaseDelete: Preferences.confirmReleaseDelete,
            largeGalleryGrid: Preferences.largeGalleryGrid,
            showStatusBar: Preferences.showStatusBar,
            rememberRightSidebarTab: Preferences.rememberRightSidebarTab,
            autoExpandRightSidebarTables: Preferences.autoExpandRightSidebarTables,
            additionalCalTableDetails: Preferences.additionalCalTableDetails,
            showReleasesSummaryTable: Preferences.showReleasesSummaryTable,
            iCalIntegration: Preferences.iCalIntegration,
            manualExtQuery: Preferences.manualExtQuery,
            smartLists: Preferences.smartLists,
            excludeQueuedFromUpForRotation: Preferences.excludeQueuedFromUpForRotation,
            maintainSelectionOnSearchExit: Preferences.maintainSelectionOnSearchExit,
            showInfoComplete: Preferences.showInfoComplete,
            performBackupAtLaunch: Preferences.performBackupAtLaunch,
            defaultRotationThreshold: Preferences.defaultRotationThreshold,
            // Import Preferences
            importScanSubfolders: Preferences.importScanSubfolders,
            fuzzyImportMatching: Preferences.fuzzyImportMatching,
            fuzzyImportYearMatching: Preferences.fuzzyImportYearMatching,
            overrideSortNameField: Preferences.overrideSortNameField,
            allowUpdatesForDuplicateImports: Preferences.allowUpdatesForDuplicateImports,
            allowUpdatesForDuplicateRatings: Preferences.allowUpdatesForDuplicateRatings,
            // Export Preferences
            exportPosterImages: Preferences.exportPosterImages,
            prunePosterImages: Preferences.prunePosterImages,
            exportUserSettings: Preferences.exportUserSettings,
            // UI State Preferences
            maintainScrollPositionOnViewSwitch: Preferences.maintainScrollPositionOnViewSwitch,
            rememberTabSelection: Preferences.rememberTabSelection,
            tabRememberScope: Preferences.tabRememberScope.rawValue,
            lastRecentsCategory: Preferences.lastRecentsCategory,
            lastReportsCategory: Preferences.lastReportsCategory,
            rememberImportsTab: Preferences.rememberImportsTab,
            lastImportsCategory: Preferences.lastImportsCategory,
            rememberSortFilterSelections: Preferences.rememberSortFilterSelections,
            confirmFilmQueueAdd: Preferences.confirmFilmQueueAdd,
            queueIsDropTarget: Preferences.queueIsDropTarget,
            queueSectionOnDrop: Preferences.queueSectionOnDrop.rawValue,
            strictFramesTableChecking: Preferences.strictFramesTableChecking,
            showWatchDetailsAnnotationGlyphs: Preferences.showWatchDetailsAnnotationGlyphs,
            // Advanced Preferences
            loggingEnabled: Preferences.loggingEnabled,
            // Complex Preferences (JSON)
            selectedSortOptionsJSON: sortOptionsJSON,
            ignoredDuplicatePairsJSON: duplicatePairsJSON
        )
    }
    
    // MARK: - Conversion: SettingsSnapshot → Preferences
    
    /// Applies every preference a restored SettingsSnapshot carries to Preferences
    /// (UserDefaults). A nil field — a key the backup predates — leaves the current value
    /// alone; defaults come from Preferences' registered list and nowhere else.
    ///
    /// Order is kept deliberately: the setters post change events and some interact
    /// (rememberTabSelection / tabRememberScope), so they run in the same sequence the
    /// restore always used.
    private func applySnapshotToPreferences(_ snapshot: SettingsSnapshot) {
        func apply<T>(_ value: T?, _ set: (T) -> Void) {
            if let value { set(value) }
        }

        // General Preferences
        apply(snapshot.confirmGalleryDelete) { Preferences.confirmGalleryDelete = $0 }
        
        apply(snapshot.confirmListEdits) { Preferences.confirmListEdits = $0 }
        
        if let raw = snapshot.listEditScope,
           let scope = Preferences.ListEditScope(rawValue: raw) {
            Preferences.listEditScope = scope
        }
        
        apply(snapshot.confirmReleaseDelete) { Preferences.confirmReleaseDelete = $0 }

        apply(snapshot.largeGalleryGrid) { Preferences.largeGalleryGrid = $0 }
        
        apply(snapshot.showStatusBar) { Preferences.showStatusBar = $0 }
        
        apply(snapshot.rememberRightSidebarTab) { Preferences.rememberRightSidebarTab = $0 }
        
        apply(snapshot.autoExpandRightSidebarTables) { Preferences.autoExpandRightSidebarTables = $0 }

        apply(snapshot.additionalCalTableDetails) { Preferences.additionalCalTableDetails = $0 }
        
        apply(snapshot.showReleasesSummaryTable) { Preferences.showReleasesSummaryTable = $0 }

        apply(snapshot.iCalIntegration) { Preferences.iCalIntegration = $0 }

        apply(snapshot.manualExtQuery) { Preferences.manualExtQuery = $0 }
        
        apply(snapshot.smartLists) { Preferences.smartLists = $0 }

        apply(snapshot.excludeQueuedFromUpForRotation) { Preferences.excludeQueuedFromUpForRotation = $0 }

        apply(snapshot.maintainSelectionOnSearchExit) { Preferences.maintainSelectionOnSearchExit = $0 }
        
        apply(snapshot.showInfoComplete) { Preferences.showInfoComplete = $0 }
        
        apply(snapshot.performBackupAtLaunch) { Preferences.performBackupAtLaunch = $0 }
        
        apply(snapshot.defaultRotationThreshold) { Preferences.defaultRotationThreshold = $0 }
        
        // Import Preferences
        apply(snapshot.importScanSubfolders) { Preferences.importScanSubfolders = $0 }
        
        apply(snapshot.fuzzyImportMatching) { Preferences.fuzzyImportMatching = $0 }
        
        apply(snapshot.fuzzyImportYearMatching) { Preferences.fuzzyImportYearMatching = $0 }
        
        apply(snapshot.overrideSortNameField) { Preferences.overrideSortNameField = $0 }
        
        apply(snapshot.allowUpdatesForDuplicateImports) { Preferences.allowUpdatesForDuplicateImports = $0 }
        
        apply(snapshot.allowUpdatesForDuplicateRatings) { Preferences.allowUpdatesForDuplicateRatings = $0 }
        
        // Export Preferences
        apply(snapshot.exportPosterImages) { Preferences.exportPosterImages = $0 }
        
        apply(snapshot.prunePosterImages) { Preferences.prunePosterImages = $0 }
        
        apply(snapshot.exportUserSettings) { Preferences.exportUserSettings = $0 }
        
        // UI State Preferences
        apply(snapshot.maintainScrollPositionOnViewSwitch) { Preferences.maintainScrollPositionOnViewSwitch = $0 }

        // Tab-remember consolidated fields. A backup exported prior to this
        // preference's consolidation simply won't contain these keys, in which case
        // both are nil here and this is a no-op — the current in-app values are left
        // untouched (see the "aside from not restoring those now-removed keys"
        // behavior this is intentionally designed to accept).
        apply(snapshot.rememberTabSelection) { Preferences.rememberTabSelection = $0 }

        if let raw = snapshot.tabRememberScope,
           let scope = Preferences.TabRememberScope(rawValue: raw) {
            Preferences.tabRememberScope = scope
        }
        
        if let val = snapshot.lastRecentsCategory {
            Preferences.lastRecentsCategory = val
        }
        
        if let val = snapshot.lastReportsCategory {
            Preferences.lastReportsCategory = val
        }
        
        apply(snapshot.rememberImportsTab) { Preferences.rememberImportsTab = $0 }
        
        if let val = snapshot.lastImportsCategory {
            Preferences.lastImportsCategory = val
        }
        
        apply(snapshot.rememberSortFilterSelections) { Preferences.rememberSortFilterSelections = $0 }
        
        apply(snapshot.confirmFilmQueueAdd) { Preferences.confirmFilmQueueAdd = $0 }
        
        apply(snapshot.queueIsDropTarget) { Preferences.queueIsDropTarget = $0 }
        
        if let raw = snapshot.queueSectionOnDrop,
           let section = Preferences.QueueDropSection(rawValue: raw) {
            Preferences.queueSectionOnDrop = section
        }

        // Advanced Preferences
        apply(snapshot.strictFramesTableChecking) { Preferences.strictFramesTableChecking = $0 }
        
        apply(snapshot.showWatchDetailsAnnotationGlyphs) { Preferences.showWatchDetailsAnnotationGlyphs = $0 }

        apply(snapshot.loggingEnabled) { Preferences.loggingEnabled = $0 }
        
        // Decode view-sort-states from the JSON string stored in selectedSortOptionsJSON.
        //
        // New format: JSON-encoded [String:[String]] dictionary keyed by view identifier.
        // Old format (pre-consolidation backups): JSON-encoded [String] flat array
        //   containing the allFilms state only.
        //
        // Attempt the new format first. If that fails, attempt the old [String] format and
        // silently drop it per the documented upgrade policy — the user's current selections
        // are lost on that one restore, but the app never crashes or produces corrupt state.
        // If neither decode succeeds, the existing viewSortStates value is left untouched.
        if let json = snapshot.selectedSortOptionsJSON,
           let data = json.data(using: .utf8) {
            if let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
                Preferences.viewSortStates = decoded
            } else if (try? JSONDecoder().decode([String].self, from: data)) != nil {
                // Old flat-array format detected. Per the upgrade policy, we do not attempt
                // to migrate this data — the allFilms-only entry is silently discarded and
                // all views reset to their built-in defaults on next launch.
                Self.log("selectedSortOptionsJSON contained legacy flat-array format; discarding (expected after first restore from a pre-consolidation backup)")
            }
        }
        
        if let json = snapshot.ignoredDuplicatePairsJSON,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            Preferences.ignoredDuplicatePairs = decoded
        }
    }
}
