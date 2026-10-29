// MARK: - SavedSearchStore.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The saved searches in memory: the sidebar's rows, every change to them (written through
// to the database memory-first, rolled back if the write fails), and the films each one
// matches.

import Foundation
import Observation
import SwiftUI

// MARK: - Changes

/// What changed, for whoever must react: whatever shows a saved search's films reloads,
/// and a deleted one's view navigates away. Not sent for a reorder — order changes no
/// search's films, and the sidebar follows `searches` itself.
enum SavedSearchChange: Equatable, Sendable {
    /// A search was created, edited, or brought back by a rollback.
    case changed
    case deleted(UUID)
}

// MARK: - Store

@MainActor
@Observable
final class SavedSearchStore: Loggable {
    nonisolated static let logTag = "[SavedSearches]"

    static let shared = SavedSearchStore()

    /// Every saved search, in sidebar order (`displayOrder` ascending).
    private(set) var searches: [SavedSearch] = []

    /// The saved searches whose stored query this build could not fully read (see
    /// DataManager.fetchSavedSearches). One matches no films — its view shows the "Search
    /// Configuration Changed" placeholder and a `#list` naming it finds nothing — until the
    /// user saves it from the builder sheet, which rewrites what is stored. Worked out from
    /// the rows at every launch, so a restore needs to record nothing.
    private(set) var needingReview: Set<UUID> = []

    /// How the store reaches the rest of the app. Set once, by DataCoordinator, when the
    /// library finishes loading; until then the store holds no searches and changes go
    /// nowhere, which is right — nothing can show a saved search before then.
    struct Hooks {
        /// DataCoordinator.trackOperation: runs `work` after every earlier persistence
        /// operation, and `rollback` on the main actor if it throws. Its signature exactly,
        /// so the hook is the method itself.
        var track: (_ rollback: (() -> Void)?, _ work: @escaping @Sendable () async throws -> Void) -> Void
        /// The database writes, in DataManager's "Saved Search Operations" extension.
        var writer: DataManager
        /// The films a query matches across the whole library — SearchController.filmIDs
        /// (matching:) over DataCoordinator's films and `#list` catalog.
        var evaluate: (SavedSearchQuery) -> Set<UUID>
        var didChange: (SavedSearchChange) -> Void
    }
    @ObservationIgnored private var hooks: Hooks?

    /// The saved searches being evaluated right now, outermost first. See filmIDs(for:).
    @ObservationIgnored private var evaluating: [UUID] = []

    init() {}

    // MARK: Loading

    /// Installs the hooks and the searches read from the database.
    func attach(_ hooks: Hooks, searches loaded: [SavedSearch], needingReview: Set<UUID>) {
        self.hooks = hooks
        searches = loaded.sorted { ($0.displayOrder, $0.dateCreated) < ($1.displayOrder, $1.dateCreated) }
        self.needingReview = needingReview
        Self.log("Loaded \(searches.count) saved searches"
            + (needingReview.isEmpty ? "" : " (\(needingReview.count) need review)"))
    }

    func search(_ id: UUID) -> SavedSearch? {
        searches.first { $0.id == id }
    }

    /// Whether saved search `id` must be saved again before it shows films (`needingReview`).
    func needsReview(_ id: UUID) -> Bool {
        needingReview.contains(id)
    }

    /// Every saved search's name as a claim on the `#list` namespace, less `excluded`'s.
    func nameClaims(excluding excluded: UUID? = nil) -> [SavedSearchName.Claim] {
        searches.filter { $0.id != excluded }.map { .init(name: $0.name, kind: .savedSearch) }
    }

    // MARK: Changes

    /// Adds a saved search at the end of the sidebar section. The caller has validated the
    /// name (SavedSearchName.problem) and the references (SavedSearchReferences.cycle).
    @discardableResult
    func create(name: String, query: SavedSearchQuery) -> SavedSearch {
        let search = SavedSearch(name: name.trimmingCharacters(in: .whitespaces), query: query,
                                 displayOrder: (searches.map(\.displayOrder).max() ?? -1) + 1)
        searches.append(search)
        Self.log("Created \"\(search.name)\": \(query.label)")
        hooks?.didChange(.changed)
        persist(rollback: { [weak self] in
            self?.remove(search.id)
            self?.hooks?.didChange(.deleted(search.id))
        }) { writer in try await writer.insertSavedSearch(search) }
        return search
    }

