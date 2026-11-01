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
        // Switching Reports tabs swaps the whole content view, but SelectionState is one shared instance that persists across the swap.
        // Without this clear, a selection would survive into a tab where nothing is highlighted, and reappear later. This matches the clear on full
        // view switches (see MainView's handleViewChange). It fires on selectedCategory, not the deferred displayedCategory, so it clears on request from any source.
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
                    .frame(width: GalleryTitleBar.pickerWidth)
                    .padding(.leading, GalleryTitleBar.pickerLeading)
            },
            trailingButtons: {
                HStack(spacing: 8) {
                    Button {
                        // The Settings sheet's Export tab holds every export option, so this button is a shortcut to it. It sends the same command as ⇧⌘E.
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
/// Only the active tab's view is in the hierarchy at a time. Keeping every tab alive (a ZStack) slowed everything down. Each visited tab kept a
/// live film-event subscriber, an AppKit subtree, and a large SwiftUI layout, all of which took part in every layout pass.
///
/// This reads `displayedCategory`, not `selectedCategory`. The Picker label updates at once. The content swap waits in
/// ReportsState.selectCategory, so it runs after the Picker's menu-dismissal fade has been committed. The fade then runs out of process.
///
/// The `.transaction` below removes any inherited animation from the incoming tab's first render.
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
        // Strips inherited animation so the incoming tab renders at once. It sits here, not on ReportsView, so it does not suppress animations in the title bar or export button.
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

// MARK: - Reports State
@MainActor
@Observable
final class ReportsState {
    static let shared = ReportsState()
    
    var selectedCategory: ReportsCategory = .costTracker
    /// The category mounted in ReportsContentSwitcher. It trails `selectedCategory` by two run-loop cycles on user-driven switches,
    /// so the heavy swap does not compete with the Picker's fade (see selectCategory). Labels read `selectedCategory` and stay instant.
    private(set) var displayedCategory: ReportsCategory = .costTracker
    var visibleItemCount: Int = 0
    
    // Export data storage per category
    private var costTrackerData: [ReleaseData] = []
    private var priceTrackerData: [ReleaseData] = []
    private var hallOfFameData: [HallOfFameFilm] = []
    private var wishlistData: [WishlistRelease] = []
    /// The Data Visualizations tab's last full recalculation, used as its mount cache. The PDF export does not read it. It is
    /// `@ObservationIgnored` because no view body reads it (the tab seeds from it in `onAppear`), and each background pass rewrites it.
    @ObservationIgnored private var visualizations: DVDataset?
    /// The Data Visualizations tab's last viewing-period figures, with the key they were computed from. Rebuilding them walks every parsed
    /// viewing. The tab rebuilt them on every mount, even when the stepper was unchanged, so this cache serves them.
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
    // The data stores above persist across tab switches. On mount, a tab seeds its state from these caches and renders at once, with no scan, sort, or placeholder.
    // It then reloads two run-loop cycles later, after the Picker's fade. The AppKit table or list is still rebuilt on each switch.

    /// Categories whose stores were populated this launch. "Never loaded" must scan at mount, to avoid a placeholder flash. "Loaded and empty"
    /// can show the placeholder, and the deferred reconcile confirms it.
    @ObservationIgnored private var loadedCategories: Set<ReportsCategory> = []

    /// Memoized sort results for the tracker tabs, keyed by the inputs they came from. Seeding reuses the cached array, so the `data` equality
    /// check short-circuits on buffer identity and the lookup is O(1).
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
    
    /// - Parameter persist: True for a deliberate tab choice, which is remembered across sessions. Navigation into Reports must not overwrite it.
    ///   See RecentsState.selectCategory.
    /// - Parameter immediate: Swap the content now, rather than two run-loop turns later. The title-bar pop-up passes true. Its NSPopUpButton
    ///   sends the action only after the menu fade (see SubcategoryPicker), so deferring would gain nothing. Menu commands and shortcuts defer.
    func selectCategory(_ category: ReportsCategory, persist: Bool = true, immediate: Bool = false) {
        // Don't skip if it's the same category - we might need to reload
        selectedCategory = category

        // Save if preference is enabled
        if persist && Preferences.rememberReportsTab {
            Preferences.lastReportsCategory = category.rawValue
        }
        
        // The content swap (displayedCategory) and the item count are deferred two run-loop cycles. The Picker's binding setter runs inside the
        // menu action, so an immediate swap would build the new tab in the same transaction that commits the menu fade, which stutters the fade.
        // A single async hop still lands before that commit. A second hop lands after it, so the fade runs out of process. DispatchQueue.main.async
        // is used rather than Task because this originates from an AppKit event (see RecentsState.selectCategory).
        //
        // selectedCategory is already set above, so the picker label, glyph, and checkmarks update at once.
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
    // Both properties are observed, so every assignment notifies, even when the value is unchanged. HallOfFameView reloads once per shifted
    // member during a drag-reorder, so both writes are change-guarded. (`loadedCategories` is @ObservationIgnored and read only for the first-load check.)
    func updateHallOfFameData(_ data: [HallOfFameFilm]) {
        let wasLoaded = loadedCategories.contains(.hallOfFame)
        if !wasLoaded {
            loadedCategories.insert(.hallOfFame)
        }

        // The `!wasLoaded` term makes the first call always assign, so an empty first load still fills the cache.
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
    // Change-guarded for the same reason as updateHallOfFameData. A wishlist drag-reorder sends one .film(.releaseChanged) per moved film,
    // each triggering a full reload. (`loadedCategories` is @ObservationIgnored and read only for the first-load check.)
    func updateWishlistData(_ data: [WishlistRelease]) {
        let wasLoaded = loadedCategories.contains(.releaseWishlist)
        if !wasLoaded {
            loadedCategories.insert(.releaseWishlist)
        }

        // The `!wasLoaded` term makes the first call always assign, so an empty first load still fills the cache.
        if !wasLoaded || wishlistData != data {
            wishlistData = data
        }

        if displayedCategory == .releaseWishlist, visibleItemCount != data.count {
            visibleItemCount = data.count
        }
    }
    
    /// Tickets order the Data Visualizations passes by when each read the library. A slower pass that read earlier cannot overwrite a later
    /// result, since passes run off the main actor and can finish in any order. A ticket is issued on the main actor as a pass copies the films.
    @ObservationIgnored private var lastVisualizationsTicket = 0
    @ObservationIgnored private var storedVisualizationsTicket = 0

    func nextVisualizationsTicket() -> Int {
        lastVisualizationsTicket += 1
        return lastVisualizationsTicket
    }

    /// Updates the Data Visualizations mount cache, unless it already holds a pass that read the library later.
    func updateVisualizationsData(_ dataset: DVDataset, ticket: Int) {
        guard ticket > storedVisualizationsTicket else { return }
        storedVisualizationsTicket = ticket
        visualizations = dataset
    }

    /// Fills the Data Visualizations mount cache in the background, so the first visit mounts from it instead of computing on the main thread.
    /// Called once, after launch settles. If a visit comes first, it computes as usual and this result is dropped. If a visit comes later, it reconciles
    /// the cache in the background, as every cached mount does.
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
/// Two tabs contribute today (see `LibraryPDFSection`). `ReleaseData` and `WishlistRelease` are unchanged, because the tabs still build
/// their on-screen tables from them.
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
