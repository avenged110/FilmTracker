// MARK: - SheetHostView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Defines the app's sheet types and their coordinator, and the invisible host view that presents the active sheet.

import SwiftUI

// MARK: - App Sheet Type

/// Sheet content type
enum SheetContent {
    case film(filmID: UUID?, sheet: FilmSheet)
    /// The bulk editor, for a selection of more than one film.
    case multiFilm(MultiFilmSheet)
    /// Settings sheet. `lockedToRestore` forces the sheet to open on the Restore tab
    /// and disables the tab bar and Close button for database-error recovery.
    /// `backupURL` carries a pre-selected backup file URL to load automatically when
    /// the Restore tab appears — used by the Finder double-click / "Open Settings" flow.
    case settings(selectedTab: SettingsTab, lockedToRestore: Bool = false, backupURL: URL? = nil)
    case duplicates
    case listManager(mode: ListManagerSheet.Mode, editID: UUID?, filmIDs: Set<UUID>?, prefillName: String? = nil)
    /// The "Up Next" slot picker, opened by clicking an empty slot (UpNextSlots.swift).
    case upNextSlot
    /// The saved-search builder: create, edit or duplicate a saved search.
    case savedSearch(SavedSearchSheet.Mode)
}

/// Unified sheet wrapper with stable ID
struct AppSheet: Identifiable, Equatable {
    // Equality is by id alone, because SheetContent holds non-Equatable values (such as FilmSheet
    // references). Equal ids mean the same logical presentation.
    static func == (lhs: AppSheet, rhs: AppSheet) -> Bool { lhs.id == rhs.id }

    let id: String
    let content: SheetContent
    
    var displayName: String {
        switch content {
        case .film: return "Film Sheet"
        case .multiFilm: return "Multi-Film Sheet"
        case .settings: return "Settings"
        case .duplicates: return "Duplicate Finder"
        case .listManager: return "List Manager"
        case .upNextSlot: return "Up Next Slot"
        case .savedSearch: return "Saved Search"
        }
    }
    
    /// The presentation id of a film sheet for `filmID`.
    ///
    /// Callers ask whether that sheet is presentable before building its FilmSheet (see the
    /// note on SheetHostView.handleAddFilm). One definition keeps the tested id and the
    /// registered id from drifting apart.
    static func filmSheetID(for filmID: UUID?) -> String {
        filmID.map { "film-\($0.uuidString)" } ?? "film-new"
    }

    // Factory functions for creating sheets with proper IDs
    static func film(filmID: UUID?, sheet: FilmSheet) -> AppSheet {
        AppSheet(id: filmSheetID(for: filmID), content: .film(filmID: filmID, sheet: sheet))
    }
    
    static func multiFilm(_ sheet: MultiFilmSheet) -> AppSheet {
        AppSheet(id: "multiFilm", content: .multiFilm(sheet))
    }

    static func settings(selectedTab: SettingsTab, lockedToRestore: Bool = false, backupURL: URL? = nil) -> AppSheet {
        AppSheet(id: "settings", content: .settings(selectedTab: selectedTab, lockedToRestore: lockedToRestore, backupURL: backupURL))
    }
    
    static func duplicates() -> AppSheet {
        AppSheet(id: "duplicates", content: .duplicates)
    }
    
    static func listManager(mode: ListManagerSheet.Mode, editID: UUID?, filmIDs: Set<UUID>? = nil, prefillName: String? = nil) -> AppSheet {
        AppSheet(id: "listManager", content: .listManager(mode: mode, editID: editID, filmIDs: filmIDs, prefillName: prefillName))
    }

    static func savedSearch(_ mode: SavedSearchSheet.Mode) -> AppSheet {
        AppSheet(id: "savedSearch", content: .savedSearch(mode))
    }

    static var upNextSlot: AppSheet {
        AppSheet(id: "upNextSlot", content: .upNextSlot)
    }
}

// MARK: - Sheet Coordinator

/// Centralized coordinator managing all sheet presentation through a single unified state
@MainActor
@Observable
final class SheetCoordinator: Loggable {
    nonisolated static let logTag = "[SheetCoordinator]"
    
