// MARK: - INTabHallOfFame.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// The Hall of Fame report: a ranked list of films, with each film's purchase standing and upgrade note. Its rows also feed the PDF export.

import SwiftUI

// MARK: - View
struct HallOfFameView: View {
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SelectionState.self) private var selectionState
    @State private var films: [HallOfFameFilm] = []
    /// Bumped by every load and drag-reorder. The mount path's off-main reconcile applies its rows only if neither has happened since.
    @State private var loadGeneration = 0
    /// Set while a film-event reload waits for the next run-loop turn (see scheduleReload).
    @State private var isReloadScheduled = false
    @State private var selection: Set<UUID> = []
    /// The rotation column follows the default rotation threshold, so a change to it in Settings rebuilds the rows.
    @AppStorage(preference: Preferences.defaultRotationThresholdKey) private var rotationMonths: Int

    private static let emptyStateConfig = EmptyStateConfig(
        glyph: InsightsCategory.hallOfFame.glyph,
        noFilmsMessage: "Add films to your library to create a Hall of Fame.",
        noDataMessage: "Set Hall of Fame positions for films to create your personal ranking."
    )

    /// Queue, rotation, best format owned, rating, then release year, with the gallery list view's 16 pt gap (ListRowView.columnGap)
    /// between each column's widest usual content and the next column's content. The table adds 12 pt between columns, so each
    /// column is its content plus 4 pt. Measured: the Queue glyph is 14 pt, so 18. The rating's star and "10" are 28 pt, so 32.
    /// The clock and "2+" are 29 pt, and the badge plate starts 3 pt into its column (InsightsTableCellView's badgeOutsideAllowance),
    /// so 30; the 18-month "1.5+" (37 pt) runs 7 pt past it and leaves 9. The 52 pt plate (the Wishlist's, for "4K UHD") ends 55 pt
    /// into the badge column, so 59. The year ends as the list's does, 8 pt (GalleryListRow.contentInset) before the cell's trailing edge:
    /// right-aligned in a 30 pt box (the list's yearColumnWidth) with an 8 pt trailing pad, so 38. "1999" in 12 pt monospaced is 29.7 pt.
    private static let trailingColumns: [InsightsTableColumn<HallOfFameFilm>] = [
        InsightsTableColumn(id: "queue", width: 18,
                          content: .symbol("text.line.last.and.arrowtriangle.forward", label: "In Queue") { $0.isQueued }),
        InsightsTableColumn(id: "rotation", width: 30,
                          content: .symbolText(symbol: "clock.fill") { $0.rotationLabel }),
        /// The plate is the column's width less its trailing pad: 59 − 7 = 52.
        InsightsTableColumn(id: "format", width: 59, trailingPad: 7, content: .badge { $0.purchase.ownedBadge }),
        InsightsTableColumn(id: "rating", width: 32, content: .rating { $0.userRating }),
        InsightsTableColumn(id: "year", width: 38, alignment: .right, font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                          isSecondary: true, trailingPad: 8, content: .text { $0.releaseYear })
    ]

    var body: some View {
        InsightsEmptyStateWrapper(
            totalFilmCount: dataCoordinator.totalFilmCount,
            isEmpty: films.isEmpty,
            config: Self.emptyStateConfig
        ) {
            InsightsRankedListView(
                items: films,
                selection: $selection,
                onSelectionChange: handleSelectionChange,
                onMove: { source, destination in
                    handleMove(from: source, to: destination)
                },
                primaryLabel: { $0.name },
                trailingColumns: Self.trailingColumns,
                menuFilmID: { $0.id }
            )
        }
        /// No .focusedSceneValue for the selection here: FilmTrackerApp publishes it at the scene root (SelectionFocusedValues),
        /// and handleSelectionChange writes this table's selection into SelectionState. Reading the selection in this body
        /// would re-evaluate the whole tab on every selection change.
        .onAppear {
            /// Mount path. Seed from the cache so the list renders at once, then reconcile with a fresh load two run-loop cycles later,
            /// after the Picker's fade (see InsightsState.selectCategory). The first visit loads synchronously, to avoid a placeholder flash.
            if InsightsState.shared.hasLoadedData(for: .hallOfFame) {
                films = InsightsState.shared.cachedHallOfFameFilms
                DispatchQueue.main.async {
                    DispatchQueue.main.async {
                        reconcileHallOfFameFilms()
                    }
                }
            } else {
                loadHallOfFameFilms()
            }
        }
        .onChange(of: rotationMonths) { loadHallOfFameFilms() }
        /// A rotation mark comes due at midnight on the 1st of a month (rotationEligibilityDate). The reload's change guard makes this a no-op
        /// on days that change no row.
        .onReceive(CurrentDay.shared.dayChanged) { _ in loadHallOfFameFilms() }
        /// The Queue column reads list membership, which a film's snapshot does not carry, so a Queue change posts no film event.
        .onReceive(AppEventBus.shared.listEvents) { event in
            guard case .membershipChanged(let listID) = event, FilmQueue.isInternalList(listID) else { return }
            scheduleReload()
        }
        /// Refresh on film updates, such as films added to or removed from the Hall of Fame in FilmSheet. Every case reloads through
        /// scheduleReload, so the guard on isReloadScheduled skips the membership scans once a reload is already on its way.
        .onFilmEvent { event in
            guard !isReloadScheduled else { return }
            switch event {
            case .updated(let filmID):
                /// Use dataCoordinator.hallOfFameFilms, the canonical UUID list. dataCoordinator.films is the active view's filtered array,
                /// which may not contain the film in Insights. Selection cleanup rides on the reload (see pruneSelectionToLiveRows).
                if films.contains(where: { $0.id == filmID })
                    || dataCoordinator.hallOfFameFilms.contains(filmID) {
                    scheduleReload()
                }
            case .deleted(let filmIDs):
                /// Reload if a deleted film was in the Hall of Fame. The reload prunes it from the selection.
                if films.contains(where: { filmIDs.contains($0.id) }) {
                    scheduleReload()
                }
            case .added(let filmID):
                /// A save never adds a film with a position: a new film the sheet puts in
                /// the Hall of Fame joins through addToHallOfFame, which posts .updated.
                /// The one film that does arrive ranked is a deletion being rolled back
                /// (its save failed): its position is restored before .added is posted,
                /// and .deleted already dropped its row here, so reload for it.
                if dataCoordinator.hallOfFameFilms.contains(filmID) {
                    scheduleReload()
                }
            case .releaseChanged(let filmID):
                /// The format column shows the purchase standing, which reads the film's releases.
                if dataCoordinator.hallOfFameFilms.contains(filmID) {
                    scheduleReload()
                }
            }
        }
    }

    /// Film events arrive synchronously, often in bursts: a drag-reorder posts one .film(.updated) per shifted member, and a bulk edit, a
    /// batch add or removal, or a rollback posts one per film. Each rebuilt every row, so a burst over K films cost K full rebuilds. The burst
    /// now collapses into one reload on the next run-loop turn, after the sender has finished its work, as the gallery title bar's and the
    /// sort menu's film-event refreshes do. A drag-reorder does not wait on it: handleMove has already applied the new order to `films`,
    /// and the reload confirms it against the store.
    private func scheduleReload() {
        guard !isReloadScheduled else { return }
        isReloadScheduled = true
        DispatchQueue.main.async {
            isReloadScheduled = false
            loadHallOfFameFilms()
        }
    }

    /// The mount path's reconciling load, with the row build off the main actor.
    private func reconcileHallOfFameFilms() {
        loadGeneration += 1
        let generation = loadGeneration
        /// Only the ranked films are copied out, not the films map. Holding the map across the build would make the next library edit copy
        /// all of it (see MemoryStore.filmsVersion), and comparing it afterward walked every film whenever anything had changed.
        let ranked = dataCoordinator.getHallOfFameFilms()
        let version = dataCoordinator.filmsVersion
        let months = Preferences.defaultRotationThreshold
        let queued = dataCoordinator.getFilmQueueFilmIDs()
        Task {
            let rebuilt = await Task.detached(priority: .userInitiated) {
                HallOfFameFilm.rows(films: ranked, rotationMonths: months, queuedFilmIDs: queued)
            }.value
            guard generation == loadGeneration else { return }
            /// Rows from a library that has since changed would be stale, and the change may not have triggered a reload. filmsVersion
            /// moves with every write to the films, which covers the ranking too: every rank change is a write to a film's hofPosition.
            /// Queue membership is not a film write, so it is compared on its own. Fall back to the synchronous load, which reads the
            /// library as it is now.
            guard dataCoordinator.filmsVersion == version,
                  Preferences.defaultRotationThreshold == months,
                  dataCoordinator.getFilmQueueFilmIDs() == queued else {
                loadHallOfFameFilms()
                return
            }
            applyHallOfFameFilms(rebuilt)
        }
    }

    private func loadHallOfFameFilms() {
        loadGeneration += 1
        /// Built by HallOfFameFilm.rows, which the PDF export also uses. The ranking, purchase standing, and upgrade note are derived once.
        applyHallOfFameFilms(HallOfFameFilm.rows(films: dataCoordinator.getHallOfFameFilms(),
                                                 rotationMonths: Preferences.defaultRotationThreshold,
                                                 queuedFilmIDs: dataCoordinator.getFilmQueueFilmIDs()))
    }

    private func applyHallOfFameFilms(_ rebuilt: [HallOfFameFilm]) {
        /// Assign only on an actual change. The reload after a drag-reorder (see scheduleReload) usually finds the order handleMove already
        /// applied, and reassigning would only push the same rows back through the table. SwiftUI compares a `@State` array by its storage,
        /// not its contents, so a freshly built but equal array would still invalidate the view; the guard compares the contents.
        if rebuilt != films {
            films = rebuilt
        }

        /// Always called. InsightsState does its own change detection, and it needs the first call to mark the category loaded.
        InsightsState.shared.updateHallOfFameData(rebuilt)

        pruneSelectionToLiveRows()
    }

    /// Drops any selected film that no longer has a row, after a reload replaces `films`. InsightsRankedListView maps the change into
    /// SelectionState through `handleSelectionChange`, including the clear when nothing is left. It runs one run-loop pass later, from the
    /// current `films`, as ReleaseWishlistView's prune does.
    private func pruneSelectionToLiveRows() {
        guard !selection.isEmpty, !selection.isSubset(of: Set(films.map(\.id))) else { return }
        DispatchQueue.main.async {
            selection.formIntersection(Set(films.map(\.id)))
        }
    }

    private func handleMove(from source: IndexSet, to destination: Int) {
        loadGeneration += 1
        /// Reorder the local array.
        var updatedFilms = films
        updatedFilms.move(fromOffsets: source, toOffset: destination)

        /// Update positions.
        for index in updatedFilms.indices {
            updatedFilms[index].position = index + 1
        }

        films = updatedFilms

        /// Extract film IDs in new order.
        let orderedFilmIDs = updatedFilms.map { $0.id }

        /// Update coordinator (debounced persistence).
        dataCoordinator.reorderHallOfFame(orderedFilmIDs)

        /// Update InsightsState.
        InsightsState.shared.updateHallOfFameData(films)
    }

    private func handleSelectionChange(_ newSelection: Set<UUID>) {
        /// No selection.
        if newSelection.isEmpty {
            selectionState.clearImmediate()
            return
        }

        /// Multi-selection.
        if newSelection.count > 1 {
            selectionState.select(newSelection)
            return
        }

        /// Single selection. The count is exactly 1 here, so `first` is non-nil.
        if let selectedFilmID = newSelection.first {
            selectionState.select(selectedFilmID)
        }
    }
}

