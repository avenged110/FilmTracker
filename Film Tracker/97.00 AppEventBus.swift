// MARK: - AppEventBus.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Centralized, type-safe event system that uses Combine publishers
// for efficient, compile-time-checked event handling.

import Foundation
import Combine

// MARK: - Film Events
/// Events related to film data changes.
enum FilmEvent: Equatable, Sendable {
    /// A film's data was updated (metadata, poster, rating, etc.)
    case updated(filmID: UUID)
    /// Films were deleted from the library
    case deleted(filmIDs: Set<UUID>)
    /// A new film was added to the library
    case added(filmID: UUID)
    /// A film's release data changed
    case releaseChanged(filmID: UUID)
}

// MARK: - List Events
/// Events related to list data changes.
enum ListEvent: Equatable, Sendable {
    /// A new list was created
    case created(listID: UUID)
    /// A list's metadata was updated (name, order, etc.)
    case updated(listID: UUID)
    /// A list was deleted
    case deleted(listID: UUID)
    /// Films were added to or removed from a list
    case membershipChanged(listID: UUID)
    /// A batch list operation started (for progress indication)
    case operationStarted(listID: UUID)
    /// A batch list operation completed
    case operationCompleted(listID: UUID)
    /// Film(s) were added to one of the three internal Film Queue lists — fired only
    /// on additions (drag-and-drop onto the LeftSidebar's Queue row, an "Add to Queue"
    /// menu selection, or an explicit Film Queue assignment saved from the FilmSheet),
    /// never on removals. Drives the
    /// LeftSidebar Queue row's momentary "checkmark.circle.fill" completion glyph,
    /// mirroring the per-list completion glyph shown on user-generated lists.
    case queueAdditionCompleted(listID: UUID)
}

// MARK: - View Events
/// Events related to view state changes.
enum ViewEvent: Equatable, Sendable {
    /// Sort, filter, or display options changed
    case stateChanged
    /// User preferences changed
    case preferencesChanged
    /// Right sidebar scroll view started a live-scroll phase. Fired via
    /// SidebarScrollView's onScrollWillStart callback into AppKitScrollView.
    /// Scoped so subscribers can react only to scrolls in the sidebar (e.g.
    /// dismissing a sidebar-anchored popover) without being pinged by unrelated
    /// NSScrollView activity elsewhere in the window.
    case rightSidebarDidStartLiveScroll
    /// A horizontal two-finger swipe was recognized over the right sidebar's tab
    /// content. Emitted by RightSidebar's own NSEvent local monitor (see
    /// installSwipeMonitor() in 24_00_RightSidebar.swift); RightSidebar itself
    /// consumes it to drive swipe-only animated tab navigation. `.forward`
    /// advances toward Notes; `.backward` retreats toward Details.
    case rightSidebarSwipe(RightSidebarSwipeDirection)
    /// Calendar authorization status changed
    case calendarAuthorizationChanged
    /// Forward a backup file URL to an already-open SettingsSheet (Restore tab).
    /// Broadcast by SheetHostView when Settings is open and an .openSettingsWithBackup
    /// command arrives — avoids dismissing and re-presenting the sheet.
    case loadBackupFile(URL)
    /// Smart list membership was recalculated outside of any specific film event —
    /// currently only fired by SmartLists' daily midnight rotation refresh. Lets a
    /// visible gallery showing an affected smart list (Up for Rotation / Viewed Over
    /// One Year Ago) refresh automatically, the same way it would for a user-driven change.
    case smartListsRecalculated
}

// MARK: - Selection Events
/// Events related to selection state.
enum SelectionEvent: Equatable, Sendable {
    /// Select all films in current view
    case selectAllFilms
    /// Clear focus ring indicators
    case clearFocusRings
}

// MARK: - Right Sidebar Swipe Direction
/// Direction of a right-sidebar tab swipe, derived from a horizontal two-finger
/// trackpad gesture over the sidebar. `.forward` moves one tab toward Notes;
/// `.backward` moves one tab toward Details.
enum RightSidebarSwipeDirection: Equatable, Sendable {
    case forward
    case backward
}

