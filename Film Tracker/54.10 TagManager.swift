// MARK: - TagManager.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Tag management: the tags pinned to the sidebar (PinnedTagStore), one tag's place in the
/// library (TagUsage), and the actions every tag menu, the menu bar and the TagSheet share
/// (TagActions): pin, unpin, rename, delete, and View All Tags. A rename also carries the
/// saved searches whose rules name the tag (SavedSearchQuery.renamingTag).

import SwiftUI
import Combine

// MARK: - Tag Usage
/// One tag in the library (SidebarTags.census): its identity, the spelling shown for it (its
/// most-used one), and how many films carry it.
nonisolated struct TagUsage: Hashable, Sendable, Identifiable {
    /// SearchText.key, as SidebarTag's.
    let key: String
    let name: String
    let filmCount: Int

    var id: String { key }
    var sidebarTag: SidebarTag { SidebarTag(name) }
}

// MARK: - Pinned Tags
/// The tags pinned to the sidebar's Pinned Tags section, in the user's order. Stored in
/// Preferences.pinnedTags (and so backed up with the library's settings), each in the spelling
/// it was pinned or last renamed with.
///
/// A pin outlives its films: a pinned tag no film carries keeps its row, which opens to the
/// "No Films Tagged" placeholder. Only unpinning or deleting the tag removes it. Renaming the
/// tag moves the pin to the new name, in place.
@MainActor
@Observable
final class PinnedTagStore {
    static let shared = PinnedTagStore()

    private(set) var tags: [SidebarTag]
    /// Whether any tag is pinned, read by LeftSidebar's body on its own, so a reorder or a
    /// rename invalidates only the Pinned Tags section. A plain `=` of an equal Bool notifies
    /// nothing, so it is written on every change.
    private(set) var hasPins: Bool
    /// The pinned tags' keys, for Most-Used Tags to pass over and the menus to test. Stored
    /// rather than worked out on each read, and, like `hasPins`, an equal set written over it
    /// notifies nothing: a reorder or a respelling in place reaches neither Most-Used Tags nor
    /// its recount.
    private(set) var keys: Set<String>

    @ObservationIgnored private var cancellable: AnyCancellable?

    private init() {
        let stored = Self.stored()
        tags = stored
        hasPins = !stored.isEmpty
        keys = Set(stored.map(\.key))
        /// A restore writes Preferences.pinnedTags behind the store's back
        /// (SettingsManager.applySnapshotToPreferences); every preference write posts this, on
        /// the main actor.
        cancellable = AppEventBus.shared.viewEvents
            .filter { if case .preferencesChanged = $0 { return true } else { return false } }
            .sink { [weak self] _ in self?.reloadIfChanged() }
    }

    func isPinned(_ tag: SidebarTag) -> Bool { keys.contains(tag.key) }

    func pin(_ tag: SidebarTag) {
        guard !tag.key.isEmpty, !isPinned(tag) else { return }
        update { $0.append(tag) }
    }

    func unpin(_ tag: SidebarTag) {
        guard isPinned(tag) else { return }
        update { $0.removeAll { $0 == tag } }
    }

