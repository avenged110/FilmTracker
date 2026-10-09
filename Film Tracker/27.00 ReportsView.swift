// MARK: - ReportsView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Displays reports and analytics for the film library.

import SwiftUI

struct ReportsView: View {
    @Environment(SelectionState.self) private var selectionState
    var reportsState = ReportsState.shared

    var body: some View {
        VStack(spacing: 0) {
            ReportsTitleBar()
            
            ReportsContentSwitcher()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        // Sub-view tab changes within Reports (Cost Tracker, Price Tracker, Hall of
        // Fame, Release Wishlist, Data Visualizations) swap the entire content view,
        // but SelectionState is a single shared instance that otherwise persists across
        // that swap. Without this, a selection made in one tab survives into another
        // where nothing is actually highlighted, and reappears as an orphaned selection
        // if the user switches back — exactly mirroring the clear performed on full
        // view switches (see MainView's handleViewChange). Firing on selectedCategory
        // (not the deferred displayedCategory) clears the instant the user requests a
        // switch, regardless of whether it originated from the picker, the menu bar, or
        // a keyboard shortcut.
        .onChange(of: reportsState.selectedCategory) { _, _ in
            selectionState.clearImmediate()
        }
    }
}

// MARK: - Reports Title Bar
private struct ReportsTitleBar: View {
    var reportsState = ReportsState.shared
    static let buttonWidth: CGFloat = 14
    
    var body: some View {
        GenericTitleBar(
            glyph: reportsState.selectedCategory.glyph,
            leadingContent: {
                ReportsCategoryPicker()
                    .frame(width: 220)
                    .padding(.leading, 12)
            },
            trailingButtons: {
                HStack(spacing: 8) {
                    Button {
                        // Every PDF export mechanism and option now lives in the Settings
                        // sheet's Export tab, so this button is a shortcut to it rather
                        // than a second, narrower export path of its own. Same command the
                        // global ⇧⌘E shortcut sends.
                        AppEventBus.shared.sendCommand(.openSettingsToTab(tab: .export))
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12))
                            .frame(width: ReportsTitleBar.buttonWidth)
                    }
                    .fixedSize()
                    .help("Export Reports…")
                }
                .focusable(false)
                .padding(.trailing, 18)
            }
        )
    }
    
}

// MARK: - Reports Category Picker
private struct ReportsCategoryPicker: View {
    var reportsState = ReportsState.shared

    var body: some View {
        SubcategoryPicker(
            label: "Reports Category",
            style: .menu,
            options: ReportsCategory.allCases,
            selection: reportsState.selectedCategory,
            title: \.displayName,
            onSelect: { reportsState.selectCategory($0, immediate: true) })
    }
}

// MARK: - Reports Content Switcher
/// Uses a plain switch to ensure only the active tab's view is in the hierarchy
/// at any time. Keeping all tabs alive simultaneously (ZStack approach) was tried
/// but caused cascading performance degradation: each additional tab visited added
/// a live `.onFilmEvent` subscriber (firing on every film event), a retained
/// AppKit subtree (NSTableView / NSOutlineView / NSScrollView), and a large
/// SwiftUI layout tree (especially DataVisualizationsView) all participating in
/// every layout pass, growing more expensive with each tab loaded.
///
/// This switcher reads `displayedCategory` (not `selectedCategory`). The selection
/// mutation is synchronous so the Picker label updates instantly, but the heavy
/// content swap — outgoing tab teardown plus incoming AppKit/SwiftUI tree
/// construction — is deferred two run-loop cycles in ReportsState.selectCategory.
/// This keeps the swap out of the run-loop cycle in which CoreAnimation commits
/// the NSPopUpButton menu-dismissal fade; once that transaction is committed to
/// the render server, the fade animates out-of-process and is immune to
/// subsequent main-thread load. This mirrors the RecentsState/SmartListVariantState
/// pattern, where the deferred block wraps the expensive switchToViewSync.
///
/// The targeted `.transaction` suppressor below additionally strips any ambient
/// animation transaction from the incoming tab's initial render, so the swap
/// itself renders immediately rather than animating in.
private struct ReportsContentSwitcher: View {
    var reportsState = ReportsState.shared

