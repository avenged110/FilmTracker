// MARK: - STabExport.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// FilmTracker.app settings window: "Export" tab.

import SwiftUI
import CoreData

// MARK: - Tab Description

/// Which tab's blurb to show. The set is closed on purpose — every case is laid out
/// invisibly behind whichever one is on screen, and the tallest sets the shared height.
enum SettingsTabBlurb: CaseIterable, Hashable {
    case export
    case restore

    var text: String {
        switch self {
        case .export:
            return "Create a complete backup of your existing database, including all films, lists, and releases, as well as – optionally – settings and poster images, which can be used to restore your library to its present state. You can also export a report of your library's contents as a PDF."
        case .restore:
            return "Select a Film Tracker backup package (.ftbackup) to restore your complete library. This will replace all existing data."
        }
    }
}

/// The blurb at the top of the Export and Restore tabs, in a box every tab sizes alike.
///
/// The height comes from laying out EVERY blurb, hidden, in a ZStack behind the visible
/// one: a ZStack is as tall as its tallest child, so the box is exactly the natural height
/// of the longest description, measured by the same engine that draws it and at the same
/// width. Two earlier attempts reserved the space arithmetically instead — first
/// `lineLimit(_:reservesSpace:)`, then an explicit `frame(height:)` off the font's line
/// height — and both were a point or two out of step with how `Text` actually wraps, which
/// is what made the two tabs disagree and then truncated the Export blurb to two lines.
/// Nothing here is a measurement, so there is nothing left to be wrong about.
///
/// Alignment is `.topLeading`, so on the tab with the shorter blurb the reserved slack
/// trails below the text rather than centering it.
struct SettingsTabDescription: View {
    let blurb: SettingsTabBlurb

    private func styled(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(SettingsTabBlurb.allCases, id: \.self) { candidate in
                styled(candidate.text)
                    .hidden()
                    .accessibilityHidden(true)
            }
            styled(blurb.text)
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Backup Include Options

/// The optional payloads of a Film Tracker backup, as offered by the tab's "Include:" picker.
///
/// Session-scoped: the tab holds the selection in its view model rather than in
/// `Preferences`, so it resets to "everything" each time the Settings sheet is opened. The
/// matching `Preferences` keys remain the fallback for exports the user did not drive from
/// this tab (see `DBExporter.createBackup(includePosters:)`).
enum BackupIncludeOption: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// The films, lists and releases themselves — the backup's base payload. Always
    /// included and always shown checked-but-disabled, so the picker reads as
    /// "the library, plus whichever of these two extras you want".
    case libraryContents
    case userSettings
    case posterImages

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .libraryContents: return "Library Contents"
        case .userSettings:    return "User Settings"
        case .posterImages:    return "Poster Images"
        }
    }

    static var all: Set<BackupIncludeOption> { Set(allCases) }
}

// MARK: - Multi-Select Picker

/// A pull-down that toggles members of a set, for the two "Include:" controls.
///
/// SwiftUI's `Picker` is single-selection on macOS, so the multi-select equivalent is a
/// `Menu` of checkmarked `Toggle`s — the same shape AppKit's own multi-value pop-ups take.
/// The closed label summarizes the selection rather than listing it, which keeps the two
/// blocks' rows the same width no matter what is checked.
struct MultiSelectPicker<Option: Identifiable & Hashable>: View {
    let options: [Option]
    let title: (Option) -> String

    /// The closed label when every option is checked — "All Content" / "All Sections".
    /// A lone selection names itself; anything in between reads "Mixed".
    let allLabel: String

    @Binding var selection: Set<Option>

    /// Options that are checked and cannot be unchecked — the backup's base payload.
    var alwaysOn: Set<Option> = []

    /// The floor the selection may not drop below. When the count is at the floor, the
    /// still-checked options lock themselves rather than the menu refusing the click,
    /// so the constraint is visible before it is hit.
    var minimumSelection: Int = 0

    var isEnabled: Bool = true

    /// The picker's fixed width. Both blocks use it so their rows agree.
    static var width: CGFloat { 200 }

