// MARK: - Harness.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Standalone gallery-list change-detection harness — NOT part of the app target.
//
// Mirrors, verbatim in behavior, the three decision procedures that
// 23.30 GalleryListView.swift's DraggableListView.updateNSView runs on every pass:
//
//   • filmsChanged / sectionInputsChanged / queueBandsNotDerivableFromFilms
//       → whether the row model is rebuilt at all          (the "Change Detection" block)
//   • idSequenceChanged
//       → whether the table takes a full reloadData        (same block)
//   • Coordinator.rebuildRowModel() + GallerySectioning.displayedSectionBreaks
//       → the row model itself                             (rebuildRowModel / computeSectionBreaks)
//
// Transcribed rather than imported, exactly as the ReleaseCardStateEquivalence and
// ReleaseYearOrdering harnesses carry their own models: the shipped code lives inside an
// NSViewRepresentable Coordinator in an @Observable app target that cannot be built with
// swiftc alone. Any edit to the originals must be mirrored here — the tests are only
// evidence about the code they copy.
//
// The scroll-clamp test at the end is the exception: it exercises real AppKit
// (NSClipView.constrainBoundsRect) rather than a transcription, so it is evidence about
// AppKit itself.
import AppKit

// MARK: - Transcribed model types

struct Section: Equatable { let id: String; let displayName: String }

enum RowItem: Equatable {
    case divider(section: Section, filmCount: Int)
    case film(index: Int)
    var isDivider: Bool { if case .divider = self { return true }; return false }
    var rowHeight: CGFloat { isDivider ? 70 : 44 }   // kListSectionDividerHeight / kListRowHeight
}

/// The FilmSnapshot subset the row model and the change gate actually read.
/// `queueSection` stands in for DataCoordinator.filmQueueSection(forFilm:) — deliberately
/// held OUTSIDE the snapshot, exactly as MemoryStore list membership is in the app.
struct Film: Equatable {
    let id: Int
    var band: String      // whatever the active sort's section resolves to
    var title: String     // a rendered field that does NOT affect banding
}

/// ← Coordinator.SectionInputs (23.30 GalleryListView.swift)
struct SectionInputs: Equatable {
    var showSortingSections: Bool
    var queueFilter: String?      // "all" is the Film Queue's unnarrowed union
    var sortOption: String?
    var recentsCategory: String?
}

// MARK: - Transcribed row-model build

/// ← GallerySectioning.bandFilmCount
func bandFilmCount(from startIndex: Int, nextBandIndex: Int?, totalCount: Int) -> Int {
    max(0, (nextBandIndex ?? totalCount) - startIndex)
}

/// ← GallerySectioning.displayedSectionBreaks. `queueSections` is the out-of-band
/// membership the Film Queue's "All" tab bands from; every other view bands from `band`.
func displayedSectionBreaks(films: [Film], inputs: SectionInputs,
                            queueSections: [Int: String]) -> [(index: Int, section: Section)] {
    guard !films.isEmpty else { return [] }
    guard inputs.queueFilter != "all" else {
        var breaks: [(index: Int, section: Section)] = []
        var last: String?
        for (i, f) in films.enumerated() {
            guard let s = queueSections[f.id] else { continue }
            if last != s { breaks.append((i, Section(id: "queue.\(s)", displayName: s))) }
            last = s
        }
        return breaks
    }
    guard inputs.showSortingSections, inputs.sortOption != nil || inputs.recentsCategory != nil
    else { return [] }
    var breaks: [(index: Int, section: Section)] = []
    var seen = Set<String>()
    var last: Section?
    for (i, f) in films.enumerated() {
        let s = Section(id: "sort.\(f.band)", displayName: f.band)
        if last != s {
            guard seen.insert(s.id).inserted else { return [] }   // contiguity guard
            breaks.append((i, s))
        }
        last = s
    }
    return breaks
}

/// ← Coordinator.rebuildRowModel
func buildRowModel(films: [Film], inputs: SectionInputs,
                   queueSections: [Int: String]) -> (rows: [RowItem], height: CGFloat) {
    let breaks = displayedSectionBreaks(films: films, inputs: inputs, queueSections: queueSections)
    var nextBreak = 0
    var items: [RowItem] = []
    for (index, _) in films.enumerated() {
        if nextBreak < breaks.count, breaks[nextBreak].index == index {
            let next = (nextBreak + 1) < breaks.count ? breaks[nextBreak + 1].index : nil
            items.append(.divider(section: breaks[nextBreak].section,
                                  filmCount: bandFilmCount(from: index, nextBandIndex: next,
                                                           totalCount: films.count)))
            nextBreak += 1
        }
        items.append(.film(index: index))
    }
    return (items, items.reduce(0) { $0 + $1.rowHeight })
}

// MARK: - Transcribed change detection

struct Decision {
    var rebuilds: Bool
    var fullReload: Bool
    /// The visible-row refresh: the `else if filmsChanged` branch after the full reload.
    var visibleRefresh: Bool
}

/// ← the "Change Detection" block in DraggableListView.updateNSView, verbatim in structure.
func decide(oldFilms: [Film], newFilms: [Film],
            lastInputs: SectionInputs?, newInputs: SectionInputs,
            isViewSwitch: Bool,
            oldRows: [RowItem], newRowsIfRebuilt: [RowItem]) -> Decision {
    let filmsChanged = oldFilms != newFilms
    let sectionInputsChanged = lastInputs != newInputs
    let queueBandsNotDerivableFromFilms = newInputs.queueFilter == "all"
    let idSequenceChanged = filmsChanged &&
        !oldFilms.elementsEqual(newFilms) { $0.id == $1.id }

    let rebuilds = filmsChanged || sectionInputsChanged || queueBandsNotDerivableFromFilms
    let effectiveRows = rebuilds ? newRowsIfRebuilt : oldRows
    let rowModelChanged = effectiveRows != oldRows
    let fullReload = isViewSwitch || idSequenceChanged || rowModelChanged
    return Decision(rebuilds: rebuilds,
                    fullReload: fullReload,
                    visibleRefresh: !fullReload && filmsChanged)
}

/// ← the reload predicate this change REPLACED, kept so the superset property is testable.
func legacyReloadPredicate(oldFilms: [Film], newFilms: [Film],
                           isViewSwitch: Bool, rowModelChanged: Bool) -> Bool {
    let countChanged = oldFilms.count != newFilms.count
    let firstOrLastChanged = !oldFilms.isEmpty && !newFilms.isEmpty &&
        (oldFilms.first?.id != newFilms.first?.id || oldFilms.last?.id != newFilms.last?.id)
    return isViewSwitch || countChanged || firstOrLastChanged || rowModelChanged
}

// MARK: - Instrumentation for the CoW short-circuit test
nonisolated(unsafe) var comparisonCounter = 0