// MARK: - Right Sidebar Tab
/// Tabs available in the right sidebar.
enum RightSidebarTab: String, Equatable, CaseIterable, Identifiable, Sendable {
    case details
    case releases
    case notes
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .details: return "Details"
        case .releases: return "Releases"
        case .notes: return "Notes"
        }
    }
}

// MARK: - UI Commands
/// Commands triggered by menus, keyboard shortcuts, or programmatic actions.
enum UICommand: Equatable, Sendable {
    // MARK: Film Operations
    /// Show add film sheet
    case addFilm
    /// Edit the currently selected film
    case editFilm
    /// Edit the currently selected film, opening the sheet on its Metadata tab (Opt+Cmd+E)
    case editFilmMetadata
    /// Edit releases for the currently selected film, opening the carousel on `format`'s
    /// first card when one is given.
    case editFilmReleases(format: String? = nil)
    
    // MARK: Import Operations
    /// Navigate to metadata import tab
    case navigateToImportsMetadata
    /// Navigate to ratings import tab
    case navigateToImportsRatings
    
    // MARK: Database Operations
    /// Find duplicate films
    case findDuplicates
    
    // MARK: UI Navigation
    /// Show list creation sheet
    case showListCreation
    /// Show list creation sheet with selected films
    case showListCreationFromSelection(filmIDs: Set<UUID>, prefillName: String? = nil)
    /// Duplicate a user-generated list and all its contents
    case duplicateList(UUID)
    /// Edit existing list name
    case editList(UUID)
    /// Toggle left sidebar visibility
    case toggleLeftSidebar
    /// Open settings to a specific tab
    case openSettingsToTab(tab: SettingsTab)
    /// Open settings with backup pane
    case openSettingsWithBackup(file: URL?)
    /// Open Settings on the Restore tab with the sheet locked for database-error recovery.
    /// The tab bar and Close button are disabled until the user completes or dismisses
    /// the restore workflow. Handled exclusively by SheetHostView.
    case openSettingsLockedToRestore
    /// Open the "Up Next" slot picker. Sent by any empty slot in the Queue's "All" tab
    /// (UpNextSlots.swift); handled by SheetHostView.
    case openUpNextSlot
    
    // MARK: Sheet Tab Navigation
    /// Change tab in active FilmSheet (1-5)
    case changeFilmSheetTab(tab: Int)
    /// Change tab in active SettingsSheet (1-5)
    case changeSettingsSheetTab(tab: Int)
    /// Step the active FilmSheet to its next (forward) or previous tab, wrapping (Cmd+Down/Up)
    case cycleFilmSheetTab(forward: Bool)
    /// Step the active SettingsSheet to its next (forward) or previous tab, wrapping (Cmd+Down/Up)
    case cycleSettingsSheetTab(forward: Bool)
    
    // MARK: Releases Tab
    /// Add a new release card in the active FilmSheet when the Releases tab is visible.
    ///
    /// The format is part of the command because the carousel presents every format in one
    /// stack and so cannot infer one: Cmd+N asks for a Blu-ray and Opt+Cmd+N for a 4K UHD,
    /// and the sender is the only party that knows which was pressed.
    case addReleaseToActiveSheet(format: String)
    /// Delete the currently visible release card in the active FilmSheet
    case deleteReleaseFromActiveSheet

    // MARK: Details Tab
    /// Open the add-date popover for the Viewing Dates table (Details tab, active FilmSheet)
    case openViewingDatesAddPopover

    // MARK: RightSidebar WatchDetails
    /// Reopen the "Add Viewing Event" popover after its "Event Already Exists" alert
    /// is dismissed. macOS automatically closes an open NSPopover the instant an
    /// NSAlert sheet is presented, so WatchDetails uses this to bring the popover
    /// back once the user acknowledges the collision — seeded from the entry
    /// snapshot it captured just before the alert appeared.
    case reopenViewingEventPopover

    // MARK: Notes Tab
    // No commands here: each frames table's add control is now its own last row
    // and scrolls itself into view, so there's nothing left for a command to carry.

