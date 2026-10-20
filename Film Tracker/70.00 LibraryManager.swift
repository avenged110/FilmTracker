// MARK: - LibraryManager.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Centralized management of the library's films and lists: film deletion, poster
// cleanup and list membership (FilmManager); list creation, renaming, reordering,
// deletion and content management (ListManager, ListManagerSheet); and the shared
// "Remove from List" / "Delete from Library" commands built on both (FilmRemoval).
// All operations use DataCoordinator for immediate in-memory updates with automatic
// background persistence.

import SwiftUI
import SwiftData
import AppKit

// MARK: - Film Manager
@MainActor
struct FilmManager: Loggable {
    nonisolated static let logTag = "[FilmManager]"

    // MARK: - Film Deletion
    
    /// Deletes films from the library with immediate in-memory updates.
    /// - Parameters:
    ///   - filmIDs: Set of film UUIDs to delete.
    ///   - coordinator: DataCoordinator for performing deletion operations.
    ///   - selectionState: Optional SelectionState to clear after deletion.
    static func deleteFilms(_ filmIDs: Set<UUID>, coordinator: DataCoordinator,
        selectionState: SelectionState? = nil) async {
        guard !filmIDs.isEmpty else { log("Delete aborted: No films provided"); return }
        log("Deleting \(filmIDs.count) film(s) from library")

        // Clear selection before deleting.
        if let selectionState = selectionState {
            log("Clearing selection state")
            selectionState.clearImmediate() }

        // Get poster UIDs for cleanup (from memory).
        var posterUIDs: [String] = []
        for filmID in filmIDs {
            if let film = coordinator.getFilm(filmID) {
                log("Found film to delete: \(film.id) - '\(film.name)'")
                if !film.posterUID.isEmpty { posterUIDs.append(film.posterUID) } } }

        // Perform deletion through coordinator (updates memory + persists in background).
        // deleteFilms(withIDs:) is non-throwing; errors are handled internally via rollback.
        //
        // Poster teardown — cache eviction AND file removal — is handed to the onPersisted
        // callback rather than run inline below, because both are irreversible while this
        // call's return means only "applied to MemoryStore". A failed background persist
        // rolls the films back into the store; running the teardown here would leave those
        // recovered films with their artwork already deleted from disk and from the cache,
        // which no rollback can undo. See DataCoordinator.deleteFilms(withIDs:onPersisted:).
        // Rebound to a constant: the callback below is concurrently-executing code, which
        // cannot capture a `var`.
        let posterUIDsToClean = posterUIDs
        let folderURL = Preferences.posterImagesFolderURL
        if folderURL == nil {
            log("WARNING: posterImagesFolderURL not available, poster file cleanup will be skipped")
        }
        await coordinator.deleteFilms(withIDs: filmIDs) {
            guard !posterUIDsToClean.isEmpty else { return }

            log("Removing \(posterUIDsToClean.count) posters from cache...")
            PosterCache.shared.removePosters(posterUIDsToClean)
            log("Posters removed from cache")

            guard let folderURL else { return }
            // Detached so the filesystem work never runs on the MainActor. Deleting a
            // large multi-selection previously stalled the UI for up to five synchronous
            // FileManager calls per film; nothing here touches main-actor state, so the
            // hop costs nothing and removes the stall entirely.
            Task.detached(priority: .utility) {
                Self.cleanupPosterFiles(posterUIDsToClean, in: folderURL)
            }
        }
        log("Deletion applied for \(filmIDs.count) film(s) (persisting in background)")

        // Post filmDeleted event.
        AppEventBus.shared.filmsDeleted(filmIDs)
        log("Posted .filmDeleted event for \(filmIDs.count) film(s)")
    }

    // MARK: - Film Addition to Lists

    /// Adds films to a list, bracketed by the `operationStarted` → `membershipChanged` →
    /// `operationCompleted` events the sidebar's row spinner and every membership menu and
    /// table follow. Synchronous, so it also serves the sidebar list row's
    /// `NSDraggingDestination.performDragOperation`: the membership change and its events
    /// land on the same call stack as AppKit's drag-completion UI teardown rather than in a
    /// `Task` that cannot run until the drag's tracking run loop mode exits. Background
    /// persistence is unaffected — `DataCoordinator.addFilmsToList` hands the database
    /// write to `trackOperation`.
    /// - Parameters:
    ///   - filmIDs: Set of film UUIDs to add.
    ///   - listID: UUID of the list to add films to.
    ///   - coordinator: DataCoordinator for database operations.
    static func addFilmsToList(_ filmIDs: Set<UUID>, listID: UUID,
        coordinator: DataCoordinator) {
        guard !filmIDs.isEmpty else {
            log("Add operation aborted: No film IDs provided"); return }

        AppEventBus.shared.send(.list(.operationStarted(listID: listID)))

        if coordinator.addFilmsToList(filmIDs: filmIDs, listID: listID) {
            log("Added \(filmIDs.count) film(s) to list \(listID)")
            AppEventBus.shared.listMembershipChanged(listID)
            if FilmQueue.isInternalList(listID) {
                AppEventBus.shared.send(.list(.queueAdditionCompleted(listID: listID)))
            }
        } else {
            log("ERROR: Add failed — list \(listID) not found")
        }

        AppEventBus.shared.send(.list(.operationCompleted(listID: listID))) }

