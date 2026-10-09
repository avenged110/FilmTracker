// MARK: - RPTabDataViz.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Contains the Data Visualizations report view: eight gallery-style sections on one
// vertically scrolling page (see DataVisualizationsView), drawn by AppKit (27.44/27.45),
// and the destinations its figures open (DVNavigation). Also contains
// DataCoordinatorModifier and DataCoordinatorScrollView, the environment re-injection
// modifier and AppKitScrollView facade shared by every consumer that needs
// DataCoordinator re-injected and nothing more (ImportsView and the Settings tabs).
// The statistics models live in 27.41 and 27.43; the page's sections in 27.45.

import SwiftUI

// MARK: - DataCoordinatorModifier

/// Re-injects DataCoordinator into the NSHostingView subtree.
/// NSHostingView does not inherit the enclosing SwiftUI environment; this modifier
/// ensures child views can read DataCoordinator via @Environment in the usual way.
struct DataCoordinatorModifier: ViewModifier {
    let dataCoordinator: DataCoordinator

    func body(content: Content) -> some View {
        content.environment(dataCoordinator)
    }
}

// MARK: - DataCoordinatorScrollView

/// `AppKitScrollView` facade for every consumer whose only hosted-environment
/// requirement is DataCoordinator: the Imports session list and the Settings tabs.
/// (The Data Visualizations tab used it too until it moved to its own AppKit-drawn
/// page, 27.45.) None passes an `isActive` flag or a live-scroll callback; only the
/// Imports list passes a proxy, for its animated card removal (`holdForAnimatedShrink`).
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

/// The Data Visualizations report: one vertically scrolling page of eight gallery-style
/// sections, capped at `Preferences.galleryMaxGridWidth` and centered beyond it, exactly
/// as the gallery grid stops widening. Every figure LibraryStatistics vends is still on
/// the page; the sections re-shape how they are shown (one ownership bar instead of five
/// tiles, one formats table instead of three cards, and so on) and add the viewing-,
/// rotation-, money- and metadata-derived figures LibraryInsights computes.
struct DataVisualizationsView: View {
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(AppState.self) private var appState
    @State private var stats: LibraryStatistics? = nil
    @State private var insights: LibraryInsights? = nil
    /// The recalculation on screen. Its parsed viewing histories let the year stepper
    /// rebuild the period section without walking every film's calendar table again, and
    /// the next pass reuse them; its inputs let the next pass tell that nothing changed.
    @State private var dataset: DVDataset? = nil
    @State private var period: ViewingPeriodStatistics? = nil
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @State private var yearToDate = true
    @State private var compareWithPriorYear = true
    @State private var compareYear: Int = Calendar.current.component(.year, from: Date()) - 1
    /// True between a recalculation being requested and the coalesced pass running.
    /// See `scheduleRecalculation`.
    @State private var recalculationPending = false
    /// Advanced for every background recalculation started; a result is applied only if
    /// it is still the newest, so two passes started in quick succession (an event burst
    /// straddling a coalescing boundary) cannot land out of order.
    @State private var recalculationGeneration = 0
    /// Advanced whenever anything the page shows changes — a dataset or period applied, the
    /// Compare switch, a setting — and handed to the page, which rebuilds only when it moves
    /// (see `DVCanvasModel.revision`).
    @State private var pageRevision = 0
    @AppStorage(preference: Preferences.showInfoCompleteKey) private var showInfoComplete: Bool
    /// Observed only so a change recalculates: every rotation figure moves with it (see
    /// `DVDataset.Inputs`), and no film event is posted when it changes.
    @AppStorage(preference: Preferences.defaultRotationThresholdKey) private var defaultRotationThreshold: Int