    // MARK: Gallery Navigation
    /// Scroll the gallery so the single selected film appears in the top visible row
    case scrollToSelection

    // MARK: Token Search
    /// Immediately activate a token-based search from a sidebar "Search" button.
    /// Clears any existing search state, applies the specified token, and switches
    /// the main content area to the search view — all as a single atomic action.
    case activateTokenSearch(field: SearchField, value: String)

    // MARK: Saved Searches
    /// Present the saved-search builder: create, edit or duplicate a saved search.
    case showSavedSearchSheet(SavedSearchSheet.Mode)
    /// Open a saved search in the search field for editing.
    case openSavedSearchInField(UUID)
}

// MARK: - Alert Commands
/// Commands to show confirmation dialogs and alerts.
enum AlertCommand: Equatable, Sendable {
    // MARK: List Deletion Alerts
    /// Confirm removal of the list itself (its films stay in the library)
    case confirmRemoveList(listID: UUID, listName: String)
    /// Confirm deleting a saved search (its films are unaffected)
    case confirmDeleteSavedSearch(id: UUID, name: String)
    /// Confirm deletion of the list's films from the library
    case confirmDeleteContents(listID: UUID, listName: String)
    /// Confirm clearing list contents (remove from list, not delete)
    case confirmClearContents(listID: UUID, listName: String)
    
    // MARK: Film Removal Alerts
    // `clearingSelection` carries the sender's FilmRemoval choice through the alert, so a
    // confirmed removal treats the selection exactly as the unconfirmed one would.
    /// Confirm removal of films from a specific list
    case confirmRemoveFromList(filmIDs: Set<UUID>, listID: UUID, listName: String, clearingSelection: Bool)
    /// Confirm removal of films from all lists
    case confirmRemoveFromAllLists(filmIDs: Set<UUID>, clearingSelection: Bool)
    /// Confirm deletion of films from library
    case confirmDeleteFromLibrary(filmIDs: Set<UUID>, clearingSelection: Bool)
    /// Confirm removal of films from the Hall of Fame (does not delete from library)
    case confirmRemoveFromHallOfFame(filmIDs: Set<UUID>, clearingSelection: Bool)
    /// Confirm removal of films from the Film Queue (whichever of the three
    /// internal sections each selected film currently belongs to)
    case confirmRemoveFromFilmQueue(filmIDs: Set<UUID>, clearingSelection: Bool)
    /// Confirm adding films to the Film Queue via LeftSidebar drag-and-drop when one
    /// or more of the dropped films carries a special sorting parameter (e.g.
    /// "Ignore", "Blacklisted") and Preferences.confirmFilmQueueAdd is enabled.
    /// Mirrors the identical confirmation gate on the FSTabDetails/DetailsView Film
    /// Queue picker. Canceling cancels the entire drop; confirming adds the full
    /// dropped set to the given internal Film Queue list.
    case confirmFilmQueueAddOnDrop(filmIDs: Set<UUID>, listID: UUID)
    /// The same confirmation for the "Add to Queue" menus (gallery contextual menu,
    /// MenuBar, GalleryTitleBar), all of which route through FilmQueueAssignment.toggle.
    /// Unlike the drop variant there is no drag session to wait out — the sender has
    /// already deferred past the menu's dismissal — so the alert is presented on receipt.
    case confirmFilmQueueAddFromMenu(filmIDs: Set<UUID>, listID: UUID)
    
    // MARK: Backup/Restore Alerts
    /// Show backup/restore alert
    case showBackupRestoreAlert(type: String, file: URL?)
    
    // MARK: Persistence Failure Alert
    /// Notify user that a background database write failed and MemoryStore was rolled back.
    /// `error` carries the summarized fault text for display when debug logging is off —
    /// see AlertErrorDetail. Nil only if a call site has no error in hand.
    case showPersistenceFailure(error: String?)

    // MARK: Database Error Alert
    /// Notify user that the persistent ModelContainer could not be opened at launch.
    /// Forces an immediate decision: Quit, Restore from Backup, or Create New Library.
    /// The app is running against a temporary in-memory store for this session only.
    case showDatabaseError