    var body: some View {
        Group {
            switch reportsState.displayedCategory {
            case .costTracker:
                CostTrackerView()
            case .priceTracker:
                PriceTrackerView()
            case .hallOfFame:
                HallOfFameView()
            case .releaseWishlist:
                ReleaseWishlistView()
            case .dataVisualizations:
                DataVisualizationsView()
            }
        }
        // Strip any inherited animation transaction so the incoming tab renders
        // immediately rather than animating in. With the swap now deferred past
        // the menu-dismissal commit this is defensive, but it remains correct:
        // it is applied here rather than on ReportsView to avoid suppressing
        // legitimate animations elsewhere in the title bar or export button.
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

// MARK: - Reports State
@MainActor
@Observable
final class ReportsState {
    static let shared = ReportsState()
    
    var selectedCategory: ReportsCategory = .costTracker
    /// The category whose content is currently mounted in ReportsContentSwitcher.
    /// Trails `selectedCategory` by two run-loop cycles on user-driven switches so
    /// the heavy tab swap does not compete with the Picker menu-dismissal fade
    /// (see selectCategory). Everything label-like (picker, glyph, menu checkmarks,
    /// status bar text) reads `selectedCategory` and stays instant.
    private(set) var displayedCategory: ReportsCategory = .costTracker
    var visibleItemCount: Int = 0
    
    // Export data storage per category
    private var costTrackerData: [ReleaseData] = []
    private var priceTrackerData: [ReleaseData] = []
    private var hallOfFameData: [HallOfFameFilm] = []
    private var wishlistData: [WishlistRelease] = []
    /// The Data Visualizations tab's last complete recalculation, its mount cache (the
    /// PDF export computes its own `LibraryStatistics` from the live library and does not
    /// read this). `@ObservationIgnored` because nothing reads it from a view body — the
    /// tab seeds itself from it in `onAppear` — and it is rewritten after every
    /// background pass, so observation tracking would only add a notification nothing
    /// listens to.
    @ObservationIgnored private var visualizations: DVDataset?
    /// The Data Visualizations tab's last viewing-period figures and what they were computed
    /// from. Rebuilding them walks every parsed viewing (~50 ms on a library-sized collection,
    /// measured by the `reports-loop` profile), and the tab did so on every mount although a
    /// cache-seeded mount with the stepper unchanged asks for exactly the figures it had.
    @ObservationIgnored private var periodCache: (key: PeriodKey, period: ViewingPeriodStatistics)?

    struct PeriodKey: Equatable {
        let inputs: DVDataset.Inputs
        let year: Int
        let yearToDate: Bool
        let compareYear: Int
        let day: Date
    }

    func cachedPeriod(for key: PeriodKey) -> ViewingPeriodStatistics? {
        guard let periodCache, periodCache.key == key else { return nil }
        return periodCache.period
    }

    func updatePeriod(_ period: ViewingPeriodStatistics, for key: PeriodKey) {
        periodCache = (key, period)
    }
    
    // Sort order storage per category
    private var costTrackerSortOrder: [KeyPathComparator<ReleaseData>] = []
    private var priceTrackerSortOrder: [KeyPathComparator<ReleaseData>] = []

    // MARK: - Mount Caches
    // The per-category data stores above already persist across tab switches; the
    // members below let the tab views exploit that: on mount, a tab seeds its local
    // state from the cache (rendering instantly with no library scan, no sort, and
    // no placeholder), then reconciles with a fresh load deferred two run-loop
    // cycles — after the Picker menu-dismissal fade has been committed. This keeps
    // the heavy data work out of the fade window entirely. The AppKit table/list
    // construction itself remains per-switch (keep-alive was tried and reverted).

    /// Categories whose data stores have been populated at least once this launch.
    /// Distinguishes "never loaded" (must scan synchronously on mount to avoid a
    /// placeholder flash) from "loaded and legitimately empty" (placeholder is
    /// correct; the deferred reconcile will confirm).
    @ObservationIgnored private var loadedCategories: Set<ReportsCategory> = []

    /// Memoized sort results for the tracker tabs, keyed by the exact inputs they
    /// were computed from. Seeding assigns the cached data array back into view
    /// state, so the `data` equality check below short-circuits on buffer identity
    /// and the mount-path lookup is O(1).
    @ObservationIgnored private var sortedReleaseCaches: [ReportsCategory: SortedReleaseCache] = [:]

    private struct SortedReleaseCache {
        let data: [ReleaseData]
        let sortOrder: [KeyPathComparator<ReleaseData>]
        let sorted: [ReleaseData]
    }

    func hasLoadedData(for category: ReportsCategory) -> Bool {
        loadedCategories.contains(category)
    }

    /// Raw (unsorted) cached rows for the tracker categories.
    func cachedReleases(for category: ReportsCategory) -> [ReleaseData] {
        switch category {
        case .costTracker:  return costTrackerData
        case .priceTracker: return priceTrackerData
        case .hallOfFame, .releaseWishlist, .dataVisualizations: return []
        }
    }

    var cachedHallOfFameFilms: [HallOfFameFilm] { hallOfFameData }
    var cachedWishlistReleases: [WishlistRelease] { wishlistData }
    var cachedVisualizations: DVDataset? { visualizations }
    /// Where the Data Visualizations tab was scrolled to when last left, for the next
    /// mount to restore (DVCanvasScrollView) when "maintain scroll position" is on.
    @ObservationIgnored var visualizationsScrollAnchor: DVScrollAnchor?

    /// The sort order last active in a tracker tab, or nil if none has been
    /// recorded yet this launch. Seeded back into the tab on mount so the cached
    /// sorted array remains valid (and so a user's column sort survives switches).
    func savedSortOrder(for category: ReportsCategory) -> [KeyPathComparator<ReleaseData>]? {
        switch category {
        case .costTracker:  return costTrackerSortOrder.isEmpty ? nil : costTrackerSortOrder
        case .priceTracker: return priceTrackerSortOrder.isEmpty ? nil : priceTrackerSortOrder
        case .hallOfFame, .releaseWishlist, .dataVisualizations: return nil
        }
    }

    /// Returns the memoized sorted array iff it was computed from exactly this
    /// data and sort order; nil forces the caller to sort (and re-cache).
    func cachedSortedReleases(
        for category: ReportsCategory,
        data: [ReleaseData],
        sortOrder: [KeyPathComparator<ReleaseData>]
    ) -> [ReleaseData]? {
        guard let cache = sortedReleaseCaches[category],
              cache.sortOrder == sortOrder,
              cache.data == data else { return nil }
        return cache.sorted
    }

    /// Records a freshly computed sort result together with the inputs it was
    /// computed from, for reuse on the next mount of this category.
    func updateSortedReleases(
        _ sorted: [ReleaseData],
        for category: ReportsCategory,
        data: [ReleaseData],
        sortOrder: [KeyPathComparator<ReleaseData>]
    ) {
        sortedReleaseCaches[category] = SortedReleaseCache(
            data: data, sortOrder: sortOrder, sorted: sorted)
    }
    
    init() {
        // Load saved category if preference is enabled
        if Preferences.rememberReportsTab,
           let savedRawValue = Preferences.lastReportsCategory,
           let saved = ReportsCategory(rawValue: savedRawValue) {
            selectedCategory = saved
        }
        // The displayed content must match the restored selection at launch.
        displayedCategory = selectedCategory
    }
    
    /// - Parameter persist: Whether this is a deliberate tab CHOICE by the user, and so
    ///   should be remembered across sessions. See RecentsState.selectCategory for the
    ///   full rationale — navigation INTO Reports must not overwrite the remembered tab.
    /// - Parameter immediate: Swap the content in this turn rather than two run-loop turns
    ///   later. The title-bar pop-up passes true: it is an NSPopUpButton, which sends its
    ///   action only after the menu's fade has finished (see SubcategoryPicker), so the
    ///   deferral below would protect nothing and only split the switch across two update
    ///   passes. Menu-bar commands and shortcuts keep the deferral.
    func selectCategory(_ category: ReportsCategory, persist: Bool = true, immediate: Bool = false) {
        // Don't skip if it's the same category - we might need to reload
        selectedCategory = category

        // Save if preference is enabled
        if persist && Preferences.rememberReportsTab {
            Preferences.lastReportsCategory = category.rawValue
        }
        
        // Defer the actual content swap (displayedCategory) and the visible-item-count
        // update by two run loop cycles. The Picker Binding setter fires synchronously
        // inside the menu action handler; mutating the switcher's source of truth here
        // would rebuild the incoming tab's entire SwiftUI/AppKit tree (NSTableView,
        // NSScrollView, or the large DataVisualizations layout) — and toggle MainView's
        // gallery chrome for the DataViz case — in the same run loop cycle, and thus
        // the same CATransaction, in which CoreAnimation commits the NSPopUpButton
        // menu-dismissal fade. That competition truncates or stutters the fade.
        //
        // CoreAnimation commits at the end of the current run loop cycle; a single
        // async hop still runs before that commit. A double hop lands in the NEXT
        // cycle, after the fade has been committed to the render server, where it
        // animates out-of-process and is immune to main-thread load.
        // DispatchQueue.main.async is used rather than Task { @MainActor in } because
        // this deferral originates from an AppKit event callback (see
        // RecentsState.selectCategory for full rationale).
        //
        // selectedCategory is already updated synchronously above so the picker label,
        // glyph, and menu checkmarks reflect the new choice immediately.
        let swap: @MainActor () -> Void = {
            self.displayedCategory = category
            switch category {
            case .costTracker:
                self.visibleItemCount = self.costTrackerData.count
            case .priceTracker:
                self.visibleItemCount = self.priceTrackerData.count
            case .hallOfFame:
                self.visibleItemCount = self.hallOfFameData.count
            case .releaseWishlist:
                self.visibleItemCount = self.wishlistData.count
            case .dataVisualizations:
                self.visibleItemCount = 0
            }
        }
        if immediate {
            swap()
        } else {
            deferPastMenuDismissal(swap)
        }
    }
    
    // Update data for a specific category
    func updateData(_ data: [ReleaseData], for category: ReportsCategory) {
        switch category {
        case .costTracker:
            costTrackerData = data
            loadedCategories.insert(.costTracker)
        case .priceTracker:
            priceTrackerData = data
            loadedCategories.insert(.priceTracker)
        case .hallOfFame, .releaseWishlist, .dataVisualizations:
            break
        }
        
        // Update visible count if this is the currently displayed category
        if category == displayedCategory {
            visibleItemCount = data.count
        }
    }
    
    // Update hall of fame data
    //
    // `hallOfFameData` and `visibleItemCount` are observed properties, so every assignment
    // notifies observers whether or not the value changed. HallOfFameView reloads once per
    // shifted member during a drag-reorder, which previously reassigned the whole 200-element
    // cache on each of those redundant reloads. Both writes are now change-guarded.
    // (`loadedCategories` is @ObservationIgnored; it is read here only to decide whether this
    // is the first load for the category.)
    func updateHallOfFameData(_ data: [HallOfFameFilm]) {
        let wasLoaded = loadedCategories.contains(.hallOfFame)
        if !wasLoaded {
            loadedCategories.insert(.hallOfFame)
        }

        // The `!wasLoaded` term guarantees the first call always assigns, so an initially
        // empty Hall of Fame still populates the cache rather than being skipped as "equal".
        if !wasLoaded || hallOfFameData != data {
            hallOfFameData = data
        }
        
        // Update visible count if hall of fame is the currently displayed category
        if displayedCategory == .hallOfFame, visibleItemCount != data.count {
            visibleItemCount = data.count
        }
    }
    
    // Update wishlist data
    //
    // Change-guarded for exactly the reason updateHallOfFameData above is, and against a
    // heavier reload pattern: a wishlist drag-reorder emits one .film(.releaseChanged) per
    // film whose position moved, each delivered synchronously and each driving a full
    // reload. `wishlistData` and `visibleItemCount` are observed, so an unconditional
    // assignment notified observers on every one of those redundant reloads.
    // (`loadedCategories` is @ObservationIgnored; it is read here only to decide whether
    // this is the first load for the category.)
    func updateWishlistData(_ data: [WishlistRelease]) {
        let wasLoaded = loadedCategories.contains(.releaseWishlist)
        if !wasLoaded {
            loadedCategories.insert(.releaseWishlist)
        }

        // The `!wasLoaded` term guarantees the first call always assigns, so an initially
        // empty wishlist still populates the cache rather than being skipped as "equal".
        if !wasLoaded || wishlistData != data {
            wishlistData = data
        }

        if displayedCategory == .releaseWishlist, visibleItemCount != data.count {
            visibleItemCount = data.count
        }
    }
    
    /// Tickets order the Data Visualizations passes by when each read the library, so a
    /// slower pass that read it earlier cannot overwrite what a later one already stored:
    /// passes run concurrently off the main actor and can finish in either order. Issued
    /// on the main actor at the moment a pass copies the films.
    @ObservationIgnored private var lastVisualizationsTicket = 0
    @ObservationIgnored private var storedVisualizationsTicket = 0

    func nextVisualizationsTicket() -> Int {
        lastVisualizationsTicket += 1
        return lastVisualizationsTicket
    }

    /// Updates the Data Visualizations tab's mount cache, unless it already holds a pass
    /// that read the library later than this one did.
    func updateVisualizationsData(_ dataset: DVDataset, ticket: Int) {
        guard ticket > storedVisualizationsTicket else { return }
        storedVisualizationsTicket = ticket
        visualizations = dataset
    }

    /// Fills the Data Visualizations tab's mount cache in the background, so the tab's
    /// first visit of a launch mounts from it rather than computing every figure on the
    /// main thread before its first frame (≈100 ms optimized, ≈330 ms in a Debug build,
    /// on a 1,400-film library). Called once, after launch has settled. A visit that
    /// arrives first computes as before and the result here is dropped; one that arrives
    /// after reconciles the cache against the library in the background, as every mount
    /// from the cache does.
    func prefetchVisualizations(films: [FilmSnapshot]) {
        guard visualizations == nil else { return }
        let ticket = nextVisualizationsTicket()
        let showInfoComplete = Preferences.showInfoComplete
        Task(priority: .utility) {
            guard let dataset = await DVDataset.compute(films: films, previous: nil,
                                                        showInfoComplete: showInfoComplete) else { return }
            updateVisualizationsData(dataset, ticket: ticket)
        }
    }

    #if DEBUG
    /// Empties the Data Visualizations mount cache, so the harness can exercise the
    /// launch prefetch in a process whose cache earlier scenarios have already filled.
    func debugResetVisualizations() { visualizations = nil }
    #endif
    
    // Update sort order for a specific category
    func updateSortOrder(_ sortOrder: [KeyPathComparator<ReleaseData>], for category: ReportsCategory) {
        switch category {
        case .costTracker:
            costTrackerSortOrder = sortOrder
        case .priceTracker:
            priceTrackerSortOrder = sortOrder
        case .hallOfFame, .releaseWishlist, .dataVisualizations:
            break
        }
    }
}

// MARK: - Reports Export Data
/// The payload one report tab contributes to the whole-library PDF.
///
/// Two tabs contribute today — see `LibraryPDFSection`. The `releases` and
/// `wishlistReleases` fields this once carried went with the three tracker sheets that
/// `discReleases` superseded; `ReleaseData` and `WishlistRelease` themselves are untouched,
/// because the tabs still build their on-screen tables from them.
struct ReportsExportData {
    let category: ReportsCategory
    let hallOfFameFilms: [HallOfFameFilm]?
    /// Everything the Data Visualizations tab draws, for the rendered half of its sheet.
    var visualizations: DVDataset? = nil
}

// MARK: - Reports Category
enum ReportsCategory: String, CaseIterable, Codable, Sendable {
    case costTracker
    case priceTracker
    case hallOfFame
    case releaseWishlist
    case dataVisualizations
    
    var displayName: String {
        switch self {
        case .costTracker: return "Purchase and Expense Tracker"
        case .priceTracker: return "Price Tracker"
        case .hallOfFame: return "Hall of Fame"
        case .releaseWishlist: return "Release Wishlist"
        case .dataVisualizations: return "Visualizations and Insights"
        }
    }
    
    var glyph: String {
        switch self {
        case .costTracker: return "chart.pie.fill"
        case .priceTracker: return "cart.fill"
        case .hallOfFame: return "trophy.fill"
        case .releaseWishlist: return "gift.fill"
        case .dataVisualizations: return "chart.bar.fill"
        }
    }
}
