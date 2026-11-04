// MARK: - ReportTrackers.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// The Purchase and Expense Tracker and Price Tracker report views. Each lists releases from the library, with the rows
/// built by ReleaseData's shared helpers, which the PDF export also uses.

import SwiftUI

// MARK: - Cost Tracker View

struct CostTrackerView: View {
    @Environment(DataCoordinator.self) private var dataCoordinator
    @State private var releases: [ReleaseData] = []
    /// Bumped by every load. The mount path's off-main reconcile applies its rows only if nothing has loaded since it started.
    @State private var loadGeneration = 0
    
    var body: some View {
        ReportsReleaseTableView(
            category: .costTracker,
            releases: releases,
            emptyStateConfig: EmptyStateConfig(
                glyph: "chart.pie.fill",
                noFilmsMessage: "Add films to your library to track costs.",
                noDataMessage: "Add purchased releases with cost information to track spending."
            ),
            columns: [
                ReportTableColumn(id: "title", title: "Title", width: 180, minWidth: 140,
                                  maxWidth: .greatestFiniteMagnitude, sortKey: "filmTitle",
                                  content: .text { $0.filmTitle }),
                ReportTableColumn(id: "cost", title: "Cost", width: 70, minWidth: 60, maxWidth: 100,
                                  alignment: .right, content: .text { $0.costFormatted }),
                ReportTableColumn(id: "spent", title: "Spent", width: 70, minWidth: 60, maxWidth: 100,
                                  alignment: .right, content: .text { $0.amountSpentFormatted }),
                ReportTableColumn(id: "purchaseDate", title: "Date of Purchase", width: 140, minWidth: 120,
                                  maxWidth: 180, alignment: .right, sortKey: "purchaseDate",
                                  content: .text { $0.purchaseDateFormatted }),
                ReportTableColumn(id: "studio", title: "Studio", width: 120, minWidth: 80, maxWidth: 160,
                                  sortKey: "studio", content: .text { $0.studio }),
                ReportTableColumn(id: "condition", title: "Condition", width: 70, minWidth: 60, maxWidth: 120,
                                  alignment: .center, sortKey: "condition", content: .text { $0.condition }),
                ReportTableColumn(id: "notes", title: "Notes", width: 200, minWidth: 140,
                                  maxWidth: .greatestFiniteMagnitude, sortKey: "notes",
                                  content: .text { $0.notes })
            ],
            defaultSortOrder: ReleaseData.costTrackerDefaultSort,
            onLoad: { seedThenReloadPurchasedReleases() },
            onDataChange: { loadPurchasedReleases() }
        )
    }

    /// Mount path. If the category loaded earlier this launch, the cached rows show at once with no library work. The fresh scan
    /// then runs two run-loop cycles later, after the Picker's fade (see ReportsState.selectCategory). On the first visit the scan runs
    /// synchronously, to avoid a visible "No Data" flash.
    private func seedThenReloadPurchasedReleases() {
        if ReportsState.shared.hasLoadedData(for: .costTracker) {
            releases = ReportsState.shared.cachedReleases(for: .costTracker)
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    reconcilePurchasedReleases()
                }
            }
        } else {
            loadPurchasedReleases()
        }
    }

    /// The mount path's reconciling load. The row build and sort run off the main actor (see ReleaseData.reconciledRows).
    /// Event-driven reloads stay synchronous.
    private func reconcilePurchasedReleases() {
        loadGeneration += 1
        let generation = loadGeneration
        let filmsMap = dataCoordinator.getAllFilmsMap()
        Task {
            let loaded = await ReleaseData.reconciledRows(
                for: .costTracker, filmsMap: filmsMap, defaultSortOrder: ReleaseData.costTrackerDefaultSort,
                build: ReleaseData.costTrackerRows)
            guard generation == loadGeneration else { return }
            /// Rows from a library that has since changed would be stale, and the change may not have triggered a reload.
            /// Fall back to the synchronous load, which reads the current library.
            guard dataCoordinator.getAllFilmsMap() == filmsMap else {
                loadPurchasedReleases()
                return
            }
            loaded.primeSortCache()
            applyPurchasedReleases(loaded.rows)
        }
    }

    private func loadPurchasedReleases() {
        loadGeneration += 1
        /// The row set comes from ReleaseData.costTrackerRows, which the PDF export also uses. The predicate and field mapping live in one place,
        /// so the table and the printed sheet cannot disagree.
        applyPurchasedReleases(ReleaseData.costTrackerRows(films: dataCoordinator.getAllFilms()))
    }

    private func applyPurchasedReleases(_ loadedReleases: [ReleaseData]) {
        releases = loadedReleases
        /// Push the result to ReportsState directly. The onChange(of: releases) handler does not fire when the result equals the current value,
        /// such as [] on a first load with no qualifying data. Without this call, the category would stay unmarked as loaded and the scan
        /// would run in the mount frame on every visit. updateData is idempotent, so a duplicate call from onChange is harmless.
        ReportsState.shared.updateData(loadedReleases, for: .costTracker)
    }
}