    /// The sidebar's drag reorder. Unanimated, as SavedSearchStore.move: the drop places the row.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        update(animated: false) { $0.move(fromOffsets: source, toOffset: destination) }
    }

    /// Moves the pin of `tag`, if it has one, to `newName`, in place. Where another pin is
    /// already `newName`'s tag, the two become that one pin.
    func rename(_ tag: SidebarTag, to newName: String) {
        guard let index = tags.firstIndex(of: tag) else { return }
        let renamed = SidebarTag(newName)
        if renamed != tag, isPinned(renamed) {
            update { $0.remove(at: index) }
        } else {
            update { $0[index] = renamed }
        }
    }

    /// Pins `tag` again at `index`, where a failed deletion's rollback found it.
    func restore(_ tag: SidebarTag, at index: Int) {
        guard !tag.key.isEmpty, !isPinned(tag) else { return }
        update { $0.insert(tag, at: min(max(index, 0), $0.count)) }
    }

    // MARK: Storage

    private func update(animated: Bool = true, _ change: (inout [SidebarTag]) -> Void) {
        var changed = tags
        change(&changed)
        if animated {
            withAnimation(.default) { apply(changed) }
        } else {
            apply(changed)
        }
        Preferences.pinnedTags = changed.map(\.name)
    }

    private func apply(_ pins: [SidebarTag]) {
        /// In place, never a plain `=`: SidebarTag compares by key, so pins that differ only in
        /// spelling (a rename that changes case) are `==` to the old ones, and assigning them
        /// would notify nothing (an equal Equatable write is silent).
        tags.replaceSubrange(tags.indices, with: pins)
        hasPins = !pins.isEmpty
        keys = Set(pins.map(\.key))
    }

    private func reloadIfChanged() {
        let stored = Self.stored()
        guard stored.map(\.name) != tags.map(\.name) else { return }
        apply(stored)
    }

    /// The stored names, one per key, blanks dropped.
    private static func stored() -> [SidebarTag] {
        var seen: Set<String> = []
        return Preferences.pinnedTags.map(SidebarTag.init).filter { !$0.key.isEmpty && seen.insert($0.key).inserted }
    }
}

// MARK: - Tag Uses
/// When each tag was last put on a film (Preferences.tagUses), for the sidebar's most-recent
/// order. A use is a film gaining a tag it did not carry, by any write: a FilmSheet or bulk
/// save, an import. MemoryStore, which every film write passes through, reports them. A film
/// re-saved with the tags it had, or a tag respelled on it, is no use.
///
/// Tags with no recorded use (all of them, before this existed) rank after those with one, in
/// most-used order (SidebarTags.mostRecent).
@MainActor
enum TagUseStore {
    /// Records a use, now, of each tag `new` carries that `old` did not (all of them for a film
    /// just added, `old` nil).
    static func recordUses(from old: [String]?, to new: [String]) {
        recordUses([(old: old, new: new)])
    }

    /// recordUses for a batch of writes, written once.
    static func recordUses(_ changes: [(old: [String]?, new: [String])]) {
        var added: Set<String> = []
        for change in changes where !change.new.isEmpty {
            let before = Set((change.old ?? []).map(SearchText.key))
            added.formUnion(Set(change.new.map(SearchText.key)).subtracting(before))
        }
        added.remove("")
        record(added)
    }

    private static func record(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        let now = Date().timeIntervalSinceReferenceDate
        var uses = Preferences.tagUses
        for key in keys { uses[key] = now }
        Preferences.tagUses = uses
    }

    /// The last use of each tag that has one, by key.
    static var uses: [String: Double] { Preferences.tagUses }

    /// The recorded uses of `keys`, for a rename or deletion to put back if its write fails.
    static func snapshot(_ keys: [String]) -> [String: Double?] {
        let uses = Preferences.tagUses
        return Dictionary(keys.map { ($0, uses[$0]) }, uniquingKeysWith: { a, _ in a })
    }

    /// Writes `values` back, a nil removing its key.
    static func restore(_ values: [String: Double?]) {
        var uses = Preferences.tagUses
        for (key, value) in values { uses[key] = value }
        Preferences.tagUses = uses
    }
}

// MARK: - Tag Actions
/// What a tag's menus (its sidebar row's ellipsis and secondary click), the menu bar and the
/// TagSheet do. Rename and delete reach every film carrying the tag (DataCoordinator.rewriteTag).
@MainActor
enum TagActions {
    static func togglePin(_ tag: SidebarTag) {
        let store = PinnedTagStore.shared
        if store.isPinned(tag) {
            store.unpin(tag)
            leaveIfStranded(tag)
        } else {
            store.pin(tag)
        }
    }

    /// Opens the TagSheet's rename view on `tag`.
    static func rename(_ tag: SidebarTag) {
        AppEventBus.shared.sendCommand(.showTagSheet(.rename(tag.name)))
    }

    /// Asks before deleting `tag` from every film (AlertHostView's "Delete Tag?").
    static func delete(_ tag: SidebarTag) {
        AppEventBus.shared.sendAlert(.confirmDeleteTag(name: tag.name))
    }

    /// "Delete Tag?" and its message, shared by AlertHostView and the TagSheet's own alert.
    nonisolated static let deleteAlertTitle = "Delete Tag?"

