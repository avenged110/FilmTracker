// MARK: - STabGeneral.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// FilmTracker.app settings window: "General" tab. SettingsSheet hosts this tab
// inside DataCoordinatorScrollView, the shared AppKitScrollView facade for
// consumers that need nothing re-injected into the hosted tree beyond DataCoordinator.
//
// Rows with a caption or a button strip are built on SettingsKit's row factory
// (SettingsRow / SettingsDescribedToggle / SettingsControlStrip) and share its grid
// (SettingsMetrics). The rows that carry a Picker inside the checkbox label are the
// genuine outliers the kit's header describes, and stay hand-built.

import SwiftUI

struct GeneralSettingsView: View, Loggable {
    nonisolated static let logTag = "[STabGeneral]"

    @Environment(DataCoordinator.self) private var dataCoordinator

    @AppStorage(preference: Preferences.confirmGalleryDeleteKey)
        private var confirmGalleryDelete: Bool
    @AppStorage(preference: Preferences.confirmListEditsKey)
        private var confirmListEdits: Bool
    @AppStorage(preference: Preferences.listEditScopeKey)
        private var listEditScopeRaw: Int
    @AppStorage(preference: Preferences.confirmReleaseDeleteKey)
        private var confirmReleaseDelete: Bool
    @AppStorage(preference: Preferences.confirmFilmQueueAddKey)
        private var confirmFilmQueueAdd: Bool
    @AppStorage(preference: Preferences.notifyAboutNewReleasesKey)
        private var notifyAboutNewReleases: Bool
    @AppStorage(preference: Preferences.onlyNotifyForWishlistedKey)
        private var onlyNotifyForWishlisted: Bool
    @AppStorage(preference: Preferences.queueIsDropTargetKey)
        private var queueIsDropTarget: Bool
    @AppStorage(preference: Preferences.queueSectionOnDropKey)
        private var queueSectionOnDropRaw: Int
    @AppStorage(preference: Preferences.largeGalleryGridKey)
        private var largeGalleryGrid: Bool
    @AppStorage(preference: Preferences.defaultRotationThresholdKey)
        private var defaultRotationThreshold: Int
    @AppStorage(preference: Preferences.iCalIntegrationKey)
        private var iCalIntegration: Bool
    @AppStorage(preference: Preferences.manualExtQueryKey)
        private var manualExtQuery: Bool
    @AppStorage(preference: Preferences.smartListsKey)
        private var smartLists: Bool
    @AppStorage(preference: Preferences.excludeQueuedFromUpForRotationKey)
        private var excludeQueuedFromUpForRotation: Bool
    @AppStorage(preference: Preferences.showStatusBarKey)
        private var showStatusBar: Bool
    @AppStorage(preference: Preferences.maintainSelectionOnSearchExitKey)
        private var maintainSelectionOnSearchExit: Bool
    @AppStorage(preference: Preferences.showSearchSuggestionsKey)
        private var showSearchSuggestions: Bool
    @AppStorage(preference: Preferences.showRecentSearchesKey)
        private var showRecentSearches: Bool
    @AppStorage(preference: Preferences.rememberRightSidebarTabKey)
        private var rememberRightSidebarTab: Bool
    @AppStorage(preference: Preferences.rememberRightSidebarReleasesFilterKey)
        private var rememberRightSidebarReleasesFilter: Bool
    @AppStorage(preference: Preferences.autoExpandRightSidebarTablesKey)
        private var autoExpandRightSidebarTables: Bool
    @AppStorage(preference: Preferences.additionalCalTableDetailsKey)
        private var additionalCalTableDetails: Bool
    @AppStorage(preference: Preferences.showReleasesSummaryTableKey)
        private var showReleasesSummaryTable: Bool
    @AppStorage(preference: Preferences.maintainScrollPositionOnViewSwitchKey)
        private var maintainScrollPositionOnViewSwitch: Bool
    @AppStorage(preference: Preferences.rememberTabSelectionKey)
        private var rememberTabSelection: Bool
    @AppStorage(preference: Preferences.tabRememberScopeKey)
        private var tabRememberScopeRaw: Int
    @AppStorage(preference: Preferences.rememberSortFilterSelectionsKey)
        private var rememberSortFilterSelections: Bool
    @AppStorage(preference: Preferences.performBackupAtLaunchKey)
        private var performBackupAtLaunch: Bool

