// MARK: - RPTabDataViz.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// The Data Visualizations report view, which draws its sections with AppKit (27.44 and 27.45), plus the navigation its figures open
/// (DVNavigation). It also holds DataCoordinatorModifier and DataCoordinatorScrollView, the environment re-injection helpers shared
/// with ImportsView and the Settings tabs. The statistics models live in 27.41 and 27.43.

import SwiftUI

// MARK: - DataCoordinatorModifier

/// Re-injects DataCoordinator into the NSHostingView subtree, which does not inherit the enclosing SwiftUI environment.
struct DataCoordinatorModifier: ViewModifier {
    let dataCoordinator: DataCoordinator

    func body(content: Content) -> some View {
        content.environment(dataCoordinator)
    }
}

// MARK: - DataCoordinatorScrollView

/// `AppKitScrollView` facade for consumers whose only hosted-environment need is DataCoordinator: the Imports session list and the Settings
/// tabs. The Data Visualizations tab used it until it moved to its own AppKit page (27.45). None passes an `isActive` flag or a live-scroll
/// callback. Only the Imports list passes a proxy, for its animated card removal (`holdForAnimatedShrink`).
struct DataCoordinatorScrollView<Content: View>: View {
    let content: Content
    var scrollProxy: AppKitScrollProxy? = nil

    @Environment(DataCoordinator.self) private var dataCoordinator

    init(scrollProxy: AppKitScrollProxy? = nil, @ViewBuilder content: () -> Content) {
        self.scrollProxy = scrollProxy
        self.content = content()
    }

    var body: some View {
        AppKitScrollView(
            modifier: DataCoordinatorModifier(dataCoordinator: dataCoordinator),
            scrollProxy: scrollProxy
        ) {
            content
        }
    }
}

// MARK: - View

/// The Data Visualizations report: one scrolling page of eight gallery-style sections, capped at `Preferences.galleryMaxGridWidth` and centered
/// beyond it, as the gallery grid stops widening. Every LibraryStatistics figure is still on the page, reshaped (for example, one ownership bar
/// in place of five tiles). It also adds the viewing, rotation, money, and metadata figures from LibraryInsights.
struct DataVisualizationsView: View {
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(AppState.self) private var appState
    @State private var stats: LibraryStatistics? = nil
    @State private var insights: LibraryInsights? = nil
    /// The recalculation on screen. Its parsed viewing histories let the year stepper rebuild the period section without rewalking every calendar,
    /// and its inputs let the next pass detect that nothing changed.
    @State private var dataset: DVDataset? = nil
    @State private var period: ViewingPeriodStatistics? = nil
    @State private var selectedYear: Int = AppCalendar.current.component(.year, from: Date())
    @State private var yearToDate = true
    @State private var compareWithPriorYear = true
    @State private var compareYear: Int = AppCalendar.current.component(.year, from: Date()) - 1
    /// True between a recalculation being requested and the coalesced pass running.
    /// See `scheduleRecalculation`.
    @State private var recalculationPending = false
    /// Advanced for every background recalculation started; a result is applied only if
    /// it is still the newest, so two passes started in quick succession (an event burst
    /// straddling a coalescing boundary) cannot land out of order.
    @State private var recalculationGeneration = 0
    /// Advanced whenever anything the page shows changes, such as a dataset, period, Compare switch, or setting. The page rebuilds only when it moves
    /// (see `DVCanvasModel.revision`).
    @State private var pageRevision = 0
    @AppStorage(preference: Preferences.showInfoCompleteKey) private var showInfoComplete: Bool
    /// Observed so a change recalculates. Every rotation figure depends on it (see `DVDataset.Inputs`), and no film event is posted when it changes.
    @AppStorage(preference: Preferences.defaultRotationThresholdKey) private var defaultRotationThreshold: Int

    #if DEBUG
    /// Every dataset applied to a mounted tab. The `dataviz-tab` harness scenario reads it to check that a remount with nothing changed applies only the cache.
    static var applications = 0
    #endif

