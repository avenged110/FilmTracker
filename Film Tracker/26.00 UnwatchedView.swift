// MARK: - UnwatchedView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Displays the Unwatched library section (Unwatched / Not Rated tabs) using the
// standard GalleryView. Uses a segmented picker in GalleryTitleBar, mirroring the
// Film Queue's segmented display filter, and the same ensureInitialViewLoad /
// resetInitialization lifecycle RecentsState uses for its own sub-category tabs.

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

/// Manages the currently selected Unwatched-view tab. Mirrors RecentsState's
/// ensureInitialViewLoad/resetInitialization lifecycle so GalleryView can drive the
/// initial load the same way it does for Recents. Unlike RecentsState, the selected
/// tab is not persisted across launches — like the smart-list variant states
/// (SmartListVariantState's per-family instances), it always starts on
/// its first tab ("Unwatched").
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
        // Don't skip if it's the same category - we might need to reload.
        let categoryChanged = category != selectedCategory
        // selectedCategory updates synchronously so the segmented control reflects the
        // new choice immediately with no visual flicker.
        selectedCategory = category

        // No parent sidebar item is passed: selectedSidebarItem is already pinned to
        // .libraryItem(.unwatched) for every tab, exactly like RecentsState.
        SubcategoryNavigation.performSwitch(
            clearingSelection: categoryChanged,
            to: .unwatched(category))
    }
}
