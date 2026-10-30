// MARK: - AlertHostView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Invisible view that exists solely to listen for alert events and present
// user-facing alerts. Centralizes all alert logic from across the application.

import SwiftUI

// MARK: - Host Alert

/// One alert AlertHostView can show, carrying everything its buttons act on.
///
/// The payload travels WITH the alert rather than in view state beside it, so a request
/// that arrives while another alert is open can neither retarget the open one nor lose its
/// own. (With a flag per alert and shared payload fields, a second "Remove from All Lists"
/// made the open alert's Remove act on the second request's films, and a "Remove List"
/// arriving under "Remove from List" redirected the removal to the wrong list and then did
/// nothing itself.)
enum HostAlert {
    /// A Film Queue add awaiting confirmation (sidebar drop or "Add to Queue" menu).
    struct QueueAdd {
        let filmIDs: Set<UUID>
        let listID: UUID
        /// Composed once when the request arrives, freezing it to the films' state then
        /// and keeping coordinator lookups out of the presentation's body passes.
        let message: String
        /// True for the menu path; confirming then also arms the post-move scroll.
        let fromMenu: Bool
    }

    /// The file itself is held in AlertHostView's `backupFile`, not here — see there.
    case backupRestore
    case removeList(listID: UUID, listName: String)
    case deleteSavedSearch(id: UUID, name: String)
    case deleteListContents(listID: UUID, listName: String, filmIDs: [UUID])
    case clearListContents(listID: UUID, listName: String, filmCount: Int)
    // `clearingSelection` carries the sender's FilmRemoval choice through the alert, so a
    // confirmed removal treats the selection exactly as the unconfirmed one would.
    case removeFromList(filmIDs: Set<UUID>, listID: UUID, listName: String, clearingSelection: Bool)
    case removeFromAllLists(filmIDs: Set<UUID>, clearingSelection: Bool)
    case deleteFromLibrary(filmIDs: Set<UUID>, clearingSelection: Bool)
    case removeFromHallOfFame(filmIDs: Set<UUID>, clearingSelection: Bool)
    case removeFromFilmQueue(filmIDs: Set<UUID>, clearingSelection: Bool)
    case filmQueueAdd(QueueAdd)
    /// Full, uncapped fault text from the failed write. Shown (elided) when debug logging
    /// is off, and copied whole by the alert's "Copy Error" button.
    case persistenceFailure(detail: String?)
    /// Launch-time fatal store failure: the store could not be OPENED.
    case databaseError
    /// The store opened, but the startup fetch threw. Deliberately distinct from
    /// `databaseError`, which offers "Create New Library" — deleting the existing store.
    /// Here the store is presumed intact and only the read failed; offering a destructive
    /// option for a recoverable, likely-transient fault would be the single worst thing
    /// this alert could do, so it offers none.
    case libraryReadFailure
    /// Shown after "Create New Library" completes.
    case newLibraryResult(success: Bool, message: String)
    case duplicateViewingDate
    case calendarEventFailure
    /// A plain informational alert with a single "OK" (AlertCommand.showNotice).
    case notice(title: String, message: String)
    /// A LeftSidebar drop on the "Up Next" row that would overflow it. Offers to send the
    /// films to "Soon" instead (AlertCommand.offerSoonForFullUpNextDrop).
    case upNextFullDrop(filmIDs: Set<UUID>, message: String)

    /// Which alert this is, payload aside — what coalescing and the one-at-a-time rules
    /// compare.
    enum Kind {
        case backupRestore, removeList, deleteSavedSearch, deleteListContents, clearListContents, removeFromList
        case removeFromAllLists, deleteFromLibrary, removeFromHallOfFame, removeFromFilmQueue
        case filmQueueAdd, persistenceFailure, databaseError, libraryReadFailure
        case newLibraryResult, duplicateViewingDate, calendarEventFailure, notice
        case upNextFullDrop
    }