    var body: some View {
        ZStack {
            if dataCoordinator.totalFilmCount == 0 {
                StandardPlaceholder(
                    glyph: "chart.bar.fill",
                    title: "No Films in Library",
                    message: "Add films to your library to view statistics and visualizations."
                )
            } else if let stats, let insights {
                /// Drawn by AppKit (27.44 and 27.45), not hosted. See DVCanvasPageView. The navigation closures capture `appState` here, in this body.
                DVCanvasScrollView(model: DVCanvasModel(
                    stats: stats, insights: insights, period: period,
                    navigation: DVNavigation(appState: appState), showInfoComplete: showInfoComplete,
                    selectedYear: $selectedYear, yearToDate: $yearToDate,
                    compare: $compareWithPriorYear, compareYear: $compareYear,
                    revision: pageRevision))
            } else {
                /// Shown only between onAppear and calculateStatistics() in the same run-loop pass, so not visible in practice.
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            /// Mount path. If statistics were computed earlier this launch, seed from the cache so the page renders at once. The fresh
            /// recalculation runs off the main actor, two run-loop cycles later, after the Picker's fade (see ReportsState.selectCategory).
            /// The first visit computes synchronously. The whole page is built in one turn.
            if let cached = ReportsState.shared.cachedVisualizations {
                apply(cached)
                Self.afterCommit { recalculateInBackground() }
            } else {
                calculateStatistics()
            }
        }
        .onChange(of: selectedYear) { _, newYear in
            let comparable = insights?.viewingYears.filter { $0 != newYear } ?? []
            let newCompareYear = comparable.contains(newYear - 1) ? newYear - 1 : (comparable.last ?? newYear - 1)
            /// If the comparison year moves too, its own onChange rebuilds the period. Rebuilding here as well would walk every viewing twice.
            if newCompareYear != compareYear {
                compareYear = newCompareYear
            } else {
                rebuildPeriod()
            }
        }
        .onChange(of: yearToDate) { _, _ in rebuildPeriod() }
        .onChange(of: compareYear) { _, _ in rebuildPeriod() }
        .onChange(of: compareWithPriorYear) { _, _ in pageRevision += 1 }
        /// Two settings the figures depend on. Settings opens as a sheet over this tab, so without these the page would keep old figures until the next remount.
        .onChange(of: showInfoComplete) { _, _ in scheduleRecalculation() }
        .onChange(of: defaultRotationThreshold) { _, _ in scheduleRecalculation() }
        /// Overdue / due-soon counts, the year-to-date span and every "last 90 days" figure
        /// are day-granular, and no film event fires at midnight: without this a tab left
        /// open overnight kept yesterday's figures until something in the library changed.
        /// `compute` compares the day, so this recalculates only when it actually rolled.
        .onReceive(CurrentDay.shared.dayChanged) { _ in scheduleRecalculation() }
        .onDisappear {
            /// A result still in flight belongs to a view that is gone. It still refreshes the cache, but must not write to this view's state.
            recalculationGeneration += 1
        }
        .onFilmEvent { _ in
            /// Any event can move a number on this tab, so no membership test applies. What is avoided is one pass per event in a burst.
            scheduleRecalculation()
        }
    }

    /// Runs `work` two run-loop cycles later. The double hop matters for the reason in ReportsState.selectCategory: a single hop still runs
    /// before this cycle's CoreAnimation commit, so its layout would land in the same frame.
    private static func afterCommit(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                work()
            }
        }
    }

    /// Coalesces recalculation requests, so a burst of film events costs one pass. `getAllFilms()` copies every snapshot, and the statistics
    /// walk them all. Deferring to the next run-loop pass collapses a burst into one recalculation and one rebuild.
    private func scheduleRecalculation() {
        guard !recalculationPending else { return }
        recalculationPending = true
        DispatchQueue.main.async {
            recalculationPending = false
            recalculateInBackground()
        }
    }

    /// The first pass, which runs synchronously so the tab never shows an empty page. Later passes use `recalculateInBackground`.
    private func calculateStatistics() {
        let ticket = ReportsState.shared.nextVisualizationsTicket()
        let dataset = DVDataset(films: dataCoordinator.getAllFilms(), previousRecords: self.dataset?.viewingRecords ?? [],
                                showInfoComplete: showInfoComplete)
        ReportsState.shared.updateVisualizationsData(dataset, ticket: ticket)
        apply(dataset)
    }

    /// Recomputes every figure off the main actor, then applies the result here. The inputs are gathered on the main actor as a value copy, and the
    /// previous viewing records let the pass skip films whose history has not changed. So the main thread is held only for the copy and the final assignment.
    ///
    /// A pass whose inputs match the dataset on screen comes back nil and applies nothing. That covers a remount with an unchanged library and an event that moved nothing this tab reads.
    private func recalculateInBackground() {
        let films = dataCoordinator.getAllFilms()
        let ticket = ReportsState.shared.nextVisualizationsTicket()
        let previous = dataset
        let showInfoComplete = showInfoComplete
        recalculationGeneration += 1
        let generation = recalculationGeneration
        Task(priority: .userInitiated) {
            guard let dataset = await DVDataset.compute(films: films, previous: previous,
                                                        showInfoComplete: showInfoComplete) else { return }
            /// The cache takes a result even if the tab went away mid-pass, but never one read from the library before what it already holds.
            /// Passes can finish out of order (see ReportsState's tickets).
            ReportsState.shared.updateVisualizationsData(dataset, ticket: ticket)
            guard generation == recalculationGeneration else { return }
            apply(dataset)
        }
    }

    private func apply(_ dataset: DVDataset) {
        #if DEBUG
        Self.applications += 1
        #endif
        self.dataset = dataset
        stats = dataset.stats
        insights = dataset.insights
        /// Clamp the stepper to a year that has viewings, on first load.
        let viewingYears = dataset.insights.viewingYears
        if !viewingYears.contains(selectedYear), let last = viewingYears.last {
            selectedYear = last
        }
        let comparable = viewingYears.filter { $0 != selectedYear }
        if !comparable.contains(compareYear) {
            compareYear = comparable.contains(selectedYear - 1) ? selectedYear - 1 : (comparable.last ?? selectedYear - 1)
        }
        rebuildPeriod()
    }

    private func rebuildPeriod() {
        let today = Date()
        /// Reused when nothing it depends on has moved, which is the common case on a cache-seeded mount (see ReportsState.cachedPeriod).
        /// The inputs comparison is cheap there, since the seeded dataset shares the cached film array.
        let key = dataset.map {
            ReportsState.PeriodKey(inputs: $0.inputs, year: selectedYear, yearToDate: yearToDate,
                                   compareYear: compareYear,
                                   day: AppCalendar.current.startOfDay(for: today))
        }
        if let key, let cached = ReportsState.shared.cachedPeriod(for: key) {
            pageRevision += 1
            period = cached
            return
        }
        pageRevision += 1
        let rebuilt = ViewingPeriodStatistics(viewings: dataset?.viewingRecords ?? [], year: selectedYear,
                                              yearToDate: yearToDate, compareYear: compareYear,
                                              today: today, calendar: .current)
        period = rebuilt
        if let key { ReportsState.shared.updatePeriod(rebuilt, for: key) }
    }
}

