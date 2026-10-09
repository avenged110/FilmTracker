// MARK: - FilmManager.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Centralized manager for all Film operations including deletion, poster cleanup,
// and list membership reconciliation. All operations use DataCoordinator for
// immediate in-memory updates with automatic background persistence.

import SwiftUI
import SwiftData

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