    /// The currently active sheet, if any. Setting this will present the sheet.
    var activeSheet: AppSheet?
    
    /// Whether `requestSheet` would accept a sheet carrying `id`, without registering
    /// anything.
    ///
    /// Exists so a caller can decline early rather than building an expensive sheet — or
    /// taking a destructive preparatory step — only to have the request refused. Its
    /// answer is `requestSheet`'s, derived from the same two conditions, so the two
    /// cannot disagree about what is presentable.
    ///
    /// Note that a `true` answer for an id that is ALREADY active means "this request
    /// will be accepted", not "a new sheet will be presented" — `requestSheet` treats
    /// that as a no-op re-presentation and keeps the live sheet. Callers that carry
    /// configuration into the sheet must handle the already-active case themselves; see
    /// `activeFilmSheet(for:)`.
    func canPresentSheet(id: String) -> Bool {
        guard let current = activeSheet else { return true }
        return current.id == id
    }

    /// The live FilmSheet for `filmID`, when one is already on screen.
    ///
    /// The counterpart to `canPresentSheet(id:)` for the case that function deliberately
    /// reports as presentable-but-not-new. A command that would open a film sheet which
    /// is already open has to act on the instance that exists rather than on the one it
    /// was about to build, or it silently does nothing.
    func activeFilmSheet(for filmID: UUID?) -> FilmSheet? {
        guard let current = activeSheet,
              current.id == AppSheet.filmSheetID(for: filmID),
              case .film(_, let sheet) = current.content else { return nil }
        return sheet
    }

    /// Request to open a sheet. Returns true if allowed, false if blocked.
    func requestSheet(_ sheet: AppSheet) -> Bool {
        if let current = activeSheet {
            // Same sheet already active — allow (for re-presentation scenarios).
            if current.id == sheet.id {
                Self.log("Sheet request: \(sheet.displayName) already active")
                return true
            }
            // Different sheet is active — block.
            Self.log("Sheet request BLOCKED: \(sheet.displayName) (current: \(current.displayName))")
            return false
        }
        
        // No active sheet — register and allow.
        Self.log("Sheet request APPROVED: \(sheet.displayName)")
        activeSheet = sheet
        return true
    }
    
    /// Dismiss the currently active sheet
    func dismissSheet(id: String? = nil) {
        // The sheet being dismissed, resolved now. A dismissal arriving late — the
        // outgoing sheet's onDisappear fires only once its dismiss animation ends — must
        // not clear a different sheet requested in the meantime.
        let target = id ?? activeSheet?.id
        // Defer state change to next run loop to avoid "publishing changes during view update" error
        Task { @MainActor in
            guard let target, activeSheet?.id == target else {
                Self.log("Sheet dismissal skipped (no longer the active sheet)")
                return
            }
            if let current = activeSheet {
                Self.log("Sheet dismissed: \(current.displayName)")
                activeSheet = nil
            } else {
                Self.log("Sheet dismissed (already nil)")
            }
        }
    }
}

// MARK: - Sheet Host View

struct SheetHostView: View, Loggable {
    nonisolated static let logTag = "[SheetHostView]"