    var kind: Kind {
        switch self {
        case .backupRestore: .backupRestore
        case .removeList: .removeList
        case .deleteSavedSearch: .deleteSavedSearch
        case .deleteListContents: .deleteListContents
        case .clearListContents: .clearListContents
        case .removeFromList: .removeFromList
        case .removeFromAllLists: .removeFromAllLists
        case .deleteFromLibrary: .deleteFromLibrary
        case .removeFromHallOfFame: .removeFromHallOfFame
        case .removeFromFilmQueue: .removeFromFilmQueue
        case .filmQueueAdd: .filmQueueAdd
        case .persistenceFailure: .persistenceFailure
        case .databaseError: .databaseError
        case .libraryReadFailure: .libraryReadFailure
        case .newLibraryResult: .newLibraryResult
        case .duplicateViewingDate: .duplicateViewingDate
        case .calendarEventFailure: .calendarEventFailure
        case .notice: .notice
        case .upNextFullDrop: .upNextFullDrop
        }
    }

    var title: String {
        switch self {
        case .backupRestore: "Restore from Backup"
        case .removeList: "Remove List"
        case .deleteSavedSearch: "Delete Saved Search?"
        case .deleteListContents: "Delete List Contents"
        case .clearListContents: "Clear List Contents"
        // The Film Queue removal shares the list wording: to the user the queue sections
        // are lists.
        case .removeFromList, .removeFromFilmQueue: "Remove from List"
        case .removeFromAllLists: "Remove from All Lists"
        case .deleteFromLibrary: "Delete from Library"
        case .removeFromHallOfFame: "Remove from Hall of Fame"
        case .filmQueueAdd: "Add to Queue"
        case .persistenceFailure: "Database Write Failed"
        case .databaseError: "Library Unavailable"
        case .libraryReadFailure: "Library Could Not Be Read"
        case .newLibraryResult(let success, _): success ? "Library Created" : "Error Creating Library"
        case .duplicateViewingDate: "Event Already Exists"
        case .calendarEventFailure: "Calendar Event Not Created"
        case .notice(let title, _): title
        case .upNextFullDrop: FilmQueue.upNextFullTitle
        }
    }
}

// MARK: - Alert Host View

struct AlertHostView: View, Loggable {
    nonisolated static let logTag = "[AlertHostView]"

