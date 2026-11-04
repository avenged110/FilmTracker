// MARK: - RPTabHallOfFame.swift
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
    @State private var selection: Set<UUID> = []

    private static let emptyStateConfig = EmptyStateConfig(
        glyph: "trophy.fill",
        noFilmsMessage: "Add films to your library to create a Hall of Fame.",
        noDataMessage: "Set Hall of Fame positions for films to create your personal ranking."
    )

    /// Rating, then release year. The rating is 30 pt, plus 20 pt trailing padding. The year is 60 pt, monospaced.
    private static let trailingColumns: [ReportTableColumn<HallOfFameFilm>] = [
        ReportTableColumn(id: "rating", width: 50, trailingPad: 20, content: .rating { $0.userRating }),
        ReportTableColumn(id: "year", width: 60, font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                          isSecondary: true, content: .text { $0.releaseYear })
    ]

    var body: some View {
        ReportsEmptyStateWrapper(
            totalFilmCount: dataCoordinator.totalFilmCount,
            isEmpty: films.isEmpty,
            config: Self.emptyStateConfig
        ) {
            ReportsRankedListView(
                items: films,
                selection: $selection,
                onSelectionChange: handleSelectionChange,
                onMove: { source, destination in
                    handleMove(from: source, to: destination)
                },
                primaryLabel: { $0.name },
                trailingColumns: Self.trailingColumns
            )
        }
        /// Expose selection to the MenuBar so that Film menu items (e.g. "Delete from Library")
        /// reflect the current HoF selection and can be enabled/disabled correctly.
        .focusedSceneValue(\.selectedFilmIDs, selectionState.selectedFilmIDs)
        .focusedSceneValue(\.selectedFilmID, selectionState.selectedFilmID)
        .onAppear {
            /// Mount path. Seed from the cache so the list renders at once, then reconcile with a fresh load two run-loop cycles later,
            /// after the Picker's fade (see ReportsState.selectCategory). The first visit loads synchronously, to avoid a placeholder flash.
            if ReportsState.shared.hasLoadedData(for: .hallOfFame) {
                films = ReportsState.shared.cachedHallOfFameFilms
                DispatchQueue.main.async {
                    DispatchQueue.main.async {
                        reconcileHallOfFameFilms()
                    }
                }
            } else {
                loadHallOfFameFilms()
            }
        }
        /// Refresh on film updates, such as films added to or removed from the Hall of Fame in FilmSheet.
        .onFilmEvent { event in
            switch event {
            case .updated(let filmID):
                /// Use dataCoordinator.hallOfFameFilms, the canonical UUID list. dataCoordinator.films is the active view's filtered array,
                /// which may not contain the film in Reports. Selection cleanup rides on the reload (see pruneSelectionToLiveRows).
                if films.contains(where: { $0.id == filmID })
                    || dataCoordinator.hallOfFameFilms.contains(filmID) {
                    loadHallOfFameFilms()
                }
            case .deleted(let filmIDs):
                /// Reload if a deleted film was in the Hall of Fame. The reload prunes it from the selection.
                if films.contains(where: { filmIDs.contains($0.id) }) {
                    loadHallOfFameFilms()
                }
            case .added(let filmID):
                /// A save never adds a film with a position: a new film the sheet puts in
                /// the Hall of Fame joins through addToHallOfFame, which posts .updated.
                /// The one film that does arrive ranked is a deletion being rolled back
                /// (its save failed): its position is restored before .added is posted,
                /// and .deleted already dropped its row here, so reload for it.
                if dataCoordinator.hallOfFameFilms.contains(filmID) {
                    loadHallOfFameFilms()
                }
            case .releaseChanged:
                /// No on-screen column reads releases. The purchase standing does, but only the PDF prints it, and the export rebuilds its rows.
                break
            }
        }
    }

    /// The mount path's reconciling load, with the row build off the main actor. Event-driven reloads stay synchronous, since a drag-reorder's
    /// reloads run inside the table's move callback and must land in the same pass.
    private func reconcileHallOfFameFilms() {
        loadGeneration += 1
        let generation = loadGeneration
        let filmsMap = dataCoordinator.getAllFilmsMap()
        let ranking = dataCoordinator.hallOfFameFilms
        Task {
            let rebuilt = await Task.detached(priority: .userInitiated) {
                /// Built the same way getHallOfFameFilms() builds them.
                HallOfFameFilm.rows(films: ranking.compactMap { filmsMap[$0] })
            }.value
            guard generation == loadGeneration else { return }
            /// Rows from a library or ranking that has since changed would be stale, and the change may not have triggered a reload.
            /// Fall back to the synchronous load, which reads both as they are now.
            guard dataCoordinator.hallOfFameFilms == ranking,
                  dataCoordinator.getAllFilmsMap() == filmsMap else {
                loadHallOfFameFilms()
                return
            }
            applyHallOfFameFilms(rebuilt)
        }
    }

    private func loadHallOfFameFilms() {
        loadGeneration += 1
        /// Built by HallOfFameFilm.rows, which the PDF export also uses. The ranking, purchase standing, and upgrade note are derived once.
        applyHallOfFameFilms(HallOfFameFilm.rows(films: dataCoordinator.getHallOfFameFilms()))
    }

    private func applyHallOfFameFilms(_ rebuilt: [HallOfFameFilm]) {
        /// Assign only on an actual change. A drag-reorder emits one .film(.updated) per shifted member, and each one reloads synchronously.
        /// Reassigning on each would rebuild the List mid-drag, even though handleMove already applied the same order. @State does not compare
        /// on assignment, so the guard is explicit.
        if rebuilt != films {
            films = rebuilt
        }

        /// Always called. ReportsState does its own change detection, and it needs the first call to mark the category loaded.
        ReportsState.shared.updateHallOfFameData(rebuilt)

        pruneSelectionToLiveRows()
    }

    /// Drops any selected film that no longer has a row, after a reload replaces `films`. ReportsRankedListView maps the change into
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

        /// Update ReportsState.
        ReportsState.shared.updateHallOfFameData(films)
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

    /// The highest-ranked recognized format present, or nil if none is. An unrecognized format string is skipped, since this value names a format in the report.
    static func best(in releases: [ReleaseSnapshot]) -> ReleaseFormat? {
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
    /// What the user owns of this film. Consumed by the PDF export's "Purchased" column.
    let purchase: HallOfFamePurchase
    /// The best format available but not owned, if any. The PDF export's Notes column
    /// reports it as "<format> available".
    let upgrade: ReleaseFormat?
    /// The film's cut, from the Metadata tab's Version picker — the DISPLAY name
    /// ("Director's Cut"), not the stored two-letter code. Empty for an unset version and
    /// for a plain theatrical cut, neither of which is worth a line in a report.
    let version: String

    /// The Hall of Fame's rows, in ranking order. This is the one definition of a row. The view and the PDF export both use it.
    ///
    /// `position` is the 1-based index in the given order, not the stored `hofPosition`. The store has already reconciled the ranking, so a
    /// stored gap or duplicate cannot give two rows the same number.
    static func rows(films: [FilmSnapshot]) -> [HallOfFameFilm] {
        films.enumerated().map { index, film in
            let purchase = HallOfFamePurchase.forReleases(film.releases)
            return HallOfFameFilm(
                id: film.id,
                position: index + 1,
                name: film.name,
                releaseYear: film.releaseYear,
                userRating: film.userRating,
                purchase: purchase,
                upgrade: HallOfFamePurchase.upgrade(for: purchase, releases: film.releases),
                version: ViewingVersion.reportableName(forStoredCode: film.digitalVersion)
            )
        }
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