    // MARK: Library Read Failure Alert
    /// Notify the user that the persistent store opened normally but the startup fetch
    /// threw, leaving the library rendered as empty while the data itself is intact.
    /// Strictly non-destructive: offers Quit, Restore from Backup, or Continue Anyway.
    /// Distinct from showDatabaseError, whose recovery options include deleting the store.
    case showLibraryReadFailure

    // MARK: Viewing Date Alerts
    /// Notify the user that the date they attempted to commit for a new (or edited)
    /// viewing event collides with an existing viewing event entry for the same film.
    /// Fired by the CalendarPopover (RightSidebar's "Add Viewing Event" flow) — the
    /// FilmSheet Details tab's ViewingDatesTable uses its own locally-scoped alert
    /// instead, since it is not routed through AlertHostView.
    case duplicateViewingDate

    /// Notify the user that the viewing was recorded in Film Tracker but the
    /// corresponding system-calendar event could not be written. Fired by the
    /// CalendarPopover only when "Add to system calendar" was requested and
    /// EventKitManager.createEvent reported failure — the viewing itself has already
    /// been committed at that point, which is what the alert's wording tells the user.
    case calendarEventCreationFailed

    // MARK: Notices
    /// A plain, informational alert with a single "OK" button — used by the "Up Next"
    /// capacity guards and the ATVQ dispatch button. `afterDragSession` defers it to the
    /// end of the current drag session, exactly as confirmFilmQueueAddOnDrop is, for a
    /// sender running inside performDragOperation.
    case showNotice(title: String, message: String, afterDragSession: Bool = false)
    /// A LeftSidebar drop on the "Up Next" row that would overflow it: the "Up Next" Queue
    /// Full alert, with "Cancel" and an offer to add the films to "Soon" instead. Always
    /// deferred to the end of the drag session, like showNotice's afterDragSession.
    case offerSoonForFullUpNextDrop(filmIDs: Set<UUID>, message: String)
}

// MARK: - App Event Bus

/// Central hub for all application events using Combine publishers.
///
/// Usage:
/// ```swift
/// // Posting events
/// AppEventBus.shared.send(.film(.updated(filmID: someID)))
///
/// // Subscribing in SwiftUI views
/// .onReceive(AppEventBus.shared.filmEvents) { event in
///     switch event {
///     case .updated(let filmID): handleUpdate(filmID)
///     case .deleted(let ids): handleDeletion(ids)
///     ...
///     }
/// }
///
/// // Subscribing with Combine in classes
/// AppEventBus.shared.filmEvents
///     .filter { if case .updated = $0 { return true } else { return false } }
///     .sink { event in ... }
///     .store(in: &cancellables)
/// ```
@MainActor
final class AppEventBus {
    /// Shared singleton instance
    static let shared = AppEventBus()

    // MARK: - Publishers
    /// Film-related events (updates, deletions, additions)
    let filmEvents = PassthroughSubject<FilmEvent, Never>()
    /// List-related events (CRUD, membership changes)
    let listEvents = PassthroughSubject<ListEvent, Never>()
    /// View state events (sort/filter changes, view switches)
    let viewEvents = PassthroughSubject<ViewEvent, Never>()
    /// Selection state events
    let selectionEvents = PassthroughSubject<SelectionEvent, Never>()
    /// UI commands from menus/keyboard shortcuts
    let uiCommands = PassthroughSubject<UICommand, Never>()
    /// Alert/dialog commands
    let alertCommands = PassthroughSubject<AlertCommand, Never>()

    // MARK: - Unified Send Method
    /// Generic send method for type-safe event dispatching
    func send(_ event: Event) {
        switch event {
        case .film(let filmEvent):
            filmEvents.send(filmEvent)
        case .list(let listEvent):
            listEvents.send(listEvent)
        case .view(let viewEvent):
            viewEvents.send(viewEvent)
        case .selection(let selectionEvent):
            selectionEvents.send(selectionEvent)
        case .ui(let uiCommand):
            uiCommands.send(uiCommand)
        case .alert(let alertCommand):
            alertCommands.send(alertCommand) } }
    
