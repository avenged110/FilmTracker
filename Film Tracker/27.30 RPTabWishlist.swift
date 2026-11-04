// MARK: - RPTabWishlist.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// The Release Wishlist report tab. It lists wishlisted releases in wishlist order, and its rows also feed the PDF export.

import SwiftUI

// MARK: - Column Width Constants
/// Edit a value here to resize that column everywhere in the wishlist row. The title column fills the space left over.
private enum WishlistColW {
    /// ─── Trailing-area columns (right of title) ───────────────────────────────
    /// Col A: format badge, sized for the widest stored format string ("4K UHD"), since the row prints `format` verbatim (see WishlistRelease.formatBadge).
    static let format:       CGFloat = 52
    static let studio:       CGFloat = 130 /// Col B – Studio name
    /// Col C: release date, "May 30, 2027". The month and day use the system face, and the year uses the monospaced face, right-aligned so the years line up.
    /// It is sized for the all-monospaced width (89 pt), which is wider than the mixed run.
    static let releaseDate:  CGFloat = 90
    static let independence: CGFloat = 72  /// Col D – Independence type
    static let availability: CGFloat = 100 /// Col E – Market availability

    /// ─── Inter-column spacing ─────────────────────────────────────────────────
    /// Every trailing column has this pad plus the table's 12 pt intercell spacing, 16 pt in total. Change it here to adjust all trailing gaps together.
    /// Any space it gives back goes to the title, the one field that flexes.
    static let detailGap: CGFloat = 4

    /// The studio column gives up to half its width before the title truncates further.
    static let studioMin: CGFloat = studio / 2

    /// The title column's floor: 50% above ReportsRankedListView's default of 80.
    static let titleMin: CGFloat = 120
}

// MARK: - View