// MARK: - Purchase Standing

/// What the user owns of a film, reduced to the single best answer.
///
/// It is derived once at load and stored on `HallOfFameFilm`, so every consumer agrees. The ordering is 4K, then Blu-ray, then DVD
/// (`ReleaseFormat.displayRank`). It applies first to what was bought, then to what merely exists.
enum HallOfFamePurchase: Equatable, Sendable {
    /// The best format actually owned.
    case purchased(ReleaseFormat)
    /// Nothing owned, but a release exists in this format.
    case available(ReleaseFormat)
    /// No releases at all — nothing has ever been recorded for this film.
    case unavailable

    /// The standing for one film's releases.
    static func forReleases(_ releases: [ReleaseSnapshot]) -> HallOfFamePurchase {
        if let owned = best(in: releases.filter(\.purchased)) { return .purchased(owned) }
        if let known = best(in: releases) { return .available(known) }
        return .unavailable
    }

    /// The best format the user does not already own, or nil when there is nothing better. The Notes column reports this as "<format> available".
    /// A Blu-ray owner upgrades to 4K if one exists. A DVD owner upgrades to 4K or Blu-ray. A 4K owner has nowhere to go. A film owned in no
    /// format upgrades to the best format available. "Better" uses `ReleaseFormat.displayRank`, the app's one format ladder.
    static func upgrade(for purchase: HallOfFamePurchase,
                        releases: [ReleaseSnapshot]) -> ReleaseFormat? {
        guard let best = best(in: releases) else { return nil }
        switch purchase {
        case let .purchased(owned):
            return best.displayRank < owned.displayRank ? best : nil
        case .available, .unavailable:
            return best
        }
    }