    private var summary: String {
        if selection.count == options.count { return allLabel }
        // One item left is unambiguous, so name it rather than calling it "Mixed" —
        // "Mixed" is reserved for a genuinely partial selection of two or more.
        if selection.count == 1, let only = options.first(where: { selection.contains($0) }) {
            return title(only)
        }
        return "Mixed"
    }

    private func isLocked(_ option: Option) -> Bool {
        if alwaysOn.contains(option) { return true }
        return selection.contains(option) && selection.count <= minimumSelection
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Toggle(title(option), isOn: Binding(
                    get: { selection.contains(option) },
                    set: { isOn in
                        guard !isLocked(option) else { return }
                        if isOn { selection.insert(option) } else { selection.remove(option) }
                    }))
                .disabled(isLocked(option))
            }
        } label: {
            Text(summary)
        }
        // Default menu style, not .borderlessButton: the bordered pull-down with its
        // chevron is what reads as a picker next to the row's push button.
        .frame(width: Self.width)
        .disabled(!isEnabled)
    }
}

// MARK: - Export Block

/// A titled, boxed group of export controls.
///
/// Fill and outline are the path bar's, so the tab's three surfaces read as one family; the
/// "Backup Information from Selected File" box in the Restore tab carries the same chrome.
///
/// The height is a CONSTANT, not content-derived. The original version ended its stack with
/// a `Spacer(minLength: 0)`, which made each block a vertically greedy child of the tab's
/// VStack: the two blocks split the tab's slack and each grew to 177.5pt around a 20pt row,
/// and they resized again whenever the progress row below them claimed or released its own
/// space. Pinning the height fixes both — the blocks cannot move, and the slack they used to
/// absorb now sits in the tab's Spacer, between the second block and the progress row.
private struct ExportBlock<Content: View>: View {
    /// 72pt, against ~61pt of content (8 padding + 12.3 caption + 6 + 1 divider + 6 + 20 row
    /// + 8 padding). A quarter off the greedy 177.5pt would have been 133, but the tab has
    /// 535pt to work in and 133s put the layout 1pt over it — the overflow that pushed the
    /// tab past the sheet. This is the density the Restore tab's info box uses.
    static var height: CGFloat { 72 }

    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)

            Divider()

            // The row is centered in whatever is left below the divider rather than
            // hugging it. An expanding frame rather than a pair of Spacers: Spacers would
            // each pick up the stack's 6pt spacing and push the row off-center by half of
            // it. Safe here in a way it was not before — the block's height is fixed, so
            // this frame divides a known remainder instead of making the block itself
            // greedy inside the tab's stack.
            content()
                .frame(maxHeight: .infinity)
        }
        .padding(8)
        .frame(height: Self.height, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }
}

// MARK: - Export Progress

/// The shared in-progress chrome, presented identically for both export pipelines.
///
/// Always in the tree, faded rather than inserted: an `if` here would hand its height back
/// to the tab's Spacer on every appearance and disappearance, nudging everything above it.
/// Hidden, it still reserves its row, so the tab's geometry is the same mid-export as it is
/// at rest.
private struct ExportProgressRow: View {
    let isExporting: Bool
    let progress: Double
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Export in Progress…")
                .font(.system(size: 12))
                .foregroundStyle(.primary)

            ProgressView(value: progress)
                .frame(maxWidth: .infinity)

            Button("Cancel") { cancel() }
                .controlSize(.regular)
        }
        .opacity(isExporting ? 1 : 0)
        .allowsHitTesting(isExporting)
        .accessibilityHidden(!isExporting)
        .animation(.easeInOut(duration: 0.2), value: isExporting)
    }
}

// MARK: - Export Settings View

struct ExportSettingsView: View {
    @Bindable var viewModel: ExportViewModel

    /// Both export buttons wear the wider label's chrome, so the two rows line up on
    /// their trailing edge — "Export Backup" measures 89pt, "Export PDF" 69pt.
    private static let exportButtonWidth: CGFloat = 89

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsTabDescription(blurb: .export)

            // The destination below is shared by BOTH pipelines — a backup and a PDF are
            // both written into whatever folder is selected here.
            Text("Export Location:")
                .font(.headline)

