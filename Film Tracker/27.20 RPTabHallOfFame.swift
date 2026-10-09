// MARK: - RPTabHallOfFame.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Contains Hall of Fame report view and related components.

import SwiftUI

// MARK: - View
struct HallOfFameView: View {
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SelectionState.self) private var selectionState
    @State private var films: [HallOfFameFilm] = []
    @State private var selection: Set<UUID> = []

    private static let emptyStateConfig = EmptyStateConfig(
        glyph: "trophy.fill",
        noFilmsMessage: "Add films to your library to create a Hall of Fame.",
        noDataMessage: "Set Hall of Fame positions for films to create your personal ranking."
    )

    /// Rating, then release year. Widths and gaps are the former SwiftUI row's: a 30 pt
    /// rating with 20 pt trailing padding, then the 60 pt monospaced year.
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
        // Expose selection to the MenuBar so that Film menu items (e.g. "Delete from Library")
        // reflect the current HoF selection and can be enabled/disabled correctly.
        .focusedSceneValue(\.selectedFilmIDs, selectionState.selectedFilmIDs)
        .focusedSceneValue(\.selectedFilmID, selectionState.selectedFilmID)
        .onAppear {
            // Mount path. Seed from the cache when available so the List renders
            // instantly with no data work in the mount frame, then reconcile with
            // a fresh load deferred two run-loop cycles — after the Picker
            // menu-dismissal fade has been committed (see ReportsState.selectCategory
            // for the deferral rationale). First-ever visit loads synchronously,
            // exactly as before, to avoid a placeholder flash.
            if ReportsState.shared.hasLoadedData(for: .hallOfFame) {
                films = ReportsState.shared.cachedHallOfFameFilms
                DispatchQueue.main.async {
                    DispatchQueue.main.async {
                        loadHallOfFameFilms()
                    }
                }
            } else {
                loadHallOfFameFilms()
            }
        }
        // Listen for film updates to refresh Hall of Fame data in real-time.
        // This catches changes like films being added/removed from Hall of Fame via FilmSheet.
        .onFilmEvent { event in
            switch event {
            case .updated(let filmID):
                // Check if the updated film affects Hall of Fame.
                // Use hallOfFameFilms (the canonical UUID list) rather than
                // dataCoordinator.films, which is the active view's filtered array
                // and may not contain the film at all when in the Reports view.
                // Selection cleanup rides on the reload (see pruneSelectionToLiveRows).
                if films.contains(where: { $0.id == filmID })
                    || dataCoordinator.hallOfFameFilms.contains(filmID) {
                    loadHallOfFameFilms()
                }
            case .deleted(let filmIDs):
                // Reload if any deleted film was in Hall of Fame; the reload prunes the
                // deleted films out of the selection.
                if films.contains(where: { filmIDs.contains($0.id) }) {
                    loadHallOfFameFilms()
                }
            case .added:
                // A save never adds a film with a position: a new film the sheet puts in
                // the Hall of Fame joins through addToHallOfFame, which posts .updated.
                break
            case .releaseChanged:
                // No on-screen column reads releases. (The rows' purchase standing does,
                // but only the PDF prints it, and the export rebuilds its own rows.)
                break
            }
        }
    }

    private func loadHallOfFameFilms() {
        // Built by HallOfFameFilm.rows, which the whole-library PDF export calls as well,
        // so the ranking, the purchase standing, and the upgrade note are derived once.
        let rebuilt = HallOfFameFilm.rows(films: dataCoordinator.getHallOfFameFilms())

        // Assign only on an actual change. A single drag-reorder emits one .film(.updated)
        // per shifted member, and the .onFilmEvent handler reloads on each of them. Those
        // events are delivered synchronously (SwiftUI's onReceive), so the array was being
        // reassigned once per shifted film from inside the List's own onMove callback —
        // invalidating and rebuilding the whole List mid-drag, even though handleMove had
        // already applied the identical order locally a moment earlier. @State does not
        // compare on assignment, so the guard has to be explicit. The mount-path reconciling
        // load benefits identically.
        if rebuilt != films {
            films = rebuilt
        }

        // Always called: ReportsState performs its own change detection and additionally
        // needs the first call in order to mark the category as loaded.
        ReportsState.shared.updateHallOfFameData(rebuilt)

        pruneSelectionToLiveRows()
    }

    /// Drops any selected film that no longer has a row, after a reload has replaced
    /// `films`. ReportsRankedListView maps the change back into SelectionState through
    /// `handleSelectionChange`, including the clear when nothing is left.
    ///
    /// Replaces two per-event cleanups: the removal branch cleared the WHOLE selection when
    /// any one film left the ranking, selected or not, and the deletion branch wrote
    /// SelectionState directly as well as through the binding. Deferred one run loop pass
    /// and re-derived from `films` at that point, as ReleaseWishlistView's prune is.
    private func pruneSelectionToLiveRows() {
        guard !selection.isEmpty, !selection.isSubset(of: Set(films.map(\.id))) else { return }
        DispatchQueue.main.async {
            selection.formIntersection(Set(films.map(\.id)))
        }
    }

    private func handleMove(from source: IndexSet, to destination: Int) {
        // Reorder the local array.
        var updatedFilms = films
        updatedFilms.move(fromOffsets: source, toOffset: destination)

        // Update positions.
        for index in updatedFilms.indices {
            updatedFilms[index].position = index + 1
        }

        films = updatedFilms

        // Extract film IDs in new order.
        let orderedFilmIDs = updatedFilms.map { $0.id }

        // Update coordinator (debounced persistence).
        dataCoordinator.reorderHallOfFame(orderedFilmIDs)

        // Update ReportsState.
        ReportsState.shared.updateHallOfFameData(films)
    }

    private func handleSelectionChange(_ newSelection: Set<UUID>) {
        // Handle no selection (cleared).
        if newSelection.isEmpty {
            selectionState.clearImmediate()
            return
        }

        // Handle multi-selection.
        if newSelection.count > 1 {
            selectionState.select(newSelection)
            return
        }

        // Handle single selection — newSelection.count is exactly 1 at this point,
        // so newSelection.first is guaranteed non-nil.
        if let selectedFilmID = newSelection.first {
            selectionState.select(selectedFilmID)
        }
    }
}