    static func deleteAlertMessage(name: String, filmCount: Int) -> String {
        let quoted = "\"\(truncateListName(name, maxLength: 42))\""
        if filmCount == 0 {
            return "\(quoted) will be removed from the sidebar. No films carry it."
        }
        return "\(quoted) will be removed from \(Fmt.count(filmCount)) \(Fmt.noun(filmCount, "film")). This action cannot be undone."
    }

    static func viewAll() {
        AppEventBus.shared.sendCommand(.showTagSheet(.viewAll))
    }

    /// Renames `tag` to `newName` on every film carrying it, moves its pin, and renames it in
    /// the saved searches whose rules name it (renameInSavedSearches). The tag's gallery, if it
    /// is on screen, follows it to the new name.
    ///
    /// The pin and the saved searches change only once the films have, in the same turn: the
    /// pin moved first, the old tag would leave Pinned Tags and show in Most-Used Tags while
    /// the films were worked out. A failed film write puts all three back, and the gallery
    /// with them.
    static func performRename(_ tag: SidebarTag, to newName: String, coordinator: DataCoordinator) async {
        let renamed = SidebarTag(newName)
        guard !renamed.key.isEmpty, renamed.name != tag.name else { return }
        /// Filled in below, before the write the rollback answers can have run.
        var searchChanges: [SavedSearchTagChange] = []
        /// The write puts the new name on the films, which MemoryStore records as a use, now.
        /// A rename is no use: the tag keeps its own last use (or, merged into another, the
        /// later of the two), written over that below.
        let usesBefore = TagUseStore.snapshot([tag.key, renamed.key])
        await coordinator.rewriteTag(tag, to: renamed.name, onRollback: {
            PinnedTagStore.shared.rename(renamed, to: tag.name)
            TagUseStore.restore(usesBefore)
            revert(searchChanges)
            follow(renamed, to: tag)
        })
        let carried = [usesBefore[tag.key] ?? nil, usesBefore[renamed.key] ?? nil].compactMap { $0 }.max()
        TagUseStore.restore(renamed.key == tag.key
            ? [tag.key: carried]
            : [tag.key: nil, renamed.key: carried])
        PinnedTagStore.shared.rename(tag, to: renamed.name)
        searchChanges = renameInSavedSearches(tag, to: renamed.name)
        follow(tag, to: renamed)
    }

    /// Moves the gallery from `old`'s films to `new`'s, if `old`'s are on screen. A change of
    /// case alone is the same tag, so the gallery stays as it is.
    private static func follow(_ old: SidebarTag, to new: SidebarTag) {
        guard let appState = AppDelegate.appState, appState.selectedSidebarItem == .tag(old) else { return }
        appState.navigate(to: .tag(new))
    }

    /// One saved search's query before and after a tag rename rewrote it.
    struct SavedSearchTagChange {
        let id: UUID
        let before: SavedSearchQuery
        let after: SavedSearchQuery
    }

    /// Renames `tag` in every saved search whose rules name it (SavedSearchQuery.renamingTag),
    /// each saved as the builder sheet saves it, and returns what changed.
    ///
    /// A search that needs review is left alone: its stored query held rules this build
    /// could not read, and saving it would both mark it reviewed and drop them for good.
    private static func renameInSavedSearches(_ tag: SidebarTag, to newName: String) -> [SavedSearchTagChange] {
        let store = SavedSearchStore.shared
        var changes: [SavedSearchTagChange] = []
        for search in savedSearchesNaming(tag) {
            guard let after = search.query.renamingTag(tag.key, to: newName) else { continue }
            store.update(search.id, name: search.name, query: after)
            changes.append(SavedSearchTagChange(id: search.id, before: search.query, after: after))
        }
        return changes
    }

    /// The saved searches a rename of `tag` may rewrite: those with a rule naming it, less any
    /// that need review (see renameInSavedSearches). The TagSheet discloses them.
    static func savedSearchesNaming(_ tag: SidebarTag) -> [SavedSearch] {
        let store = SavedSearchStore.shared
        return store.searches.filter { !store.needsReview($0.id) && $0.query.namesTag(tag.key) }
    }