            PathBarView(
                pathComponents: viewModel.displayPathComponents,
                icon: Image(systemName: "folder.fill"))
            .overlay(
                Button(action: { viewModel.selectDestination() }) {
                    Rectangle().foregroundStyle(.clear) }
                .buttonStyle(.plain))

            HStack(spacing: 12) {
                Button {
                    viewModel.selectDestination()
                } label: {
                    Text("Select Destination…")
                        .frame(width: Preferences.settingsSelectButtonWidth)
                }
                .controlSize(.regular)
                .disabled(viewModel.isExporting)
                Spacer() }

            Divider()

            ExportBlock(title: "Export Library as Film Tracker Backup") {
                HStack(spacing: 8) {
                    Text("Include:")
                    MultiSelectPicker(
                        options: BackupIncludeOption.allCases,
                        title: \.displayName,
                        allLabel: "All Content",
                        selection: $viewModel.backupIncludes,
                        alwaysOn: [.libraryContents],
                        isEnabled: !viewModel.isExporting)

                    Spacer()

                    Button { viewModel.startExport() } label: {
                        Text("Export Backup").frame(width: Self.exportButtonWidth)
                    }
                    .disabled(!viewModel.canExport)
                }
            }

            ExportBlock(title: "Export Library as PDF") {
                HStack(spacing: 8) {
                    Text("Include:")
                    MultiSelectPicker(
                        options: LibraryPDFSection.allCases,
                        title: \.displayName,
                        allLabel: "All Sections",
                        selection: $viewModel.pdfSections,
                        minimumSelection: 1,
                        isEnabled: !viewModel.isExporting)

                    Spacer()

                    Button { viewModel.exportLibraryPDF() } label: {
                        Text("Export PDF").frame(width: Self.exportButtonWidth)
                    }
                    .disabled(!viewModel.canExportPDF)
                }
            }

            Spacer()

            // One progress component for both pipelines, parked against the button gutter
            // at the same inset the tab uses on its other edges.
            ExportProgressRow(isExporting: viewModel.isExporting,
                              progress: viewModel.progress) {
                viewModel.cancelExport()
            }
        }
        .padding()
        // "Export Successful" alert.
        .alert("Export Successful", isPresented: $viewModel.showExportSuccess) {
            Button("OK") { }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(viewModel.exportSuccessMessage)
        }
        // "Export Failed" alert.
        .alert("Export Failed", isPresented: $viewModel.showExportFailure) {
            Button("OK") { }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(viewModel.exportFailureMessage)
        }
    }
}

// MARK: - Export View Model
@MainActor
@Observable
final class ExportViewModel: Loggable {
    nonisolated static let logTag = "[ExportViewModel]"

    private(set) var displayPathComponents: [String] = ["No location selected."]
    private(set) var isExporting: Bool = false
    private(set) var progress: Double = 0.0

    /// Session-scoped picker selections. Deliberately NOT backed by `Preferences`: the
    /// tab's spec is that both pickers reset to "everything included" every time the
    /// Settings sheet is opened, and this view model is rebuilt with the sheet.
    var backupIncludes: Set<BackupIncludeOption> = BackupIncludeOption.all
    var pdfSections: Set<LibraryPDFSection> = LibraryPDFSection.all

    // Alert state — two separate Bool+message pairs following the same pattern
    // used by RestoreViewModel. This avoids the deprecated Alert/Identifiable API.
    var showExportSuccess = false
    var exportSuccessMessage = ""
    var showExportFailure = false
    var exportFailureMessage = ""

    // Reference to the hosting window (Settings sheet) for proper panel attachment
    var hostingWindow: NSWindow?

    /// Both pipelines write into the one destination the tab's path bar names, so both
    /// buttons gate on the same resolved URL and on the same shared progress state.
    var canExport: Bool { resolvedDestinationURL != nil && !isExporting }

    /// As `canExport`, plus: a document with no sections selected would be an empty file.
    var canExportPDF: Bool { canExport && !pdfSections.isEmpty }

