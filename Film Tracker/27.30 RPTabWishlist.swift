// MARK: - RPTabWishlist.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Contains the Release Wishlist report tab and related components.

import SwiftUI

// MARK: - Column Width Constants
// Edit a value here to resize that column everywhere it appears in the wishlist row.
// The title column is dynamic — it fills the space between the position badge and
// the first fixed-width trailing column.
private enum WishlistColW {
    // ─── Trailing-area columns (right of title) ───────────────────────────────
    // Col A – Format badge. Sized for the widest STORED format string ("4K UHD"), not for
    // an abbreviation: the row prints `format` verbatim. See WishlistRelease.formatBadge.
    static let format:       CGFloat = 52
    static let studio:       CGFloat = 130 // Col B – Studio name
    static let releaseYear:  CGFloat = 42  // Col C – Release year
    static let independence: CGFloat = 72  // Col D – Independence type
    static let availability: CGFloat = 100 // Col E – Market availability

    // ─── Inter-column spacing ─────────────────────────────────────────────────
    // All trailing columns share a single uniform gap. Adjust here to tighten
    // or loosen the spacing between every trailing field simultaneously.
    //
    // Tightened from 14: the four gaps between the five trailing columns give back 16 pt
    // in total, and all of it goes to the title, which is the only non-fixed field in the
    // row — the ranked list gives it whatever the position badge and the trailing region
    // leave, so a narrower trailing region is directly more room before it truncates.
    static let columnGap: CGFloat = 10
}

// MARK: - View