    /// The best format owned, for the format column; nil when nothing is owned.
    var ownedFormat: ReleaseFormat? {
        if case let .purchased(format) = self { return format }
        return nil
    }

    /// The format column's badge: the best format owned, or none.
    var ownedBadge: InsightsBadge? { ownedFormat.map { InsightsBadge.format($0.rawValue) } }

    /// The highest-ranked recognized format present, or nil if none is. An unrecognized format string is skipped, since this value names a format in the report.
    private static func best(in releases: [ReleaseSnapshot]) -> ReleaseFormat? {
        releases
            .compactMap { ReleaseFormat(rawValue: $0.format) }
            .min { $0.displayRank < $1.displayRank }
    }
}

// MARK: - Film Data
struct HallOfFameFilm: Identifiable, Equatable, RankedItem {
    let id: UUID
    var position: Int
    let name: String
    let releaseYear: String
    let userRating: Int
    /// What the user owns of this film. Shown by the format column and the status bar's summary, and printed in the PDF export's "Purchased" column.
    let purchase: HallOfFamePurchase
    /// The best format available but not owned, if any. The PDF export's Notes column
    /// reports it as "<format> available".
    let upgrade: ReleaseFormat?
    /// The film's cut, from the Metadata tab's Version picker — the DISPLAY name
    /// ("Director's Cut"), not the stored two-letter code. Empty for an unset version and
    /// for a plain theatrical cut, neither of which is worth a line in a report.
    let version: String
    /// The rotation column's text ("2+") when the film has not been viewed within the default rotation threshold, else nil.
    let rotationLabel: String?
    /// Whether the film is in any Film Queue section (Up Next, Soon, or Later). Shown by the Queue column; the PDF export does not print it.
    let isQueued: Bool