    /// The builder sheet's save: name and query in one write. Reported as a query change,
    /// which reloads whatever shows the search; the sidebar row follows `searches` itself.
    ///
    /// A search that needs review is written even unchanged: the save is what replaces the
    /// stored query this build could not read, and what lets it show films again.
    func update(_ id: UUID, name: String, query: SavedSearchQuery) {
        guard let index = searches.firstIndex(where: { $0.id == id }) else { return }
        let before = searches[index]
        let wasNeedingReview = needingReview.contains(id)
        var after = before
        after.name = name.trimmingCharacters(in: .whitespaces)
        after.query = query
        guard after != before || wasNeedingReview else { return }
        after.dateModified = Date()
        searches[index] = after
        needingReview.remove(id)
        let written = after
        Self.log("Updated \"\(written.name)\": \(written.query.label)"
            + (wasNeedingReview ? " (reviewed)" : ""))
        hooks?.didChange(.changed)
        persist(rollback: { [weak self] in
            guard let self, let index = self.searches.firstIndex(where: { $0.id == id }) else { return }
            self.searches[index] = before
            if wasNeedingReview { self.needingReview.insert(id) }
            self.hooks?.didChange(.changed)
        }) { writer in try await writer.updateSavedSearch(written) }
    }

    func delete(_ id: UUID) {
        guard let removed = search(id) else { return }
        let wasNeedingReview = needingReview.remove(id) != nil
        remove(id)
        Self.log("Deleted \"\(removed.name)\"")
        hooks?.didChange(.deleted(id))
        persist(rollback: { [weak self] in
            self?.reinsert(removed)
            if wasNeedingReview { self?.needingReview.insert(id) }
            self?.hooks?.didChange(.changed)
        }) { writer in try await writer.deleteSavedSearch(id: id) }
    }

    /// Sidebar drag reordering (List.onMove's arguments). Renumbers from 0 and writes only
    /// the searches whose number changed.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let before = searches
        var reordered = searches
        reordered.move(fromOffsets: source, toOffset: destination)
        var orders: [UUID: Int] = [:]
        for index in reordered.indices where reordered[index].displayOrder != index {
            reordered[index].displayOrder = index
            orders[reordered[index].id] = index
        }
        searches = reordered
        let changed = orders
        guard !changed.isEmpty else { return }
        persist(rollback: { [weak self] in
            guard let self else { return }
            // Only the order is undone: a search created or deleted since keeps that change.
            let oldOrder = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.displayOrder) })
            self.searches = self.searches
                .map { var s = $0; s.displayOrder = oldOrder[s.id] ?? s.displayOrder; return s }
                .sorted { $0.displayOrder < $1.displayOrder }
        }) { writer in try await writer.updateSavedSearchOrders(changed) }
    }

    // MARK: Evaluation

    /// The films saved search `id` matches across the whole library, or none when it does
    /// not exist, needs review, or is already being evaluated. (An empty one matches nothing
    /// too: SearchController.filmIDs(matching:) refuses it.)
    ///
    /// One that needs review is missing rules it was saved with, so what is left could match
    /// far more than its user meant ("not watched" alone, once the rule beside it is gone).
    ///
    /// That last case is a `#list` loop: A names B and B names A. Saving refuses to close
    /// one (SavedSearchReferences.cycle), but a partial `#list` value can gain a match
    /// later — through a rename of any list — so evaluation guards itself as well. The
    /// inner, repeated search answers nothing, which leaves the outer one's other tokens
    /// to decide; it is logged, since it means a search is not saying what its user meant.
    func filmIDs(for id: UUID) -> Set<UUID> {
        guard let search = search(id), let hooks, !needingReview.contains(id) else { return [] }
        guard !evaluating.contains(id) else {
            let path = (evaluating + [id]).compactMap { self.search($0)?.name }.joined(separator: " → ")
            Self.log("WARNING: #list loop — \(path); the repeated search contributes no films", level: .warning)
            return []
        }
        evaluating.append(id)
        defer { evaluating.removeLast() }
        return hooks.evaluate(search.query)
    }

    // MARK: Private

    private func remove(_ id: UUID) {
        searches.removeAll { $0.id == id }
    }

    /// Inserts `search` by its displayOrder, after any search with the same number.
    private func reinsert(_ search: SavedSearch) {
        let index = searches.firstIndex { $0.displayOrder > search.displayOrder } ?? searches.endIndex
        searches.insert(search, at: index)
    }

    private func persist(rollback: @escaping () -> Void,
                         _ work: @escaping @Sendable (DataManager) async throws -> Void) {
        guard let hooks else { return }
        let writer = hooks.writer
        hooks.track({
            Self.log("WARNING: Saved search write failed — rolling back", level: .warning)
            rollback()
        }) {
            try await work(writer)
        }
    }
}