// MARK: - Price Tracker View

struct PriceTrackerView: View {
    @Environment(DataCoordinator.self) private var dataCoordinator
    @State private var releases: [ReleaseData] = []
    /// See CostTrackerView.loadGeneration.
    @State private var loadGeneration = 0
    
    var body: some View {
        ReportsReleaseTableView(
            category: .priceTracker,
            releases: releases,
            emptyStateConfig: EmptyStateConfig(
                glyph: "cart.fill",
                noFilmsMessage: "Add films to your library to track prices.",
                noDataMessage: "Add unpurchased releases with lowest price information to track deals."
            ),
            columns: [
                ReportTableColumn(id: "title", title: "Title", width: 180, minWidth: 140,
                                  maxWidth: .greatestFiniteMagnitude, sortKey: "filmTitle",
                                  content: .text { $0.filmTitle }),
                ReportTableColumn(id: "lowestPrice", title: "Lowest Price", width: 100, minWidth: 80,
                                  maxWidth: 120, alignment: .right, content: .text { $0.lowestPriceFormatted }),
                ReportTableColumn(id: "lowestPriceDate", title: "Date of Lowest Price", width: 140,
                                  minWidth: 120, maxWidth: 180, alignment: .right, sortKey: "lowestPriceDate",
                                  content: .text { $0.lowestPriceDateFormatted }),
                ReportTableColumn(id: "studio", title: "Studio", width: 120, minWidth: 80, maxWidth: 160,
                                  sortKey: "studio", content: .text { $0.studio }),
                ReportTableColumn(id: "notes", title: "Notes", width: 200, minWidth: 140,
                                  maxWidth: .greatestFiniteMagnitude, sortKey: "notes",
                                  content: .text { $0.notes })
            ],
            defaultSortOrder: ReleaseData.priceTrackerDefaultSort,
            onLoad: { seedThenReloadPriceTrackerData() },
            onDataChange: { loadPriceTrackerData() }
        )
    }

    /// Mount path: cache-seeded, with a deferred reconciling scan. See CostTrackerView.seedThenReloadPurchasedReleases.
    private func seedThenReloadPriceTrackerData() {
        if ReportsState.shared.hasLoadedData(for: .priceTracker) {
            releases = ReportsState.shared.cachedReleases(for: .priceTracker)
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    reconcilePriceTrackerData()
                }
            }
        } else {
            loadPriceTrackerData()
        }
    }

    /// See CostTrackerView.reconcilePurchasedReleases.
    private func reconcilePriceTrackerData() {
        loadGeneration += 1
        let generation = loadGeneration
        let filmsMap = dataCoordinator.getAllFilmsMap()
        Task {
            let loaded = await ReleaseData.reconciledRows(
                for: .priceTracker, filmsMap: filmsMap, defaultSortOrder: ReleaseData.priceTrackerDefaultSort,
                build: ReleaseData.priceTrackerRows)
            guard generation == loadGeneration else { return }
            /// See CostTrackerView.reconcilePurchasedReleases.
            guard dataCoordinator.getAllFilmsMap() == filmsMap else {
                loadPriceTrackerData()
                return
            }
            loaded.primeSortCache()
            applyPriceTrackerData(loaded.rows)
        }
    }

    private func loadPriceTrackerData() {
        loadGeneration += 1
        /// Shared with the PDF export. See CostTrackerView.loadPurchasedReleases.
        applyPriceTrackerData(ReleaseData.priceTrackerRows(films: dataCoordinator.getAllFilms()))
    }

    private func applyPriceTrackerData(_ loadedReleases: [ReleaseData]) {
        releases = loadedReleases
        /// See CostTrackerView.loadPurchasedReleases for why this direct push is needed.
        ReportsState.shared.updateData(loadedReleases, for: .priceTracker)
    }
}

