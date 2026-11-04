// MARK: - StatusBar.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// The status bar at the foot of GalleryView. It shows a live count of films (or list members when filtered)
/// and of selected items.

import SwiftUI

struct StatusBar: View {
    /// The bar's height. The gallery, list and Reports insets read it to clear the overlay.
    nonisolated static let height: CGFloat = 29

    @Environment(AppState.self) private var appState
    @Environment(SelectionState.self) private var selectionState
    @Environment(DataCoordinator.self) private var dataCoordinator
    var reportsState = ReportsState.shared

    /// Monitor the preference for live updates.
    @AppStorage(preference: Preferences.showStatusBarKey) private var showStatusBar: Bool

    // MARK: - View
    /// Derived inline rather than cached in @State. A cache would add a body pass per change, and a hidden bar reads
    /// none of its inputs.
    var body: some View {
        Group { if showStatusBar { statusBarContent } } }

    private var statusBarContent: some View {
        HStack {
            Spacer()
            Text(displayText)
                .font(.caption)
            Spacer() }
        .padding(.horizontal, 8) }

    private var displayText: String {
        let isReportsView = appState.selectedSidebarItem == .libraryItem(.reports)
        let currentCategory = reportsState.selectedCategory
        let total = isReportsView ? reportsState.visibleItemCount : dataCoordinator.filmCount
        let selected = selectionState.selectedFilmIDs.count

        let label: String
        if isReportsView {
            /// The Hall of Fame tab lists films, so it uses the film label. The Cost Tracker, Price Tracker, and
            /// Release Wishlist tabs list releases.
            if currentCategory == .hallOfFame {
                label = (total == 1) ? "film" : "films"
            } else {
                label = (total == 1) ? "release" : "releases"
            }
        } else {
            label = (total == 1) ? "film" : "films"
        }

        switch selected {
        case 0: return "\(total) \(label)"
        case 1: return "1 of \(total) \(label)"
        default: return "\(selected) of \(total) \(label)" } }
}