    @Environment(AppState.self) private var appState
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SelectionState.self) private var selectionState

    // Cached preference for alert message composition.
    @AppStorage(preference: Preferences.loggingEnabledKey) private var loggingEnabled: Bool

    /// The alert on screen.
    @State private var presented: HostAlert?
    /// Alerts requested while another was open, in arrival order. Each is shown when the
    /// one before it is answered — the order SwiftUI's per-alert flags used to produce,
    /// now with each alert's own payload intact.
    @State private var waiting: [HostAlert] = []
    /// A Film Queue drop waiting for its drag session to end before it is presented (see
    /// the `.dragSessionDidEnd` handler).
    @State private var stashedQueueDrop: HostAlert.QueueAdd?
    /// A notice sent from inside a drag (AlertCommand.showNotice with afterDragSession),
    /// held for the same `.dragSessionDidEnd` hand-off as `stashedQueueDrop`.
    @State private var stashedNotice: HostAlert?
    /// The backup file the restore prompt opens. Kept beside the alert rather than in it:
    /// a second backup-open retargets the prompt already on screen, and an open alert keeps
    /// the payload it was drawn with, so its button reads this at click time instead.
    @State private var backupFile: URL?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .alert(Text(presented?.title ?? ""), isPresented: Binding(
                get: { presented != nil },
                set: { if !$0 { presented = nil } }),
                   presenting: presented) { alert in
                actions(for: alert)
            } message: { alert in
                message(for: alert)
            }
            // The next waiting alert goes up one turn after the answered one is dismissed,
            // off the dismissal's own call stack.
            .onChange(of: presented == nil) { _, isEmpty in
                guard isEmpty else { return }
                DispatchQueue.main.async { presentNextWaiting() }
            }
            .onReceive(AppEventBus.shared.alertCommands) { receive($0) }
            // MARK: Deferred Film Queue Drop Alert Presentation
            // GalleryDragEngine posts .dragSessionDidEnd from its session-end callbacks
            // (both the grid's NSDraggingSource endedAt and the list's forwarded table
            // endedAt), which AppKit defers until after its drag-completion rendering
            // pass. Presenting here — rather than when the .confirmFilmQueueAddOnDrop
            // event was stashed — is what lets Core Animation drive the alert's appear
            // animation: nothing from the drag teardown is left contending for the main
            // thread. A session end with nothing stashed (unconfirmed drops, user-list
            // drops, canceled drags) is a no-op. The one-turn DispatchQueue.main.async hop
            // moves the presentation off the notification's delivery stack, which is still
            // inside the AppKit endedAt delegate callback — matching the codebase-wide rule
            // of never mutating presentation state synchronously from AppKit delegate
            // contexts (main.async over Task for run-loop ordering and QoS inheritance).
            .onReceive(NotificationCenter.default.publisher(for: .dragSessionDidEnd)) { _ in
                // A drop-time notice rides the same hand-off as the Queue drop below.
                if stashedNotice != nil {
                    DispatchQueue.main.async {
                        guard let notice = stashedNotice else { return }
                        stashedNotice = nil
                        enqueue(notice)
                    }
                }
                guard stashedQueueDrop != nil, !hasAlert(.filmQueueAdd) else { return }
                DispatchQueue.main.async {
                    guard let add = stashedQueueDrop else { return }
                    stashedQueueDrop = nil
                    enqueue(.filmQueueAdd(add))
                }
            }
            // Publishes "an alert is on screen or waiting" for MenuBar's lock. The two
            // database-error alerts keep their own isDatabaseErrorAlertActive as well; this
            // flag is what also locks the menu under "Library Could Not Be Read" and every
            // confirmation.
            .onChange(of: isAnyAlertActive, initial: true) { _, isActive in
                appState.isHostAlertActive = isActive
            }
            // Locks the menu bar while "Library Unavailable" or its result is up.
            .onChange(of: isDatabaseAlertActive) { _, isActive in
                appState.isDatabaseErrorAlertActive = isActive
            }
    }

    // MARK: - Queue

    private var isAnyAlertActive: Bool { presented != nil || !waiting.isEmpty }

    private var isDatabaseAlertActive: Bool {
        hasAlert(.databaseError) || hasAlert(.newLibraryResult)
    }

    /// Whether an alert of `kind` is on screen or waiting.
    private func hasAlert(_ kind: HostAlert.Kind) -> Bool {
        presented?.kind == kind || waiting.contains { $0.kind == kind }
    }

    /// Shows `alert` now, or behind whatever is open or already waiting.
    private func enqueue(_ alert: HostAlert) {
        if presented == nil && waiting.isEmpty {
            presented = alert
        } else {
            waiting.append(alert)
        }
    }

    /// Replaces the alert of the same kind that is on screen or waiting, or queues `alert`
    /// when there is none — so a burst of the same notice is one alert carrying the latest
    /// detail, as it was when each alert was a single flag.
    private func coalesce(_ alert: HostAlert) {
        if presented?.kind == alert.kind {
            presented = alert
        } else if let index = waiting.firstIndex(where: { $0.kind == alert.kind }) {
            waiting[index] = alert
        } else {
            enqueue(alert)
        }
    }

    private func presentNextWaiting() {
        guard presented == nil, !waiting.isEmpty else { return }
        presented = waiting.removeFirst()
    }

    // MARK: - Requests

    private func receive(_ command: AlertCommand) {
        switch command {
        case .showBackupRestoreAlert(_, let file):
            // isSheetPresented is the authoritative physical-presence flag managed by
            // SheetHostView. It is set true when any sheet begins presenting and cleared
            // only when NSWindow.didEndSheetNotification fires — after the dismiss
            // animation fully completes. This is deliberately more conservative than
            // sheetCoordinator.activeSheet, which clears at animation start and would
            // create a race window.
            //
            // Three cases:
            // A) No sheet on screen: present the confirmation alert normally.
            // B) Settings sheet on screen: forward directly to the in-place load path — no
            //    alert needed, user is already in the right place. The "Restore Database"
            //    button in STabRestore is the confirmation.
            // C) Any other sheet on screen: discard silently. The user must dismiss that
            //    sheet first to open a backup file.
            //
            // Another alert on screen or waiting is treated like case C: the prompt would
            // otherwise surface later, out of context. Re-opening while the restore prompt
            // itself is up just retargets it.
            if isAnyAlertActive && !hasAlert(.backupRestore) {
                log("Backup file open ignored — another alert is on screen")
            } else if !appState.isSheetPresented {
                backupFile = file
                coalesce(.backupRestore)
            } else if appState.sheetCoordinator.activeSheet?.id == "settings" {
                AppEventBus.shared.sendCommand(.openSettingsWithBackup(file: file))
            } else {
                log("Backup file open ignored — sheet '\(appState.sheetCoordinator.activeSheet?.id ?? "unknown")' is active")
            }
        case .confirmRemoveList(let listID, let listName):
            enqueue(.removeList(listID: listID, listName: listName))
        case .confirmDeleteSavedSearch(let id, let name):
            enqueue(.deleteSavedSearch(id: id, name: name))
        case .confirmDeleteContents(let listID, let listName):
            // The film IDs are not carried on the event, so they are read here, once.
            if let list = dataCoordinator.getList(listID) {
                enqueue(.deleteListContents(listID: listID, listName: listName,
                                            filmIDs: Array(list.filmIDs)))
            }
        case .confirmClearContents(let listID, let listName):
            // Film count is not carried on the event either; same O(1) lookup.
            if let list = dataCoordinator.getList(listID) {
                enqueue(.clearListContents(listID: listID, listName: listName,
                                           filmCount: list.filmIDs.count))
            }
        case .confirmRemoveFromList(let filmIDs, let listID, let listName, let clearing):
            enqueue(.removeFromList(filmIDs: filmIDs, listID: listID, listName: listName,
                                    clearingSelection: clearing))
        case .confirmRemoveFromAllLists(let filmIDs, let clearing):
            enqueue(.removeFromAllLists(filmIDs: filmIDs, clearingSelection: clearing))
        case .confirmDeleteFromLibrary(let filmIDs, let clearing):
            // "Delete from Library" always routes to the standard single-purpose alert.
            // The dedicated "Remove from List" menu item handles the list-removal path.
            enqueue(.deleteFromLibrary(filmIDs: filmIDs, clearingSelection: clearing))
        case .confirmRemoveFromHallOfFame(let filmIDs, let clearing):
            enqueue(.removeFromHallOfFame(filmIDs: filmIDs, clearingSelection: clearing))
        case .confirmRemoveFromFilmQueue(let filmIDs, let clearing):
            enqueue(.removeFromFilmQueue(filmIDs: filmIDs, clearingSelection: clearing))
        case .confirmFilmQueueAddOnDrop(let filmIDs, let listID):
            // Sent synchronously from LeftSidebar's performDragOperation, i.e. this handler
            // runs INSIDE NSDraggingSession's tracking run loop. Deliberately NOT presented
            // here — SwiftUI would open the alert transaction while AppKit's
            // drag-completion rendering pass is still consuming frames, and the appear
            // animation would be dropped. Instead the request is stashed with its message
            // composed once, and presented from GalleryDragEngine's .dragSessionDidEnd
            // notification (above), which AppKit guarantees to deliver after the rendering
            // pass completes — and for every begun session, so a stash is never orphaned.
            //
            // One Queue alert at a time: a request arriving while one is open or waiting
            // is ignored, as it always was.
            guard !hasAlert(.filmQueueAdd) else { break }
            stashedQueueDrop = HostAlert.QueueAdd(
                filmIDs: filmIDs, listID: listID,
                message: filmQueueAddMessage(filmIDs), fromMenu: false)
        case .confirmFilmQueueAddFromMenu(let filmIDs, let listID):
            // Same request, presented at once: the sender (FilmQueueAssignment.toggle)
            // already ran past the menu's dismissal animation, and no drag session end will
            // arrive to present it. It supersedes any drop still stashed.
            guard !hasAlert(.filmQueueAdd) else { break }
            stashedQueueDrop = nil
            enqueue(.filmQueueAdd(HostAlert.QueueAdd(
                filmIDs: filmIDs, listID: listID,
                message: filmQueueAddMessage(filmIDs), fromMenu: true)))
        case .showPersistenceFailure(let error):
            coalesce(.persistenceFailure(detail: error))
        case .showDatabaseError:
            coalesce(.databaseError)
        case .showLibraryReadFailure:
            coalesce(.libraryReadFailure)
        case .duplicateViewingDate:
            coalesce(.duplicateViewingDate)
        case .calendarEventCreationFailed:
            coalesce(.calendarEventFailure)
        case .offerSoonForFullUpNextDrop(let filmIDs, let message):
            // Sent from inside performDragOperation, so it rides the stashed-notice
            // hand-off to the drag session's end, as a drop-time notice does.
            stashedNotice = .upNextFullDrop(filmIDs: filmIDs, message: message)
        case .showNotice(let title, let message, let afterDragSession):
            // Same-kind coalescing would let an unrelated notice replace one on screen,
            // so notices queue; a burst of identical ones is still collapsed.
            let notice = HostAlert.notice(title: title, message: message)
            if afterDragSession {
                stashedNotice = notice
            } else if case .notice(let shownTitle, let shownMessage)? = presented,
                      shownTitle == title, shownMessage == message {
                break
            } else {
                enqueue(notice)
            }
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private func actions(for alert: HostAlert) -> some View {
        switch alert {
        case .backupRestore:
            Button("Open Settings") {
                if let backupFile {
                    AppEventBus.shared.sendCommand(.openSettingsWithBackup(file: backupFile))
                }
                // Clear the reference regardless of whether it was used.
                backupFile = nil
            }
            Button("Cancel", role: .cancel) { backupFile = nil }

        case .removeList(let listID, _):
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                Task {
                    if !ListManager.deleteList(listID, coordinator: dataCoordinator) {
                        log("deleteListFromGallery failed for list \(listID)")
                    }
                }
            }

        case .deleteSavedSearch(let id, _):
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { SavedSearchStore.shared.delete(id) }

        case .deleteListContents(let listID, _, let filmIDs):
            Button("Cancel", role: .cancel) { }
            Button("Delete Contents", role: .destructive) {
                guard !filmIDs.isEmpty else { return }
                Task {
                    await ListManager.deleteListContents(listID, filmIDs: filmIDs,
                                                         coordinator: dataCoordinator)
                }
            }

        case .clearListContents(let listID, _, _):
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                Task {
                    if !ListManager.clearListContents(listID, coordinator: dataCoordinator) {
                        log("clearListContents failed for list \(listID)")
                    }
                }
            }

        case .removeFromList(let filmIDs, let listID, _, let clearing):
            Button("Cancel", role: .cancel) {
                log("Remove from list canceled — \(filmIDs.count) film(s) left in place")
            }
            Button("Remove", role: .destructive) {
                Task {
                    FilmManager.removeFilmsFromList(filmIDs, listID: listID,
                                                    coordinator: dataCoordinator)
                    clearSelection(if: clearing)
                }
            }

        case .removeFromAllLists(let filmIDs, let clearing):
            Button("Cancel", role: .cancel) {
                log("Remove from all lists canceled — \(filmIDs.count) film(s) left in place")
            }
            Button("Remove", role: .destructive) {
                Task {
                    ListManager.removeFilmsFromAllLists(filmIDs, coordinator: dataCoordinator)
                    clearSelection(if: clearing)
                }
            }

        case .deleteFromLibrary(let filmIDs, let clearing):
            Button("Cancel", role: .cancel) {
                // Closes the loop on the "awaiting confirmation" line FilmRemoval logged
                // when the command was invoked: without this, a canceled deletion left
                // that line as the last word on the subject.
                log("Delete from library canceled — \(filmIDs.count) film(s) left in place")
            }
            Button("Delete", role: .destructive) {
                // Mirrors FilmRemoval.deleteFromLibrary's direct branch: deleteFilms
                // reconciles the selection itself, so the flag chooses whether to hand the
                // selection over.
                Task {
                    await FilmManager.deleteFilms(filmIDs, coordinator: dataCoordinator,
                                                  selectionState: clearing ? selectionState : nil)
                }
            }

        case .removeFromHallOfFame(let filmIDs, let clearing):
            Button("Cancel", role: .cancel) {
                log("Remove from Hall of Fame canceled — \(filmIDs.count) film(s) left in place")
            }
            Button("Remove", role: .destructive) {
                // Single batched call: one compaction of the surviving ranking, one atomic
                // database transaction, and one coherent rollback baseline for the whole
                // selection.
                dataCoordinator.removeFromHallOfFame(filmIDs)
                clearSelection(if: clearing)
            }

        case .removeFromFilmQueue(let filmIDs, let clearing):
            Button("Cancel", role: .cancel) {
                log("Remove from Film Queue canceled — \(filmIDs.count) film(s) left in place")
            }
            Button("Remove", role: .destructive) {
                Task {
                    FilmManager.removeFromFilmQueue(filmIDs, coordinator: dataCoordinator)
                    clearSelection(if: clearing)
                }
            }

        case .filmQueueAdd(let add):
            // Mirrors FSTabDetails/DetailsView's Film Queue confirmation alert. Canceling
            // cancels the whole request; confirming adds the full set exactly as the
            // unconfirmed path does.
            Button("Cancel", role: .cancel) { }
            Button("Add Anyway") {
                // "Up Next" may have filled while this alert was up; re-checked at the
                // moment of commitment, as FilmQueueAssignment.toggle does for its menus.
                if add.listID == FilmQueueSection.upNext.listID,
                   FilmQueue.refuseUpNextAddIfFull(add.filmIDs, coordinator: dataCoordinator) {
                    return
                }
                FilmManager.addFilmsToList(add.filmIDs, listID: add.listID,
                                           coordinator: dataCoordinator)
                if add.fromMenu {
                    FilmQueueAssignment.armPostMoveScroll(add.filmIDs, coordinator: dataCoordinator)
                }
            }

        case .persistenceFailure(let detail):
            // Button order is deliberate and counterintuitive: the alert panel lays buttons
            // out RIGHT to LEFT in declaration order, so OK is declared first to sit
            // rightmost as the highlighted default, leaving Copy Error to its left.
            // Reversing these two swaps their positions on screen.
            Button("OK") { }
                .keyboardShortcut(.defaultAction)
            if let detail, !loggingEnabled {
                Button("Copy Error") { AlertErrorDetail.copyToPasteboard(detail) }
            }

        case .databaseError:
            // "Quit" carries role: .cancel — this is required on macOS to suppress
            // SwiftUI's automatic system "OK" button injection, which occurs whenever no
            // cancel-role button is present. It also means Escape activates Quit, which is
            // the correct deferral behavior for this forced-action flow.
            Button("Quit", role: .cancel) { NSApp.terminate(nil) }
            // .defaultAction designates this as the primary button — it receives the
            // Return-key binding and the keyboard focus ring on presentation, ensuring
            // focus lands here rather than drifting to another button.
            Button("Restore from Backup") {
                AppEventBus.shared.sendCommand(.openSettingsLockedToRestore)
            }
            .keyboardShortcut(.defaultAction)
            Button("Create New Library") {
                Task { @MainActor in await createNewLibrary() }
            }

        case .libraryReadFailure:
            // No destructive option is offered (see HostAlert.libraryReadFailure). "Quit"
            // carries role: .cancel for the same macOS reason as "Library Unavailable".
            Button("Quit", role: .cancel) { NSApp.terminate(nil) }
            Button("Restore from Backup") {
                AppEventBus.shared.sendCommand(.openSettingsLockedToRestore)
            }
            .keyboardShortcut(.defaultAction)
            Button("Continue Anyway") { }

        case .newLibraryResult:
            Button("Restart Now") { DBRestorer.restartApplication() }
                .keyboardShortcut(.defaultAction)

        case .duplicateViewingDate:
            // A single "OK" carries the default action (Return), per the app's standard
            // single-button alert convention.
            Button("OK") {
                // The CalendarPopover was auto-dismissed by the system the moment this
                // alert appeared (an alert sheet always closes an open NSPopover). Ask
                // WatchDetails to reopen it now that the user has acknowledged the
                // collision — it seeds the reopened popover from the entry snapshot
                // captured just before the alert was fired.
                AppEventBus.shared.sendCommand(.reopenViewingEventPopover)
            }
            .keyboardShortcut(.defaultAction)

        case .notice:
            Button("OK") { }
                .keyboardShortcut(.defaultAction)

        case .upNextFullDrop(let filmIDs, _):
            // The user's explicit answer overrides their "drop onto Queue adds to Up Next"
            // preference for this one drop. The special-sorting gate still applies to the
            // films now headed for "Soon".
            Button("Cancel", role: .cancel) {
                log("Full 'Up Next' drop canceled — \(filmIDs.count) film(s) not added")
            }
            Button("Add to \"Soon\" Queue Instead") {
                let soon = FilmQueueSection.soon.listID
                if FilmQueue.addNeedsConfirmation(filmIDs, coordinator: dataCoordinator) {
                    enqueue(.filmQueueAdd(HostAlert.QueueAdd(
                        filmIDs: filmIDs, listID: soon,
                        message: filmQueueAddMessage(filmIDs), fromMenu: false)))
                    return
                }
                log("Adding \(filmIDs.count) film(s) to 'Soon' in place of a full 'Up Next'")
                FilmManager.addFilmsToList(filmIDs, listID: soon, coordinator: dataCoordinator)
            }
            .keyboardShortcut(.defaultAction)

        case .calendarEventFailure:
            // Deliberately does NOT reopen the popover: unlike the duplicate-date case, the
            // viewing HAS been committed by the time this alert appears, so reopening it
            // would invite the user to enter it a second time (and be rejected as a
            // duplicate for their trouble).
            Button("OK") { }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Messages

    @ViewBuilder
    private func message(for alert: HostAlert) -> some View {
        switch alert {
        case .backupRestore:
            Text("Do you want to open Settings to restore from this backup? Completing the restore there will replace all existing data with the backup contents.")
        case .removeList(_, let listName):
            Text("Are you sure you want to remove \"\(truncateListName(listName, maxLength: 42))\"? This action cannot be undone.")
        case .deleteSavedSearch(_, let name):
            Text("\"\(truncateListName(name, maxLength: 42))\" will be removed from the sidebar. Films are not affected.")
        case .deleteListContents(_, let listName, let filmIDs):
            DeleteContentsMessage(listName: listName, filmCount: filmIDs.count)
        case .clearListContents(_, let listName, let filmCount):
            ClearContentsMessage(listName: listName, filmCount: filmCount)
        case .removeFromList(let filmIDs, _, let listName, _):
            RemoveFromListMessage(listName: listName, filmCount: filmIDs.count)
        case .removeFromAllLists(let filmIDs, _):
            RemoveFromAllListsMessage(filmCount: filmIDs.count)
        case .deleteFromLibrary(let filmIDs, _):
            DeleteFromLibraryMessage(filmCount: filmIDs.count)
        case .removeFromHallOfFame(let filmIDs, _):
            RemoveFromHallOfFameMessage(filmCount: filmIDs.count)
        case .removeFromFilmQueue(let filmIDs, _):
            RemoveFromFilmQueueMessage(filmCount: filmIDs.count)
        case .filmQueueAdd(let add):
            Text(add.message)
        case .persistenceFailure(let detail):
            // With debug logging ON, "check the log" is sound advice and the user — who
            // turned it on deliberately — knows where to look. With logging OFF, no log
            // exists to consult, so the fault text travels in the alert itself instead.
            if loggingEnabled {
                Text("The change was not saved. Check the log for more information.")
            } else if let detail {
                Text("The change was not saved.\n\n\(AlertErrorDetail.cap(detail))")
            } else {
                Text("The change was not saved.")
            }
        case .databaseError:
            Text("Film Tracker encountered a fatal, unrecoverable error and could not open its database. You can either restore your library from a backup or create a new, empty library to continue. This will delete all existing data and cannot be undone.")
        case .libraryReadFailure:
            // The persistent store opened normally but the Phase 1 fetch threw, so the
            // library renders as empty despite the data being intact on disk. Surfacing
            // this is not cosmetic: an unexplained empty library invites the user to "fix"
            // it by re-importing or restoring over a healthy store.
            Text("Film Tracker opened its database but could not read your library, so no films are shown. Your data has not been changed or deleted, and background maintenance has been disabled for this session to keep it that way. Relaunching will usually resolve this.")
        case .newLibraryResult(_, let message):
            Text(message)
        case .duplicateViewingDate:
            Text("There is already a viewing event for the selected date. Please choose a different date.")
        case .notice(_, let message), .upNextFullDrop(_, let message):
            Text(message)
        case .calendarEventFailure:
            Text("The viewing was recorded in Film Tracker, but the event could not be added to your system calendar. Check that the selected calendar is still available and writable.")
        }
    }

    // MARK: - Helpers

    /// Clears the selection after a confirmed removal only when the sender asked for it,
    /// matching what the same removal does with confirmation turned off.
    private func clearSelection(if requested: Bool) {
        guard requested else { return }
        selectionState.clearImmediate()
    }

    /// Builds the confirmation message for the Film Queue add alert. The single-film case
    /// is `FilmQueue.addConfirmationMessage`, the same text the FilmSheet picker's alert
    /// shows; multi-film adds fall back to a count-based summary in the same voice.
    private func filmQueueAddMessage(_ filmIDs: Set<UUID>) -> String {
        let flaggedFilms = filmIDs.compactMap { dataCoordinator.getFilm($0) }
            .filter { !$0.specialSorting.isEmpty }
        let totalCount = filmIDs.count

        if totalCount == 1, let onlyFlagged = flaggedFilms.first {
            return FilmQueue.addConfirmationMessage(flaggedWith: onlyFlagged.specialSorting)
        }

        return FilmQueue.addConfirmationMessage(adding: totalCount, flagged: flaggedFilms.count)
    }

    // MARK: Create New Library
    // Takes the same staged-store pathway as the restore flow, but without importing any
    // data: an empty store is staged, and the relaunch swaps it in (PendingRestore). A
    // restart is required because the app's current NSPersistentContainer is an in-memory
    // fallback opened at launch.
    private func createNewLibrary() async {
        let restorer = DBRestorer(container: dataCoordinator.persistentContainer)
        do {
            try await restorer.createFreshDatabase()
            enqueue(.newLibraryResult(success: true, message:
                "A new, empty library has been created. Film Tracker must restart for the changes to take effect."))
        } catch {
            enqueue(.newLibraryResult(success: false, message:
                "The library could not be created: \(error.localizedDescription)"))
        }
    }
}

// MARK: - Message Views

private struct DeleteContentsMessage: View {
    let listName: String?
    let filmCount: Int
    
    var body: some View {
        if let listName = listName {
            let truncatedName = truncateListName(listName, maxLength: 42)
            let isPlural = filmCount != 1
            Text("""
                Are you sure you want to delete all \
                \(filmCount) film\(isPlural ? "s" : "") in "\(truncatedName)"? \
                This will remove \(isPlural ? "them" : "it") from your \
                library. This action cannot be undone.
                """)
        }
    }
}

private struct ClearContentsMessage: View {
    let listName: String?
    let filmCount: Int?
    
    var body: some View {
        if let listName = listName, let filmCount = filmCount {
            let truncatedName = truncateListName(listName, maxLength: 42)
            let isPlural = filmCount != 1
            Text("""
                Clear all \(filmCount) film\(isPlural ? "s" : "") from "\(truncatedName)"? \
                \(isPlural ? "They" : "It") will remain in your library.
                """)
        }
    }
}

private struct RemoveFromListMessage: View {
    let listName: String?
    let filmCount: Int
    
    var body: some View {
        let isPlural = filmCount != 1
        if let listName = listName {
            let truncatedName = truncateListName(listName, maxLength: 42)
            Text("""
                Remove \(filmCount) film\(isPlural ? "s" : "") \
                from "\(truncatedName)"? \(isPlural ? "They" : "It") \
                will remain in your library.
                """)
        } else {
            Text("Remove \(filmCount) film\(isPlural ? "s" : "") from the list?")
        }
    }
}

private struct RemoveFromAllListsMessage: View {
    let filmCount: Int
    
    var body: some View {
        let isPlural = filmCount != 1
        Text("""
            Remove \(filmCount) film\(isPlural ? "s" : "") \
            from all lists? \(isPlural ? "They" : "It") will remain in your library.
            """)
    }
}

private struct DeleteFromLibraryMessage: View {
    let filmCount: Int

    var body: some View {
        let isPlural = filmCount != 1
        Text("""
            Are you sure you want to delete \(filmCount) film\(isPlural ? "s" : "") \
            from your library? This action cannot be undone.
            """)
    }
}

private struct RemoveFromHallOfFameMessage: View {
    let filmCount: Int
    
    var body: some View {
        let isPlural = filmCount != 1
        Text("""
            Remove \(filmCount) film\(isPlural ? "s" : "") from the Hall of Fame? \
            \(isPlural ? "They" : "It") will remain in your library.
            """)
    }
}

private struct RemoveFromFilmQueueMessage: View {
    let filmCount: Int
    
    var body: some View {
        let isPlural = filmCount != 1
        Text("""
            Remove \(filmCount) film\(isPlural ? "s" : "") from the Film Queue? \
            \(isPlural ? "They" : "It") will remain in your library.
            """)
    }
}