struct ReleaseWishlistView: View {
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SelectionState.self) private var selectionState
    @State private var releases: [WishlistRelease] = []
    @State private var selection: Set<UUID> = []
    /// Bumped by every load and every drag-reorder. The mount path's off-main reconcile
    /// applies its rows only if neither has happened since it started.
    @State private var loadGeneration = 0

    private static let emptyStateConfig = EmptyStateConfig(
        glyph: "gift.fill",
        noFilmsMessage: "Add films to your library to build your release wishlist.",
        noDataMessage: "Add releases of films to your wishlist to see them collated here."
    )

    /// Format badge, studio, release date, independence, and availability. Each column's `trailingPad` (`detailGap`) plus the table's
    /// 12 pt spacing gives the gap to the next column.
    private static let trailingColumns: [ReportTableColumn<WishlistRelease>] = {
        let detailPad = WishlistColW.detailGap
        let secondary = NSFont.systemFont(ofSize: 12)
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let italic = NSFont(descriptor: secondary.fontDescriptor.withSymbolicTraits(.italic), size: 12)
            ?? secondary
        return [
            ReportTableColumn(id: "format", width: WishlistColW.format + detailPad, trailingPad: detailPad,
                              content: .badge { row in
                                  /// The ReleaseCard header's band tint, with near-white lettering on every format's tint, including DVD gray.
                                  ReportBadge(text: row.formatBadge,
                                              fill: ReleaseFormatPalette.tint(for: row.format),
                                              ink: ReleaseFormatPalette.lightInk)
                              }),
            /// The one trailing column that resizes. It shrinks with the title, down to half its width, and never grows past its normal width.
            ReportTableColumn(id: "studio", width: WishlistColW.studio + detailPad,
                              minWidth: WishlistColW.studioMin + detailPad,
                              maxWidth: WishlistColW.studio + detailPad, font: secondary,
                              isSecondary: true, trailingPad: detailPad, content: .text { $0.studio }),
            ReportTableColumn(id: "year", width: WishlistColW.releaseDate + detailPad, alignment: .right,
                              font: secondary, isSecondary: true, trailingPad: detailPad,
                              content: .runs { row in
                                  /// "May 30, " in the system face, with the year monospaced. A year-only or unreadable value is all "year".
                                  guard let comma = row.releaseDate.range(of: ", ", options: .backwards) else {
                                      return [ReportTextRun(text: row.releaseDate, font: mono)]
                                  }
                                  return [ReportTextRun(text: String(row.releaseDate[..<comma.upperBound])),
                                          ReportTextRun(text: String(row.releaseDate[comma.upperBound...]), font: mono)]
                              }),
            ReportTableColumn(id: "independence", width: WishlistColW.independence + detailPad, font: secondary,
                              isSecondary: true, trailingPad: detailPad, content: .text { $0.independence }),
            ReportTableColumn(id: "availability", width: WishlistColW.availability, font: secondary,
                              isSecondary: true, content: .runs { row in
                                  /// An upcoming release has no availability yet, so the column says "Upcoming".
                                  row.isUpcoming
                                      ? [ReportTextRun(text: "Upcoming", font: italic)]
                                      : [ReportTextRun(text: row.marketAvailability)]
                              })
        ]
    }()

    var body: some View {
        ReportsEmptyStateWrapper(
            totalFilmCount: dataCoordinator.totalFilmCount,
            isEmpty: releases.isEmpty,
            config: Self.emptyStateConfig
        ) {
            ReportsRankedListView(
                items: releases,
                selection: $selection,
                onSelectionChange: handleSelectionChange,
                onMove: { source, destination in
                    handleMove(from: source, to: destination)
                },
                primaryLabel: { $0.filmName },
                trailingColumns: Self.trailingColumns,
                primaryMinWidth: WishlistColW.titleMin
            )
        }
        /// Expose selection to the MenuBar so that Film menu items (e.g. "Delete from Library")
        /// reflect the current wishlist selection and can be enabled/disabled correctly.
        .focusedSceneValue(\.selectedFilmIDs, selectionState.selectedFilmIDs)
        .focusedSceneValue(\.selectedFilmID, selectionState.selectedFilmID)
        .onAppear {
            /// Mount path: cache-seeded, with a deferred reconciling load. This keeps the full-library scan (getWishlistReleases walks every
            /// release of every film) out of the mount frame on revisits. See HallOfFameView.onAppear.
            if ReportsState.shared.hasLoadedData(for: .releaseWishlist) {
                releases = ReportsState.shared.cachedWishlistReleases
                DispatchQueue.main.async {
                    DispatchQueue.main.async {
                        reconcileWishlistReleases()
                    }
                }
            } else {
                loadWishlistReleases()
            }
        }
        /// A release dated today stops being upcoming at midnight. The reload's change guard makes this a no-op on days that change no row.
        .onReceive(CurrentDay.shared.dayChanged) { _ in
            loadWishlistReleases()
        }
        /// Listen for film and release changes to keep the list current in real-time.
        .onFilmEvent { event in
            switch event {
            case .updated(let filmID):
                /// Reload if this film is in the list, or if it now has wishlist releases. The "belongs here" test reads this one film's releases,
                /// rather than calling getWishlistReleases(), which would scan the whole library just to answer for one film. The predicate matches
                /// getWishlistReleases (`wishlist > 0 && isTopLevel`), so the answer is the same.
                let wasInList = releases.contains(where: { $0.filmID == filmID })
                let hasWishlistNow = dataCoordinator.getFilm(filmID)?.releases
                    .contains(where: { $0.wishlist > 0 && $0.isTopLevel }) ?? false
                if wasInList || hasWishlistNow {
                    /// loadWishlistReleases prunes row-level selection against the rows that survived the reload.
                    loadWishlistReleases()
                }
            case .deleted(let filmIDs):
                /// Reload if a deleted film had wishlist releases in the list. Selection cleanup rides on the reload.
                if releases.contains(where: { filmIDs.contains($0.filmID) }) {
                    loadWishlistReleases()
                }
            case .added(let filmID):
                /// A new film saved with releases also posts .releaseChanged, which is
                /// where its wishlisted releases normally arrive. But a film can also come
                /// back with releases already on it and ONLY .added announcing it — the
                /// rollback of a deletion whose save failed restores the whole snapshot
                /// after .deleted dropped its rows here — so a film that holds wishlisted
                /// releases on arrival reloads the list. Gated, so ordinary adds and
                /// imports (no wishlisted releases) stay free.
                let hasWishlistNow = dataCoordinator.getFilm(filmID)?.releases
                    .contains(where: { $0.wishlist > 0 && $0.isTopLevel }) ?? false
                if hasWishlistNow {
                    loadWishlistReleases()
                }
            case .releaseChanged(let filmID):
                /// Same two-part test as .updated, for the same reason. Only the named film's releases can have changed, so a film that is neither
                /// in the list nor wishlisted cannot affect it, and a reload would only rebuild the list already on screen.
                ///
                /// The gate does not narrow drag-reorder. reorderWishlist emits one event per moved film, and each film is already in the list, so the
                /// gate passes. The change guard in loadWishlistReleases absorbs those reloads. The gate removes unrelated edits, which would otherwise rescan the library.
                let wasInList = releases.contains(where: { $0.filmID == filmID })
                let hasWishlistNow = dataCoordinator.getFilm(filmID)?.releases
                    .contains(where: { $0.wishlist > 0 && $0.isTopLevel }) ?? false
                if wasInList || hasWishlistNow {
                    loadWishlistReleases()
                }
            }
        }
    }

    // MARK: - Data Loading

    /// The mount path's reconciling load, with the library scan and row build off the main actor. Event-driven reloads stay synchronous,
    /// since a drag-reorder's reloads run inside the table's move callback and must land in the same pass.
    private func reconcileWishlistReleases() {
        loadGeneration += 1
        let generation = loadGeneration
        let filmsMap = dataCoordinator.getAllFilmsMap()
        let today = CurrentDay.shared.today
        Task {
            let rebuilt = await Task.detached(priority: .userInitiated) {
                /// Array(values) matches what getAllFilms() returns for this dictionary.
                WishlistRelease.rows(pairs: DataCoordinator.wishlistPairs(in: Array(filmsMap.values)),
                                     today: today)
            }.value
            guard generation == loadGeneration else { return }
            /// Rows from a library (or a day) that has since changed would be stale, and the change may not have triggered a reload.
            /// Fall back to the synchronous load, which reads both as they are now.
            guard CurrentDay.shared.today == today,
                  dataCoordinator.getAllFilmsMap() == filmsMap else {
                loadWishlistReleases()
                return
            }
            applyWishlistReleases(rebuilt)
        }
    }

    private func loadWishlistReleases() {
        loadGeneration += 1
        /// Built by WishlistRelease.rows, which also serves the PDF export, so the printed sheet and this list number the wishlist the same way.
        applyWishlistReleases(WishlistRelease.rows(pairs: dataCoordinator.getWishlistReleases()))
    }

    private func applyWishlistReleases(_ rebuilt: [WishlistRelease]) {

        /// Assign only on an actual change, as in HallOfFameView, but more important here. A drag-reorder emits one .film(.releaseChanged) per moved film.
        /// AppEventBus delivers those synchronously inside the List's onMove callback, so each triggers a full-library scan. Without this guard, each
        /// would also reassign the @State array, which does not compare on assignment, and rebuild the List mid-drag.
        if rebuilt != releases {
            releases = rebuilt
        }

        /// Update ReportsState so the status bar count is current. Always called, since ReportsState does its own change detection and needs
        /// the first call to mark the category loaded.
        ReportsState.shared.updateWishlistData(rebuilt)

        pruneSelectionToLiveRows()
    }

    /// Drops selected row ids that no longer match a row, after a reload replaces `releases`. One prune replaces the per-event cleanups, which
    /// missed cases. `.deleted` built its removed set after the reload, so it was always empty. `.updated` cleared only when a film left entirely,
    /// and `.releaseChanged` did no cleanup. Pruning against the surviving rows covers all three and cannot go stale.
    ///
    /// `ReportRankedListView` reports the change through `onSelectionChange`, so the mapping into `SelectionState` happens in the normal path.
    ///
    /// It runs one run-loop pass later, from the current `releases`. Clearing synchronously lets NSTableView re-sync a stale selection into the binding.
    /// This matches HallOfFameView's prune.
    private func pruneSelectionToLiveRows() {
        guard !selection.isEmpty else { return }
        guard !selection.isSubset(of: Set(releases.map(\.id))) else { return }
        DispatchQueue.main.async {
            selection.formIntersection(Set(releases.map(\.id)))
        }
    }

    // MARK: - Reorder

    private func handleMove(from source: IndexSet, to destination: Int) {
        loadGeneration += 1
        var updated = releases
        updated.move(fromOffsets: source, toOffset: destination)

        /// Re-number positions.
        for index in updated.indices {
            updated[index].position = index + 1
        }

        releases = updated
        persistCurrentOrder()
        ReportsState.shared.updateWishlistData(releases)
    }

    // MARK: - Persistence

    /// Pushes the current display order back into the model via DataCoordinator,
    /// which updates MemoryStore immediately and debounces the store write.
    private func persistCurrentOrder() {
        let orderedPairs = releases.map { (filmID: $0.filmID, releaseID: $0.releaseID) }
        dataCoordinator.reorderWishlist(orderedPairs)
    }

    // MARK: - Selection

    private func handleSelectionChange(_ newSelection: Set<UUID>) {
        /// newSelection contains WishlistRelease.id values (which equal the release UUIDs).
        /// Map back to film IDs for SelectionState so the RightSidebar shows the film.
        if newSelection.isEmpty {
            selectionState.clearImmediate()
            return
        }

        let filmIDs = Set(
            releases
                .filter { newSelection.contains($0.id) }
                .map { $0.filmID }
        )

        if filmIDs.count == 1, let single = filmIDs.first {
            selectionState.select(single)
        } else {
            selectionState.select(filmIDs)
        }
    }
}

