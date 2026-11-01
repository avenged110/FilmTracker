// MARK: - RTabDetails.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Displays film details in the right sidebar's "Details" tab.

import SwiftUI
import AppKit

struct RTabDetails: View {
    // The releases summary table is a module of the Releases tab and owns its own expansion state
    // (`releasesSummaryExpanded` in RightSidebar). See RSBReleasesSection in ReleasesTable.swift.
    var calendarTableExpanded: Binding<Bool>
    var listTableExpanded: Binding<Bool>

    var body: some View {
        // Scrollable content, AppKit-backed for smooth scrolling. RightSidebar renders the shared Header, so
        // this tab owns only its module stack.
        //
        // No `@Environment(\.sidebarFilm)` is read here: every module below resolves the
        // film itself, so subscribing at this level only invalidated the whole stack.
        //
        // The stack is its own view, built inside the scroll view, so the expansion state it animates lives in
        // the hosted tree (see RTabDetailsContent).
        SidebarScrollView {
            RTabDetailsContent(calendarTableExpanded: calendarTableExpanded,
                               listTableExpanded: listTableExpanded)
        }
    }
}

/// The Details tab's module stack, with the tables' expansion animated.
///
/// RightSidebar owns the expansion flags. It resets them per selection and substitutes `.constant(true)` under
/// the auto-expand preference. A change reaches this tree through SidebarScrollView's rootView replacement, which
/// carries no animation. So each flag is mirrored in local @State inside the hosted tree. The tables read and write
/// the mirror, the stack's `.animation(_:value:)` is keyed to it, and the mirror stays in step with RightSidebar's
/// flag both ways. Changes from RightSidebar (a new selection collapsing the tables, or the preference toggling)
/// apply without animation, so only the user's "Show All" animates.
private struct RTabDetailsContent: View {
    var calendarTableExpanded: Binding<Bool>
    var listTableExpanded: Binding<Bool>

    @State private var calendarExpanded: Bool
    @State private var listExpanded: Bool

    #if DEBUG
    /// Identifies this instance to DetailsExpandProbe; see the onDisappear below.
    @State private var probeOwner = UUID()
    #endif

    init(calendarTableExpanded: Binding<Bool>, listTableExpanded: Binding<Bool>) {
        self.calendarTableExpanded = calendarTableExpanded
        self.listTableExpanded = listTableExpanded
        _calendarExpanded = State(initialValue: calendarTableExpanded.wrappedValue)
        _listExpanded = State(initialValue: listTableExpanded.wrappedValue)
    }

    var body: some View {
        // RSBTopPinnedLayout: without it, expanding a table (which makes the stack taller)
        // threw the whole stack down by half the growth before sliding it back. See the
        // layout's note in RSBHelpers.
        RSBTopPinnedLayout {
            // Module stack.
            VStack(alignment: .leading, spacing: 4) {
                WatchDetails()
                RSBHelpers.sectionDivider
                CalendarTable(isTableExpanded: $calendarExpanded)
                RSBHelpers.sectionDivider
                ListTable(isTableExpanded: $listExpanded)
                RSBHelpers.sectionDivider
                Synopsis()
                RSBHelpers.sectionDivider
                // Module 06. It supplies its own headers and internal dividers.
                Metadata()
            }
            // The tables flip their flag plainly (rather than with animations disabled)
            // only where this is set; see `customTableAnimatesExpansion`.
            .environment(\.customTableAnimatesExpansion, true)
            // Scoped to the two flags, so a new film or any other change still lands in
            // one step. Re-enables animation explicitly for this subtree, past MainView's
            // container-wide `animation = nil`.
            .animation(.smooth(duration: 0.3), value: calendarExpanded)
            .animation(.smooth(duration: 0.3), value: listExpanded)
            .padding(.horizontal, RSBCardChrome.sidebarInset)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // Local → RightSidebar: keeps its reset and the other tabs' view of the flag current.
        .onChange(of: calendarExpanded) { _, value in
            if calendarTableExpanded.wrappedValue != value { calendarTableExpanded.wrappedValue = value }
        }
        .onChange(of: listExpanded) { _, value in
            if listTableExpanded.wrappedValue != value { listTableExpanded.wrappedValue = value }
        }
        // RightSidebar → local, unanimated.
        .onChange(of: calendarTableExpanded.wrappedValue) { _, value in
            if calendarExpanded != value { RSBHelpers.withoutAnimation { calendarExpanded = value } }
        }
        .onChange(of: listTableExpanded.wrappedValue) { _, value in
            if listExpanded != value { RSBHelpers.withoutAnimation { listExpanded = value } }
        }
        #if DEBUG
        // The `details-expand` harness scenario (99.56) drives the tables through this probe, writing the same
        // flags "Show All" writes. Teardown checks ownership, because SidebarPrewarm builds and discards a
        // throwaway copy, which could otherwise unhook the real sidebar's probe.
        .onAppear {
            let calendar = $calendarExpanded, list = $listExpanded
            DetailsExpandProbe.owner = probeOwner
            DetailsExpandProbe.set = { table, value in
                if table == "calendar" { calendar.wrappedValue = value } else { list.wrappedValue = value }
            }
        }
        .onDisappear {
            guard DetailsExpandProbe.owner == probeOwner else { return }
            DetailsExpandProbe.owner = nil
            DetailsExpandProbe.set = nil
        }
        #endif
    }

}