    // MARK: - Film Removal from Lists
    
    /// The one implementation of "remove these films from these lists", including the
    /// event protocol every list-removal surface owes its observers: every targeted list
    /// is bracketed in `operationStarted` / `operationCompleted` so its row spinner tracks
    /// its own work window, with `membershipChanged` between them. Shared by the
    /// single-list wrapper below, `removeFromFilmQueue`, `ListManager.clearListContents`
    /// and `ListManager.removeFilmsFromAllLists`, so none of them restates it.
    ///
    /// Callers pass the removal already grouped per list, which is what lets the Film Queue
    /// and "remove from all lists" paths express a selection whose films sit in different
    /// lists without any special casing here.
    static func removeFilmsFromLists(_ filmIDsByList: [UUID: Set<UUID>],
        coordinator: DataCoordinator) {
        for (listID, ids) in filmIDsByList where !ids.isEmpty {
            AppEventBus.shared.send(.list(.operationStarted(listID: listID)))
            coordinator.removeFilmsFromList(filmIDs: ids, listID: listID)
            log("Removed \(ids.count) film(s) from list \(listID)")
            AppEventBus.shared.listMembershipChanged(listID)
            AppEventBus.shared.send(.list(.operationCompleted(listID: listID)))
        }
    }

    /// Removes films from a single list with immediate in-memory updates.
    /// - Parameters:
    ///   - filmIDs: Set of film UUIDs to remove.
    ///   - listID: UUID of the list to remove films from.
    ///   - coordinator: DataCoordinator for database operations.
    static func removeFilmsFromList(_ filmIDs: Set<UUID>, listID: UUID,
        coordinator: DataCoordinator) {
        guard !filmIDs.isEmpty else {
            log("Remove operation aborted: No film IDs provided"); return }
        removeFilmsFromLists([listID: filmIDs], coordinator: coordinator) }

    /// Removes films from the Film Queue, resolving each film's actual current
    /// section(s) independently rather than assuming a single shared list. A mixed
    /// multi-selection (e.g. one film currently in "Up Next", another in "Soon") is
    /// handled correctly in a single call; films not currently in any of the three
    /// internal lists are silently skipped.
    /// - Parameters:
    ///   - filmIDs: Set of film UUIDs to remove from the queue.
    ///   - coordinator: DataCoordinator for database operations.
    static func removeFromFilmQueue(_ filmIDs: Set<UUID>, coordinator: DataCoordinator) {
        guard !filmIDs.isEmpty else {
            log("Remove-from-queue operation aborted: No film IDs provided"); return }

        // Group the selected films by every internal section list they actually
        // belong to, rather than only each film's single canonical section. Under
        // normal operation every add path self-heals to guarantee mutual exclusivity,
        // so a film is never in more than one queue section — but resolving the full
        // intersection here (the same approach the auto-removal helper in
        // DataCoordinator already uses) makes this corruption-proof: even a film left
        // in two sections by a corrupted or pre-exclusivity backup restore will have
        // every membership stripped in one pass, rather than only the canonical one.
        var filmIDsByListID: [UUID: Set<UUID>] = [:]
        for filmID in filmIDs {
            let queueListIDs = coordinator.filmQueueListIDs(forFilm: filmID)
            for listID in queueListIDs {
                filmIDsByListID[listID, default: []].insert(filmID)
            }
        }
        guard !filmIDsByListID.isEmpty else {
            log("Remove-from-queue operation skipped: none of the selected films are in the queue")
            return
        }

        removeFilmsFromLists(filmIDsByListID, coordinator: coordinator)
        log("Remove-from-queue completed for \(filmIDsByListID.count) section(s)")
    }

    // MARK: - Poster Cleanup
    
    /// `nonisolated` so it can run inside the detached task in deleteFilms — it touches
    /// only FileManager and its two value-type arguments, never main-actor state.
    nonisolated private static func cleanupPosterFiles(_ posterUIDs: [String], in folderURL: URL) {
        log("Cleaning up \(posterUIDs.count) poster file(s)")
        log("Poster folder URL: \(folderURL.path(percentEncoded: false))")

        for posterUID in posterUIDs {
            guard !posterUID.isEmpty else { continue }

            // Try common JPEG filename variants.
            let base = folderURL.appendingPathComponent(posterUID)
            let candidates: [URL] = [
                base.appendingPathExtension("jpg"),
                base.appendingPathExtension("jpeg"),
                base.appendingPathExtension("JPG"),
                base.appendingPathExtension("JPEG") ]

            if let existingURL = candidates.first(where: {
                FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }) {
                do {
                    try FileManager.default.removeItem(at: existingURL)
                    log("Successfully deleted poster: \(existingURL.lastPathComponent)")
                } catch {
                    log("ERROR: Failed to delete poster \(existingURL.lastPathComponent): \(error.localizedDescription)") }
            } else {
                let triedNames = candidates.map { $0.lastPathComponent }
                    .joined(separator: ", ")
                log("WARNING: Poster file not found for UID '\(posterUID)'. Tried: \(triedNames)") } } }
}

