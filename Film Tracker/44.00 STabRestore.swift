// MARK: - STabRestore.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// FilmTracker.app settings window: "Restore" tab.

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Backup Info Box

/// The validated backup's particulars, in the same boxed chrome the Export tab's blocks and
/// the path bars use.
///
/// The "Restore Database" button lives INSIDE the box, centered in the space below the
/// divider and pinned to the trailing edge, with the descriptive items flowing across three
/// rows beside it. Fixed height for the same reason `ExportBlock` has one: a "vertically
/// centered in the space below the divider" button needs that space to be a known quantity
/// rather than whatever the tab's stack happens to hand out.
private struct BackupInfoBox: View {
    /// 8 padding + ~12 caption + 6 + 1 divider + 6 + three ~14pt caption rows with 6pt
    /// gaps + 8 padding, with a little air.
    static var height: CGFloat { 104 }

    let info: RestoreViewModel.BackupFileInfo
    let restore: () -> Void

    /// One "Label: value" pair. The label is secondary, the value is not.
    private func item(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
        }
        .font(.caption)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Backup Information from Selected File")
                    .font(.caption)
                Spacer()
                if let created = info.formattedCreationDate {
                    Text("Created: \(created)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(alignment: .center, spacing: 16) {
                // Three rows rather than two: the button takes width out of the box, and
                // the old two-row split would have had to crowd or truncate against it.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 16) {
                        item("Format:", info.format)
                        item("Format Version:", "\(info.version)")
                        if let appVer = info.appVersion {
                            item("Application Version:", appVer)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 16) {
                        item("Films:", "\(info.filmCount)")
                        item("Lists:", "\(info.listCount)")
                        item("Releases:", "\(info.releaseCount)")
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 16) {
                        item("Poster Images:", "\(info.posterCount)")
                        item("Includes User Settings:", info.hasSettings ? "Yes" : "No")
                        Spacer(minLength: 0)
                    }
                }

                // No .defaultAction: the button reads as the system's standard chrome
                // rather than as the sheet's primary action. (Return is already spoken
                // for — the sheet's key monitor dismisses on it.)
                Button("Restore Database") { restore() }
            }
            // Fills the space below the divider so its children center in it.
            .frame(maxHeight: .infinity)
        }
        .padding(8)
        .frame(height: Self.height, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Same fill and outline as the path bar above and as the Export tab's two blocks.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }
}

// MARK: - Restore Settings View
struct RestoreSettingsView: View {
    @Bindable var viewModel: RestoreViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Sized against every tab's blurb, so the top-half contents of the Export and
            // Restore tabs stay positionally aligned. See SettingsTabDescription.
            SettingsTabDescription(blurb: .restore)

            // Backup file label.
            Text("Backup file:")
                .font(.headline)

            // PathBar (always visible).
            PathBarView(
                pathComponents: viewModel.backupInfo?.url.pathComponents.filter {
                    $0 != "/"
                } ?? ["No file selected."],
                icon: Image(systemName: viewModel.backupInfo != nil ? "doc.fill"
                    : "questionmark.folder.fill")
            )