    /// Puts back the saved searches a rename changed, each only while it still holds what the
    /// rename wrote: an edit the user has made since is theirs.
    private static func revert(_ changes: [SavedSearchTagChange]) {
        let store = SavedSearchStore.shared
        for change in changes {
            guard let search = store.search(change.id), search.query == change.after else { continue }
            store.update(change.id, name: search.name, query: change.before)
        }
    }

    /// Removes `tag` from every film carrying it and unpins it. Its gallery, if it is on
    /// screen, returns to All Films, as a removed list's does.
    ///
    /// Unpinned once the films are written, in the same turn, for the reason performRename
    /// moves its pin then; a failed write pins it again where it was.
    static func performDelete(_ tag: SidebarTag, coordinator: DataCoordinator) async {
        if let appState = AppDelegate.appState, appState.selectedSidebarItem == .tag(tag) {
            appState.navigate(to: .libraryItem(.allFilms))
        }
        let pinIndex = PinnedTagStore.shared.tags.firstIndex(of: tag)
        let usesBefore = TagUseStore.snapshot([tag.key])
        await coordinator.rewriteTag(tag, to: nil, onRollback: {
            if let pinIndex { PinnedTagStore.shared.restore(tag, at: pinIndex) }
            TagUseStore.restore(usesBefore)
        })
        PinnedTagStore.shared.unpin(tag)
        TagUseStore.restore([tag.key: nil])
    }

    /// Whether `tag`'s gallery may stay open, or be returned to as search closes: it is
    /// pinned, or Most-Used Tags is shown and some film carries it. A tag that has only fallen
    /// below that section's cut keeps its gallery, as it did before pins.
    static func canStayOpen(_ tag: SidebarTag, in coordinator: DataCoordinator) -> Bool {
        PinnedTagStore.shared.isPinned(tag)
            || (Preferences.showTagsInSidebar != .hidden
                && SidebarTags.census(in: coordinator).contains { $0.key == tag.key })
    }

    /// A tag on screen left with no row (just unpinned, or Most-Used Tags just hidden) returns
    /// to All Films. The one rule for both, canStayOpen, is also what search's exit applies.
    static func leaveIfStranded(_ tag: SidebarTag) {
        guard let appState = AppDelegate.appState, appState.selectedSidebarItem == .tag(tag),
              let coordinator = AppDelegate.dataCoordinator, !canStayOpen(tag, in: coordinator) else { return }
        appState.navigate(to: .libraryItem(.allFilms))
    }
}

// MARK: - Saved Search Tag Rules
extension SavedSearchQuery {
    /// This query with every `#tags` rule that names the tag `key` renamed to `newName`, its
    /// "!" and "/" marks kept; nil when no rule changes.
    ///
    /// A `#tags` rule matches inside longer tags ("noir" finds "Neo-Noir"), so only a rule
    /// whose value is the tag itself names it; a partial one ("noi") is left as written. A rule
    /// is also left as written when the new name still contains it ("Noir" → "Film Noir"): it
    /// already finds the renamed films, and rewriting it would stop it finding the others it
    /// did. Free text never reaches tags, so it is left alone. A new name holding a comma is
    /// left out too: a rule's commas separate alternatives ("noir, dark" is noir or dark), so
    /// written as a rule it would name other tags than the renamed one.
    nonisolated func renamingTag(_ key: String, to newName: String) -> SavedSearchQuery? {
        let newKey = SearchText.key(newName)
        guard namesTag(key), !newName.contains(","), !SearchText.contains(newKey, key) else { return nil }
        let renamed = tokens.map { token in
            guard Self.names(token, key) else { return token }
            return SearchToken(field: .tags, value: newName, isInverted: token.isInverted, isOr: token.isOr)
        }
        return SavedSearchQuery(tokens: renamed, text: text)
    }

    /// Whether a `#tags` rule of this query is the tag `key` itself (see renamingTag).
    nonisolated func namesTag(_ key: String) -> Bool {
        !key.isEmpty && tokens.contains { Self.names($0, key) }
    }

    nonisolated private static func names(_ token: SearchToken, _ key: String) -> Bool {
        token.field == .tags && SearchText.key(token.value) == key
    }
}