    @Environment(AppState.self) private var appState
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SelectionState.self) private var selectionState
    @Environment(SheetCoordinator.self) private var sheetCoordinator
    
    // Holds a backup URL for an already-open Settings sheet. A new AppSheet cannot carry it,
    // since re-presenting would dismiss and re-show the sheet. onChange below sends it on the
    // event bus, and SettingsSheet navigates to Restore and loads the file in place.
    @State private var pendingBackupURL: URL?
    
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            // Sheet presentation observes coordinator changes via @Environment + @Bindable
            .sheet(item: Bindable(sheetCoordinator).activeSheet) { sheet in
                sheetContent(for: sheet)
                    .onDisappear {
                        sheetCoordinator.dismissSheet(id: sheet.id)
                    }
            }
            // Terminates the app once a sheet dismissed by the locked-restore quit path has detached.
            // AppKit ignores NSApp.terminate while a sheet is attached, and the sheet stays attached
            // until its dismiss animation completes, after the SwiftUI binding has cleared. So the
            // reliable signal is NSWindow.didEndSheetNotification. The flag makes this a no-op for
            // ordinary dismissals.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { note in
                // An alert closing from a sheet posts this too, with the alert's window as the
                // object. The sheet itself is still on screen.
                if let window = note.object as? NSWindow, window.sheetParent != nil { return }
                // Clear the physical-presence flag when AppKit confirms the sheet window
                // has fully detached. This is the authoritative "sheet is gone" signal —
                // more reliable than sheetCoordinator.activeSheet (which clears when the
                // dismiss animation begins, not when it ends).
                appState.isSheetPresented = false
                guard appState.pendingTerminationAfterSheetDismiss else { return }
                appState.pendingTerminationAfterSheetDismiss = false
                NSApp.terminate(nil)
            }
            // Track physical sheet presence for AlertHostView's sheet-active guard.
            // Set immediately when a sheet is requested (activeSheet goes non-nil) so
            // the guard is in place before any presentation animation begins.
            .onChange(of: sheetCoordinator.activeSheet) { _, newSheet in
                if newSheet != nil {
                    appState.isSheetPresented = true
                }
                // Clearing is handled exclusively by didEndSheetNotification above,
                // which fires only when the sheet window is fully detached from the
                // main window — never here, to avoid clearing during dismiss animations.
            }
            // Single consolidated event listener
            .onReceive(AppEventBus.shared.uiCommands) { command in
                handleUICommand(command)
            }
            // Re-anchors an open sheet after a display-configuration change. AppKit can position a
            // sheet against stale screen geometry (a long-standing issue that plain NSWindow sheets
            // share, so there is no first-party fix). The sheet can end up off-screen or offset from
            // its parent; it stays attached and works, only its frame is wrong. Most reliably seen on
            // an external-display connect or disconnect while the Mac is locked or asleep.
            //
            // On didChangeScreenParametersNotification, reanchorAttachedSheetIfNeeded() recenters the
            // sheet and top-aligns it beneath the title bar, using synchronous frame math so it cannot
            // race the present and dismiss animations.
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification)) { _ in
                reanchorAttachedSheetIfNeeded()
            }
            // Forwards a staged backup URL to an already-open SettingsSheet. Sending it on the event
            // bus makes SettingsSheet navigate to the Restore tab and load the file without dismissing.
            .onChange(of: pendingBackupURL) { _, newURL in
                guard let url = newURL else { return }
                AppEventBus.shared.send(.view(.loadBackupFile(url)))
                pendingBackupURL = nil
            }
    }
    
    // MARK: - Sheet Content Builder
    @ViewBuilder
    private func sheetContent(for sheet: AppSheet) -> some View {
        switch sheet.content {
        case .film(_, let filmSheet):
            FilmSheetView(owner: filmSheet)

        case .multiFilm(let sheet):
            MultiFilmSheetView(owner: sheet)
            
        case .settings(let selectedTab, let lockedToRestore, let backupURL):
            SettingsSheet(initialTab: selectedTab, lockedToRestore: lockedToRestore, backupURL: backupURL)
                .environment(appState)
                .environment(sheetCoordinator)
            
        case .duplicates:
            DuplicateSheet()
                .environment(appState)
                .environment(dataCoordinator)
                .environment(sheetCoordinator)
            
        case .listManager(let mode, let editID, let filmIDs, let prefillName):
            ListManagerSheet(mode: mode, existingListID: editID, filmIDs: filmIDs, prefillName: prefillName)
                .environment(dataCoordinator)
                .environment(sheetCoordinator)
                .interactiveDismissDisabled(false)

        case .upNextSlot:
            UpNextSlotSheet()
                .environment(dataCoordinator)
                .environment(sheetCoordinator)

        case .savedSearch(let mode):
            SavedSearchSheet(mode: mode, coordinator: dataCoordinator)
                .environment(dataCoordinator)
                .environment(sheetCoordinator)
        }
    }
    
    // MARK: - Command Handlers
    
    private func handleUICommand(_ command: UICommand) {
        switch command {
        case .addFilm:
            handleAddFilm()
        case .editFilm:
            handleEditFilm()
        case .editFilmMetadata:
            handleEditFilm(initialTab: .metadata)
        case .editFilmReleases(let format):
            handleEditFilmReleases(format: format)
        case .findDuplicates:
            present(.duplicates())
        case .showListCreation:
            present(.listManager(mode: .create, editID: nil))
        case .showListCreationFromSelection(let filmIDs, let prefillName):
            present(.listManager(mode: .create, editID: nil, filmIDs: filmIDs, prefillName: prefillName))
        case .duplicateList(let listID):
            handleDuplicateList(listID)
        case .editList(let listID):
            present(.listManager(mode: .edit, editID: listID))
        case .openSettingsToTab(let tab):
            present(.settings(selectedTab: tab))
        case .openSettingsWithBackup(let file):
            handleOpenSettingsWithBackup(file: file)
        case .openSettingsLockedToRestore:
            // Locked mode rides in the sheet content so SettingsSheet.onAppear can
            // activate the lock immediately, without a secondary broadcast that could
            // cause re-entry.
            present(.settings(selectedTab: .restore, lockedToRestore: true))
        case .openUpNextSlot:
            present(.upNextSlot)
        case .showSavedSearchSheet(let mode):
            present(.savedSearch(mode))
        // Other commands handled elsewhere
        default:
            break
        }
    }
    
    // MARK: - Display-Change Sheet Recovery

    /// Recomputes and resets the frame of any sheet attached to the main window, correcting the
    /// misalignment a display-configuration change can cause (see the comment on the
    /// didChangeScreenParametersNotification subscription above).
    ///
    /// No-op when no sheet is attached, which is the overwhelmingly common case this
    /// notification fires for (e.g. a resolution or scaling change with no sheet open).
    private func reanchorAttachedSheetIfNeeded() {
        guard let mainWindow = NSApp.mainWindow,
              let sheetWindow = mainWindow.attachedSheet else { return }

        let parentFrame = mainWindow.frame
        var sheetFrame = sheetWindow.frame

        // Center horizontally on the parent window.
        sheetFrame.origin.x = parentFrame.origin.x + (parentFrame.width - sheetFrame.width) / 2

        // Top-align just beneath the parent's title bar. NSWindow's frame origin is
        // its bottom-left corner in screen coordinates, so the sheet's top edge sits
        // at parentFrame.maxY minus the title bar height; the sheet's own origin.y is
        // that value minus the sheet's own height.
        let titleBarHeight = parentFrame.height - mainWindow.contentLayoutRect.height
        let sheetTopY = parentFrame.origin.y + parentFrame.height - titleBarHeight
        sheetFrame.origin.y = sheetTopY - sheetFrame.height

        // Clamp to the screen the parent window currently resides on, so a parent
        // window that itself ended up partially off-screen after the display change
        // can't drag the sheet fully off-screen with it.
        if let targetScreen = mainWindow.screen ?? NSScreen.main {
            let visible = targetScreen.visibleFrame
            sheetFrame.origin.x = min(max(sheetFrame.origin.x, visible.minX),
                                       visible.maxX - sheetFrame.width)
            sheetFrame.origin.y = min(max(sheetFrame.origin.y, visible.minY),
                                       visible.maxY - sheetFrame.height)
        }

        sheetWindow.setFrame(sheetFrame, display: true, animate: false)
        log("Re-anchored attached sheet after display configuration change")
    }

    // MARK: - Sheet Presentation Handlers
    // MARK: Why every film path asks BEFORE it builds
    //
    // Building a FilmSheet is costly and has side effects. Its init builds all of its tab view
    // models, which reads the film from MemoryStore, loads and repairs every release, and arms a
    // ReleaseChangeObserver per release. Building one only to learn another sheet is open
    // discards that work.
    //
    // handleAddFilm once cleared the selection before that check, so Cmd+N with Settings, the
    // Duplicate Finder or the List Manager open wiped the selection and opened nothing. Every path
    // now asks `canPresentSheet(id:)` first, which answers as `requestSheet` would, without committing.

    /// Asks whether a film sheet for `filmID` may be presented, logging a refusal.
    private func canPresentFilmSheet(for filmID: UUID?) -> Bool {
        guard sheetCoordinator.canPresentSheet(id: AppSheet.filmSheetID(for: filmID)) else {
            log("Cannot open FilmSheet - another sheet is active")
            return false
        }
        return true
    }

    /// The tail all three film paths share: wire the sheet's dismissal and register it.
    private func presentFilmSheet(_ filmSheet: FilmSheet, filmID: UUID?) {
        filmSheet.dismissHandler = { [weak sheetCoordinator] in
            sheetCoordinator?.dismissSheet()
        }
        present(.film(filmID: filmID, sheet: filmSheet))
    }

    /// Registers `sheet`, logging when another sheet already holds the window.
    private func present(_ sheet: AppSheet) {
        guard sheetCoordinator.requestSheet(sheet) else {
            log("Cannot open \(sheet.displayName) - another sheet is active")
            return
        }
    }

    private func handleAddFilm() {
        guard canPresentFilmSheet(for: nil) else { return }

        // The FilmSheet serves both as an editor for an existing film and as the
        // "Add New" form. Any selection left standing while the sheet is open in the
        // latter capacity is ambiguous — the sheet is not editing that film, but every
        // selection-driven surface (RightSidebar, status bar, menu items) still reads as
        // though it were. Cleared synchronously, and only once the sheet is known to be
        // presentable.
        selectionState.clearImmediate()

        presentFilmSheet(FilmSheet(coordinator: dataCoordinator, filmID: nil), filmID: nil)
    }

    private func handleEditFilm(initialTab: FilmTab = .details) {
        // More than one film: the bulk editor, whatever tab was asked for.
        if selectionState.selectedFilmIDs.count > 1 {
            handleEditFilms(selectionState.selectedFilmIDs)
            return
        }
        guard let selectedID = selectionState.selectedFilmID else {
            log("No film selected for editing")
            return
        }

        // Same reasoning as handleEditFilmReleases: a request for a specific tab on a
        // film whose sheet is already open is routed into the live instance.
        if initialTab != .details, let liveSheet = sheetCoordinator.activeFilmSheet(for: selectedID) {
            liveSheet.selectedTab = initialTab
            return
        }

        guard canPresentFilmSheet(for: selectedID) else { return }

        presentFilmSheet(FilmSheet(coordinator: dataCoordinator, filmID: selectedID,
                                   initialTab: initialTab),
                         filmID: selectedID)
    }

    /// Opens the MultiFilmSheet on `filmIDs`, listed in the gallery's order — what the user
    /// was looking at when they selected them. Selected films the gallery is not showing
    /// (none, normally) follow, by title.
    private func handleEditFilms(_ filmIDs: Set<UUID>) {
        guard sheetCoordinator.canPresentSheet(id: "multiFilm") else {
            log("Cannot open MultiFilmSheet - another sheet is active")
            return
        }
        let shown = dataCoordinator.films.map(\.id).filter(filmIDs.contains)
        let rest = filmIDs.subtracting(shown).compactMap { dataCoordinator.getFilm($0) }
            .sorted { $0.name.englishStandardCompare($1.name) == .orderedAscending }
            .map(\.id)
        let sheet = MultiFilmSheet(coordinator: dataCoordinator, filmIDs: shown + rest)
        sheet.dismissHandler = { [weak sheetCoordinator] in
            sheetCoordinator?.dismissSheet()
        }
        present(.multiFilm(sheet))
    }

    private func handleEditFilmReleases(format: String?) {
        guard let selectedID = selectionState.selectedFilmID else {
            log("No film selected for releases editing")
            return
        }

        // MARK: The film's sheet is already open
        //
        // `requestSheet` treats a request for the active sheet's id as a no-op re-presentation and
        // keeps the live sheet. That is fine in general, but this path configures the sheet it builds
        // (the Releases tab and format), so those settings would be lost. Route the request into the
        // live instance instead: switch it to the Releases tab and reveal the format's first card.
        // `selectedTab`'s didSet records the tab in `appearedTabs`, so an unvisited Releases tab is built
        // exactly as a click on the tab strip would build it.
        if let liveSheet = sheetCoordinator.activeFilmSheet(for: selectedID) {
            log("FilmSheet for \(selectedID) already open — routing releases request into it")
            liveSheet.selectedTab = .releases
            if let format {
                // revealFirstCard, not openOnFirstCard: openOnFirstCard writes the index directly and is
                // only correct before the first render (see its doc comment). This carousel is on screen,
                // possibly mid-animation, so the move goes through the navigation pipeline. Commit first,
                // as the carousel's own navigation does: resolveFirstCard may change the destination
                // card's displayed variant, which swaps the model under a card with a stable identity. A
                // TextField still holding the field editor would then be rebound in place. See selectVariant
                // in ReleasesView.
                commitPendingFieldEdit()
                liveSheet.releasesTab.revealFirstCard(ofFormat: format)
                log("Revealing the first \(format) release in the open sheet")
            }
            return
        }

        guard canPresentFilmSheet(for: selectedID) else { return }

        // Passed to init rather than assigned afterward: FilmSheet seeds its
        // `appearedTabs` set from the initial tab, and a post-init assignment would
        // leave `.details` in that set — building and laying out a tab the user never
        // asked to see.
        let filmSheet = FilmSheet(coordinator: dataCoordinator,
                                  filmID: selectedID,
                                  initialTab: .releases)

        // If a format was requested, position the carousel on that format's first card. This is
        // done on the new sheet here, not in the tab's onAppear: the carousel is one stack, so the
        // format is a starting index, and an index set in onAppear would land a body pass late.
        if let format {
            filmSheet.releasesTab.openOnFirstCard(ofFormat: format)
            log("Opening releases carousel on the first \(format) release")
        }

        presentFilmSheet(filmSheet, filmID: selectedID)
    }
    
    private func handleDuplicateList(_ listID: UUID) {
        guard let sourceList = dataCoordinator.getList(listID) else {
            log("Cannot duplicate list — list \(listID) not found")
            return
        }
        let filmIDs = sourceList.filmIDs
        let rawName = sourceList.listName
        let baseName = Self.duplicateBaseName(for: rawName, coordinator: dataCoordinator)
        log("Duplicating list '\(rawName)' (base: '\(baseName)') with \(filmIDs.count) film(s)")
        Task {
            _ = ListManager.createList(baseName: baseName,
            coordinator: dataCoordinator, filmIDs: filmIDs.isEmpty ? nil : filmIDs)
        }
    }
    
    /// The base name `ListManager.createList`'s collision-avoidance should start from when
    /// duplicating the list currently named `rawName`.
    ///
    /// A trailing " <number>" is stripped ONLY when the remainder is itself the name of an
    /// existing list — that's what distinguishes a suffix this app generated from a number
    /// that's part of the title the user chose. Otherwise "Blade Runner 2049" or "Top 100"
    /// would lose their trailing digits on duplication. "List"/"List 1" still duplicates to
    /// "List 2", not "List 1 1", because "List" exists as a base to strip to.
    private static func duplicateBaseName(for rawName: String,
                                          coordinator: DataCoordinator) -> String {
        let stripped = rawName.replacingOccurrences(
            of: #"\s+\d+$"#, with: "", options: .regularExpression)
        guard stripped != rawName, !stripped.isEmpty else { return rawName }

        // Case-insensitive, matching generateUniqueName's own comparison.
        let target = stripped.lowercased()
        let baseExists = coordinator.getAllLists().contains { $0.listName.lowercased() == target }
        return baseExists ? stripped : rawName
    }


    private func handleOpenSettingsWithBackup(file: URL?) {
        // Case A: Settings is already open. Re-presenting (a new AppSheet with id "settings")
        // would dismiss and re-show it. Stage the URL in pendingBackupURL instead: onChange
        // forwards it on the event bus, and SettingsSheet loads the file in place.
        if let current = sheetCoordinator.activeSheet, current.id == "settings" {
            log("Settings already open — forwarding backup URL in-place")
            pendingBackupURL = file
            return
        }

        // Case B: Settings is not open. Open it on the Restore tab carrying the URL.
        // SettingsSheet.onAppear picks up backupURL and calls loadBackupFile(_:).
        present(.settings(selectedTab: .restore, backupURL: file))
    }
}