// MARK: - List Manager
@MainActor
final class ListManager: Loggable {
    nonisolated static let logTag = "[ListManager]"
    
    // NOTE: `getListInfo(for:coordinator:)` and `getListInfos(for:coordinator:)` used to
    // live here. Both built a ListInfo — including an O(n) `filmIDs.count` — purely to
    // hand back one or two fields their callers actually read. The bulk variant's only
    // caller (the Right Sidebar's List Membership table) now reads
    // `DataCoordinator.userLists(forFilm:)`, which returns the same lists already in the
    // canonical order it had to re-derive; the single variant's only caller
    // (ListManagerSheet, below) wanted nothing but the name. ListInfo itself remains —
    // it is the sidebar's row model, and there `filmCount` genuinely drives the row's
    // contextual-menu enablement.

    // MARK: - Create Operations
    
    /// Creates a new list with a unique name, optionally with initial (selected) films.
    /// - Parameters:
    ///   - baseName: The desired name for the list
    ///   - coordinator: DataCoordinator for database operations
    ///   - filmIDs: Optional set of film UUIDs to add to the list upon creation
    /// - Returns: UUID of the created list, or nil if creation failed
    static func createList(baseName: String,
        coordinator: DataCoordinator, filmIDs: Set<UUID>? = nil) -> UUID? {
        let trimmedName = baseName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            log("ERROR: Cannot create list with empty name")
            return nil
        }

        // Get all existing lists from MemoryStore.
        let allLists = coordinator.getAllLists()
        
        // Generate a unique name.
        let uniqueName = generateUniqueName(baseName: trimmedName,
            existingNames: allLists.map { $0.listName })

        // Calculate next display order.
        let maxOrder = allLists.map { $0.displayOrder }.max() ?? -1

        // Create new list through coordinator.
        let newListID = coordinator.createList(name: uniqueName, displayOrder: maxOrder + 1)
        log("Created list '\(uniqueName)'")

        if let filmIDs = filmIDs, !filmIDs.isEmpty {
            coordinator.addFilmsToList(filmIDs: filmIDs, listID: newListID)
            log("Added \(filmIDs.count) film(s) to the new list")
            // Mirror the event FilmManager.addFilmsToList posts so that membership
            // observers (e.g. AddToListMenuItems, AddToQueueMenuItems) respond correctly
            // to the initial population.
            AppEventBus.shared.listMembershipChanged(newListID)
        }