            // Select Backup File Button with validation indicator.
            // Use overlay to prevent layout shifting when the validation indicator
            // appears/disappears.
            HStack(spacing: 0) {
                Button {
                    viewModel.selectBackupFile()
                } label: {
                    Text("Select Backup File…")
                        .frame(width: Preferences.settingsSelectButtonWidth)
                }
                .disabled(viewModel.isRestoring || viewModel.isValidating)
                .controlSize(.regular)
                
                // Validation indicator with fade animation - positioned as overlay
                if viewModel.isValidating {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                        Text("Validating...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 12)
                    .transition(.opacity)
                }
                
                Spacer()
            }
            .animation(.easeInOut(duration: 0.15), value: viewModel.isValidating)

            Divider()

            // Backup Information (shown after successful validation).
            if let info = viewModel.backupInfo {
                BackupInfoBox(info: info) {
                    viewModel.showConfirmRestore = true
                }
            }
            
            Spacer()
        }
        .padding()
        // Progress sheet.
        .sheet(isPresented: viewModel.isRestoringBinding) {
            RestoreProgressSheet()
                .interactiveDismissDisabled()
        }
        // "Validation Error" alert.
        .alert("Backup File Error", isPresented: $viewModel.showValidationError) {
            Button("OK", role: .cancel) {
                viewModel.clearSelectedFile()
            }
        } message: {
            Text(viewModel.validationErrorMessage)
        }
        // "Restore Confirmation" alert.
        .alert("Restore Database", isPresented: $viewModel.showConfirmRestore) {
            Button("Cancel", role: .cancel) { }
            Button("Restore", role: .destructive) {
                viewModel.performRestore()
            }
        } message: {
            Text("Are you sure you want to restore this database? All existing data will be permanently replaced with the contents of the selected backup. This action cannot be undone.")
        }
        // "Restore Error" alert.
        //
        // Two shapes, chosen by how far the restore got. A failure BEFORE the persistent
        // store was rebuilt left the existing database untouched, so the session carries on
        // and the alert simply dismisses. A failure AFTER it cannot be carried on from —
        // the old store's files are already gone — so the alert offers the same forced
        // relaunch the success path does, and no way to dismiss back into a session whose
        // writes would land in an unlinked file. See DBRestorer.storeWasRebuilt.
        .alert("Restoration Failed", isPresented: $viewModel.showRestoreError) {
            if viewModel.restoreFailureRequiresRestart {
                Button("Quit and Restart") {
                    DBRestorer.restartApplication()
                }
            } else {
                Button("OK", role: .cancel) {
                    viewModel.clearSelectedFile()
                }
            }
        } message: {
            Text(viewModel.restoreErrorMessage)
        }
        // "Restore Complete" alert.
        .alert("Restoration Complete", isPresented: $viewModel.showRestoreComplete) {
            Button("Quit and Restart") {
                DBRestorer.restartApplication()
            }
        } message: {
            Text(viewModel.restoreCompletionMessage)
        }
    }
}

// MARK: - Restore Progress Sheet
struct RestoreProgressSheet: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            // Large icon.
            Image(systemName: "doc.badge.clock")
                .font(.system(size: 60))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .padding(.vertical, 20)
            // Title.
            Text("Restoring Database")
                .font(.title2)
                .fontWeight(.medium)
                .padding(.bottom, 10)
            // Information message.
            Text("Please wait. Do not quit the application.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            // Indeterminate spinner.
            ProgressView()
                .scaleEffect(0.8)
                .padding(.top, 40)
                .padding(.bottom, 20)
            Spacer()
        }
        .frame(width: 500, height: 300)
        .padding()
    }
}

// MARK: - Restore View Model
/// View model that manages the restoration process and provides state to RestoreSettingsView.
/// Follows the same architecture pattern as ExportViewModel for consistency.
@MainActor
@Observable
final class RestoreViewModel: Loggable {
    nonisolated static let logTag = "[RestoreViewModel]"
    
    // MARK: - Published State
    private(set) var backupInfo: BackupFileInfo?
    private(set) var isValidating = false
    private(set) var isRestoring = false
    
    // Alert states
    var showValidationError = false
    var validationErrorMessage = ""
    var showConfirmRestore = false
    var showRestoreError = false
    var restoreErrorMessage = ""
    /// True when the failure happened after DBRestorer replaced the persistent store, so
    /// the current session can no longer write to a live database and must be relaunched.
    /// Drives which button the "Restoration Failed" alert offers.
    private(set) var restoreFailureRequiresRestart = false
    var showRestoreComplete = false
    // Message shown in the completion alert. Set by performRestore() so that a
    // non-fatal settings-apply failure can be disclosed to the user alongside the
    // successful-restore confirmation. Defaults to the standard success text.
    var restoreCompletionMessage: String =
        "The restoration was successful. The application must be restarted for changes to take effect."
    
