// MARK: - RecentsView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Displays recents categories (viewed, rotated, added, purchased) using standard GalleryView.
// Uses category picker in GalleryTitleBar and date subtitles via GallerySubtitleProvider.

import SwiftUI
import SwiftData

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
        // Load saved category if preference is enabled
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
        // Trigger view switch to current category
        ViewStateManager.shared.switchToViewSync(.recents(selectedCategory))
    }
    
    /// Resets initialization flag when leaving RecentsView
    func resetInitialization() {
        hasInitializedView = false
    }
    
    /// - Parameter persist: Whether this selection represents a deliberate tab CHOICE by
    ///   the user, and should therefore be remembered across sessions. True for the
    ///   gallery Picker, the Recents tab menu, and the Opt+Cmd+# in-view tab shortcuts.
    ///   False for navigation INTO Recents (Cmd+3 / the Go menu row), which merely needs
    ///   a category to display and must not overwrite what the user last chose — passing
    ///   true there is what silently reset the remembered sub-tab to the first tab.
    /// - Parameter immediate: Switch views in this turn; see SubcategoryNavigation.performSwitch.
    func selectCategory(_ category: RecentsCategory, persist: Bool = true, immediate: Bool = false) {
        // Don't skip if it's the same category - we might need to reload
        let categoryChanged = category != selectedCategory
        // selectedCategory updates synchronously so the picker label reflects the new
        // choice immediately with no visual flicker.
        selectedCategory = category

        // Save if preference is enabled
        if persist && Preferences.rememberRecentsTab {
            Preferences.lastRecentsCategory = category.rawValue
        }

        // Standard sub-category switch: clear the selection (only when the category
        // genuinely changed — pressing the same category's shortcut twice, the "might
        // need to reload" case above, must not clear a selection nothing has actually
        // left) and defer the view switch past the menu-dismissal animation. No parent
        // sidebar item is passed: selectedSidebarItem is already pinned to
        // .libraryItem(.recents) for every category. See SubcategoryNavigation's doc
        // comment for the full selection-clear and deferral rationale.
        SubcategoryNavigation.performSwitch(
            clearingSelection: categoryChanged,
            to: .recents(category),
            immediate: immediate)
    }
}