// MARK: - Wishlist Release Data Model

/// One wishlist row in the Release Wishlist tab. It conforms to `RankedItem`, so `ReportsRankedListView` reads the stored `position`.
struct WishlistRelease: Identifiable, Equatable, RankedItem {
    /// `id` is the release UUID, used for list row identity and selection.
    var id: UUID { releaseID }

    var position: Int
    let filmID: UUID
    let filmName: String
    let releaseID: UUID

    /// Display fields
    let studio: String
    /// "Jan 15, 2027", or the year alone for a release known only by its year.
    let releaseDate: String
    let format: String
    let independence: String
    let marketAvailability: String
    /// The release date lies after today (`ReleaseDateValue.isUpcoming`).
    let isUpcoming: Bool

    /// The format badge text: the stored format verbatim ("4K UHD", "Blu-ray", "DVD"). The ReleaseCard header (33.20) and the sidebar cards
    /// (24.20) show it the same way, so a disc gets one name everywhere. Passing it through also keeps unrecognized formats readable.
    var formatBadge: String { format }

    /// The wishlist's rows, numbered in display order, from the (film, release) pairs. This is the one definition of a wishlist row and its order.
    /// `ReleaseWishlistView` and `LibraryPDFExporter` both use it.
    ///
    /// Sorted by stored wishlist position, ascending. Positions are normally at least 1, since FSTabReleases.handleWishlistToggle issues one when
    /// the Wishlisted trait is ticked. The release id breaks ties, so the order is total. Positions are normally unique, but an older library can
    /// hold a duplicate pair, and `sorted(by:)` is not stable. Without the tiebreak, the two rows could swap between loads, and a drag would then persist that swap.
    @MainActor
    static func rows(
        pairs: [(film: FilmSnapshot, release: ReleaseSnapshot)]
    ) -> [WishlistRelease] {
        rows(pairs: pairs, today: CurrentDay.shared.today)
    }