    #if DEBUG
    /// Every dataset applied to a mounted tab. Read by the `dataviz-tab` harness scenario
    /// to show that a remount with nothing changed applies the cache and nothing after it;
    /// never read in a release build.
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
                // Drawn by AppKit (27.44/27.45), not hosted: see DVCanvasPageView. The
                // navigation closures capture `appState` here, in this view's own body.
                DVCanvasScrollView(model: DVCanvasModel(
                    stats: stats, insights: insights, period: period,
                    navigation: DVNavigation(appState: appState), showInfoComplete: showInfoComplete,
                    selectedYear: $selectedYear, yearToDate: $yearToDate,
                    compare: $compareWithPriorYear, compareYear: $compareYear,
                    revision: pageRevision))
            } else {
                // Only during the window between onAppear and calculateStatistics() on the
                // same run loop pass; never visible in practice.
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Mount path. When statistics were computed before this launch, seed from the
            // cache so the tree renders immediately; the fresh recalculation is deferred
            // two run-loop cycles so it lands after the Picker menu-dismissal fade has
            // been committed (see ReportsState.selectCategory), and then runs off the
            // main actor. First-ever visit computes synchronously, so the Color.clear
            // branch remains invisible in practice. The whole page is built in one turn:
            // drawn by AppKit, it lays out in a few milliseconds.
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
            // When the comparison year moves too, its own onChange rebuilds the period;
            // rebuilding here as well would walk every viewing twice for one step.
            if newCompareYear != compareYear {
                compareYear = newCompareYear
            } else {
                rebuildPeriod()
            }
        }
        .onChange(of: yearToDate) { _, _ in rebuildPeriod() }
        .onChange(of: compareYear) { _, _ in rebuildPeriod() }
        .onChange(of: compareWithPriorYear) { _, _ in pageRevision += 1 }
        // Two settings the figures are computed from; Settings is a sheet over this tab,
        // so without these the page kept the old figures until the next remount.
        .onChange(of: showInfoComplete) { _, _ in scheduleRecalculation() }
        .onChange(of: defaultRotationThreshold) { _, _ in scheduleRecalculation() }
        .onDisappear {
            // A result still in flight belongs to a view that no longer exists; it will
            // still refresh the mount cache, but must not write to this view's state.
            recalculationGeneration += 1
        }
        .onFilmEvent { _ in
            // Every event case can move a number on this tab, so there is no membership
            // test to gate on; what IS avoided is one pass per event in a burst.
            scheduleRecalculation()
        }
    }

    /// Runs `work` on the run-loop cycle after the current one. The double hop is the
    /// point, for the reason ReportsState.selectCategory gives: a single hop still runs
    /// before this cycle's CoreAnimation commit, so its layout would land in the same
    /// frame.
    private static func afterCommit(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                work()
            }
        }
    }

    /// Coalesces recalculation requests so a burst of film events costs one pass, not one
    /// per event: `getAllFilms()` materializes a copy of every snapshot and the statistics
    /// passes walk all of them; deferring to the next run loop pass collapses a burst into
    /// one recalculation and one tree rebuild.
    private func scheduleRecalculation() {
        guard !recalculationPending else { return }
        recalculationPending = true
        DispatchQueue.main.async {
            recalculationPending = false
            recalculateInBackground()
        }
    }

    /// The first-ever pass: synchronous, so the tab never shows an empty page. Every later
    /// pass goes through `recalculateInBackground`.
    private func calculateStatistics() {
        let ticket = ReportsState.shared.nextVisualizationsTicket()
        let dataset = DVDataset(films: dataCoordinator.getAllFilms(), previousRecords: self.dataset?.viewingRecords ?? [],
                                showInfoComplete: showInfoComplete)
        ReportsState.shared.updateVisualizationsData(dataset, ticket: ticket)
        apply(dataset)
    }

    /// Recomputes every figure off the main actor and applies the result here. The inputs
    /// are gathered on the main actor — the snapshot array is a value copy, and the
    /// previous viewing records let the pass skip re-parsing every film whose history has
    /// not changed — so nothing the computation reads can move underneath it, and the
    /// main thread is held only for the copy and the final assignment. This tab used to do
    /// all of it inline, close to a second of main-thread time for a library-sized
    /// collection, on every film event and on every mount from the cache.
    ///
    /// A pass whose inputs match the dataset on screen (a remount's reconcile with the
    /// library unchanged since the cache was filled, or an event that moved nothing this
    /// tab reads) comes back nil and applies nothing: the page already shows its figures,
    /// and the cache already holds them.
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
            // The cache takes an orphaned result (the tab went away mid-pass) as well as a
            // current one, but never one read from the library before what it already
            // holds: two passes can finish out of order (see ReportsState's tickets).
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
        // Clamp the stepper to a year that has viewings on first load.
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
        // Reused when nothing it depends on has moved — the common case on a cache-seeded
        // mount (see ReportsState.cachedPeriod). The inputs comparison is cheap there: the
        // seeded dataset shares the cached one's film array.
        let key = dataset.map {
            ReportsState.PeriodKey(inputs: $0.inputs, year: selectedYear, yearToDate: yearToDate,
                                   compareYear: compareYear,
                                   day: Calendar.current.startOfDay(for: today))
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

/// The few destinations a figure on this tab can open. Built in DataVisualizationsView's
/// body, where AppState is in the environment, and handed down as plain closures. With
/// no AppState (the harness's off-screen render) every destination is nil and the rows
/// draw without chevrons.
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