// MARK: - Purchase Standing

/// What the user owns of a film, reduced to the single best answer.
///
/// Derived from a film's releases at load time and carried on `HallOfFameFilm` rather than
/// recomputed by each consumer: the ranking is a property of the film, and two readers
/// deriving it independently is how two surfaces come to disagree about the same shelf.
///
/// The ordering is 4K, then Blu-ray, then DVD — `ReleaseFormat.displayRank` — applied first
/// to what has been bought and then, failing that, to what merely exists.
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

    /// The best format the user does NOT already own at that tier, or nil when there is
    /// nothing to upgrade to.
    ///
    /// This is what the report's Notes column reports as "<format> available". It answers
    /// one question for every purchase state at once: a film owned on Blu-ray upgrades to a
    /// 4K release if one exists, a film owned on DVD upgrades to whichever of 4K or Blu-ray
    /// is present, a film owned on 4K has nowhere to go, and a film owned in no format at
    /// all upgrades to the best format that exists for it.
    ///
    /// "Strictly better" is `ReleaseFormat.displayRank`, the app's one format ladder — so
    /// this cannot drift out of step with the ordering every other list sorts by.
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

    /// The highest-ranked recognized format present, or nil when none is.
    ///
    /// An unrecognized format string is skipped rather than ranked last: this value is used
    /// to NAME a format in the report, and a value this build cannot interpret is not a
    /// name it can print.
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

    /// The Hall of Fame's rows, in ranking order, from the films the store hands back in
    /// that order.
    ///
    /// The single definition of what a Hall of Fame row IS. `HallOfFameView` shows these
    /// and `LibraryPDFExporter` prints them; the export used to carry its own copy of this
    /// mapping, which is the kind of duplication that lets one surface start reporting a
    /// different purchase standing than the other.
    ///
    /// `position` is the 1-based index in the given order rather than the stored
    /// `hofPosition`: the store has already reconciled the ranking, so the array's own
    /// order is authoritative and a stored gap or duplicate cannot put two rows at the
    /// same number.
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
    /// The version worth REPORTING for a stored `Film.digitalVersion` code.
    ///
    /// Empty for an unset field and for `.theatrical`: a report lists what makes a film's
    /// copy unusual, and the theatrical cut is the default every film is assumed to be
    /// until something says otherwise. An unrecognized code yields nothing rather than a
    /// guess.
    static func reportableName(forStoredCode code: String) -> String {
        guard let version = ViewingVersion(rawValue: code), version != .theatrical else {
            return ""
        }
        return version.displayName
    }
}
