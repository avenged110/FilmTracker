// MARK: - RTabDetails.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Displays film details in the right sidebar's "Details" tab.

import SwiftUI
import AppKit

struct RTabDetails: View {
    // Individual table expansion bindings.
    //
    // The releases summary table is not part of this tab's module stack, so no
    // `releasesExpanded` binding is threaded here. That table is a module of the
    // "Releases" tab and owns its own expansion state (`releasesSummaryExpanded` in
    // RightSidebar). See RSBReleasesSection in ReleasesTable.swift.
    var calendarTableExpanded: Binding<Bool>
    var listTableExpanded: Binding<Bool>

    var body: some View {
        // Scrollable Content (AppKit-backed for smooth, consistent frame-rate scrolling).
        // The Header is rendered by RightSidebar and shared across all tabs;
        // RTabDetails owns only its scrollable module stack.
        //
        // No `@Environment(\.sidebarFilm)` is read here: every module below resolves the
        // film itself, so subscribing at this level only invalidated the whole stack.
        SidebarScrollView {
            // Module stack.
            VStack(alignment: .leading, spacing: 4) {
                WatchDetails()
                RSBHelpers.sectionDivider
                CalendarTable(isTableExpanded: calendarTableExpanded)
                RSBHelpers.sectionDivider
                ListTable(isTableExpanded: listTableExpanded)
                RSBHelpers.sectionDivider
                Synopsis()
                RSBHelpers.sectionDivider
                // Module 06 — formerly the standalone "Metadata" tab, now the final
                // module of this tab. It supplies its own headers and internal dividers.
                Metadata()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }
}
