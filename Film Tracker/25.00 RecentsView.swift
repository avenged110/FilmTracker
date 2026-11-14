// MARK: - RecentsView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Displays recents categories (viewed, rotated, added, updated, purchased) using standard GalleryView, behind a
/// summary tab that shows a row of each (RecentsSummaryView).
/// Uses category picker in GalleryTitleBar and date subtitles via GallerySubtitleProvider.

import SwiftUI

// MARK: - Recents State

/// Manages the currently selected recents category
@MainActor
@Observable
final class RecentsState: SubcategoryViewState {
    static let shared = RecentsState()
    
    var selectedCategory: RecentsCategory = .summary
    
    private var hasInitializedView = false

    /// See SubcategoryViewState.
    var scopedSidebarItem: SidebarItem { .libraryItem(.recents) }

    /// Called when RecentsView first appears to ensure initial category is loaded
    func ensureInitialViewLoad() {
        guard !hasInitializedView else { return }
        hasInitializedView = true
        /// Trigger view switch to current category
        ViewStateManager.shared.switchToViewSync(.recents(selectedCategory))
    }
    
    /// Resets initialization flag when leaving RecentsView
    func resetInitialization() {
        hasInitializedView = false
    }
    
    /// - Parameter immediate: Switch views in this turn. See SubcategoryNavigation.performSwitch.
    func selectCategory(_ category: RecentsCategory, immediate: Bool = false) {
        /// Don't skip if it's the same category - we might need to reload
        let categoryChanged = category != selectedCategory
        /// selectedCategory updates synchronously so the picker label reflects the new
        /// choice immediately with no visual flicker.
        selectedCategory = category

        /// Standard sub-category switch. The selection clears only when the category changed, so repeating a shortcut does not
        /// clear a selection. The view switch waits for the menu dismissal animation. No parent sidebar item is passed, since
        /// selectedSidebarItem is already .libraryItem(.recents). See SubcategoryNavigation for the deferral rationale.
        SubcategoryNavigation.performSwitch(
            clearingSelection: categoryChanged,
            to: .recents(category),
            immediate: immediate)
    }
}
