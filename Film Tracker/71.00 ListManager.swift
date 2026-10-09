// MARK: - ListManager.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Centralized manager for all List operations including creation, deletion,
// and list content management. All operations use DataCoordinator for immediate
// in-memory updates with automatic background persistence.

import SwiftUI
import SwiftData
import AppKit

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