// MARK: - Reports Release Table View

struct ReportsReleaseTableView: View, Loggable {
    nonisolated static var logTag: String { "[ReportsView]" }

    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SelectionState.self) private var selectionState

    let category: ReportsCategory
    let releases: [ReleaseData]
    let emptyStateConfig: EmptyStateConfig
    let columns: [ReportTableColumn<ReleaseData>]
    let defaultSortOrder: [KeyPathComparator<ReleaseData>]
    let onLoad: () -> Void
    let onDataChange: () -> Void
    
    @State private var selection: Set<UUID> = []
    @State private var sortOrder: [KeyPathComparator<ReleaseData>]

    /// Memoized sort result, recomputed only when `releases` or `sortOrder` changes, via the onChange handlers below.
    /// A computed property would re-sort on every body pass, such as selection changes, and each sort would reload the table.
    @State private var sortedReleases: [ReleaseData] = []

    /// No row windowing. ReportTable builds only the rows on screen, so the full sorted set costs about what the first screen does.

    init(
        category: ReportsCategory,
        releases: [ReleaseData],
        emptyStateConfig: EmptyStateConfig,
        columns: [ReportTableColumn<ReleaseData>],
        defaultSortOrder: [KeyPathComparator<ReleaseData>],
        onLoad: @escaping () -> Void,
        onDataChange: @escaping () -> Void
    ) {
        self.category = category
        self.releases = releases
        self.emptyStateConfig = emptyStateConfig
        self.columns = columns
        self.defaultSortOrder = defaultSortOrder
        self.onLoad = onLoad
        self.onDataChange = onDataChange
        self._sortOrder = State(initialValue: defaultSortOrder)
    }
    
    var body: some View {
        ReportsEmptyStateWrapper(
            totalFilmCount: dataCoordinator.totalFilmCount,
            isEmpty: releases.isEmpty,
            config: emptyStateConfig
        ) {
            ReportTable(rows: sortedReleases, columns: columns, selection: $selection,
                        rowHeight: 24,
                        sort: ReleaseData.headerSort(for: sortOrder),
                        onSort: { sortOrder = ReleaseData.comparators(forHeaderSort: $0) })
                .frame(maxHeight: .infinity)
            .onChange(of: selection) { _, newSelection in
                handleSelectionChange(newSelection)
            }
            .onChange(of: sortOrder) { _, newSortOrder in
                /// Update ReportsState with current sort order for this category.
                ReportsState.shared.updateSortOrder(newSortOrder, for: category)
                /// Recompute the memoized sort when the sort order changes.
                recomputeSort(releases, using: newSortOrder)
            }
        }
        .reportsStatusBarInset()
        .onAppear {
            /// Restore the sort order from the last visit, so the column sort survives tab switches. The mount-path cache was sorted under
            /// that order, so a default order here would force a full re-sort in the mount frame.
            if let saved = ReportsState.shared.savedSortOrder(for: category) {
                sortOrder = saved
            }
            onLoad()
            ReportsState.shared.updateSortOrder(sortOrder, for: category)
        }
        .onChange(of: releases) { _, newReleases in
            /// Recompute the memoized sort when the data changes.
            recomputeSort(newReleases, using: sortOrder)
            /// Update ReportsState with current data for export.
            ReportsState.shared.updateData(newReleases, for: category)
            /// Drop any selected release that is no longer in the loaded rows.
            reconcileSelection(against: newReleases)
        }
        /// Clears the table selection when SelectionState is cleared elsewhere, such as on a view switch.
        .onChange(of: selectionState.selectedFilmIDs) { _, newSelectedFilmIDs in
            /// If SelectionState was cleared, clear the local table selection
            if newSelectedFilmIDs.isEmpty && !selection.isEmpty {
                selection = []
            }
        }
        /// Refresh on film events, such as releases added, removed, or edited in FilmSheet. Each case reloads when the event could affect this table.
        /// Selection cleanup is in `reconcileSelection(against:)`, called from `.onChange(of: releases)` with the fresh rows. It runs a run-loop pass
        /// later, so NSTableView does not re-sync a stale selection back into the binding.
        .onFilmEvent { event in
            switch event {
            case .updated(let filmID):
                /// Only matters if the film is shown, such as a title change. Release changes arrive as `.releaseChanged`.
                guard releases.contains(where: { $0.filmID == filmID }) else { break }
                onDataChange()

            case .deleted(let filmIDs):
                /// Reload only if a deleted film had releases in this table.
                guard releases.contains(where: { filmIDs.contains($0.filmID) }) else { break }
                onDataChange()

            case .releaseChanged:
                /// Always reload. A release change can add a film (marking it purchased or adding price data) or remove one.
                onDataChange()

            case .added:
                /// A new film may have qualifying release data.
                onDataChange()
            }
        }
    }

    // MARK: - Selection Reconciliation

    /// Drops selected release IDs that are no longer in `newReleases`. The change flows through `handleSelectionChange` to keep
    /// `SelectionState` in sync. The prune waits one run-loop pass, so the table has reloaded first and cannot re-sync a stale selection.
    private func reconcileSelection(against newReleases: [ReleaseData]) {
        guard !selection.isEmpty else { return }
        let validIDs = Set(newReleases.map(\.releaseID))
        guard !selection.isSubset(of: validIDs) else { return }
        DispatchQueue.main.async {
            selection = selection.intersection(validIDs)
        }
    }
    
    // MARK: - Custom Sort

    /// Recomputes `sortedReleases` for the inputs, checking the ReportsState cache first. On mount, the data is the cached instance, so the equality
    /// check is O(1). The full sort runs only when the data or order changes.
    private func recomputeSort(
        _ items: [ReleaseData],
        using order: [KeyPathComparator<ReleaseData>]
    ) {
        if let cached = ReportsState.shared.cachedSortedReleases(
            for: category, data: items, sortOrder: order) {
            sortedReleases = cached
            return
        }
        let sorted = ReleaseData.sorted(items, using: order)
        sortedReleases = sorted
        ReportsState.shared.updateSortedReleases(
            sorted, for: category, data: items, sortOrder: order)
    }

    private func handleSelectionChange(_ newSelection: Set<UUID>) {
        /// Handle no selection (cleared)
        if newSelection.isEmpty {
            selectionState.clearImmediate()
            return
        }
        
        /// Handle multi-selection
        if newSelection.count > 1 {
            let filmIDs = newSelection.compactMap { releaseID in
                releases.first(where: { $0.releaseID == releaseID })?.filmID
            }
            selectionState.select(Set(filmIDs))
            return
        }
        
        /// Single selection. The empty and multi cases have returned, so `first` is non-nil. Matches HallOfFameView.handleSelectionChange.
        guard let selectedReleaseID = newSelection.first else { return }

        /// Look up the release data to get the film ID
        if let releaseData = releases.first(where: { $0.releaseID == selectedReleaseID }) {
            selectionState.select(releaseData.filmID)
        } else {
            /// Not found in the array, which is an error. Log it and clear the selection to prevent stale state.
            log("ERROR: Selected release \(selectedReleaseID) not found in releases array")
            selectionState.clearImmediate()
        }
    }
}