    // MARK: - Progress Presentation Timing
    //
    // The progress row is a fade-in/fade-out affair, and a small library finishes faster
    // than the fade does — so without these beats the user sees a bar arrive already full
    // and leave again, which reads as a glitch rather than as work being done. The rules
    // the export tasks follow:
    //
    //   1. Show the row, then WAIT for the fade-in to finish before any work starts, so the
    //      bar is never filling while it is still materializing.
    //   2. Keep the row on screen for at least `minimumVisibleDuration` once the work does
    //      start, however quickly the work returns.
    //   3. Hold the full bar, fade out, and only THEN reset progress to zero — resetting it
    //      any earlier would empty the bar in the middle of the fade.

    /// Matches `ExportProgressRow`'s fade, plus a frame's margin.
    private static let fadeDuration: Duration = .milliseconds(250)

    /// The floor on how long the bar is on screen and filling.
    private static let minimumVisibleDuration: Duration = .milliseconds(1200)

    /// The beat the finished bar is held at 100% before it fades.
    private static let completionHoldDuration: Duration = .milliseconds(600)

    /// Clears the previous run's state and waits out the row's fade-in. Callers must not
    /// touch `progress` until this returns.
    ///
    /// `isExporting` is raised SYNCHRONOUSLY by the caller before its task is created, not
    /// here: it is what disables both export buttons, and leaving it until the task's first
    /// hop would leave a window in which a second click could start a second export.
    private func beginExportPresentation() async {
        progress = 0.0
        showExportSuccess = false
        showExportFailure = false
        try? await Task.sleep(for: Self.fadeDuration)
    }

    /// Fills the bar, honors the minimum on-screen time, RAISES THE SUCCESS ALERT, fades
    /// the row out, and only then clears progress. `startedAt` is the instant the work
    /// itself began — i.e. after the fade-in, not before it.
    ///
    /// The alert is raised HERE, and specifically in the same MainActor turn that lowers
    /// `isExporting`, because those two are what closes the tab's last race. `isExporting`
    /// is the whole basis of `SettingsCoordinator.isSheetDismissBlocked` — lowering it
    /// re-enables the tab bar, the Close button, Escape and Return. The caller used to
    /// raise the alert AFTER awaiting this method, which put the fade's 250ms between the
    /// unlock and the alert: a Close or a tab switch landing in that window tore down the
    /// view that owns the `.alert` modifier, and the user's export finished with no
    /// confirmation at all.
    ///
    /// There is no "the alert is now on screen" callback to wait for — SwiftUI's `.alert`
    /// offers none — but none is needed, because the ordering can be made structural
    /// instead of timed. Setting the message and the flag and then clearing `isExporting`
    /// with no suspension point between them means SwiftUI observes all three in ONE
    /// update: the alert is presented by the same render pass that re-enables the
    /// controls, so there is no frame in which the controls are live and the alert is not.
    /// The remaining sleep only covers the row's fade, which now happens behind the alert.
    private func endExportPresentation(startedAt: ContinuousClock.Instant,
                                       successMessage: String) async {
        let elapsed = ContinuousClock.now - startedAt
        if elapsed < Self.minimumVisibleDuration {
            try? await Task.sleep(for: Self.minimumVisibleDuration - elapsed)
        }

        progress = 1.0
        try? await Task.sleep(for: Self.completionHoldDuration)

        // One turn, no awaits: alert up and controls released together.
        exportSuccessMessage = successMessage
        showExportSuccess = true
        isExporting = false

        try? await Task.sleep(for: Self.fadeDuration)
        progress = 0.0
    }

    /// The failure counterpart, with the same one-turn ordering. `abortExportPresentation`
    /// stays separate because a cancellation raises no alert at all.
    private func failExportPresentation(_ message: String) async {
        exportFailureMessage = message
        showExportFailure = true
        isExporting = false
        try? await Task.sleep(for: Self.fadeDuration)
        progress = 0.0
    }

    /// Tears the row down after a cancellation or a failure, leaving the bar where it
    /// stopped until the fade has actually finished.
    private func abortExportPresentation() async {
        isExporting = false
        try? await Task.sleep(for: Self.fadeDuration)
        progress = 0.0
    }

    private var resolvedDestinationURL: URL?
    private var exportTask: TaskHandle?
    private var exporter: DBExporter?
    private var isConfigured = false
    private weak var dataCoordinator: DataCoordinator?