        // Notify observers that the list itself was created.
        AppEventBus.shared.listCreated(newListID)
        return newListID
    }

    // MARK: - Update Operations
    
    /// Updates a list's name.
    ///
    /// The requested name is uniquified exactly as `createList` uniquifies a new one: two
    /// user-generated lists may not share a name, so renaming onto an existing one quietly
    /// becomes "Name 1", "Name 2", and so on. Renaming was previously the one path that
    /// allowed a collision, which meant a duplicate name could only ever be produced by a
    /// rename — and once produced, the two lists were genuinely indistinguishable in every
    /// surface that shows a list by name: both "Add to List" menus, "Show in List", the
    /// Right Sidebar's List Membership table, and the sidebar rows themselves.
    ///
    /// The list being renamed is excluded from the comparison set, so re-saving a list's
    /// own unchanged name is a no-op rather than a rename to "Name 1", and correcting only
    /// the capitalization of a name keeps that name (`generateUniqueName` compares
    /// case-insensitively, so "movies" → "Movies" would otherwise collide with itself).
    static func updateListName(_ listID: UUID, newName: String,
        coordinator: DataCoordinator) -> Bool {
        let trimmedName = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            log("ERROR: Cannot update list name to empty string")
            return false
        }

        guard let list = coordinator.getList(listID) else {
            log("ERROR: Cannot update name for non-existent list")
            return false
        }

        let oldName = list.listName

        let uniqueName = generateUniqueName(baseName: trimmedName,
            existingNames: coordinator.getAllLists()
                .filter { $0.listID != listID }
                .map { $0.listName })
        if uniqueName != trimmedName {
            log("Requested list name '\(trimmedName)' is already in use — using '\(uniqueName)'")
        }

        // Nothing to persist when the name is unchanged. Without this, re-saving an
        // unedited name would still dispatch a write and post an .updated event.
        guard uniqueName != oldName else {
            log("List name unchanged ('\(oldName)') — no update dispatched")
            return true
        }

        coordinator.updateList(listID: listID, name: uniqueName,
            displayOrder: nil, sortFilterOptions: nil)
        log("Updated list name: '\(oldName)' → '\(uniqueName)'")

        // Post event that the list was updated.
        AppEventBus.shared.send(.list(.updated(listID: listID)))
        return true
    }

    /// Reorders lists based on new positions.
    static func reorderLists(from source: IndexSet, to destination: Int,
        coordinator: DataCoordinator) {
        // getAllLists() is already sorted by displayOrder and already excludes the
        // internal Film Queue lists, so the indices in `source`/`destination` line up
        // exactly with the sidebar rows the user dragged.
        var lists = coordinator.getAllLists()
        log("Reordering lists: moving \(source) to \(destination)")
        lists.move(fromOffsets: source, toOffset: destination)

        // Build updates as a flat array for the single-operation batch call.
        let updates = lists.enumerated().map { (index, list) in
            (listID: list.listID, displayOrder: index)
        }

        coordinator.batchUpdateListOrders(updates)
        log("Reordered \(lists.count) list(s)")

        // A single updated event triggers the sidebar's @Observable subscription
        // to re-read cachedLists, which already reflects the new order via syncListsCache().
        // Use the first list's ID as a representative value; the sidebar reacts to any
        // list event regardless of which specific ID is embedded in the payload.
        if let firstListID = lists.first?.listID {
            AppEventBus.shared.send(.list(.updated(listID: firstListID)))
        }
    }

    // MARK: - Delete Operations
    
    /// Deletes a list and all its memberships.
    static func deleteList(_ listID: UUID, coordinator: DataCoordinator) -> Bool {
        guard let list = coordinator.getList(listID) else {
            log("ERROR: Cannot delete non-existent list")
            return false
        }

        let listName = list.listName
        let filmCount = list.filmIDs.count

        log("Deleting list '\(listName)' (ID: \(listID)) with \(filmCount) film(s)")

        // Check if user is actively viewing this list in the current view state.
        let wasViewingThisList: Bool
        if case .list(let activeListID) = ViewStateManager.shared.activeView {
            wasViewingThisList = (activeListID == listID)
        } else {
            wasViewingThisList = false
        }

        // Delete through coordinator (handles memberships automatically).
        coordinator.deleteList(listID: listID)
        log("Deleted list '\(listName)'")

        // If user was viewing this list, switch the gallery's view state back to
        // All Films. The sidebar's own selection is NOT touched here: the
        // .deleted event posted just below is what moves selectedSidebarItem off
        // the now-gone list, and only when that list is genuinely the selected
        // row. (This used to also broadcast a blanket "clear list selection"
        // event, which forced the sidebar to All Films whenever the ACTIVE VIEW
        // was this list — wrongly kicking the user off a pinned parent row such
        // as Recents during "Show in List" navigation, where activeView and
        // selectedSidebarItem intentionally diverge.)
        if wasViewingThisList {
            ViewStateManager.shared.switchToViewSync(.allFilms)
            log("Switched view to All Films after deleting active list")
        }

        // Notify observers that list was deleted.
        AppEventBus.shared.listDeleted(listID)

        return true
    }

    /// Returns an array of film IDs for a list, for use by callers that need to capture
    /// the IDs before triggering deletion (avoids relationship access issues mid-delete).
    /// Synchronous because all data is served from the in-memory MemoryStore.
    static func getFilmIDsForListDeletion(_ listID: UUID,
        coordinator: DataCoordinator) -> [UUID] {
        guard let memoryList = coordinator.getList(listID) else {
            log("ERROR: Cannot get film IDs for non-existent list")
            return []
        }
        let filmIDs = Array(memoryList.filmIDs)
        log("Found \(filmIDs.count) film(s) in list for deletion")
        return filmIDs
    }

    /// Deletes all films contained in a list from the library.
    /// This deletes the actual Film objects; their memberships will be cascade deleted.
    /// - Parameters:
    ///   - listID: UUID of the list whose contents should be deleted.
    ///   - filmIDs: Pre-fetched array of film IDs to delete (from getFilmIDsForListDeletion).
    ///   - coordinator: DataCoordinator for performing deletion operations.
    static func deleteListContents(_ listID: UUID, filmIDs: [UUID],
        coordinator: DataCoordinator) async {
        guard !filmIDs.isEmpty else {
            log("Delete list contents aborted: No films in list")
            return
        }

        log("Deleting \(filmIDs.count) film(s) from list contents")

        // Use FilmManager for actual deletion (handles poster cleanup, etc.)
        await FilmManager.deleteFilms(Set(filmIDs), coordinator: coordinator,
            selectionState: nil)

        log("Successfully deleted list contents")
    }

    // MARK: - Clear List Contents Operation
    
    /// Clears all films from a list without deleting the films from the library.
    /// This removes all memberships but keeps the Film objects intact.
    /// - Parameters:
    ///   - listID: UUID of the list to clear.
    ///   - coordinator: DataCoordinator for database operations.
    static func clearListContents(_ listID: UUID, coordinator: DataCoordinator) -> Bool {
        guard let memoryList = coordinator.getList(listID) else {
            log("ERROR: Cannot clear contents for non-existent list")
            return false
        }
        
        let listName = memoryList.listName
        let filmCount = memoryList.filmIDs.count
        
        guard filmCount > 0 else {
            log("List '\(listName)' is already empty")
            return true
        }
        
        log("Clearing \(filmCount) film(s) from list '\(listName)'")

        // The operationStarted / membershipChanged / operationCompleted bracket lives in
        // FilmManager.removeFilmsFromLists, shared with every other removal surface — see
        // its doc comment.
        FilmManager.removeFilmsFromLists([listID: memoryList.filmIDs], coordinator: coordinator)
        log("Cleared \(filmCount) film(s) from list '\(listName)'")
        return true
    }

    // MARK: - Remove from All Lists Operation
    
    /// Removes films from all lists they belong to.
    static func removeFilmsFromAllLists(_ filmIDs: Set<UUID>,
        coordinator: DataCoordinator) {
        guard !filmIDs.isEmpty else {
            log("Remove from all lists aborted: No film IDs provided")
            return
        }
        
        log("Removing \(filmIDs.count) film(s) from all lists")
        
        // Collect the union of all list memberships for the selected films from MemoryStore.
        // Internal Film Queue lists are excluded: a film's queue membership is managed
        // exclusively through the FilmSheet's Up Next picker, never via this bulk user action.
        let affectedListIDs = filmIDs.reduce(into: Set<UUID>()) { result, filmID in
            result.formUnion(coordinator.getListIDs(forFilm: filmID))
        }.subtracting(FilmQueue.allListIDs)
        
        guard !affectedListIDs.isEmpty else {
            log("No list memberships found for selected films")
            return
        }
        
        log("Found \(affectedListIDs.count) list(s) affected")

        // Each affected list gets its own operationStarted/Completed pair, so each row's
        // progress indicator tracks its own work window — all of which lives in
        // FilmManager.removeFilmsFromLists rather than being restated here. The same
        // `filmIDs` set is offered to every affected list; removeFilmsFromList already
        // ignores IDs a given list does not hold.
        let removals = Dictionary(uniqueKeysWithValues: affectedListIDs.map { ($0, filmIDs) })
        FilmManager.removeFilmsFromLists(removals, coordinator: coordinator)

        log("Removed \(filmIDs.count) film(s) from \(affectedListIDs.count) list(s)")
    }

    // MARK: - Validation Helpers
    
    /// Checks if a list exists and is valid.
    static func listExists(_ listID: UUID, coordinator: DataCoordinator) -> Bool {
        return coordinator.getList(listID) != nil
    }

    // MARK: - Private Helpers
    
    private static func generateUniqueName(baseName: String,
        existingNames: [String]) -> String {
        let lowerExisting = existingNames.map { $0.lowercased() }

        // If the base name doesn't exist (case-insensitive), use it as-is.
        if !lowerExisting.contains(baseName.lowercased()) { return baseName }

        // Find the next available numbered suffix.
        var counter = 1
        var candidateName = "\(baseName) \(counter)"

        while lowerExisting.contains(candidateName.lowercased()) {
            counter += 1
            candidateName = "\(baseName) \(counter)"
        }
        return candidateName
    }
}

