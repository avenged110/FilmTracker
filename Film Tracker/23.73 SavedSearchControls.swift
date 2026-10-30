// MARK: - SavedSearchControls.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The title bar's "Save Search" button, and the saved-search actions it, the sidebar, the
// toolbar and the menu bar share.

import SwiftUI

// MARK: - Actions

/// What can be done to a saved search, from any surface — sidebar row, title bar, toolbar,
/// menu bar. One place, so the surfaces cannot drift (the role FilmRemoval plays for films).
@MainActor
enum SavedSearchActions {
    /// Opens the builder sheet on the saved search: name, rules, live results.
    static func edit(_ id: UUID) {
        AppEventBus.shared.sendCommand(.showSavedSearchSheet(.edit(id)))
    }

    /// Opens the search in the field instead, pills editable, remembering which saved search
    /// it came from. Leaving search returns to the view it was opened from, as any search
    /// does. Once the field is changed, the title bar's Save Search button offers to
    /// update that saved search (`fieldOrigin`).
    static func openInSearchField(_ id: UUID) {
        AppEventBus.shared.sendCommand(.openSavedSearchInField(id))
    }

    /// The saved search the field was opened from with "Open in Search Field", while the
    /// field holds it; nil for any other search.
    static var fieldOrigin: SavedSearch? {
        SearchController.shared.editingSavedSearchID.flatMap { SavedSearchStore.shared.search($0) }
    }

    /// Whether the field's search differs from `search` — what it held when opened there.
    static func fieldDiffers(from search: SavedSearch) -> Bool {
        SearchController.shared.currentQuery != search.query
    }

    /// Whether the field holds a search that can be saved. Not while a "#" token is
    /// half-typed: filtering is paused, so what would be saved is not what the gallery shows.
    static var canSaveCurrentSearch: Bool {
        SearchController.shared.isActive && !SearchController.shared.currentQuery.isEmpty
    }

    /// The builder sheet on saved search `id`, holding the search now in the field; its
    /// "Update" saves the field's rules over the saved ones.
    static func updateFromField(_ id: UUID) {
        let query = SearchController.shared.currentQuery
        guard !query.isEmpty else { return }
        AppEventBus.shared.sendCommand(.showSavedSearchSheet(.editFromField(id, query)))
    }

    /// The builder sheet, empty.
    static func newSearch() {
        AppEventBus.shared.sendCommand(.showSavedSearchSheet(.create(SavedSearchQuery(tokens: [], text: ""))))
    }

    /// The builder sheet, starting from the search in the field.
    static func saveCurrentSearch() {
        let query = SearchController.shared.currentQuery
        guard !query.isEmpty else { return }
        AppEventBus.shared.sendCommand(.showSavedSearchSheet(.create(query)))
    }

    static func duplicate(_ id: UUID) {
        AppEventBus.shared.sendCommand(.showSavedSearchSheet(.duplicate(id)))
    }

    /// Deletes, after the same confirmation "Remove List" asks for when the list-structure
    /// confirmation preference is on.
    static func delete(_ id: UUID) {
        guard let search = SavedSearchStore.shared.search(id) else { return }
        if Preferences.shouldConfirmListStructure {
            AppEventBus.shared.sendAlert(.confirmDeleteSavedSearch(id: id, name: search.name))
        } else {
            SavedSearchStore.shared.delete(id)
        }
    }
}

// MARK: - Title Bar Button

/// Search's "Save Search" button, leading the title bar's button row as "Dispatch to ATVQ"
/// does in the Film Queue. A view of its own, so the search state it reads invalidates only
/// this button.
///
/// When the field holds a saved search opened there ("Open in Search Field"), the button
/// waits for the field to change, then becomes a menu: "Save New Search…" saves it as a
/// new search, as the plain button does, leaving the saved one alone; "Update Saved
/// Search…" opens the builder on the saved one with the field's rules.
struct SaveSearchButton: View {
    var body: some View {
        let canSave = SavedSearchActions.canSaveCurrentSearch
        if let origin = SavedSearchActions.fieldOrigin, SavedSearchActions.fieldDiffers(from: origin) {
            Menu {
                Button("Save New Search\u{2026}") { SavedSearchActions.saveCurrentSearch() }
                Button("Update Saved Search\u{2026}") { SavedSearchActions.updateFromField(origin.id) }
            } label: {
                glyph.frame(width: Preferences.buttonWidth)
            }
            // Sized as TrashMenuButton, the row's other glyph-only menu; see the sizing
            // note at the top of GalleryTitleBar.buttonSection.
            .fixedSize()
            .menuIndicator(.hidden)
            .frame(width: Preferences.buttonSpacing)
            .disabled(!canSave)
            .help("Save this search as a new one, or update \u{201C}\(origin.name)\u{201D}")
        } else {
            let isUnchangedOrigin = SavedSearchActions.fieldOrigin != nil
            Button {
                SavedSearchActions.saveCurrentSearch()
            } label: {
                glyph.frame(width: 14)
            }
            // Sized like the view-style toggle; see the sizing note at the top of
            // GalleryTitleBar.buttonSection.
            .frame(maxWidth: Preferences.buttonWidth)
            .fixedSize()
            .frame(width: Preferences.buttonSpacing)
            // A saved search opened in the field and not yet changed is already saved.
            .disabled(!canSave || isUnchangedOrigin)
            .help("Save this search to the sidebar")
        }
    }

    private var glyph: some View {
        Image(systemName: "plus.magnifyingglass")
            .font(.system(size: 14))
            .offset(y: 1)
    }
}