    func configure(persistentContainer: NSPersistentContainer?,
                   dataCoordinator: DataCoordinator? = nil) {
        guard !isConfigured else { return }
        // The exporter is built from the NSPersistentContainer, never from a long-lived
        // NSManagedObjectContext: DBExporter creates a fresh NSManagedObjectContext per export internally, so
        // each backup reflects the current persisted state rather than a stale snapshot.
        guard let container = persistentContainer else { return }
        self.exporter = DBExporter(persistentContainer: container)
        self.dataCoordinator = dataCoordinator
        isConfigured = true }

    func loadSavedBookmarkIfNeeded() {
        // All bookmark I/O is routed through Preferences to ensure a single
        // canonical UserDefaults key ("preferences.exportPathBookmark").
        guard let url = Preferences.exportPathURL else {
            displayPathComponents = ["No location selected."]
            resolvedDestinationURL = nil
            return }

        resolvedDestinationURL = url
        updateDisplayPath(url: url) }

    private func updateDisplayPath(url: URL) {
        let comps = url.pathComponents.filter { $0 != "/" }
        displayPathComponents = comps.isEmpty ? [url.path(percentEncoded: false)] : comps }

    func selectDestination() {
        // Defer panel presentation to the next run-loop turn to avoid a "multiple
        // updates per frame" warning when the NSOpenPanel triggers focus changes.
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let config = OpenPanelConfiguration(canChooseFiles: false,
                canChooseDirectories: true, allowsMultipleSelection: false,
                allowedContentTypes: [], title: nil, message: "Select Export Destination",
                prompt: "Select")

            // Use hostingWindow to attach panel to the Settings sheet, not the main window.
            let selection = await OpenPanelPresenter.present(
                configuration: config,
                attachedTo: self.hostingWindow
            )
            guard case let .urls(urls) = selection,
                  let url = urls.first else { return }

            // Persist via Preferences so the bookmark key is always canonical.
            Preferences.exportPathURL = url
            self.resolvedDestinationURL = url
            self.updateDisplayPath(url: url)
            Self.log("Export destination set to '\(url.lastPathComponent)'") } }

    func startExport() {
        guard !isExporting, let dest = resolvedDestinationURL,
            let exporter = exporter else {
            Self.log("WARNING: startExport() called but preconditions were not met (isExporting=\(isExporting), hasDestination=\(resolvedDestinationURL != nil), hasExporter=\(exporter != nil))")
            return }

        let filename = BackupFilename.make(auto: false)

        isExporting = true

        Self.log("User-initiated export starting: filename='\(filename)', destination='\(dest.lastPathComponent)'")

        exportTask = TaskHandle(Task { [weak self] in
            guard let self = self else { return }

            // Raise the progress row and let it finish fading in before anything reports
            // a single percent — see the Progress Presentation Timing notes above.
            await self.beginExportPresentation()
            let startedAt = ContinuousClock.now

            do {
                // Access the resolved destination URL. Re-resolving the bookmark
                // here would be redundant and would also risk reading from a stale key.
                let started = dest.startAccessingSecurityScopedResource()
                defer { if started { dest.stopAccessingSecurityScopedResource() }}

                // The exporter reads the store, not memory: commit what is still
                // debounced (a preference changed on another tab of this sheet moments
                // ago, a recent Hall of Fame or wishlist drag) so the backup has it.
                await self.dataCoordinator?.commitPendingWritesForExport()

                // Collect posterUIDs from MemoryStore for orphan poster pruning.
                // In-memory read on MainActor — near-instant, no NSManagedObjectContext access required.
                //
                // Passed through as-is, including when it is EMPTY, so that this call agrees
                // with the automatic launch backup, which has always passed the set through
                // unconditioned. `nil` means "no DataCoordinator, so the set of valid UIDs is
                // unknown"; an empty set means "the coordinator answered, and no film in this
                // library claims a poster".
                //
                // An empty set does NOT cause every file in the posters folder to be pruned.
                // PosterPruner refuses to prune on an empty set at all, deliberately and
                // unconditionally — see the SAFETY note in pruneOrphanedPosters. From inside
                // the pruner "the library genuinely has no posters" and "the library could not
                // be read" are indistinguishable, and acting on the second would delete every
                // poster the user owns while the films that reference them are still intact.
                // So the two states differ only in which layer declines: `nil` stops at
                // DBExporter, empty stops at the pruner. Do not "fix" the pruner's guard to
                // make this comment's earlier wording come true.
                let posterUIDsTakenAt = Date()
                let posterUIDs: Set<String>? = self.dataCoordinator.map {
                    Set($0.getAllPosterUIDs()) }

                let result = try await exporter.createCompleteBackup(
                    filename: filename,
                    destinationURL: dest,
                    includeSettings: self.backupIncludes.contains(.userSettings),
                    includePosters: self.backupIncludes.contains(.posterImages),
                    posterUIDs: posterUIDs,
                    posterUIDsTakenAt: posterUIDsTakenAt,
                    progress: { @Sendable p in
                        Task { @MainActor in self.progress = p } })

                await self.endExportPresentation(
                    startedAt: startedAt,
                    successMessage:
                        "Your backup has been created successfully as \"\(result.packageURL.lastPathComponent)\" at the destination selected.")
                Self.log("Export succeeded: '\(result.packageURL.lastPathComponent)'")
            } catch is CancellationError {
                await self.abortExportPresentation()
                Self.log("NOTE: Export canceled by user: '\(filename)'")
                // No alert shown on cancellation — user initiated, state is already reset.
            } catch {
                await self.failExportPresentation(
                    "The export could not be completed:\n\n\(error.localizedDescription)")
                Self.log("WARNING: Export failed: '\(filename)': \(error.localizedDescription)") } }) }

    // MARK: - Library PDF Export

    /// Renders the library PDF into the tab's shared destination folder.
    ///
    /// Unlike the earlier standalone button, this does NOT prompt for a folder of its own:
    /// the destination section above applies to every export in the tab. It also drives the
    /// same `isExporting`/`progress` pair the backup does, which is what puts one progress
    /// component — and one sheet lock — behind both pipelines.
    func exportLibraryPDF() {
        guard !isExporting, let dest = resolvedDestinationURL else {
            Self.log("WARNING: exportLibraryPDF() called but preconditions were not met (isExporting=\(isExporting), hasDestination=\(resolvedDestinationURL != nil))")
            return }

        guard let coordinator = dataCoordinator else {
            exportFailureMessage =
                "The library PDF could not be created because the library is unavailable."
            showExportFailure = true
            Self.log("WARNING: Library PDF export aborted — no DataCoordinator")
            return }

        let sections = pdfSections
        guard !sections.isEmpty else { return }

        isExporting = true

        Self.log("User-initiated library PDF export starting: \(sections.count) section(s), destination='\(dest.lastPathComponent)'")

        exportTask = TaskHandle(Task { [weak self] in
            guard let self = self else { return }

            await self.beginExportPresentation()
            let startedAt = ContinuousClock.now

            do {
                let url = try await LibraryPDFExporter.export(
                    dataCoordinator: coordinator,
                    destinationFolder: dest,
                    sections: sections,
                    progress: { [weak self] p in self?.progress = p })

                // The same presentation beats the backup export uses, so the two pipelines
                // are indistinguishable from the progress component's point of view.
                await self.endExportPresentation(
                    startedAt: startedAt,
                    successMessage:
                        "Your library has been exported to \"\(url.lastPathComponent)\" at the destination selected.")
                Self.log("Library PDF export succeeded: '\(url.lastPathComponent)'")
            } catch is CancellationError {
                await self.abortExportPresentation()
                Self.log("NOTE: Library PDF export canceled by user")
                // No alert shown on cancellation — user initiated, state is already reset.
            } catch {
                await self.failExportPresentation(
                    "The library PDF could not be created:\n\n\(error.localizedDescription)")
                Self.log("WARNING: Library PDF export failed: \(error.localizedDescription)") } }) }

    func cancelExport() {
        // Nil the TaskHandle — its deinit cancels the underlying Task, which then
        // follows the CancellationError catch path to reset isExporting and progress.
        // Clearing state here in parallel would race with the task's own teardown.
        Self.log("User requested export cancellation")
        exportTask = nil
    }
}