    // Reference to the hosting window (Settings sheet) for proper panel attachment
    var hostingWindow: NSWindow?
    
    // MARK: - Computed Bindings
    // Provides a binding for the restoration sheet presentation
    var isRestoringBinding: Binding<Bool> {
        Binding(
            get: { self.isRestoring },
            set: { _ in /* Read-only binding, sheet dismissal not allowed */ }
        )
    }
    
    // MARK: - Dependencies
    private weak var dataCoordinator: DataCoordinator?
    private var modelContainer: ModelContainer?
    
    struct BackupFileInfo {
        let url: URL
        let format: String
        let version: Int
        let filmCount: Int
        let listCount: Int
        let releaseCount: Int
        let posterCount: Int
        let created: String
        let appVersion: String?
        let hasSettings: Bool

        // Parses the ISO 8601 creation string stored in the backup manifest and
        // returns a human-readable "Month Day, Year" string for display in the UI.
        // Returns nil if the stored string cannot be parsed, so the label is simply
        // omitted rather than showing a raw ISO timestamp.
        //
        private static let isoParser = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true)
        private static let isoParserNoFrac = Date.ISO8601FormatStyle(timeZoneSeparator: .colon)
        private static let displayFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MMMM d, yyyy"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()

        var formattedCreationDate: String? {
            // Try with fractional seconds first, then without, to handle both
            // ISO 8601 variants that backup files may contain.
            // Leading whitespace skipped, as the ISO8601DateFormatter these replaced skipped it.
            let trimmed = String(created.drop(while: \.isWhitespace))
            let date = (try? Self.isoParser.parse(trimmed)) ?? (try? Self.isoParserNoFrac.parse(trimmed))
            return date.map { Self.displayFormatter.string(from: $0) }
        }
    }
    
    // MARK: - Configuration
    
    func configure(dataCoordinator: DataCoordinator, modelContainer: ModelContainer) {
        self.dataCoordinator = dataCoordinator
        self.modelContainer = modelContainer
    }
    
    // MARK: - File Selection
    
    func selectBackupFile() {
        Task { @MainActor in
            // This avoids the "dyn.*" ad-hoc type mismatch that causes grayed-out items.
            let ftbackupTypes = UTType.types(tag: "ftbackup", tagClass: .filenameExtension,
                conformingTo: .package)
            
            // Prefer the canonical types if found, otherwise allow any package (still
            // gated by extension below).
            let allowedTypes: [UTType] = ftbackupTypes.isEmpty ? [.package] : ftbackupTypes
            
            let config = OpenPanelConfiguration(
                canChooseFiles: true,
                canChooseDirectories: false,
                allowsMultipleSelection: false,
                allowedContentTypes: allowedTypes,
                title: "Select Backup File",
                message: "Select a Film Tracker backup package (.ftbackup) to restore",
                prompt: "Select"
            )
            
            // Use hostingWindow to attach panel to Settings sheet, not main window
            let selection = await OpenPanelPresenter.present(
                configuration: config,
                attachedTo: hostingWindow
            )
            guard case let .urls(urls) = selection,
                  let url = urls.first else { return }
            
            // Safety: Double-check that the selected file has a .ftbackup extension
            // in case filtering fell back to '.package' type.
            guard url.pathExtension.lowercased() == "ftbackup" else {
                validationErrorMessage =
                    "The selected file is not a valid Film Tracker backup (.ftbackup)."
                showValidationError = true
                return
            }
            
            loadBackupFile(url)
        }
    }
    
    func loadBackupFile(_ url: URL) {
        isValidating = true
        backupInfo = nil
        
        Task {
            do {
                // Begin security-scoped access in case the package is outside the sandbox.
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                
                // Verify it's a package directory.
                guard url.isExistingDirectory else {
                    throw DBRestorerError.notAPackage(url)
                }
                
                // Verify backup.xml exists inside the package.
                let xmlURL = url.appendingPathComponent("backup.xml")
                guard FileManager.default.fileExists(atPath: xmlURL.path(percentEncoded: false)) else {
                    throw DBRestorerError.missingXML(url)
                }
                
                let importer = DBImporter()
                // Parse the XML file. parseBackupFile validates format and version
                // internally (throws DBImporterError.unsupportedFormat / .unsupportedVersion
                // on failure), so a separate validateBackupFile call is redundant here.
                let backup = try await importer.parseBackupFile(at: xmlURL)
                let format = backup.format
                let version = backup.version
                
                // Count objects by type.
                var filmCount = 0
                var listCount = 0
                var releaseCount = 0
                var hasSettings = false
                
                for obj in backup.objects {
                    switch obj.entityName {
                    case "Film": filmCount += 1
                    case "ListObject": listCount += 1
                    case "Release": releaseCount += 1
                    case "SettingsObject": hasSettings = true
                    default: break
                    }
                }
                
                // Count poster images in the package's Posters folder.
                // Listed off the main actor: a full library's folder holds thousands of
                // entries. The security-scoped access begun above stays open across this
                // await, since its `defer` runs only when the Task body exits.
                let imagesURL = url.appendingPathComponent("Posters")
                let posterCount = await Task.detached(priority: .userInitiated) { () -> Int in
                    guard FileManager.default.fileExists(atPath: imagesURL.path(percentEncoded: false)),
                          let contents = try? FileManager.default.contentsOfDirectory(
                            at: imagesURL,
                            includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles]
                          ) else { return 0 }
                    return contents.count
                }.value
                
                // RestoreViewModel is @MainActor-isolated; the unstructured Task {}
                // created within that context inherits the same isolation. All code in
                // this Task body — including the resume points after async calls — runs
                // on the main actor, so direct property assignment is correct here.
                backupInfo = BackupFileInfo(
                    url: url,
                    format: format,
                    version: version,
                    filmCount: filmCount,
                    listCount: listCount,
                    releaseCount: releaseCount,
                    posterCount: posterCount,
                    created: backup.createdISO8601,
                    appVersion: backup.appVersion,
                    hasSettings: hasSettings
                )
                isValidating = false
            } catch let error as DBImporterError {
                validationErrorMessage = Self.formatValidationError(error)
                isValidating = false
                showValidationError = true
            } catch let error as DBRestorerError {
                validationErrorMessage = Self.formatRestoreError(error)
                isValidating = false
                showValidationError = true
            } catch {
                validationErrorMessage = "An unexpected error occurred: \(error.localizedDescription)"
                isValidating = false
                showValidationError = true
            }
        }
    }
    
    // MARK: - Restoration
    
    func performRestore() {
        guard let info = backupInfo,
              let container = modelContainer else { return }
        
        // Start the restore state
        isRestoring = true
        showRestoreError = false
        showRestoreComplete = false
        restoreFailureRequiresRestart = false
        // Reset the completion message so a prior failed attempt cannot leak stale
        // non-fatal-warning text into a subsequent successful run.
        restoreCompletionMessage =
            "The restoration was successful. The application must be restarted for changes to take effect."
        
        let backupURL = info.url
        let coordinator = self.dataCoordinator
        
        // Run the restore on MainActor, inheriting from the @MainActor view model.
        // DBRestorer is @MainActor-isolated and dispatches its heavy work off MainActor
        // internally where needed — wrapping the call in Task.detached would capture the
        // @MainActor-isolated `coordinator` across an actor boundary, which Swift 6
        // strict concurrency flags as unsafe. Running here keeps the isolation contract
        // simple and removes the need for MainActor.run trampolines in every branch.
        // Not retained: a restore cannot be canceled (see DBRestorer.restoreFromBackup),
        // so there is nothing a stored handle could be used for. The task keeps itself
        // alive until it completes.
        Task { [weak self] in
            guard let self = self else { return }
            
            do {
                // Begin security-scoped access during restore.
                let didAccess = backupURL.startAccessingSecurityScopedResource()
                defer { if didAccess { backupURL.stopAccessingSecurityScopedResource() } }
                
                let restorer = DBRestorer(container: container, dataCoordinator: coordinator)

                do {
                    try await restorer.restoreFromBackup(at: backupURL) { _, _ in
                        // Progress callback intentionally ignored — UI shows indeterminate spinner
                    }
                } catch {
                    // Record how far the restore got BEFORE the error is classified below.
                    // Past the store rebuild there is no live database left to return to,
                    // so the failure alert must force a relaunch rather than dismiss.
                    self.restoreFailureRequiresRestart = restorer.storeWasRebuilt
                    throw error
                }
                
                // If the database restore succeeded but the settings-apply step
                // failed (non-fatal), append a note to the completion message so the
                // user knows to verify preferences after relaunch.
                if let failureMessage = restorer.settingsApplyFailure {
                    self.restoreCompletionMessage =
                        "The database was restored successfully, but restored preferences could not be applied to the current session (\(failureMessage)). Preferences will be reloaded from the database the next time the application launches."
                }
                
                // Mark complete and do not refresh any data here. The application
                // will restart, which will re-initialize everything cleanly.
                self.isRestoring = false
                self.showRestoreComplete = true
            } catch let error as DBRestorerError {
                self.finishWithFailure(Self.formatRestoreError(error))
            } catch let error as DBImporterError {
                self.finishWithFailure(Self.formatValidationError(error))
            } catch {
                self.finishWithFailure("An unexpected error occurred: \(error.localizedDescription)")
            }
        }
    }
    
    /// Ends a failed restore, appending the relaunch notice when the database was already
    /// replaced and the session therefore cannot continue. One funnel for all three catch
    /// branches so the notice can never be attached to one message and forgotten on another.
    private func finishWithFailure(_ message: String) {
        isRestoring = false
        restoreErrorMessage = restoreFailureRequiresRestart
            ? message + "\n\nThe previous database has already been replaced and cannot be "
                + "recovered in this session. The application must be restarted."
            : message
        showRestoreError = true
        Self.log("WARNING: Restore failed (requiresRestart=\(restoreFailureRequiresRestart)): \(message)")
    }

    func clearSelectedFile() {
        backupInfo = nil
    }
    
    // MARK: - Error Formatting
    
    private static func formatValidationError(_ error: DBImporterError) -> String {
        switch error {
        case .fileNotFound:
            return "The backup file could not be found. Please ensure the file exists and try again."
        case .invalidXML(let msg):
            return "The backup file contains invalid XML data: \(msg)"
        case .unsupportedFormat(let fmt):
            return "The backup format '\(fmt)' is not supported by this version of Film Tracker."
        case .unsupportedVersion(let ver):
            return "The backup version (\(ver)) is not supported. Please update Film Tracker to restore this backup."
        case .missingRequiredElement(let elem):
            return "The backup file is missing required data: '\(elem)'"
        case .corrupted(let msg):
            return "The backup file appears to be corrupted: \(msg)"
        }
    }
    
    private static func formatRestoreError(_ error: DBRestorerError) -> String {
        switch error {
        case .invalidBackupStructure(let msg):
            return "The backup file has an invalid structure: \(msg)"
        case .restorationFailed(let msg):
            return "The restoration process failed: \(msg)"
        case .notAPackage(let url):
            return "The selected file is not a valid backup package: \(url.lastPathComponent)"
        case .missingXML(let url):
            return "The backup package is missing required data: \(url.lastPathComponent)"
        case .storeRebuildFailed(let msg):
            return "Failed to rebuild the database store before restoration: \(msg)"
        }
    }
}