struct ReleaseWishlistView: View {
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SelectionState.self) private var selectionState
    @State private var releases: [WishlistRelease] = []
    @State private var selection: Set<UUID> = []

    private static let emptyStateConfig = EmptyStateConfig(
        glyph: "gift.fill",
        noFilmsMessage: "Add films to your library to build your release wishlist.",
        noDataMessage: "Add releases of films to your wishlist to see them collated here."
    )

    /// Format badge, studio, release year, independence, availability. Each fixed column's
    /// `trailingPad` plus the table's 12 pt intercell spacing reproduces the former row's gap
    /// (12 pt HStack spacing either side of a `columnGap` spacer).
    private static let trailingColumns: [ReportTableColumn<WishlistRelease>] = {
        let pad = WishlistColW.columnGap + 12
        let secondary = NSFont.systemFont(ofSize: 12)
        return [
            ReportTableColumn(id: "format", width: WishlistColW.format + pad, trailingPad: pad,
                              content: .badge { $0.formatBadge }),
            ReportTableColumn(id: "studio", width: WishlistColW.studio + pad, font: secondary,
                              isSecondary: true, trailingPad: pad, content: .text { $0.studio }),
            ReportTableColumn(id: "year", width: WishlistColW.releaseYear + pad,
                              font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                              isSecondary: true, trailingPad: pad, content: .text { $0.releaseYear }),
            ReportTableColumn(id: "independence", width: WishlistColW.independence + pad, font: secondary,
                              isSecondary: true, trailingPad: pad, content: .text { $0.independence }),
            ReportTableColumn(id: "availability", width: WishlistColW.availability, font: secondary,
                              isSecondary: true, content: .text { $0.marketAvailability })
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
                trailingColumns: Self.trailingColumns
            )
        }
        // Expose selection to the MenuBar so that Film menu items (e.g. "Delete from Library")
        // reflect the current wishlist selection and can be enabled/disabled correctly.
        .focusedSceneValue(\.selectedFilmIDs, selectionState.selectedFilmIDs)
        .focusedSceneValue(\.selectedFilmID, selectionState.selectedFilmID)
        .onAppear {
            // Mount path — cache-seeded with a deferred reconciling load. This
            // removes the full-library release scan (getWishlistReleases walks
            // every release of every film) from the mount frame on revisits.
            // See HallOfFameView.onAppear for the full rationale.
            if ReportsState.shared.hasLoadedData(for: .releaseWishlist) {
                releases = ReportsState.shared.cachedWishlistReleases
                DispatchQueue.main.async {
                    DispatchQueue.main.async {
                        loadWishlistReleases()
                    }
                }
            } else {
                loadWishlistReleases()
            }
        }
        // Listen for film and release changes to keep the list current in real-time.
        .onFilmEvent { event in
            switch event {
            case .updated(let filmID):
                // Any film update may have changed its releases' wishlist flags or
                // other display fields. Reload if this film is currently represented
                // in the list, or if it now has wishlist releases that should appear.
                //
                // The "does it belong here now" test reads ONE film's releases rather
                // than calling getWishlistReleases(), which walks every release of every
                // film and materializes a (film, release) pair array for all of them —
                // an entire library scan and allocation to answer a question about a
                // single film, immediately before loadWishlistReleases() performs the
                // very same scan for real. The predicate is character-for-character the
                // one getWishlistReleases applies (`wishlist > 0 && isTopLevel`), so the
                // answer is identical; only the work is gone.
                let wasInList = releases.contains(where: { $0.filmID == filmID })
                let hasWishlistNow = dataCoordinator.getFilm(filmID)?.releases
                    .contains(where: { $0.wishlist > 0 && $0.isTopLevel }) ?? false
                if wasInList || hasWishlistNow {
                    // Row-level selection cleanup is handled inside loadWishlistReleases,
                    // which prunes against the rows that actually survived the reload.
                    loadWishlistReleases()
                }
            case .deleted(let filmIDs):
                // Reload if any deleted film had wishlist releases in our list.
                // Selection cleanup, again, rides on the reload.
                if releases.contains(where: { filmIDs.contains($0.filmID) }) {
                    loadWishlistReleases()
                }
            case .added:
                // A new film saved with releases also posts .releaseChanged, which is
                // where its wishlisted releases arrive.
                break
            case .releaseChanged(let filmID):
                // Release changes may have altered wishlist flags or the fields a row
                // displays. Gated by the same two-part test as .updated, and for the same
                // reason: only the named film's releases can have changed, so a film that
                // is neither in the list nor wishlisted now cannot have altered it, and
                // reloading for one is a full-library scan that provably reproduces the
                // list already on screen.
                //
                // This does NOT narrow the drag-reorder path — reorderWishlist emits one
                // of these per film whose position moved, and every one of those films is
                // in the list by construction, so the gate passes. Those reloads are
                // absorbed by the change guard in loadWishlistReleases instead. What the
                // gate removes is the unrelated traffic: any release edit on any film that
                // has nothing on the wishlist previously rescanned the whole library here.
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

    private func loadWishlistReleases() {
        // Built by WishlistRelease.rows, which owns the ordering rule and which the
        // whole-library PDF export calls as well, so the printed sheet and this list
        // cannot number the wishlist differently.
        let rebuilt = WishlistRelease.rows(pairs: dataCoordinator.getWishlistReleases())

        // Assign only on an actual change, for the reason HallOfFameView's equivalent load
        // documents — and more acutely here. A single drag-reorder calls reorderWishlist,
        // which emits one .film(.releaseChanged) per film whose position moved, and
        // AppEventBus is a PassthroughSubject, so onFilmEvent runs those handlers
        // SYNCHRONOUSLY from inside the List's own onMove callback. Each one reloads, and
        // each reload is a full-library release scan plus a sort. Without this guard every
        // one of them also reassigned the whole @State array — @State does not compare on
        // assignment — invalidating and rebuilding the List mid-drag, once per shifted
        // film, to arrive at the order handleMove had already applied locally. The mount
        // path's deferred reconciling load benefits identically.
        if rebuilt != releases {
            releases = rebuilt
        }

        // Update ReportsState so the status bar count reflects the new list.
        // Always called: ReportsState does its own change detection and additionally needs
        // the first call in order to mark the category as loaded.
        ReportsState.shared.updateWishlistData(rebuilt)

        pruneSelectionToLiveRows()
    }

    /// Drops any selected row id that no longer names a row, after a reload has replaced
    /// `releases`.
    ///
    /// One prune in place of per-branch cleanup in the event handler, which could not cover
    /// the cases it needed to:
    ///
    ///   • `.deleted` computed its "which rows went away" set from `releases` AFTER the
    ///     reload had already removed them, so the set was always empty and the stale
    ///     selection was never cleared.
    ///   • `.updated` only cleaned up when a film left the wishlist ENTIRELY. Un-wishlisting
    ///     one of a film's two wishlisted releases left the vanished row's id selected.
    ///   • `.releaseChanged` — the path an un-tick from the FilmSheet actually travels —
    ///     reloaded with no cleanup at all.
    ///
    /// Pruning against the surviving rows answers all three with the same test, and cannot
    /// go stale the way a precomputed "removed" set does.
    ///
    /// `ReportsRankedListView` observes `selection` and calls `onSelectionChange`, so the
    /// mapping back into `SelectionState` (including the clear when nothing is left) happens
    /// through the normal path rather than being duplicated here.
    ///
    /// Deferred one run loop pass, and re-derived from `releases` at that point rather than
    /// captured: clearing synchronously lets the List's underlying NSTableView re-sync its
    /// stale row selection back into the binding before it has processed the data source
    /// change. Same reasoning, and same deferral, as HallOfFameView's clear.
    private func pruneSelectionToLiveRows() {
        guard !selection.isEmpty else { return }
        guard !selection.isSubset(of: Set(releases.map(\.id))) else { return }
        DispatchQueue.main.async {
            selection.formIntersection(Set(releases.map(\.id)))
        }
    }

    // MARK: - Reorder

    private func handleMove(from source: IndexSet, to destination: Int) {
        var updated = releases
        updated.move(fromOffsets: source, toOffset: destination)

        // Re-number positions.
        for index in updated.indices {
            updated[index].position = index + 1
        }

        releases = updated
        persistCurrentOrder()
        ReportsState.shared.updateWishlistData(releases)
    }

    // MARK: - Persistence

    /// Pushes the current display order back into the model via DataCoordinator,
    /// which updates MemoryStore immediately and debounces the SwiftData write.
    private func persistCurrentOrder() {
        let orderedPairs = releases.map { (filmID: $0.filmID, releaseID: $0.releaseID) }
        dataCoordinator.reorderWishlist(orderedPairs)
    }

    // MARK: - Selection

    private func handleSelectionChange(_ newSelection: Set<UUID>) {
        // newSelection contains WishlistRelease.id values (which equal the release UUIDs).
        // Map back to film IDs for SelectionState so the RightSidebar shows the film.
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

/// Value type representing a single wishlist row in the Release Wishlist report tab.
/// Conforms to `RankedItem` so that `ReportsRankedListView` reads the stored
/// `position` directly rather than computing it from array index.
struct WishlistRelease: Identifiable, Equatable, RankedItem {
    // `id` is the release UUID — used as the List row identity and for selection.
    var id: UUID { releaseID }

    var position: Int
    let filmID: UUID
    let filmName: String
    let releaseID: UUID

    // Display fields
    let studio: String
    let releaseYear: String
    let format: String
    let independence: String
    let marketAvailability: String

    /// The format badge text shown in the row.
    ///
    /// The STORED format verbatim ("4K UHD", "Blu-ray", "DVD"), which is what the other
    /// format badges of the same kind show — the ReleaseCard header badge (33.20) and the
    /// right sidebar's release cards (24.20) both render `format` directly. This row used
    /// to abbreviate to "4K" / "BD" via `ReleaseFormat.badge(for:)`, so the same disc was
    /// named two different ways depending on which pane the user was looking at.
    ///
    /// Passing the stored string through also keeps an unrecognized format truthful, which
    /// was the abbreviation helper's own reason for existing.
    var formatBadge: String { format }

    /// The wishlist's rows, numbered in display order, from the (film, release) pairs the
    /// store hands back.
    ///
    /// Sorted by stored wishlist position (ascending). All positions are >= 1 under normal
    /// operation because FSTabReleases.handleWishlistToggle issues a real position the
    /// moment the Wishlisted trait is ticked.
    ///
    /// The release id breaks ties, which makes this a TOTAL order. Positions are unique
    /// under current operation — handleWishlistToggle issues each new one above every
    /// position in use, so it cannot duplicate an existing slot — but a library written by
    /// a build that derived positions from a count can carry a duplicate pair, and
    /// `sorted(by:)` is not stable. Without a tiebreak those two rows could swap between
    /// one load of this report and the next, which then persists as a real reordering the
    /// moment the user drags anything (reorderWishlist rewrites the entire sequence from
    /// the displayed order). The tiebreak costs nothing when positions are unique and is
    /// never reached in that case.
    ///
    /// The single definition of what a wishlist row is and what order it sits in:
    /// `ReleaseWishlistView` shows these and `LibraryPDFExporter` prints them.
    static func rows(
        pairs: [(film: FilmSnapshot, release: ReleaseSnapshot)]
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
                releaseYear: pair.release.releaseYear,
                format: pair.release.format,
                // Shortened for the 72 pt Independence column: see
                // ReleaseIndependence.compactDisplay. Only ever narrows
                // "Combo-pack (dual BD)", which the column cannot fit; every other value
                // passes through unchanged.
                independence: ReleaseIndependence.compactDisplay(pair.release.independence),
                marketAvailability: pair.release.marketAvailability.first ?? ""
            )
        }
    }
}
