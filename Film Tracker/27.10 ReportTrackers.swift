// MARK: - ReportTrackers.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Contains "Purchase and Expense Tracker" and "Price Tracker" report views.

import SwiftUI

// MARK: - Cost Tracker View

struct CostTrackerView: View {
    @Environment(DataCoordinator.self) private var dataCoordinator
    @State private var releases: [ReleaseData] = []
    /// Bumped by every load. The mount path's off-main reconcile applies its rows only if
    /// nothing has loaded since it started, so it can never overwrite newer data.
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

    /// Mount path. When the category has been loaded before this launch, the cached
    /// rows are assigned immediately — rendering the table with zero library work in
    /// the mount frame — and the fresh scan is deferred two run-loop cycles so it
    /// lands after the Picker menu-dismissal fade has been committed (see
    /// ReportsState.selectCategory for the deferral rationale). On the first-ever
    /// visit the scan runs synchronously, exactly as before, to avoid a visible
    /// "No Data" placeholder flash.
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

    /// The mount path's reconciling load, with the row build and the sort off the main
    /// actor (see ReleaseData.reconciledRows). Event-driven reloads stay synchronous.
    private func reconcilePurchasedReleases() {
        loadGeneration += 1
        let generation = loadGeneration
        let filmsMap = dataCoordinator.getAllFilmsMap()
        Task {
            let loaded = await ReleaseData.reconciledRows(
                for: .costTracker, filmsMap: filmsMap, defaultSortOrder: ReleaseData.costTrackerDefaultSort,
                build: ReleaseData.costTrackerRows)
            guard generation == loadGeneration else { return }
            // Rows built from a library that has since changed would be stale, and the change
            // may not have triggered a reload (a film absent from the seeded rows is not
            // reloaded for). Fall back to the synchronous load, which reads it as it is now.
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
        // The row set comes from ReleaseData.costTrackerRows, which the whole-library PDF
        // export calls as well. The predicate and the field mapping live in exactly one
        // place, so the table and the printed sheet cannot come to disagree about which
        // releases qualify or what a row says.
        applyPurchasedReleases(ReleaseData.costTrackerRows(films: dataCoordinator.getAllFilms()))
    }

    private func applyPurchasedReleases(_ loadedReleases: [ReleaseData]) {
        releases = loadedReleases
        // Push the result to ReportsState directly rather than relying solely on
        // ReportsReleaseTableView's onChange(of: releases) — that handler never
        // fires when the scan result equals the current value (notably [] == []
        // on a first load with no qualifying data), which would leave the
        // category unmarked as loaded and force this full-library scan back into
        // the mount frame on every visit. updateData is idempotent, so the
        // duplicate call from onChange when data is non-empty is harmless.
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

    /// Mount path — cache-seeded with a deferred reconciling scan.
    /// See CostTrackerView.seedThenReloadPurchasedReleases for the full rationale.
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
            // See CostTrackerView.reconcilePurchasedReleases.
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
        // Shared with the PDF export — see CostTrackerView.loadPurchasedReleases.
        applyPriceTrackerData(ReleaseData.priceTrackerRows(films: dataCoordinator.getAllFilms()))
    }

    private func applyPriceTrackerData(_ loadedReleases: [ReleaseData]) {
        releases = loadedReleases
        // See CostTrackerView.loadPurchasedReleases for why this direct push exists.
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

    // Memoized sort result. Recomputed only when `releases` or `sortOrder`
    // actually changes, via the onChange handlers below. Using a computed
    // property here would re-sort the full array on every body re-evaluation
    // (e.g. selection changes, SelectionState changes, showStatusBar changes),
    // each of which would also trigger NSTableView.reloadData() — significant
    // unnecessary work on large datasets.
    @State private var sortedReleases: [ReleaseData] = []

    // (No row windowing. Under SwiftUI's Table every row handed over had a real reload cost,
    // so this view capped the table at 50 rows behind a "Show More" button. ReportTable is a
    // data-source NSTableView that builds only the rows on screen, so the full sorted set
    // costs what the first screenful does.)

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
                // Update ReportsState with current sort order for this category.
                ReportsState.shared.updateSortOrder(newSortOrder, for: category)
                // Recompute the memoized sort when the sort order changes.
                recomputeSort(releases, using: newSortOrder)
            }
        }
        .reportsStatusBarInset()
        .onAppear {
            // Restore the sort order that was active the last time this category
            // was shown. This keeps the user's column sort across tab switches,
            // and it is load-bearing for the mount-path fast sort below: the
            // sorted array cached in ReportsState was computed under that order,
            // so seeding a different (default) order here would force a full
            // re-sort inside the mount frame — exactly the cost being removed.
            if let saved = ReportsState.shared.savedSortOrder(for: category) {
                sortOrder = saved
            }
            onLoad()
            ReportsState.shared.updateSortOrder(sortOrder, for: category)
        }
        .onChange(of: releases) { _, newReleases in
            // Recompute the memoized sort whenever the underlying data changes.
            recomputeSort(newReleases, using: sortOrder)
            // Update ReportsState with current data for export.
            ReportsState.shared.updateData(newReleases, for: category)
            // Reconcile the table selection against the freshly loaded rows so any
            // selection that referenced a now-absent release is dropped.
            reconcileSelection(against: newReleases)
        }
        // Sync SelectionState changes back to local table selection.
        // This ensures the table selection clears when SelectionState is cleared externally
        // (e.g., switching views, clearing selection programmatically).
        .onChange(of: selectionState.selectedFilmIDs) { _, newSelectedFilmIDs in
            // If SelectionState was cleared, clear the local table selection
            if newSelectedFilmIDs.isEmpty && !selection.isEmpty {
                selection = []
            }
        }
        // Listen for film events to refresh table data in real-time. This catches
        // changes like releases being added/removed/modified via FilmSheet.
        //
        // Each case simply triggers a reload when the event could affect this table;
        // the actual selection cleanup (clearing rows that disappear from the reloaded
        // data) is handled centrally in `reconcileSelection(against:)`, invoked from
        // `.onChange(of: releases)` once the new data has landed. Centralizing it there
        // means the cleanup always evaluates the freshly loaded rows rather than a
        // captured (and therefore stale) copy of `releases`, and it is deferred to the
        // next run loop pass so the prune executes after the Table has re-rendered with
        // the updated data source — preventing NSTableView from re-syncing a stale row
        // selection back into the binding.
        .onFilmEvent { event in
            switch event {
            case .updated(let filmID):
                // A metadata update only matters if the film is currently shown
                // (e.g. its title changed). Release-level changes arrive separately
                // as `.releaseChanged`, so a non-displayed film cannot newly qualify here.
                guard releases.contains(where: { $0.filmID == filmID }) else { break }
                onDataChange()

            case .deleted(let filmIDs):
                // Only reload if any deleted film had releases in our table.
                guard releases.contains(where: { filmIDs.contains($0.filmID) }) else { break }
                onDataChange()

            case .releaseChanged:
                // Reload unconditionally — a release change can add a film to the table
                // (marking purchased / adding price data) or remove it (clearing those).
                onDataChange()

            case .added:
                // New films might have qualifying release data — reload to check.
                onDataChange()
            }
        }
    }

    // MARK: - Selection Reconciliation

    /// Drops any selected release IDs that are no longer present in `newReleases`,
    /// then lets the resulting `selection` change flow through `handleSelectionChange`
    /// to keep `SelectionState` in sync. The prune is deferred by one run loop pass so
    /// it lands after the Table has reloaded with `newReleases`; clearing in the same
    /// pass as the data-source reload can cause the backing NSTableView to re-sync the
    /// stale row selection back into the binding.
    private func reconcileSelection(against newReleases: [ReleaseData]) {
        guard !selection.isEmpty else { return }
        let validIDs = Set(newReleases.map(\.releaseID))
        guard !selection.isSubset(of: validIDs) else { return }
        DispatchQueue.main.async {
            selection = selection.intersection(validIDs)
        }
    }
    
    // MARK: - Custom Sort

    /// Recomputes `sortedReleases` for the given inputs, consulting the
    /// ReportsState per-category sorted cache first. On mount, the seeded data
    /// array is the exact instance held by the cache, so the equality check
    /// short-circuits on buffer identity and this is O(1) — the full sort
    /// (localized string comparisons on every element) only runs when the data
    /// or the sort order has genuinely changed, which the deferral in the
    /// seed-then-reload mount path keeps out of the menu-fade window.
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
        // Handle no selection (cleared)
        if newSelection.isEmpty {
            selectionState.clearImmediate()
            return
        }
        
        // Handle multi-selection
        if newSelection.count > 1 {
            let filmIDs = newSelection.compactMap { releaseID in
                releases.first(where: { $0.releaseID == releaseID })?.filmID
            }
            selectionState.select(Set(filmIDs))
            return
        }
        
        // Handle single selection. `newSelection.count` is exactly 1 at this point — the
        // empty and multi cases both returned above — so `first` is non-nil by
        // construction and the defensive `guard let` that used to stand here could never
        // take its else branch. Matches HallOfFameView.handleSelectionChange.
        guard let selectedReleaseID = newSelection.first else { return }

        // Look up the release data to get the film ID
        if let releaseData = releases.first(where: { $0.releaseID == selectedReleaseID }) {
            selectionState.select(releaseData.filmID)
        } else {
            // Release not found in array - this is an error condition
            // Log it and clear selection to prevent stale state
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
    /// The film's sort name (from `FilmSnapshot.sortName`). Empty when the film has no
    /// explicit sort override, in which case `filmTitle` is used as the sort key.
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
        // Precomputed once per row: stripArticles is a unicode-scalar walk with
        // allocations, and a sort compares each row O(log n) times.
        self.titleSort = GalleryTitleKey(name: filmTitle, sortName: filmSortName,
                                         year: Int(filmYear) ?? 0, filmID: filmID)
    }

    /// The row's place in the gallery's Title sort — what the Title column sorts by, and
    /// the tiebreak under every other column.
    let titleSort: GalleryTitleKey

    // Cost Tracker formatters
    var costFormatted: String {
        guard cost > 0 else { return "—" }
        return Fmt.dollars(cost)
    }
    
    var amountSpentFormatted: String {
        // Intentionally left as displaying '$0.00' for empty fields.
        return Fmt.dollars(amountSpent)
    }
    
    var purchaseDateFormatted: String {
        formatDate(purchaseDate)
    }
    
    // Price Tracker formatters
    var lowestPriceFormatted: String {
        guard lowestPrice > 0 else { return "—" }
        return Fmt.dollars(lowestPrice)
    }
    
    var lowestPriceDateFormatted: String {
        formatDate(lowestPriceDate)
    }
    
    // "May 1, 2024" for a stored date, or the stored text itself when it is not one.
    //
    // Read with the app's one date parser. Purchase and lowest-price dates are stored as
    // `yyyy.MM.dd` (`StorageDateFormatters.dot`), which the private formatter list this
    // replaced — dash and slash spellings only — never matched, so both tracker date
    // columns showed the raw stored string.
    private func formatDate(_ dateString: String) -> String {
        guard !dateString.isEmpty else { return "—" }
        guard let date = parseDate(from: dateString) else { return dateString }
        return Film_Tracker.formatDate(date)
    }
}

