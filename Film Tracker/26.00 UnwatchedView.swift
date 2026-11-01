// MARK: - UnwatchedView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The Unwatched library section (Unwatched and Not Rated tabs), shown in the standard GalleryView. The segmented picker sits in
// GalleryTitleBar, as in the Film Queue. Its lifecycle matches RecentsState's ensureInitialViewLoad and resetInitialization.

import Foundation

// MARK: - Unwatched Category

/// The two tabs of the Unwatched library section. "Unwatched" shows every film not
/// marked as watched; "Not Rated" shows every film with no userRating.
enum UnwatchedCategory: String, CaseIterable, Codable, Sendable {
    case unwatched
    case notRated

    var displayName: String {
        switch self {
        case .unwatched: return "Unwatched"
        case .notRated: return "Not Rated"
        }
    }
}

// MARK: - Unwatched State

/// Manages the selected Unwatched tab. It follows RecentsState's ensureInitialViewLoad and resetInitialization lifecycle,
/// so GalleryView drives the initial load the same way. Unlike Recents, the tab is not persisted across launches. It always
/// starts on "Unwatched", as the smart-list variant states do.
@MainActor
@Observable
final class UnwatchedState: SubcategoryViewState {
    static let shared = UnwatchedState()

    var selectedCategory: UnwatchedCategory = .unwatched

    private var hasInitializedView = false

    /// See SubcategoryViewState.
    var scopedSidebarItem: SidebarItem { .libraryItem(.unwatched) }

    private init() {}

    /// Called when the Unwatched view first appears to ensure the initial tab is loaded.
    func ensureInitialViewLoad() {
        guard !hasInitializedView else { return }
        hasInitializedView = true
        ViewStateManager.shared.switchToViewSync(.unwatched(selectedCategory))
    }

    /// Resets initialization flag when leaving the Unwatched view.
    func resetInitialization() {
        hasInitializedView = false
    }

    func selectCategory(_ category: UnwatchedCategory) {
        // Don't skip a repeated category, since it may need a reload.
        let categoryChanged = category != selectedCategory
        // selectedCategory updates synchronously, so the segmented control shows the new choice at once.
        selectedCategory = category

        // No parent sidebar item is passed, since selectedSidebarItem is already .libraryItem(.unwatched) for every tab, as in RecentsState.
        SubcategoryNavigation.performSwitch(
            clearingSelection: categoryChanged,
            to: .unwatched(category))
    }
}