// MARK: - Release Data

struct ReleaseData: Identifiable, Equatable {
    let releaseID: UUID
    let filmID: UUID
    let filmTitle: String
    /// The film's sort name (`FilmSnapshot.sortName`). Empty when there is no override, so `filmTitle` is the sort key.
    let filmSortName: String
    let cost: Double
    let amountSpent: Double
    let lowestPrice: Double
    let purchaseDate: String
    let lowestPriceDate: String
    let studio: String
    let condition: String
    let notes: String
    
    var id: UUID { releaseID }
    
    init(
        releaseID: UUID,
        filmID: UUID,
        filmTitle: String,
        filmSortName: String,
        filmYear: String = "",
        cost: Double,
        amountSpent: Double,
        lowestPrice: Double,
        purchaseDate: String,
        lowestPriceDate: String,
        studio: String,
        condition: String,
        notes: String
    ) {
        self.releaseID = releaseID
        self.filmID = filmID
        self.filmTitle = filmTitle
        self.filmSortName = filmSortName
        self.cost = cost
        self.amountSpent = amountSpent
        self.lowestPrice = lowestPrice
        self.purchaseDate = purchaseDate
        self.lowestPriceDate = lowestPriceDate
        self.studio = studio
        self.condition = condition
        self.notes = notes
        /// Precomputed once per row, since stripArticles allocates and a sort compares each row many times.
        self.titleSort = GalleryTitleKey(name: filmTitle, sortName: filmSortName,
                                         year: Int(filmYear) ?? 0, filmID: filmID)
    }