    @State private var showResetOverridesAlert = false
    @State private var backupFilesExist = false
    /// True while deleteBackups' background deletion runs, so the button cannot start a
    /// second one.
    @State private var isDeletingBackups = false
    @State private var showDeleteBackupsAlert = false
    @State private var backupMonitorTask: TaskHandle?
    // Debounce task for rememberSortFilterSelections toggle to prevent rapid
    // clear/capture cycles if the user checks and unchecks the box quickly.
    @State private var sortFilterPrefDebounceTask: Task<Void, Never>?

    // Convert months to years display format
        private func formatRotationThresholdAsYears(_ months: Int) -> String {
            let years = Double(months) / 12.0
            if years == 1.0 { return "1 year"
            } else if years.truncatingRemainder(dividingBy: 1.0) == 0 {
                return "\(Int(years)) years"
            } else { return "\(years) years" } }

    var body: some View {
        // SettingsPage with no padding: the inset is applied at the call site in
        // SettingsSheet, which also supplies the scroll container.
        SettingsPage(padding: 0) {
            SettingsDescribedToggle("System calendar integration",
                description: """
                    Optionally add viewing events directly to your system calendar from within Film Tracker.
                    
                    Note: This feature requires full access to your system calendars via Apple's TCC system. This is only used to manually add viewing events and to enumerate your calendars for selection in the menu.
                    """,
                isOn: $iCalIntegration)

            Divider()

            SettingsRow("Default viewing rotation threshold:",
                        description: "The margin of time since the most recent viewing date for a film to be considered in-rotation for viewing again. This can be overridden on a per-film basis.") {
                Picker("", selection: $defaultRotationThreshold) {
                    ForEach(Preferences.rotationThresholdOptions, id: \.self) { months in
                        Text(formatRotationThresholdAsYears(months)).tag(months) } }
                .labelsHidden()
                .frame(width: 120)
                // @AppStorage bypasses Preferences' setter and its preferencesChanged
                // post, so without this neither SettingsObject (backups) nor the
                // rotation-derived state ever heard about the change.
                .onChange(of: defaultRotationThreshold) { _, _ in
                    AppEventBus.shared.send(.view(.preferencesChanged)) }
            } accessory: {
                SettingsControlStrip {
                    Button("Reset All Overrides") { showResetOverridesAlert = true } } }

            Divider()

            SettingsRow("Show a warning before:")

            Group {
                Toggle(isOn: $confirmGalleryDelete) {
                    Text("Deleting films from the library") }

                Toggle(isOn: $confirmReleaseDelete) {
                    Text("Deleting disc-based releases from the library")
                }

                // The Toggle acts as the master on/off switch for all list-related confirmation
                // alerts. The inline Picker sits inside the Toggle's label closure so the
                // checkbox aligns naturally with the surrounding rows — no manual HStack needed.
                // The Picker refines which class of change is gated and is disabled while the
                // toggle is off.
                Toggle(isOn: $confirmListEdits) {
                    HStack(spacing: 4) {
                        Text("Making changes to")
                        Picker("", selection: $listEditScopeRaw) {
                            Text("lists and their contents")
                                .tag(Preferences.ListEditScope.both.rawValue)
                            Text("lists, but not their contents")
                                .tag(Preferences.ListEditScope.listOnly.rawValue)
                            Text("list contents only")
                                .tag(Preferences.ListEditScope.contentsOnly.rawValue)
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        .disabled(!confirmListEdits)
                    }
                    .padding(.vertical, -2)
                }

                Toggle(isOn: $confirmFilmQueueAdd) {
                    Text("Adding films with special sorting parameters to the Queue")
                }
            }
            .settingsChildRowInset()

            // Master checkbox + scope Picker, matching the confirmListEdits/ListEditScope
            // design above: the checkbox turns release-day notifications on and off, and the
            // Picker, disabled while it is off, narrows them to wishlisted releases.
            Toggle(isOn: $notifyAboutNewReleases) {
                HStack(spacing: 4) {
                    Text("Notify me about")
                    Picker("", selection: $onlyNotifyForWishlisted) {
                        Text("all new releases").tag(false)
                        Text("wishlisted new releases only").tag(true)
                    }
                    .labelsHidden()
                    .frame(width: 215)
                    .disabled(!notifyAboutNewReleases)
                }
                .padding(.vertical, -2)
            }
            // @AppStorage writes directly to UserDefaults, bypassing Preferences' setters and
            // their preferencesChanged post. Mirrored and posted here, as for smartLists
            // below, because ReleaseNotifications reschedules on that event — turning the
            // checkbox on is also what asks macOS for permission to notify.
            .onChange(of: notifyAboutNewReleases) { _, newValue in
                Preferences.notifyAboutNewReleases = newValue
                AppEventBus.shared.send(.view(.preferencesChanged)) }
            .onChange(of: onlyNotifyForWishlisted) { _, newValue in
                Preferences.onlyNotifyForWishlisted = newValue
                AppEventBus.shared.send(.view(.preferencesChanged)) }

            Divider()

            SettingsDescribedToggle("Large poster images",
                description: "Use larger poster images in the gallery's grid-style view at larger window sizes by capping the maximum number of columns at six instead of eight.",
                isOn: $largeGalleryGrid)

            Toggle(isOn: $showStatusBar) {
                Text("Show the status bar at the bottom of the window") }

            Toggle(isOn: $smartLists) {
                Text("Show the Smart Lists section in the sidebar") }
            .onChange(of: smartLists) { _, newValue in
                // @AppStorage writes directly to UserDefaults, bypassing Preferences'
                // custom setter (and therefore its postPreferenceChangedEvent() call).
                // Mirror the value through the Preferences setter and post the event
                // manually — matching the excludeQueuedFromUpForRotation pattern above.
                //
                // This is what lets SmartLists react to the master toggle at all. Without
                // it, turning the feature off left the computed sets populated and the
                // midnight rotation timer armed, and turning it back on never triggered a
                // recalculation — so every film edit made while the feature was off stayed
                // missing from the lists for the rest of the session.
                Preferences.smartLists = newValue
                AppEventBus.shared.send(.view(.preferencesChanged)) }

            // Governs whether films already present on any of the three internal Film
            // Queue lists are hidden from the "Up for Rotation" smart list. Purely a
            // presentation-layer filter — disabled whenever Smart Lists themselves are
            // disabled, since the smart list is hidden from the sidebar in that case.
            // Indented beneath the "Show the Smart Lists section" toggle above, matching
            // the visual nesting used for the "Show a warning before:" and "Contextual
            // sidebar:" grouped rows.
            Toggle(isOn: $excludeQueuedFromUpForRotation) {
                Text("Exclude enqueued films from the \"Up for Rotation\" smart lists")
            }
            .disabled(!smartLists)
            .settingsChildRowInset()
            .onChange(of: excludeQueuedFromUpForRotation) { _, newValue in
                // @AppStorage writes directly to UserDefaults, bypassing Preferences'
                // custom setter (and therefore its postPreferenceChangedEvent() call).
                // Explicitly mirror the value through the Preferences setter and post
                // the event manually — matching the loggingEnabled pattern above — so
                // SmartLists' preferencesChanged listener picks up the change and
                // refreshes any open "Up for Rotation" gallery in real time.
                Preferences.excludeQueuedFromUpForRotation = newValue
                AppEventBus.shared.send(.view(.preferencesChanged)) }

            // NOTE: the "Show sorting-based gallery dividers" toggle that stood here is
            // deliberately gone. Section dividers are per-view state now, chosen from the
            // "Section Dividers:" Show/Hide pair in each view's own Sort menu and stored
            // in that view's ViewState alongside its sort, filters, and view style — so
            // the setting is governed by the "Remember the last-selected view options"
            // preference below rather than being one global switch for every view at once.

            // Governs whether the sidebar's "Film Queue" item accepts dragged films
            // and, if so, which of the three internal Film Queue lists receives them.
            // The Picker sits inside the Toggle's label closure so it aligns naturally
            // with the checkbox, matching the confirmListEdits/ListEditScope pattern below.
            Toggle(isOn: $queueIsDropTarget) {
                HStack(spacing: 4) {
                    Text("When dragging films onto the Queue, add them to the")
                    Picker("", selection: $queueSectionOnDropRaw) {
                        Text("\"Up Next\"").tag(Preferences.QueueDropSection.upNext.rawValue)
                        Text("\"Soon\"").tag(Preferences.QueueDropSection.soon.rawValue)
                        Text("\"Later\"").tag(Preferences.QueueDropSection.later.rawValue)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    .disabled(!queueIsDropTarget)
                    Text("section")
                }
                .padding(.vertical, -2)
            }

            Divider()

            SettingsRow("Contextual sidebar:")

            Group {
                SettingsDescribedToggle("Show the Web Query button",
                    description: "The Web Query button provides a single-click shortcut to query IMDb.com or Blu-ray.com for the selected film in the default Web browser.",
                    isOn: $manualExtQuery)

                Toggle(isOn: $rememberRightSidebarTab) {
                    Text("Maintain the active tab across selection changes") }

                Toggle(isOn: $autoExpandRightSidebarTables) {
                    Text("Automatically expand collapsed tables") }

                Toggle(isOn: $additionalCalTableDetails) {
                    Text("Show additional details in the Viewing History table") }

                Toggle(isOn: $rememberRightSidebarReleasesFilter) {
                    Text("Maintain the active releases filter across selection changes") }

                Toggle(isOn: $showReleasesSummaryTable) {
                    Text("Show a table summarizing all available releases") }
            }
            .settingsChildRowInset()

            Divider()

            SettingsDescribedToggle("Show relevant suggestions when using the search field",
                description: "Suggestions are based off of content in your library and local heuristics.",
                isOn: $showSearchSuggestions)

            // Indented beneath the suggestions toggle and disabled while it is off, matching
            // the excludeQueuedFromUpForRotation row: recent searches are offered through
            // the same drop-down, and SearchSuggestions only shows them while both are on.
            SettingsDescribedToggle("Show recent searches when the search field is selected",
                description: "The recording of recent searches is ephemeral and session-local.",
                isOn: $showRecentSearches,
                isEnabled: showSearchSuggestions)
            .settingsChildRowInset()

            SettingsDescribedToggle("Persist selection when exiting search results",
                description: "If a single film is selected within search results when the query is cleared and this same film is present in the prior view, persist the selection instead of clearing it.",
                isOn: $maintainSelectionOnSearchExit)

            Toggle(isOn: $maintainScrollPositionOnViewSwitch) {
                Text("Remember prior scroll positions across view changes") }

            // Master checkbox + scope Picker, matching the confirmListEdits/
            // ListEditScope design above. rememberTabSelection is the on/off switch;
            // tabRememberScopeRaw refines which tab(s) it applies to when enabled.
            Toggle(isOn: $rememberTabSelection) {
                HStack(spacing: 4) {
                    Text("Remember the last-selected tab in")
                    Picker("", selection: $tabRememberScopeRaw) {
                        Text("Recents").tag(Preferences.TabRememberScope.recents.rawValue)
                        Text("Reports").tag(Preferences.TabRememberScope.reports.rawValue)
                        Text("Recents and Reports").tag(Preferences.TabRememberScope.both.rawValue)
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .disabled(!rememberTabSelection)
                    Text("across sessions")
                }
                .padding(.vertical, -2)
            }

            SettingsDescribedToggle("Remember the last-selected view options across sessions",
                description: "Independently persist sorting, filtering, and view style selections on a per-view basis. This does not apply to search results as their view options are reset with each query, nor does it apply to user-generated lists as their view options are always persisted, regardless.",
                isOn: Binding(
                get: { rememberSortFilterSelections },
                set: { newValue in
                    rememberSortFilterSelections = newValue
                    // Debounce the side-effects (clear or capture) by 400ms to prevent
                    // redundant UserDefaults mutations if the user toggles the checkbox
                    // rapidly. The AppStorage write above is immediate and intentional;
                    // only the subsequent sort-state manipulation is deferred.
                    sortFilterPrefDebounceTask?.cancel()
                    sortFilterPrefDebounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        if newValue {
                            // Re-enabled: capture the current runtime sort/filter state
                            // for all loaded views and write it to Preferences so these
                            // selections persist across the next application restart.
                            let snapshot = ViewStateManager.shared.snapshotAllViewSortStates()
                            Preferences.viewSortStates = snapshot
                            log("rememberSortFilterSelections enabled — captured \(snapshot.count) view state(s)")
                        } else {
                            // Disabled: clear existing persisted state so all views
                            // return to their built-in defaults on the next launch.
                            Preferences.clearViewSortStates()
                            log("rememberSortFilterSelections disabled — cleared persisted view sort states")
                        }
                    }
                }
            ))

            Divider()

            SettingsRow("Automatic database backup",
                        description: "Automatically create a database backup in the background shortly following each launch. Only the three most recent backups will be retained.",
                        leading: .checkbox($performBackupAtLaunch)) {
            } accessory: {
                SettingsControlStrip {
                    Button("Reveal Backups in Finder") { revealBackupsFolder() }
                    .disabled(!backupFilesExist)

                    Button("Delete Existing Backups") { showDeleteBackupsAlert = true }
                    .disabled(!backupFilesExist || isDeletingBackups) } }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            updateBackupFilesStatus()
            startMonitoringBackups() }
        .onDisappear { stopMonitoringBackups() }
        .alert("Reset All Rotation Threshold Overrides",
            isPresented: $showResetOverridesAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                // resetAllRotationThresholdOverrides() is fire-and-forget:
                // optimistic MemoryStore update is applied synchronously; background
                // persistence is dispatched via trackOperation, which handles rollback
                // and user alerting on failure internally.
                dataCoordinator.resetAllRotationThresholdOverrides()
            }
        } message: {
            Text("Are you sure you want to reset all per-film rotation threshold overrides? They will revert to the default value, and films will continue to use the global default setting until individual overrides are configured again. This action cannot be undone.") }
        .alert("Delete All Automatic Backups",
            isPresented: $showDeleteBackupsAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { deleteBackups() }
        } message: {
            Text("Are you sure you want to delete all automatic backups? This will permanently remove every automatically-generated backup file from the Backups folder in Film Tracker's sandbox container. This action cannot be undone.") } }

    // MARK: - Backup Folder Operations
    private func startMonitoringBackups() {
        // Avoid starting multiple tasks.
        guard backupMonitorTask == nil else { return }

        backupMonitorTask = TaskHandle(Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                // The once-a-second directory listing runs off the main actor; only the
                // resulting Bool comes back to set the view's state.
                let backupURL = Preferences.backupFolderURL
                let exist = await Task.detached(priority: .utility) {
                    Self.backupFilesExist(in: backupURL) }.value
                guard !Task.isCancelled else { return }
                if backupFilesExist != exist { backupFilesExist = exist } } }) }

    private func stopMonitoringBackups() {
        // Nil the handle — its deinit cancels the underlying Task automatically.
        backupMonitorTask = nil }

    private func updateBackupFilesStatus() {
        backupFilesExist = Self.backupFilesExist(in: Preferences.backupFolderURL) }

    private nonisolated static func backupFilesExist(in backupURL: URL?) -> Bool {
        guard let backupURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: backupURL, includingPropertiesForKeys: nil) else { return false }
        return files.contains { $0.pathExtension == "ftbackup" } }

    private func revealBackupsFolder() {
        guard let url = Preferences.backupFolderURL else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path(percentEncoded: false)) }

    /// Deletes every backup package off the main actor — each is a directory holding the
    /// whole poster folder, so removing them can take a while — then refreshes the button
    /// state here.
    private func deleteBackups() {
        guard let backupURL = Preferences.backupFolderURL else {
            log("ERROR: Backup folder URL is nil"); return }
        guard !isDeletingBackups else { return }
        isDeletingBackups = true

        Task {
            let exist = await Task.detached(priority: .userInitiated) { () -> Bool in
                Self.deleteBackupFiles(in: backupURL)
                return Self.backupFilesExist(in: backupURL) }.value
            backupFilesExist = exist
            isDeletingBackups = false } }

    private nonisolated static func deleteBackupFiles(in backupURL: URL) {
        do {
            let fileManager = FileManager.default

            // Get all .ftbackup files.
            let files = try fileManager.contentsOfDirectory(
                at: backupURL, includingPropertiesForKeys: nil)
            let backupFiles = files.filter { $0.pathExtension == "ftbackup" }

            if backupFiles.isEmpty { log("No backup files to delete")
            } else {
                // Each package on its own: the automatic backup's retention pass also deletes
                // packages off the main actor and can remove one first. A failure skips that
                // package rather than abandoning the rest; the button state is re-read after.
                var deleted = 0
                for file in backupFiles {
                    do {
                        try fileManager.removeItem(at: file)
                        deleted += 1
                    } catch CocoaError.fileNoSuchFile {
                        continue
                    } catch {
                        log("ERROR: Failed to delete backup \(file.lastPathComponent): \(error.localizedDescription)") } }
                log("Deleted \(deleted) backup file(s)") }
        } catch { log("ERROR: Failed to delete backups: \(error.localizedDescription)") } }
}