    /// The Hall of Fame's rows, in ranking order. This is the one definition of a row. The view and the PDF export both use it.
    ///
    /// `position` is the 1-based index in the given order, not the stored `hofPosition`. The store has already reconciled the ranking, so a
    /// stored gap or duplicate cannot give two rows the same number.
    ///
    /// `rotationMonths` is the default rotation threshold (Preferences.defaultRotationThreshold), passed in so the rows can be built off
    /// the main actor. A film is marked once its last viewing plus the threshold has arrived, by the app's one rotation rule
    /// (`rotationEligibilityDate`, which rounds up to the 1st of the next month), so the mark agrees with the "Up for Rotation" smart
    /// lists' timing. Only viewing recency counts: a film's own threshold override and its special sorting are not consulted. A film
    /// with no viewing is not marked. Nil leaves the column empty (the PDF export does not print it). `now` is read when the rows are
    /// built. The tab reloads when the day changes, so a mark that comes due while it stays open appears then.
    static func rows(films: [FilmSnapshot], rotationMonths: Int? = nil, queuedFilmIDs: Set<UUID> = [],
                     now: Date = Date()) -> [HallOfFameFilm] {
        let label = rotationMonths.map { "\(Preferences.rotationThresholdYearsText($0))+" }
        return films.enumerated().map { index, film in
            let purchase = HallOfFamePurchase.forReleases(film.releases)
            return HallOfFameFilm(
                id: film.id,
                position: index + 1,
                name: film.name,
                releaseYear: film.releaseYear,
                userRating: film.userRating,
                purchase: purchase,
                upgrade: HallOfFamePurchase.upgrade(for: purchase, releases: film.releases),
                version: ViewingVersion.reportableName(forStoredCode: film.digitalVersion),
                rotationLabel: label.flatMap { label in
                    guard let months = rotationMonths,
                          let watched = parseDate(from: film.lastWatched),
                          let due = rotationEligibilityDate(from: watched, months: months),
                          due <= now else { return nil }
                    return label
                },
                isQueued: queuedFilmIDs.contains(film.id)
            )
        }
    }
}