    /// `rows(pairs:)` with today's date supplied, so it can run off the main actor.
    static func rows(
        pairs: [(film: FilmSnapshot, release: ReleaseSnapshot)],
        today: Date
    ) -> [WishlistRelease] {
        let sorted = pairs.sorted {
            if $0.release.wishlist != $1.release.wishlist {
                return $0.release.wishlist < $1.release.wishlist
            }
            return $0.release.id.uuidString < $1.release.id.uuidString
        }

        return sorted.enumerated().map { index, pair in
            WishlistRelease(
                position: index + 1,
                filmID: pair.film.id,
                filmName: pair.film.name,
                releaseID: pair.release.id,
                studio: pair.release.studio,
                /// An unreadable value prints as it is stored, as the year always did.
                releaseDate: ReleaseDateValue(pair.release.releaseDate, format: pair.release.format)?
                    .shortDisplayText
                    ?? ReleaseDateValue.yearText(of: pair.release.releaseDate, format: pair.release.format),
                format: pair.release.format,
                /// Shortened for the 72 pt Independence column: see
                /// ReleaseIndependence.compactDisplay. Only "Combo-pack (dual BD)" narrows.
                independence: ReleaseIndependence.compactDisplay(pair.release.independence),
                marketAvailability: ReleaseMarketAvailability.displayText(pair.release.marketAvailability),
                isUpcoming: ReleaseDateValue(pair.release.releaseDate, format: pair.release.format)?
                    .isUpcoming(today: today) ?? false
            )
        }
    }
}