// MARK: - Release Data Row Building

/// The two tracker tabs' row sets and their orderings, in one place.
///
/// These used to exist twice: once in `CostTrackerView`/`PriceTrackerView`, which build
/// what the table shows, and once in `LibraryPDFExporter`, which builds what the printed
/// sheet shows. The two restated the same qualifying predicate, the same field mapping,
/// and — imperfectly — the same order, and the PDF copy had already drifted: it sorted
/// with a bare `>` on the date string and no tiebreak, so rows sharing a purchase date
/// came out in whatever order `getAllFilms()` happened to hand them over (it is
/// `Array(films.values)` over a Dictionary, which is unordered), giving a different
/// printed order on each export and one that never matched the screen.
///
/// One definition each removes the drift by construction.
extension ReleaseData {
    /// The Purchase and Expense Tracker's rows: purchased top-level releases carrying
    /// cost or spend data. Unsorted — the table applies the user's column order.
    static func costTrackerRows(films: [FilmSnapshot]) -> [ReleaseData] {
        var rows: [ReleaseData] = []
        for film in films {
            for release in film.releases where release.purchased && release.isTopLevel {
                // Only include releases with cost or amount spent data.
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

    /// The Price Tracker's rows: unpurchased top-level releases carrying a lowest-price
    /// observation. Unsorted, as `costTrackerRows`.
    static func priceTrackerRows(films: [FilmSnapshot]) -> [ReleaseData] {
        var rows: [ReleaseData] = []
        for film in films {
            for release in film.releases where !release.purchased && release.isTopLevel {
                // Only include releases with lowest price data.
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

    /// A tracker tab's rows, built and sorted off the main actor for the mount path's
    /// reconciling load.
    struct Reconciled {
        let category: ReportsCategory
        let rows: [ReleaseData]
        let sorted: [ReleaseData]
        let sortOrder: [KeyPathComparator<ReleaseData>]

        /// Records the sort in ReportsState's sorted cache, so the table's recomputeSort
        /// finds it there instead of sorting on the main actor. Called only when the rows
        /// are applied, so a dropped result never displaces a newer entry.
        @MainActor
        func primeSortCache() {
            ReportsState.shared.updateSortedReleases(sorted, for: category, data: rows, sortOrder: sortOrder)
        }
    }

    /// The sort is done under the order the table will use — the saved one, else the
    /// default, as ReportsReleaseTableView.onAppear picks. If the order changes before the
    /// rows land, the cache simply misses and the table sorts as it always has.
    @MainActor
    static func reconciledRows(
        for category: ReportsCategory,
        filmsMap: [UUID: FilmSnapshot],
        defaultSortOrder: [KeyPathComparator<ReleaseData>],
        build: @escaping @Sendable ([FilmSnapshot]) -> [ReleaseData]
    ) async -> Reconciled {
        let order = ReportsState.shared.savedSortOrder(for: category) ?? defaultSortOrder
        let (rows, sorted) = await Task.detached(priority: .userInitiated) {
            // Array(values) is exactly what getAllFilms() returns for this dictionary.
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

    /// The comparator a header key sorts by. Title sorts by `titleSort`, the gallery's
    /// order; the rest by their stored strings, under English rules (a String key path's
    /// default comparator, `.localizedStandard`, follows the system language).
    private static func comparator(forKey key: String, order: SortOrder) -> KeyPathComparator<ReleaseData>? {
        switch key {
        // The gallery's Title order (sort name, articles stripped, numbers last), not
        // the raw title.
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

    /// Sorts `items` by the given column order, applying a title tiebreaker whenever every
    /// active comparator treats two items as equal. The tiebreaker mirrors the gallery
    /// view's title sort: article-stripped, numbers-last, `englishStandardCompare`.
    /// Swift's `sorted(by:)` is a stable sort, so items that also tie on title retain
    /// their original relative order.
    ///
    /// The tiebreak is what makes the result a TOTAL order, and so what makes it
    /// reproducible: without it the order among equal keys is inherited from the input,
    /// which for anything derived from `getAllFilms()` is a Dictionary's unordered values.
    static func sorted(
        _ items: [ReleaseData],
        using order: [KeyPathComparator<ReleaseData>]
    ) -> [ReleaseData] {
        // No active sort descriptor: preserve the input order (stable no-op). Unreachable
        // in practice — both tracker tabs open with a non-empty default and
        // ReportsState.savedSortOrder reports an empty stored order as nil — so this is
        // left exactly as it was rather than given a new fallback ordering of its own.
        guard !order.isEmpty else { return items }

        return items.sorted { lhs, rhs in
            // Apply each comparator in priority order; the first non-equal result wins.
            for comparator in order {
                switch comparator.compare(lhs, rhs) {
                case .orderedAscending:  return true
                case .orderedDescending: return false
                case .orderedSame:       continue
                }
            }
            // All comparators tied → the gallery's title order (which ends on the film id),
            // and then the release's own id: two purchased copies of ONE film tie on
            // everything else, and `items` arrives in `getAllFilms()`'s Dictionary order,
            // reseeded every launch, so without it a double dip's rows could swap.
            if lhs.titleSort != rhs.titleSort { return lhs.titleSort < rhs.titleSort }
            return lhs.releaseID.uuidString < rhs.releaseID.uuidString
        }
    }
}
