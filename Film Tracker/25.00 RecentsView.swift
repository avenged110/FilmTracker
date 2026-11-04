// MARK: - RecentsView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Displays recents categories (viewed, rotated, added, purchased) using standard GalleryView.
/// Uses category picker in GalleryTitleBar and date subtitles via GallerySubtitleProvider.

import SwiftUI

// MARK: - Recents State

/// Manages the currently selected recents category
@MainActor
@Observable
final class RecentsState: SubcategoryViewState {
    static let shared = RecentsState()
    
    var selectedCategory: RecentsCategory = .recentlyViewed
    
    private var hasInitializedView = false

    /// See SubcategoryViewState.
    var scopedSidebarItem: SidebarItem { .libraryItem(.recents) }

    init() {
        /// Load saved category if preference is enabled
        if Preferences.rememberRecentsTab,
           let savedRawValue = Preferences.lastRecentsCategory,
           let saved = RecentsCategory(rawValue: savedRawValue) {
            selectedCategory = saved
        }
    }

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
    
    /// - Parameter persist: True for a deliberate tab choice, which is remembered across sessions. That covers the gallery Picker,
    ///   the Recents tab menu, and the Opt+Cmd+# shortcuts. False for navigation into Recents (Cmd+3 or the Go menu). That only
    ///   needs a category to show, and must not overwrite the remembered choice. Passing true there once reset it to the first tab.
    /// - Parameter immediate: Switch views in this turn. See SubcategoryNavigation.performSwitch.
    func selectCategory(_ category: RecentsCategory, persist: Bool = true, immediate: Bool = false) {
        /// Don't skip if it's the same category - we might need to reload
        let categoryChanged = category != selectedCategory
        /// selectedCategory updates synchronously so the picker label reflects the new
        /// choice immediately with no visual flicker.
        selectedCategory = category

        /// Save if preference is enabled
        if persist && Preferences.rememberRecentsTab {
            Preferences.lastRecentsCategory = category.rawValue
        }

        /// Standard sub-category switch. The selection clears only when the category changed, so repeating a shortcut does not
        /// clear a selection. The view switch waits for the menu dismissal animation. No parent sidebar item is passed, since
        /// selectedSidebarItem is already .libraryItem(.recents). See SubcategoryNavigation for the deferral rationale.
        SubcategoryNavigation.performSwitch(
            clearingSelection: categoryChanged,
            to: .recents(category),
            immediate: immediate)
    }
}