// MARK: - Supporting Types

/// Safe, value-type representation of list information.
struct ListInfo: Identifiable, Equatable {
    let listID: UUID
    let listName: String
    let filmCount: Int
    let displayOrder: Int

    var id: UUID { listID }
}

// MARK: - SwiftUI Sheet for Creating/Editing Lists

@MainActor
struct ListManagerSheet: View, Loggable {
    nonisolated static let logTag = "[ListSheet]"

    @Environment(\.dismiss) private var dismiss
    @Environment(DataCoordinator.self) private var coordinator

    let mode: Mode
    let existingListID: UUID?
    let filmIDs: Set<UUID>?
    let prefillName: String?

    @State private var listName: String = ""
    @State private var isSaving: Bool = false
    @State private var showingSmartListCollisionAlert: Bool = false

    /// Returns true when the trimmed, lowercased entry matches a smart list name or an
    /// internal Film Queue list name (both are reserved and cannot be used for a user list).
    private var collidesWithSmartList: Bool {
        let trimmed = listName.trimmingCharacters(in: .whitespaces)
        return SmartListType.isReservedName(trimmed) || FilmQueue.isReservedName(trimmed)
    }

    enum Mode { case create; case edit }

    /// The frame both the create and edit glyphs are placed in, top-leading aligned —
    /// see the glyph itself, below, for why. Sized from the "note.text.badge.plus"
    /// glyph specifically (rather than whichever glyph this instance shows): it is the
    /// larger of the two — the badge extends the canvas outward without moving the base
    /// note shape — so sizing the frame to it, rather than to "note.text", guarantees
    /// there is always room for either glyph regardless of which mode is showing.
    /// Measured from the live NSImage rather than hand-picked constants so it tracks
    /// the symbol's actual metrics if a future OS revises them.
    private static let glyphFrameSize: CGSize = {
        let config = NSImage.SymbolConfiguration(pointSize: 36, weight: .regular)
        let image = NSImage(systemSymbolName: "note.text.badge.plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        return image?.size ?? CGSize(width: 36, height: 36)
    }()

    /// Empirically-tuned correction for a small residual vertical mismatch between the
    /// two glyphs that `glyphFrameSize` + `.topLeading` alone doesn't fully close.
    private static let createGlyphVerticalCorrection: CGFloat = -0.5

    init(mode: Mode, existingListID: UUID? = nil, filmIDs: Set<UUID>? = nil, prefillName: String? = nil) {
        self.mode = mode
        self.existingListID = existingListID
        self.filmIDs = filmIDs
        self.prefillName = prefillName
    }

    var body: some View {
        VStack(spacing: 0) {
            // Large glyph, shown in both modes so the two sheets share one layout —
            // "note.text.badge.plus" when creating, its base "note.text" when editing an
            // existing list's name. The two symbols are the same base glyph plus an
            // appended "+" badge that only enlarges the canvas to the right and below —
            // confirmed by rendering both and comparing their visible-pixel bounding
            // boxes, which share the same top-left origin. Pinning both to `.topLeading`
            // inside the shared `glyphFrameSize` frame (sized to the larger, badged
            // variant) therefore keeps the base note shape at the identical position in
            // both sheets; only the badge appears or doesn't, extending outward from it.
            Image(systemName: mode == .create ? "note.text.badge.plus" : "note.text")
                .font(.system(size: 36))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: Self.glyphFrameSize.width, height: Self.glyphFrameSize.height,
                       alignment: .topLeading)
                .offset(y: mode == .create ? Self.createGlyphVerticalCorrection : 0)
                .padding(.top, 20)

            // Title.
            Text(mode == .create ? "Create New List" : "Edit List Name")
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 8)
                .padding(.bottom, filmIDs != nil ? 4 : 16)
            
            // Show selection count when creating from selection
            if mode == .create, let filmIDs = filmIDs, !filmIDs.isEmpty {
                let count = filmIDs.count
                let itemText = count == 1 ? "Item" : "Items"
                Text("Containing \(count) Selected \(itemText)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
            }
            
            // Text field.
            TextField("List Name", text: $listName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .onSubmit {
                    if !listName.trimmingCharacters(in: .whitespaces).isEmpty { saveList() }
                }

            // Smart list name constraint notice.
            Text("Note: Name must not match that of any smart lists.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 280, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)

            Divider()

            // Button gutter.
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .padding(4)
                        .font(.system(size: 12))
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
                
                Spacer()
                
                Button {
                    saveList()
                } label: {
                    Text(mode == .create ? "Create" : "Done")
                        .padding(4)
                        .font(.system(size: 12))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(listName.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
        }
        .frame(width: 320)
        .fixedSize()
        .onAppear {
            if mode == .create, let prefillName {
                listName = prefillName
            }
            loadExistingNameSync()
        }
        .alert("Name Not Allowed", isPresented: $showingSmartListCollisionAlert) {
            Button("OK") {
                listName = ""
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("List name cannot be the same as that of a smart list. Please choose another name.")
        }
    }

    private func loadExistingNameSync() {
        guard mode == .edit, let listID = existingListID else { return }

        // Synchronously load directly from MemoryStore via DataCoordinator (instant)
        if let list = coordinator.getList(listID) {
            listName = list.listName
        } else {
            Self.log("WARNING: Could not load list name for editing")
            dismiss()
        }
    }

    private func saveList() {
        guard !isSaving else { return }

        // Reject names that collide with a smart list name (case-insensitive).
        if collidesWithSmartList {
            showingSmartListCollisionAlert = true
            return
        }

        isSaving = true

        Task {
            let success: Bool

            if mode == .create {
                success = ListManager.createList(baseName: listName,
                    coordinator: coordinator, filmIDs: filmIDs) != nil
            } else if let listID = existingListID {
                success = ListManager.updateListName(listID, newName: listName,
                    coordinator: coordinator)
            } else {
                success = false
            }

            if success {
                dismiss()
            } else {
                Self.log("ERROR: Failed to save list")
                isSaving = false
            }
        }
    }
}

// MARK: - Film Removal Commands

/// The shared implementation behind every "Remove from List" / "Remove from All Lists" /
/// "Delete from Library" command in the app — the MenuBar's "Film" menu, the
/// GalleryTitleBar's TrashMenuButton, the gallery contextual menu (GalleryContextMenu),
/// and KeyboardManager's Opt+Delete fallback.
///
/// Before this existed the same three operations were written out four times, each with
/// its own copy of the context if-chain, the membership pre-filter, the
/// `Preferences.shouldConfirmListContents` / `Preferences.confirmGalleryDelete` gate, and
/// the alert payload. Keeping four copies in agreement was entirely manual: the
/// enablement test (`canRemoveFromCurrentList`) existed in two of them and inline in a
/// third, the Film Queue branch pre-filtered its selection in all four but the
/// user-list branch pre-filtered in none, and adding a new removable context meant
/// finding and editing every copy by hand. All of that now lives here once.
///
/// The one genuine behavioral difference between the hosts is preserved as an explicit
/// parameter rather than being flattened away: the two gallery surfaces clear the
/// selection after an unconfirmed removal, while the MenuBar and keyboard paths leave it
/// standing. See `clearingSelection` below.
@MainActor
enum FilmRemoval: Loggable {
    nonisolated static let logTag = "[FilmRemoval]"

    // MARK: - Context

    /// The list a "Remove from List" command would remove from, given the view on
    /// screen. Deliberately narrower than SidebarItem: these are the only three places
    /// where "remove from THIS list" is a distinct operation from "remove from every
    /// list," and naming them explicitly keeps each caller from having to re-derive the
    /// same if-chain from `selectedSidebarItem` plus a category singleton.
    enum ListContext: Equatable {
        case hallOfFame
        case filmQueue
        case userList(UUID)
    }

    /// Resolves the active removal context, or nil where "Remove from List" is
    /// meaningless (All Films, Search, Recents, Unwatched, the smart lists, Imports, and
    /// the Reports tabs other than Hall of Fame).
    ///
    /// The gallery hosts can never observe `.hallOfFame` — Reports is not a gallery
    /// view, and GalleryContextMenu additionally gates the whole item on
    /// `ViewCapabilities.showsRemoveFromListInTrashMenu`, which is false there — so
    /// resolving all three contexts in one place is a superset that costs those callers
    /// nothing and removes a divergence point.
    static func currentListContext(appState: AppState) -> ListContext? {
        if appState.selectedSidebarItem == .libraryItem(.reports) {
            return ReportsState.shared.selectedCategory == .hallOfFame ? .hallOfFame : nil
        }
        if appState.selectedSidebarItem == .libraryItem(.filmQueue) {
            return .filmQueue
        }
        if case .list(let listID) = appState.selectedSidebarItem {
            return .userList(listID)
        }
        return nil
    }

    /// The subset of `filmIDs` that is actually resident in `context` and would
    /// therefore genuinely be affected by a removal.
    ///
    /// Every removal path filters through this before acting or alerting, so a
    /// confirmation alert's film count is always exact and a selection that is only
    /// partially resident does the right (partial) thing rather than the wrong (whole)
    /// one. The underlying operations already skip non-members, so this changes what the
    /// user is *told*, not what is done to the database.
    static func removableFilmIDs(from filmIDs: Set<UUID>,
                                 in context: ListContext,
                                 coordinator: DataCoordinator) -> Set<UUID> {
        switch context {
        case .hallOfFame:
            // hallOfFameFilms is an Array; hoisting it into a Set once keeps this linear
            // rather than quadratic in the size of the selection.
            let hofIDs = Set(coordinator.hallOfFameFilms)
            return filmIDs.filter { hofIDs.contains($0) }
        case .filmQueue:
            return filmIDs.filter { coordinator.filmQueueSection(forFilm: $0) != nil }
        case .userList(let listID):
            return filmIDs.filter { coordinator.filmExists(filmID: $0, inList: listID) }
        }
    }

    /// True when a "Remove from List" command should be enabled for `filmIDs`.
    ///
    /// `contains`-style semantics — at least one selected film resident in the context,
    /// not all of them — because `removableFilmIDs` narrows the set before acting, so a
    /// partially-resident selection still has real work to do.
    static func canRemoveFromCurrentList(filmIDs: Set<UUID>,
                                         appState: AppState,
                                         coordinator: DataCoordinator) -> Bool {
        guard !filmIDs.isEmpty,
              let context = currentListContext(appState: appState) else { return false }
        return !removableFilmIDs(from: filmIDs, in: context, coordinator: coordinator).isEmpty
    }

    // MARK: - Commands

    /// Removes `filmIDs` from the active list context, honoring
    /// `Preferences.shouldConfirmListContents`.
    ///
    /// - Parameter clearingSelection: Whether to clear the selection once an unconfirmed
    ///   removal completes. True for the two gallery surfaces (the trash menu and the
    ///   contextual menu), whose films visibly leave the view under the user's cursor;
    ///   false for the MenuBar and Opt+Delete, which have always left the selection
    ///   standing. A confirmed removal carries the flag on its alert payload, and
    ///   AlertHostView's completion path honors it the same way.
    static func removeFromCurrentList(filmIDs: Set<UUID>,
                                      appState: AppState,
                                      coordinator: DataCoordinator,
                                      clearingSelection: Bool) {
        guard let context = currentListContext(appState: appState) else { return }
        let targets = removableFilmIDs(from: filmIDs, in: context, coordinator: coordinator)
        guard !targets.isEmpty else { return }

        let confirm = Preferences.shouldConfirmListContents

        // Logged as a request, not as the removal itself, whenever confirmation is on:
        // this method then only raises an alert — the removal happens later, from the
        // alert's completion path, and may never happen at all. Announcing the outcome
        // here made the log assert a removal that a cancel silently contradicted.
        if confirm {
            Self.log("Remove from \(context) requested for \(targets.count) film(s) — awaiting confirmation")
        } else {
            Self.log("Removing \(targets.count) film(s) from \(context)")
        }

        switch context {
        case .hallOfFame:
            if confirm {
                AppEventBus.shared.sendAlert(.confirmRemoveFromHallOfFame(filmIDs: targets,
                                                                          clearingSelection: clearingSelection))
            } else {
                // Single batched call: one compaction, one atomic database transaction,
                // and one coherent rollback baseline for the whole selection. Synchronous,
                // so the selection clear follows it directly.
                coordinator.removeFromHallOfFame(targets)
                clearSelectionIfRequested(clearingSelection)
            }

        case .filmQueue:
            if confirm {
                AppEventBus.shared.sendAlert(.confirmRemoveFromFilmQueue(filmIDs: targets,
                                                                         clearingSelection: clearingSelection))
            } else {
                Task {
                    FilmManager.removeFromFilmQueue(targets, coordinator: coordinator)
                    clearSelectionIfRequested(clearingSelection)
                }
            }

        case .userList(let listID):
            if confirm {
                // The list record is needed only for the alert's title, so the lookup is
                // scoped to this branch — requiring it up front would silently swallow the
                // unconfirmed removal in the one case where it can be missing (the list
                // deleted out from under an open menu).
                guard let list = coordinator.getList(listID) else {
                    Self.log("Remove from list aborted: list \(listID) no longer exists")
                    return
                }
                AppEventBus.shared.sendAlert(.confirmRemoveFromList(filmIDs: targets,
                                                                    listID: listID,
                                                                    listName: list.listName,
                                                                    clearingSelection: clearingSelection))
            } else {
                Task {
                    FilmManager.removeFilmsFromList(targets, listID: listID,
                                                          coordinator: coordinator)
                    clearSelectionIfRequested(clearingSelection)
                }
            }
        }
    }

    /// Removes `filmIDs` from every list they belong to, honoring
    /// `Preferences.shouldConfirmListContents`. Unlike `removeFromCurrentList` this is
    /// available in every view, so there is no context to resolve and nothing to
    /// pre-filter — a film in no lists is simply a no-op inside ListManager.
    static func removeFromAllLists(filmIDs: Set<UUID>,
                                   coordinator: DataCoordinator,
                                   clearingSelection: Bool) {
        guard !filmIDs.isEmpty else { return }

        if Preferences.shouldConfirmListContents {
            // See removeFromCurrentList: request, not outcome.
            Self.log("Remove from all lists requested for \(filmIDs.count) film(s) — awaiting confirmation")
            AppEventBus.shared.sendAlert(.confirmRemoveFromAllLists(filmIDs: filmIDs,
                                                                    clearingSelection: clearingSelection))
        } else {
            Self.log("Removing \(filmIDs.count) film(s) from all lists")
            Task {
                ListManager.removeFilmsFromAllLists(filmIDs, coordinator: coordinator)
                clearSelectionIfRequested(clearingSelection)
            }
        }
    }

    /// Deletes `filmIDs` from the library, honoring `Preferences.confirmGalleryDelete`.
    ///
    /// Always deletes from the library regardless of the active view — "Remove from
    /// List" is the separate, dedicated operation for list membership.
    ///
    /// The selection handling here differs in shape from the two methods above because
    /// `FilmManager.deleteFilms` takes the SelectionState directly (it must reconcile the
    /// selection as rows disappear, not merely clear it afterwards), so `clearingSelection`
    /// chooses whether to hand it over rather than driving a trailing clear.
    static func deleteFromLibrary(filmIDs: Set<UUID>,
                                  coordinator: DataCoordinator,
                                  clearingSelection: Bool) {
        guard !filmIDs.isEmpty else { return }

        if Preferences.confirmGalleryDelete {
            // Deliberately NOT "Deleting N film(s) from library". With confirmation on,
            // this method deletes nothing — it raises an alert and returns. The previous
            // wording was emitted the instant the command was invoked, so a canceled
            // deletion left the log claiming films had been removed, with nothing after
            // it to say otherwise. FilmManager.deleteFilms logs the deletion proper when
            // the alert's completion path actually calls it.
            Self.log("Delete from library requested for \(filmIDs.count) film(s) — awaiting confirmation")
            AppEventBus.shared.sendAlert(.confirmDeleteFromLibrary(filmIDs: filmIDs,
                                                                   clearingSelection: clearingSelection))
        } else {
            Self.log("Deleting \(filmIDs.count) film(s) from library (confirmation disabled)")
            Task {
                await FilmManager.deleteFilms(filmIDs, coordinator: coordinator,
                                              selectionState: clearingSelection
                                                  ? SelectionState.shared : nil)
            }
        }
    }

    // MARK: - Helpers

    private static func clearSelectionIfRequested(_ shouldClear: Bool) {
        guard shouldClear else { return }
        SelectionState.shared.clearImmediate()
    }
}
