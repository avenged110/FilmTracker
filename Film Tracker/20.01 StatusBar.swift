// MARK: - StatusBar.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Small bar at the bottom of GalleryView listing a live count of the total
// number of films (or list members when filtered) and number of items
// currently-selected (if applicable) with DataCoordinator integration.

import SwiftUI

struct StatusBar: View {
    @Environment(AppState.self) private var appState
    @Environment(SelectionState.self) private var selectionState
    @Environment(DataCoordinator.self) private var dataCoordinator
    var reportsState = ReportsState.shared

    // Monitor the preference for live updates.
    @AppStorage(preference: Preferences.showStatusBarKey) private var showStatusBar: Bool

    // MARK: - View
    // The text is derived here rather than cached in @State. A cache written from
    // onChange cost two extra body passes per change (the value change, then the cache
    // write) to save a string interpolation; computed inline, a change costs exactly one
    // pass, and a hidden bar reads none of the inputs at all.
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
            // The Hall of Fame tab lists films, not releases; use the film label there.
            // The other tabs with a status bar (Cost Tracker, Price Tracker, Release
            // Wishlist) list releases. Data Visualizations hides the bar.
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
