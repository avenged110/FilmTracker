// MARK: - SSControls.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// The saved-search actions that the sidebar, title bar, toolbar, and menu bar share, and the
/// title bar's "Save Search" button.

import SwiftUI

// MARK: - Actions

/// Every saved-search action, from any surface: sidebar row, title bar, toolbar, or menu bar.
/// One place keeps the surfaces from drifting, as FilmRemoval does for films.
@MainActor
enum SavedSearchActions {
    /// Opens the builder sheet on the saved search: name, rules, live results.
    static func edit(_ id: UUID) {
        AppEventBus.shared.sendCommand(.showSavedSearchSheet(.edit(id)))
    }

    /// Opens the search in the field, pills editable, remembering its saved search. Leaving
    /// search returns to the view it was opened from. Once the field changes, the title bar's
    /// Save Search button can update that saved search (`fieldOrigin`).
    static func openInSearchField(_ id: UUID) {
        if reviewInsteadOfOpening(id) { return }
        AppEventBus.shared.sendCommand(.openSavedSearchInField(id))
    }

    /// A saved search that needs review (SavedSearchStore.needsReview) is never run with the
    /// rules it has left, in the field any more than in its own view: that could find far
    /// more films than its user meant. Asked to open one in the field — from its menus or
    /// the field's drop-down — this goes to its own view instead, which finds nothing and
    /// says why, and opens the builder over it once the view has switched. True when it did.
    static func reviewInsteadOfOpening(_ id: UUID) -> Bool {
        guard SavedSearchStore.shared.needsReview(id) else { return false }
        AppDelegate.appState?.navigate(to: .savedSearch(id))
        /// One turn later, so the sheet opens over the view it is about, not the one left.
        Task { @MainActor in edit(id) }
        return true
    }

    /// The saved search the field was opened from, while the field still holds it; nil
    /// otherwise.
    static var fieldOrigin: SavedSearch? {
        SearchController.shared.editingSavedSearchID.flatMap { SavedSearchStore.shared.search($0) }
    }

    /// Whether the field's search differs from `search`, the query it held when opened.
    static func fieldDiffers(from search: SavedSearch) -> Bool {
        SearchController.shared.currentQuery != search.query
    }

    /// Whether the field holds a saveable search. Not while a "#" token is half-typed:
    /// filtering is paused, so the saved search would not match what the gallery shows.
    static var canSaveCurrentSearch: Bool {
        SearchController.shared.isActive && !SearchController.shared.currentQuery.isEmpty
    }

    /// Opens the builder sheet on saved search `id`, holding the field's search. "Update"
    /// saves those rules over the saved ones.
    static func updateFromField(_ id: UUID) {
        let query = SearchController.shared.currentQuery
        guard !query.isEmpty else { return }
        AppEventBus.shared.sendCommand(.showSavedSearchSheet(.editFromField(id, query)))
    }

    /// The builder sheet, empty.
    static func newSearch() {
        AppEventBus.shared.sendCommand(.showSavedSearchSheet(.create(SavedSearchQuery(tokens: [], text: ""))))
    }

    /// Opens the builder sheet with the field's search.
    static func saveCurrentSearch() {
        let query = SearchController.shared.currentQuery
        guard !query.isEmpty else { return }
        AppEventBus.shared.sendCommand(.showSavedSearchSheet(.create(query)))
    }

    static func duplicate(_ id: UUID) {
        AppEventBus.shared.sendCommand(.showSavedSearchSheet(.duplicate(id)))
    }

    /// Deletes, after the confirmation "Remove List" shows when the list-structure
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

/// Search's "Save Search" button, at the start of the title bar's button row (as "Dispatch to
/// ATVQ" is in the Film Queue). It is its own view, so only this button re-renders when the
/// search state changes.
///
/// When a saved search opened in the field has been changed, the button becomes a menu:
/// "Save New Search…" saves a new search and leaves the saved one alone; "Update Saved
/// Search…" opens the builder on the saved search with the field's rules.
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
            /// Sized like TrashMenuButton, the row's other glyph-only menu (see the sizing
            /// note on GalleryTitleBar.buttonSection).
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
            /// Sized like the view-style toggle (see the sizing note on
            /// GalleryTitleBar.buttonSection).
            .frame(maxWidth: Preferences.buttonWidth)
            .fixedSize()
            .frame(width: Preferences.buttonSpacing)
            /// A saved search opened in the field and not yet changed is already saved.
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