    // MARK: - Event Type
    /// Unified event type for type-safe dispatching
    enum Event: Sendable {
        case film(FilmEvent)
        case list(ListEvent)
        case view(ViewEvent)
        case selection(SelectionEvent)
        case ui(UICommand)
        case alert(AlertCommand) }
    
    // MARK: - Convenience Methods (Film Events)
    /// Notify that films were deleted. Post it only after removing the films from MemoryStore
    /// and reloading the current view: GalleryView does not reload for this event, because
    /// every sender has already loaded the final film set (see DataCoordinator.deleteFilms).
    func filmsDeleted(_ filmIDs: Set<UUID>) {
        filmEvents.send(.deleted(filmIDs: filmIDs))
    }
    /// Notify that a film was added
    func filmAdded(_ filmID: UUID) {
        filmEvents.send(.added(filmID: filmID))
    }

    // MARK: - Convenience Methods (List Events)
    /// Notify that a list was created
    func listCreated(_ listID: UUID) {
        listEvents.send(.created(listID: listID)) }
    /// Notify that a list was deleted
    func listDeleted(_ listID: UUID) {
        listEvents.send(.deleted(listID: listID)) }
    /// Notify that list membership changed
    func listMembershipChanged(_ listID: UUID) {
        listEvents.send(.membershipChanged(listID: listID)) }

    // MARK: - Convenience Methods (View Events)
    /// Notify that view state changed
    func viewStateChanged() {
        viewEvents.send(.stateChanged) }
    /// Notify that preferences changed
    func preferencesChanged() {
        viewEvents.send(.preferencesChanged) }
    /// Notify that the right sidebar's scroll view started a live-scroll phase
    func rightSidebarDidStartLiveScroll() {
        viewEvents.send(.rightSidebarDidStartLiveScroll) }
    /// Notify that a horizontal two-finger swipe was recognized over the right sidebar
    func rightSidebarSwipe(_ direction: RightSidebarSwipeDirection) {
        viewEvents.send(.rightSidebarSwipe(direction)) }
    /// Notify that calendar authorization changed
    func calendarAuthorizationChanged() {
        viewEvents.send(.calendarAuthorizationChanged) }
    /// Notify that smart list membership was recalculated outside of a specific film event
    func smartListsRecalculated() {
        viewEvents.send(.smartListsRecalculated) }

    // MARK: - Convenience Methods (Selection Events)
    /// Select all films
    func selectAllFilms() {
        selectionEvents.send(.selectAllFilms) }
    /// Clear focus rings
    func clearFocusRings() {
        selectionEvents.send(.clearFocusRings) }

    // MARK: - Convenience Methods (UI Commands)
    /// Send a UI command
    func sendCommand(_ command: UICommand) {
        uiCommands.send(command) }

    // MARK: - Convenience Methods (Alert Commands)
    /// Send an alert command
    func sendAlert(_ alert: AlertCommand) {
        alertCommands.send(alert) }

    // MARK: - Initialization
    private init() {}
}

// MARK: - SwiftUI View Extensions
import SwiftUI

@MainActor
extension View {
    /// Subscribe to film events
    func onFilmEvent(perform action: @escaping (FilmEvent) -> Void) -> some View {
        self.onReceive(AppEventBus.shared.filmEvents, perform: action) }
    /// Subscribe to list events
    func onListEvent(perform action: @escaping (ListEvent) -> Void) -> some View {
        self.onReceive(AppEventBus.shared.listEvents, perform: action) }
    /// Subscribe to any list data change (created, updated, deleted)
    func onListDataChanged(perform action: @escaping () -> Void) -> some View {
        self.onReceive(AppEventBus.shared.listEvents) { event in
            switch event {
            case .created, .updated, .deleted: action()
            default: break } } }
    /// Subscribe to view state changes
    func onViewStateChanged(perform action: @escaping () -> Void) -> some View {
        self.onReceive(AppEventBus.shared.viewEvents) { event in
            if case .stateChanged = event { action() } } }
}