// MARK: - Navigation

/// The destinations a figure on this tab can open. DataVisualizationsView builds it in its body, where AppState is available, and passes
/// plain closures down. With no AppState (the harness's off-screen render), every destination is nil and rows draw without chevrons.
@MainActor
struct DVNavigation {
    let appState: AppState?

    /// Overdue films are exactly the Up for Rotation smart list, when smart lists are on.
    var upForRotation: (() -> Void)? { smartList(.upForRotation) }

    var hallOfFame: (() -> Void)? { report(.hallOfFame) }

    /// The Wishlist card opens the ranked list it summarizes.
    var releaseWishlist: (() -> Void)? { report(.releaseWishlist) }

    private func report(_ category: ReportsCategory) -> (() -> Void)? {
        guard let appState else { return nil }
        return {
            appState.navigate(to: .libraryItem(.reports))
            ReportsState.shared.selectCategory(category)
        }
    }

    func unwatched(_ category: UnwatchedCategory) -> (() -> Void)? {
        guard let appState else { return nil }
        return {
            UnwatchedState.shared.selectedCategory = category
            appState.navigate(to: .libraryItem(.unwatched))
        }
    }

    func smartList(_ type: SmartListType) -> (() -> Void)? {
        guard let appState, Preferences.smartLists else { return nil }
        return { appState.navigate(to: .smartList(type)) }
    }
}