    /// The row's place in the gallery's Title sort. It orders the Title column and breaks ties in the other columns.
    let titleSort: GalleryTitleKey

    /// Cost Tracker formatters
    var costFormatted: String {
        guard cost > 0 else { return "—" }
        return Fmt.dollars(cost)
    }
    
    var amountSpentFormatted: String {
        /// Intentionally left as displaying '$0.00' for empty fields.
        return Fmt.dollars(amountSpent)
    }
    
    var purchaseDateFormatted: String {
        formatDate(purchaseDate)
    }
    
    /// Price Tracker formatters
    var lowestPriceFormatted: String {
        guard lowestPrice > 0 else { return "—" }
        return Fmt.dollars(lowestPrice)
    }
    
    var lowestPriceDateFormatted: String {
        formatDate(lowestPriceDate)
    }
    
    /// "May 1, 2024" for a stored date, or the stored text if it does not parse. Dates are stored as `yyyy.MM.dd`, which the app's
    /// shared parser reads.
    private func formatDate(_ dateString: String) -> String {
        guard !dateString.isEmpty else { return "—" }
        guard let date = parseDate(from: dateString) else { return dateString }
        return Film_Tracker.formatDate(date)
    }
}

// MARK: - Release Data Row Building

/// The two tracker tabs' row sets and orderings. The table and the PDF export share these, so they cannot drift apart.
extension ReleaseData {
    /// The Purchase and Expense Tracker's rows: purchased top-level releases with cost or spend data. Unsorted, since the table applies the column order.
    static func costTrackerRows(films: [FilmSnapshot]) -> [ReleaseData] {
        var rows: [ReleaseData] = []
        for film in films {
            for release in film.releases where release.purchased && release.isTopLevel {
                /// Only include releases with cost or amount spent data.
                guard release.cost > 0 || release.amountSpent > 0 else { continue }

                rows.append(ReleaseData(
                    releaseID: release.id,
                    filmID: film.id,
                    filmTitle: film.name,
                    filmSortName: film.sortName,
                    filmYear: film.releaseYear,
                    cost: release.cost,
                    amountSpent: release.amountSpent,
                    lowestPrice: 0,
                    purchaseDate: release.purchaseDate,
                    lowestPriceDate: "",
                    studio: release.studio,
                    condition: release.condition,
                    notes: release.notes
                ))
            }
        }
        return rows
    }

    /// The Price Tracker's rows: unpurchased top-level releases with a lowest-price observation. Unsorted, like `costTrackerRows`.
    static func priceTrackerRows(films: [FilmSnapshot]) -> [ReleaseData] {
        var rows: [ReleaseData] = []
        for film in films {
            for release in film.releases where !release.purchased && release.isTopLevel {
                /// Only include releases with lowest price data.
                guard release.lowestPrice > 0 else { continue }

                rows.append(ReleaseData(
                    releaseID: release.id,
                    filmID: film.id,
                    filmTitle: film.name,
                    filmSortName: film.sortName,
                    filmYear: film.releaseYear,
                    cost: 0,
                    amountSpent: 0,
                    lowestPrice: release.lowestPrice,
                    purchaseDate: "",
                    lowestPriceDate: release.lowestPriceDate,
                    studio: release.studio,
                    condition: "",
                    notes: release.notes
                ))
            }
        }
        return rows
    }

    /// A tracker tab's rows, built and sorted off the main actor for the mount path's reconciling load.
    struct Reconciled {
        let category: ReportsCategory
        let rows: [ReleaseData]
        let sorted: [ReleaseData]
        let sortOrder: [KeyPathComparator<ReleaseData>]

        /// Records the sort in ReportsState's cache, so the table finds it there. Called only when the rows apply, so a dropped result cannot replace a newer entry.
        @MainActor
        func primeSortCache() {
            ReportsState.shared.updateSortedReleases(sorted, for: category, data: rows, sortOrder: sortOrder)
        }
    }