// MARK: - Status Bar Totals

/// The Hall of Fame's status bar summary: how many films are owned in each best format, how many are not owned, and how many carry each
/// rating. Rebuilt with the rows in InsightsState.updateHallOfFameData, change-guarded, so a drag-reorder does not redraw the bar.
struct HallOfFameTotals: Equatable {
    var total = 0
    /// Films by best format owned, in ladder order (4K UHD, Blu-ray, DVD); formats nobody's best is are left out.
    var owned: [(format: ReleaseFormat, count: Int)] = []
    var notOwned = 0
    /// Films per rating present, highest first. Unrated films (0) are left out.
    var ratings: [(rating: Int, count: Int)] = []

    init() {}

    init(rows: [HallOfFameFilm]) {
        total = rows.count
        var byFormat: [ReleaseFormat: Int] = [:]
        var byRating: [Int: Int] = [:]
        for row in rows {
            if let format = row.purchase.ownedFormat { byFormat[format, default: 0] += 1 } else { notOwned += 1 }
            if row.userRating > 0 { byRating[row.userRating, default: 0] += 1 }
        }
        owned = ReleaseFormat.allCases.sorted { $0.displayRank < $1.displayRank }
            .compactMap { format in byFormat[format].map { (format, $0) } }
        ratings = byRating.sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }

    static func == (a: HallOfFameTotals, b: HallOfFameTotals) -> Bool {
        a.total == b.total && a.notOwned == b.notOwned
            && a.owned.elementsEqual(b.owned) { $0.format == $1.format && $0.count == $1.count }
            && a.ratings.elementsEqual(b.ratings) { $0.rating == $1.rating && $0.count == $1.count }
    }
}

// MARK: - Version Reporting

extension ViewingVersion {
    /// The version to report for a stored `Film.digitalVersion` code. It is empty for an unset field and for `.theatrical`, since a report
    /// lists only unusual cuts. An unrecognized code also yields nothing.
    static func reportableName(forStoredCode code: String) -> String {
        guard let version = ViewingVersion(rawValue: code), version != .theatrical else {
            return ""
        }
        return version.displayName
    }
}
