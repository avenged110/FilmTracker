// MARK: - SheetHostView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Invisible view that centralizes all sheet presentation logic with unified sheet coordinator.

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
    // Equality is determined solely by id. SheetContent contains non-Equatable associated
    // values (e.g. FilmSheet class references), so Equatable is implemented manually.
    // Two AppSheet instances with the same id represent the same logical sheet presentation.
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
    
    /// The presentation id a film sheet for `filmID` will carry.
    ///
    /// Split out of the factory below so a caller can ask whether that sheet is
    /// presentable BEFORE constructing the FilmSheet the factory demands — see the note
    /// on SheetHostView.handleAddFilm. One definition, so the id a path tests and the id
    /// it later registers cannot drift apart.
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
    func dismissSheet() {
        // Defer state change to next run loop to avoid "publishing changes during view update" error
        Task { @MainActor in
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
    
    // State to track a pending backup URL for the already-open-Settings edge case.
    // When Settings is already open and .openSettingsWithBackup arrives, the URL
    // cannot be embedded in a new AppSheet (re-presenting would dismiss/re-show the
    // sheet). Instead it is staged here and forwarded to SettingsCoordinator, which
    // SettingsSheet observes via onChange to navigate and load the file in-place.
    @State private var pendingBackupURL: URL?
    
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            // Sheet presentation observes coordinator changes via @Environment + @Bindable
            .sheet(item: Bindable(sheetCoordinator).activeSheet) { sheet in
                sheetContent(for: sheet)
                    .onDisappear {
                        sheetCoordinator.dismissSheet()
                    }
            }
            // Terminate-after-sheet-dismiss observer.
            //
            // When the database-error recovery flow sets pendingTerminationAfterSheetDismiss
            // and dismisses the Settings sheet, we need to call NSApp.terminate(nil) at the
            // precise moment AppKit stops blocking termination due to an attached sheet.
            //
            // AppKit's sheet window remains physically attached to the main window until the
            // dismiss animation COMPLETES, well after the SwiftUI binding clears — calling
            // NSApp.terminate(nil) before then is silently ignored. NSWindow.didEndSheetNotification
            // fires only once endSheet: has fully executed and the sheet is detached, so it is
            // the reliable signal. SwiftUI's .sheet(item:) is built on AppKit's native sheet
            // mechanism, so it's guaranteed to fire here.
            //
            // The pendingTerminationAfterSheetDismiss guard makes this a no-op for normal sheet
            // dismissals; it only acts when the quit-from-locked-restore path staged a pending
            // termination.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { note in
                // An alert closing on a sheet (SavedSearchSheet's, FilmSheet's) posts this
                // too, with the sheet's window as its object; the sheet is still on screen.
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
            // Re-anchor an open sheet after a display-configuration change.
            //
            // Workaround for a long-standing AppKit issue (also reproducible with plain
            // NSWindow/NSApp.beginSheet, so it's not SwiftUI-specific and there's no
            // first-party opt-out): if the set of attached displays changes while a sheet
            // is on screen, AppKit's sheet-positioning math can be computed against stale
            // screen geometry, leaving the sheet centered on the old, now-nonexistent
            // display arrangement — partially or fully off-screen, or offset from its
            // parent window. The sheet itself stays correctly attached and functional;
            // only its frame is wrong. Observed most reliably with an external-display
            // connect/disconnect while the Mac is locked or asleep.
            //
            // On didChangeScreenParametersNotification, if a sheet is attached to the main
            // window, its frame is recomputed explicitly — recentered horizontally and
            // top-aligned beneath the title bar (the standard resting position) — using
            // animator-free, synchronous math so it can't race the dismiss/present
            // animations tracked elsewhere in this file.
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification)) { _ in
                reanchorAttachedSheetIfNeeded()
            }
            // Forward a staged backup URL to an already-open SettingsSheet.
            // pendingBackupURL is set by handleOpenSettingsWithBackup when Settings is
            // already active and cannot be re-presented. Broadcasting via the event bus
            // reaches SettingsSheet's onChange handler, which navigates to the Restore
            // tab and calls loadBackupFile(_:) without dismissing the sheet.
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

    /// Recomputes and resets the frame of any sheet currently attached to the main
    /// window, correcting the misalignment that can follow a display-configuration
    /// change (see the doc comment on the didChangeScreenParametersNotification
    /// subscription above for the full rationale).
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
    // Constructing a FilmSheet is not free and is not free of side effects. Its init
    // eagerly builds all five tab view models (deliberately — see FilmSheet's note on
    // why they are not lazy), which reads the film out of MemoryStore five times, loads
    // and repairs every release, and arms a ReleaseChangeObserver per release. Doing
    // that before learning whether the sheet may even be presented threw the whole
    // graph away whenever another sheet was open.
    //
    // For handleAddFilm the ordering was not merely wasteful, it was destructive: the
    // selection was cleared unconditionally on the line above the construction, so
    // pressing Cmd+N while Settings, the Duplicate Finder, or the List Manager was open
    // wiped the user's selection and then declined to open anything, with no way to get
    // it back. `canPresentSheet(id:)` answers the same question `requestSheet` does
    // without committing to it, so every path can decline before it touches anything.

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
        // More than one film: the bulk editor, whatever tab was asked for (it has none).
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
        // `requestSheet` accepts a request whose id matches the active sheet, but treats
        // it as a no-op re-presentation: it keeps the live sheet and does not adopt the
        // one just handed to it. That is right for the general case and was wrong for
        // this one, because this path is the only one that CONFIGURES the sheet it
        // builds — `initialTab: .releases` plus the requested format. Both were built
        // into an instance that was then dropped on the floor, so invoking "Edit Film
        // Releases" on a film whose sheet was already open appeared to do nothing.
        //
        // Routed into the live instance instead, which is what the user asked for either
        // way: switch it to the Releases tab and reveal the requested format's first
        // card. `selectedTab`'s didSet records the tab in `appearedTabs`, so a Releases
        // tab that had never been visited is built by this exactly as a click on the tab
        // strip would build it.
        if let liveSheet = sheetCoordinator.activeFilmSheet(for: selectedID) {
            log("FilmSheet for \(selectedID) already open — routing releases request into it")
            liveSheet.selectedTab = .releases
            if let format {
                // revealFirstCard, not openOnFirstCard: the latter writes currentIndex
                // directly and is only correct before the carousel's first render (see
                // its doc comment). This carousel is on screen and may be mid-animation,
                // so the move goes through the navigation pipeline.
                // Commit first, for the same reason the carousel's own navigation does:
                // resolveFirstCard may change the destination card's displayed VARIANT, which
                // swaps the model under a card that keeps its SwiftUI identity. A TextField
                // still holding the window's field editor would be rebound in place, leaving
                // the editor clipped to stale geometry. See selectVariant in ReleasesView.
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

        // If a format was requested, position the carousel on that format's first card.
        //
        // Applied here, to the freshly constructed sheet, rather than being stashed for the
        // tab to consume on appear: the carousel is a single unified stack now, so "open on
        // this format" is a starting INDEX, and an index applied in `onAppear` would land
        // one body pass too late — the tab would render its first card and then jump.
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
        // Case A: Settings is already open.
        // Re-presenting (creating a new AppSheet with id "settings") would cause a
        // visible dismiss-and-reshow. Instead, stage the URL in pendingBackupURL —
        // SettingsSheet observes this via onChange and navigates to the Restore tab
        // then begins loading the file in-place, with no sheet dismissal.
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