    /// The sort uses the order the table will use: the saved order, else the default, as ReportsReleaseTableView.onAppear picks. If the order
    /// changes before the rows land, the cache misses and the table sorts as usual.
    @MainActor
    static func reconciledRows(
        for category: ReportsCategory,
        filmsMap: [UUID: FilmSnapshot],
        defaultSortOrder: [KeyPathComparator<ReleaseData>],
        build: @escaping @Sendable ([FilmSnapshot]) -> [ReleaseData]
    ) async -> Reconciled {
        let order = ReportsState.shared.savedSortOrder(for: category) ?? defaultSortOrder
        let (rows, sorted) = await Task.detached(priority: .userInitiated) {
            /// Array(values) matches what getAllFilms() returns for this dictionary.
            let rows = build(Array(filmsMap.values))
            return (rows, ReleaseData.sorted(rows, using: order))
        }.value
        return Reconciled(category: category, rows: rows, sorted: sorted, sortOrder: order)
    }

    /// The Purchase and Expense Tracker's opening order: newest purchase first.
    static let costTrackerDefaultSort: [KeyPathComparator<ReleaseData>] =
        [comparator(forKey: "purchaseDate", order: .reverse)!]

    /// The sortable columns' keys, as `ReportTableColumn.sortKey` names them.
    private static let sortKeys = ["filmTitle", "purchaseDate", "lowestPriceDate", "studio", "condition", "notes"]

    /// The comparator for a header key. Title sorts by `titleSort`, the gallery's order. The rest sort by their strings under English
    /// rules, since a String key path's default comparator follows the system language.
    private static func comparator(forKey key: String, order: SortOrder) -> KeyPathComparator<ReleaseData>? {
        switch key {
        /// The gallery's Title order (sort name, articles stripped, numbers last), not the raw title.
        case "filmTitle":       return KeyPathComparator(\.titleSort, order: order)
        case "purchaseDate":    return KeyPathComparator(\.purchaseDate, comparator: EnglishText.standardComparator, order: order)
        case "lowestPriceDate": return KeyPathComparator(\.lowestPriceDate, comparator: EnglishText.standardComparator, order: order)
        case "studio":          return KeyPathComparator(\.studio, comparator: EnglishText.standardComparator, order: order)
        case "condition":       return KeyPathComparator(\.condition, comparator: EnglishText.standardComparator, order: order)
        case "notes":           return KeyPathComparator(\.notes, comparator: EnglishText.standardComparator, order: order)
        default:                return nil
        }
    }

    /// A sort order as the table header shows it; comparators on unknown properties drop out.
    static func headerSort(for order: [KeyPathComparator<ReleaseData>]) -> [(key: String, ascending: Bool)] {
        order.compactMap { comparator in
            sortKeys.first { comparator.keyPath == Self.comparator(forKey: $0, order: .forward)?.keyPath }
                .map { ($0, comparator.order == .forward) }
        }
    }

    /// The comparators for a header sort the user just chose.
    static func comparators(forHeaderSort sort: [(key: String, ascending: Bool)]) -> [KeyPathComparator<ReleaseData>] {
        sort.compactMap { comparator(forKey: $0.key, order: $0.ascending ? .forward : .reverse) }
    }

    /// The Price Tracker's opening order: most recent price observation first.
    static let priceTrackerDefaultSort: [KeyPathComparator<ReleaseData>] =
        [comparator(forKey: "lowestPriceDate", order: .reverse)!]

    /// Sorts `items` by the column order. If every comparator ties, a title tiebreaker applies, using the gallery's title order.
    /// The tiebreak makes the result a total order, so it is reproducible. Without it, equal keys would keep the input order, which comes from an unordered Dictionary.
    static func sorted(
        _ items: [ReleaseData],
        using order: [KeyPathComparator<ReleaseData>]
    ) -> [ReleaseData] {
        /// No active sort: keep the input order. Unreachable in practice, since both tabs open with a non-empty default.
        guard !order.isEmpty else { return items }

        return items.sorted { lhs, rhs in
            /// Apply each comparator in priority order; the first non-equal result wins.
            for comparator in order {
                switch comparator.compare(lhs, rhs) {
                case .orderedAscending:  return true
                case .orderedDescending: return false
                case .orderedSame:       continue
                }
            }
            /// All comparators tied. Use the gallery's title order (which ends on the film id), then the release id. Two copies of one film tie
            /// on everything else, and the input order changes each launch, so without the release id their rows could swap.
            if lhs.titleSort != rhs.titleSort { return lhs.titleSort < rhs.titleSort }
            return lhs.releaseID.uuidString < rhs.releaseID.uuidString
        }
    }
}
