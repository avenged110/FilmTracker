// MARK: - RecommendationsGrid.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Behind `Preferences.recommendationsEnabled` (experiment flag + Settings checkbox). The Recommendations view's grid
/// (29.50 RecommendationsView.swift).
///
/// It is the gallery's own grid with the view's extras laid into it, not a look-alike:
///  • the collection view is GalleryCollectionView (clicks, drags, the contextual menu);
///  • every poster is a real GalleryItem (tile, shadow, selection ring, edge sheen, poster loading),
///    hosted inside RecGridItem, which adds the view's overlay on top;
///  • cells are SmoothResizingGridLayout's cells: the same columns (columnMetrics), the same height
///    (ColumnMetrics.itemHeight) and the same spacing, so a poster here is a poster there at any width;
///  • the section bands are the gallery's SectionDividerDecorationView, with its optional subtitle.
/// Only two things are the view's own: RecGridLayout, which places the featured pick and the
/// double feature as rows of the grid with a card beside their posters, and those cards. A card
/// spans whole columns and is exactly one poster tall, so it scales as the posters do.
///
/// Hover follows PhotoGallery's GridHoverRouter: one tracking area on the collection view finds the
/// cell under the pointer, so at most one cell ever shows its controls and none can be left
/// showing them by a missed mouseExited (a reload, a scroll, a cell reused under the pointer).
///
/// HIT-TESTING. NSCollectionView.indexPathForItem(at:) finds a cell by hit-testing views and walking
/// up to an item's view. The poster is a nested NSCollectionViewItem's view (GalleryItem's), so a
/// point on it resolved to that item, which the collection view does not own, and so to no cell at
/// all: clicks, drags, the menu and hover all failed everywhere but outside the poster.
/// RecGridItemView therefore answers every hit inside the cell itself, except a visible overlay
/// control, which keeps its own clicks.

import AppKit
import SwiftUI

// MARK: - Content

/// Everything the grid draws, flattened to one item per poster in display order.
struct RecGridContent: Equatable {
    enum Role: Equatable { case hero, pick, wildcard, pairFirst, pairSecond }

    struct Entry: Equatable {
        let pick: RecPick
        let role: Role
    }

    struct Section: Equatable {
        let section: GallerySection
        /// The line under the band's title (SectionDividerLayoutAttributes.subtitle).
        let subtitle: String
        let range: Range<Int>
    }

    let entries: [Entry]
    let sections: [Section]
    let doubleFeature: RecDoubleFeature?
    /// Films the user asked for more of: their thumbs-up control shows filled.
    let liked: Set<UUID>

    init(result: RecResult, liked: Set<UUID>) {
        var entries: [Entry] = []
        var sections: [Section] = []
        func add(_ id: String, _ title: String, _ subtitle: String, _ picks: [RecPick], _ role: (Int) -> Role) {
            guard !picks.isEmpty else { return }
            let start = entries.count
            entries += picks.enumerated().map { Entry(pick: $1, role: role($0)) }
            sections.append(Section(section: GallerySection(id: "rec.\(id)", displayName: title),
                                    subtitle: subtitle, range: start..<entries.count))
        }
        add("hero", "Tonight’s Pick", "The best fit for tonight, out of every eligible film.",
            result.hero.map { [$0] } ?? []) { _ in .hero }
        add("picks", "More Picks for You", "Strong fits, spread across different reasons to watch.",
            Self.byMatch(result.picks)) { _ in .pick }
        add("wildcards", "Wildcards", "Films unlike anything you’ve watched in the past year.",
            Self.byMatch(result.wildcards)) { _ in .wildcard }
        if let pair = result.doubleFeature {
            add("double", "Double Feature", "Two strong picks tied by a person, a tag, or a list.",
                [pair.first, pair.second]) { $0 == 0 ? .pairFirst : .pairSecond }
        }
        self.entries = entries
        self.sections = sections
        self.doubleFeature = result.doubleFeature
        self.liked = liked.intersection(entries.map(\.pick.id))
    }

    /// Highest taste match first; equal matches keep the engine's order.
    private static func byMatch(_ picks: [RecPick]) -> [RecPick] {
        picks.enumerated()
            .sorted { $0.element.match != $1.element.match ? $0.element.match > $1.element.match : $0.offset < $1.offset }
            .map(\.element)
    }

    var hero: RecPick? { entries.first { $0.role == .hero }?.pick }
}

// MARK: - Grid View

struct RecGridView: NSViewRepresentable {
    let content: RecGridContent
    /// Read in the parent's body, so a selection made elsewhere (a feedback action clears it)
    /// reaches the grid.
    let selectedIDs: Set<UUID>
    let model: RecommendationsModel
    let dataCoordinator: DataCoordinator

    @AppStorage(preference: Preferences.largeGalleryGridKey) private var largeGalleryGrid: Bool

    func makeCoordinator() -> RecGridCoordinator { RecGridCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = RecGridScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.scrollerStyle = .overlay
        scrollView.usesPredominantAxisScrolling = false
        scrollView.wantsLayer = true
        scrollView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        /// As the gallery's scroll view (GallerySubview.configureScrollView): the grid never holds the
        /// window wider than the space it is given, so its width, and with it every column, is the
        /// gallery's at any window size.
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let collectionView = GalleryCollectionView()
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.wantsLayer = true
        collectionView.layerContentsRedrawPolicy = .onSetNeedsDisplay

        let layout = RecGridLayout()
        layout.maxColumns = largeGalleryGrid ? Preferences.galleryMaxColumnsLargeGrid : Preferences.galleryMaxColumns
        collectionView.collectionViewLayout = layout
        collectionView.register(RecGridItem.self, forItemWithIdentifier: RecGridItem.identifier)
        layout.register(SectionDividerDecorationView.self, forDecorationViewOfKind: sectionDividerDecorationKind)
        collectionView.register(RecBannerView.self, forSupplementaryViewOfKind: RecGridLayout.bannerKind,
                                withIdentifier: RecBannerView.identifier)

        let coordinator = context.coordinator
        coordinator.attach(collectionView: collectionView, scrollView: scrollView, layout: layout)
        coordinator.update(content: content, model: model, dataCoordinator: dataCoordinator)
        collectionView.dataSource = coordinator
        collectionView.delegate = coordinator
        scrollView.documentView = collectionView
        coordinator.syncSelection(selectedIDs)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let maxColumns = largeGalleryGrid ? Preferences.galleryMaxColumnsLargeGrid : Preferences.galleryMaxColumns
        coordinator.setMaxColumns(maxColumns)
        coordinator.update(content: content, model: model, dataCoordinator: dataCoordinator)
        coordinator.syncSelection(selectedIDs)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: RecGridCoordinator) {
        coordinator.detach()
    }
}

/// As the gallery's WidthObservingScrollView does: no implicit animation while a resize lays the
/// grid out, so cells track the window instead of easing after it.
final class RecGridScrollView: NSScrollView {
    override func layout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        super.layout()
        CATransaction.commit()
    }
}

// MARK: - Coordinator

@MainActor
final class RecGridCoordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSPopoverDelegate {
    private weak var collectionView: GalleryCollectionView?
    private weak var scrollView: NSScrollView?
    private weak var layout: RecGridLayout?
    private weak var model: RecommendationsModel?
    private weak var dataCoordinator: DataCoordinator?
    private var content: RecGridContent?
    private let hoverRouter = RecHoverRouter()
    private var boundsObserver: (any NSObjectProtocol)?
    private var lastClipOrigin: NSPoint?
    /// Set while the grid's selection is written from the model, so the write is not echoed back.
    private var isSyncingSelection = false

    /// The open Why? popover, the film it explains, and the last one to close (for the toggle).
    private var whyPopover: NSPopover?
    private var whyFilmID: UUID?
    private var lastClosedWhy: (filmID: UUID, at: TimeInterval)?

    func attach(collectionView: GalleryCollectionView, scrollView: NSScrollView, layout: RecGridLayout) {
        self.collectionView = collectionView
        self.scrollView = scrollView
        self.layout = layout

        collectionView.getContextMenu = { [weak self] in self?.contextMenu(forItemAt: $0) }
        collectionView.getFilmID = { [weak self] in self?.filmID(at: $0) }
        collectionView.getDragFilmIDs = { [weak self, weak collectionView] indexPath in
            guard let self else { return [] }
            if let indexPath, let id = self.filmID(at: indexPath) { return [id] }
            return Set((collectionView?.selectionIndexPaths ?? []).compactMap { self.filmID(at: $0) })
        }
        collectionView.getPosterImage = { [weak self] filmID in
            guard let pick = self?.content?.entries.first(where: { $0.pick.id == filmID })?.pick,
                  !pick.posterUID.isEmpty else { return nil }
            return PosterCache.shared.dragPreviewImage(for: pick.posterUID)
        }
        collectionView.onArrowNavigation = { [weak self] direction, _, _ in self?.moveSelection(direction) }
        /// A click on empty space clears the grid's selection (GalleryCollectionView's marquee start);
        /// the app's selection follows, as the gallery's does. A marquee selects nothing here.
        collectionView.onMarqueeSelectionChanged = { [weak self] _ in self?.selectionClearedByGrid() }
        /// One film at a time (ViewCapabilities.supportsMultiSelection is off for this view).
        collectionView.onSelectAll = { false }

        hoverRouter.install(on: collectionView)
        /// The Why popover belongs to its cell's overlay: the pointer may cross into it, and it closes
        /// when the overlay goes (the pointer leaving both the cell and the popover).
        hoverRouter.keepsHover = { [weak self] in self?.isPointerInWhyPopover() ?? false }
        hoverRouter.onHoverChange = { [weak self] indexPath in
            guard let self, let whyPopover = self.whyPopover, whyPopover.isShown else { return }
            if indexPath.flatMap({ self.filmID(at: $0) }) != self.whyFilmID { whyPopover.close() }
        }
        /// A scroll moves cells under a pointer that is not moving, which raises no mouse events, and
        /// moves a popover's anchor out from under it.
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        lastClipOrigin = clip.bounds.origin
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clipBoundsChanged() }
        }
    }

    func detach() {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        hoverRouter.uninstall()
        whyPopover?.close()
    }

    private func clipBoundsChanged() {
        hoverRouter.resync()
        /// As every popover in the app does on a scroll; a resize keeps the origin and the popover.
        guard let origin = scrollView?.contentView.bounds.origin, origin != lastClipOrigin else { return }
        lastClipOrigin = origin
        if whyPopover?.isShown == true { whyPopover?.close() }
    }

    func setMaxColumns(_ maxColumns: Int) {
        guard let layout, layout.maxColumns != maxColumns else { return }
        layout.maxColumns = maxColumns
        layout.invalidateLayout()
    }

    func update(content: RecGridContent, model: RecommendationsModel, dataCoordinator: DataCoordinator) {
        self.model = model
        self.dataCoordinator = dataCoordinator
        guard content != self.content else { return }
        /// Only the thumbs-up states changed (a More Like This, before the pass it starts returns):
        /// set them on the cells that exist rather than rebuilding every cell.
        if let old = self.content, old.entries == content.entries, old.sections == content.sections,
           old.doubleFeature == content.doubleFeature, let collectionView {
            self.content = content
            for (index, entry) in content.entries.enumerated() {
                (collectionView.item(at: IndexPath(item: index, section: 0)) as? RecGridItem)?
                    .setLiked(content.liked.contains(entry.pick.id))
            }
            return
        }
        self.content = content
        layout?.content = content
        layout?.buildsEveryElement = false
        hoverRouter.clear()
        /// The reload replaces the cell the popover points from.
        whyPopover?.close()
        collectionView?.reloadData()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            /// The reload replaced the cells under the pointer; the one now there takes the hover.
            self.hoverRouter.resync()
            /// Then, once the visible rows have drawn, the rest of the grid is built while nothing
            /// moves: every cell below the fold and the double feature's card. Built on the first
            /// scroll instead, they cost a hitch there (the card's SwiftUI hosting view above all,
            /// partway down the page). The grid holds at most about thirty elements.
            guard let layout = self.layout, let collectionView = self.collectionView else { return }
            layout.buildsEveryElement = true
            layout.invalidateLayout()
            collectionView.layoutSubtreeIfNeeded()
        }
    }

    // MARK: Lookup

    private func entry(at indexPath: IndexPath) -> RecGridContent.Entry? {
        guard indexPath.section == 0, let entries = content?.entries,
              entries.indices.contains(indexPath.item) else { return nil }
        return entries[indexPath.item]
    }

    func filmID(at indexPath: IndexPath) -> UUID? { entry(at: indexPath)?.pick.id }

    private func indexPath(of filmID: UUID) -> IndexPath? {
        content?.entries.firstIndex { $0.pick.id == filmID }.map { IndexPath(item: $0, section: 0) }
    }

    // MARK: Data Source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        content?.entries.count ?? 0
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let item = collectionView.makeItem(withIdentifier: RecGridItem.identifier, for: indexPath) as? RecGridItem,
              let entry = entry(at: indexPath), let content else { return NSCollectionViewItem() }
        let pick = entry.pick
        let film = dataCoordinator?.getFilm(pick.id)
        item.configure(pick: pick, film: film, isLiked: content.liked.contains(pick.id),
                       showsSubtitle: entry.role != .hero) { [weak self] action, sender in
            self?.perform(action, on: pick, from: sender)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: RecBannerView.identifier, for: indexPath)
        guard let banner = view as? RecBannerView, let content, let model, let dataCoordinator else { return view }
        switch indexPath.item {
        case RecGridLayout.heroBannerItem:
            if let hero = content.hero {
                banner.show(AnyView(RecHeroPanel(pick: hero, model: model, dataCoordinator: dataCoordinator)))
            }
        default:
            if let pair = content.doubleFeature {
                banner.show(AnyView(RecPairPanel(pair: pair)))
            }
        }
        return banner
    }

    // MARK: Selection

    /// The gallery's own click handling (GalleryCollectionView.mouseDown) calls this for a click on
    /// a poster. The view selects one film at a time, whatever the modifiers.
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !isSyncingSelection else { return }
        guard let clicked = indexPaths.first, let id = filmID(at: clicked) else { return }
        if collectionView.selectionIndexPaths != [clicked] { collectionView.selectionIndexPaths = [clicked] }
        SelectionState.shared.select([id], inputKind: .fromCurrentAppKitEvent())
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        guard !isSyncingSelection, collectionView.selectionIndexPaths.isEmpty else { return }
        SelectionState.shared.select(Set<UUID>(), inputKind: .fromCurrentAppKitEvent())
    }

    private func selectionClearedByGrid() {
        guard let collectionView else { return }
        if !collectionView.selectionIndexPaths.isEmpty {
            isSyncingSelection = true
            collectionView.selectionIndexPaths = []
            isSyncingSelection = false
        }
        SelectionState.shared.select(Set<UUID>(), inputKind: .fromCurrentAppKitEvent())
    }

    func syncSelection(_ selectedIDs: Set<UUID>) {
        /// A click's own selection is still on its way to SelectionState; the next pass syncs.
        guard let collectionView, !SelectionState.shared.hasPendingSelection else { return }
        let paths = Set(selectedIDs.compactMap { indexPath(of: $0) })
        guard collectionView.selectionIndexPaths != paths else { return }
        isSyncingSelection = true
        collectionView.selectionIndexPaths = paths
        isSyncingSelection = false
    }

    /// Left and Right step through the picks in order; Up and Down move to the nearest poster in
    /// the row above or below.
    private func moveSelection(_ direction: ArrowDirection) {
        guard let collectionView, let layout, let count = content?.entries.count, count > 0 else { return }
        let current = collectionView.selectionIndexPaths.first?.item
        let target: Int?
        switch direction {
        case .left:  target = current.map { max(0, $0 - 1) } ?? 0
        case .right: target = current.map { min(count - 1, $0 + 1) } ?? 0
        case .up, .down:
            guard let current, let from = layout.layoutAttributesForItem(at: IndexPath(item: current, section: 0))?.frame
            else { target = 0; break }
            let below = direction == .down
            target = (0..<count)
                .compactMap { index -> (Int, NSRect)? in
                    layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0)).map { (index, $0.frame) }
                }
                .filter { below ? $0.1.minY > from.minY + 1 : $0.1.minY < from.minY - 1 }
                .min { lhs, rhs in
                    let dy = (abs(lhs.1.minY - from.minY), abs(rhs.1.minY - from.minY))
                    if abs(dy.0 - dy.1) > 1 { return dy.0 < dy.1 }
                    return abs(lhs.1.midX - from.midX) < abs(rhs.1.midX - from.midX)
                }?.0
        }
        guard let target, target != current, let id = filmID(at: IndexPath(item: target, section: 0)) else { return }
        let path = IndexPath(item: target, section: 0)
        isSyncingSelection = true
        collectionView.selectionIndexPaths = [path]
        isSyncingSelection = false
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        SelectionState.shared.selectImmediate([id], inputKind: .discrete)
    }

    // MARK: Contextual Menu

    private func contextMenu(forItemAt indexPath: IndexPath) -> NSMenu? {
        guard let collectionView, let id = filmID(at: indexPath) else { return nil }
        if collectionView.selectionIndexPaths != [indexPath] {
            isSyncingSelection = true
            collectionView.selectionIndexPaths = [indexPath]
            isSyncingSelection = false
        }
        /// Edit Metadata… and Edit Releases… read SelectionState, so it is written at once.
        SelectionState.shared.selectImmediate([id], inputKind: .fromCurrentAppKitEvent())
        guard let menu = GalleryContextMenu.makeMenu(for: [id]) else { return nil }
        for item in model?.menuItems(for: id) ?? [] { menu.addItem(item) }
        return menu
    }

    // MARK: Overlay Actions

    private func perform(_ action: RecOverlayAction, on pick: RecPick, from sender: NSView) {
        guard let model else { return }
        let filmID = pick.id
        switch action {
        case .why:
            showWhy(for: pick, from: sender)
        case .moreLikeThis:
            if model.feedback.liked[filmID] != nil { model.forget(filmID) } else { model.moreLikeThis(filmID) }
        case .lessLikeThis: model.lessLikeThis(filmID)
        case .notNow:       model.notNow(filmID)
        case .never:        model.neverRecommend(filmID)
        }
    }

    // MARK: Why? Popover

    /// Opens the reasons for a pick beside its Why? control. A second click on the same control closes
    /// it, whichever way AppKit delivers that click: a transient popover closes itself on the click
    /// outside it, and the click then reaches the control, so a click on the control of the popover
    /// that is open, or of one this very click just closed, opens nothing (as DVCanvasPageView's
    /// popovers do).
    private func showWhy(for pick: RecPick, from anchor: NSView) {
        if let whyPopover, whyPopover.isShown, whyFilmID == pick.id {
            whyPopover.performClose(nil)
            return
        }
        if let closed = lastClosedWhy, closed.filmID == pick.id,
           let clickTime = NSApp.currentEvent?.timestamp, closed.at >= clickTime {
            return
        }
        whyPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        /// Leaving the popover re-aims the hover: back over the cell keeps it, anywhere else closes it.
        popover.contentViewController = RecExitTrackingController(rootView: RecWhyPopover(pick: pick)) { [weak self] in
            self?.hoverRouter.resync()
        }
        /// The real size before it shows, so the arrow points where it should from the first frame.
        popover.contentSize = RecWhyPopover.size
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        whyPopover = popover
        whyFilmID = pick.id
    }

    private func isPointerInWhyPopover() -> Bool {
        guard let whyPopover, whyPopover.isShown, let window = unsafe whyPopover.contentViewController?.view.window else { return false }
        return window.frame.contains(NSEvent.mouseLocation)
    }

    func popoverWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPopover, closing === whyPopover, let whyFilmID else { return }
        lastClosedWhy = (whyFilmID, ProcessInfo.processInfo.systemUptime)
        self.whyFilmID = nil
    }
}

// MARK: - Layout

/// SmoothResizingGridLayout's geometry, row for row: its columns (columnMetrics), its cell height
/// (ColumnMetrics.itemHeight), its spacing and its band frames. The rows are the view's: a band, then
/// the section's posters. The featured pick and the double feature are rows whose spare columns
/// hold a card (a supplementary view) one poster tall; when too few columns are spare, the card
/// takes the next row, across the whole grid.
final class RecGridLayout: NSCollectionViewLayout {
    static let bannerKind = "RecBannerPanel"
    static let heroBannerItem = 0
    static let pairBannerItem = 1
    /// A card is never narrower than two posters beside its own; with fewer columns spare it goes
    /// below them instead.
    private static let minimumCardColumns = 2

    private let edgeInset = SmoothResizingGridLayout.edgeInset
    private let lineSpacing = SmoothResizingGridLayout.lineSpacing
    /// A band here carries a subtitle, which makes it that much taller than the gallery's.
    private let dividerHeight = SmoothResizingGridLayout.dividerHeight + SectionDividerDecorationView.subtitleHeight

    var maxColumns = Preferences.galleryMaxColumns
    var content: RecGridContent? {
        didSet { invalidateLayout() }
    }
    /// When true, every element is reported for any rect, so the collection view builds (and keeps)
    /// the whole grid rather than only the rows near the visible ones (RecGridCoordinator.update).
    var buildsEveryElement = false

    private var itemAttributes: [NSCollectionViewLayoutAttributes] = []
    private var decorationAttributes: [NSCollectionViewLayoutAttributes] = []
    private var bannerAttributes: [Int: NSCollectionViewLayoutAttributes] = [:]
    private var contentSize: NSSize = .zero
    private var preparedWidth: CGFloat = -1

    override func prepare() {
        super.prepare()
        itemAttributes = []
        decorationAttributes = []
        bannerAttributes = [:]
        guard let collectionView, let content, !content.entries.isEmpty else {
            contentSize = .zero
            return
        }
        let width = collectionView.enclosingScrollView?.bounds.width ?? collectionView.bounds.width
        preparedWidth = width
        let scale = unsafe collectionView.window?.backingScaleFactor ?? 2.0
        let metrics = SmoothResizingGridLayout.columnMetrics(scrollWidth: width, scale: scale, maxColumns: maxColumns)
        let columns = metrics.columnsPerRow

        /// Column origins and widths in backing pixels, the first columns taking the remainder, as
        /// SmoothResizingGridLayout spreads it.
        let basePx = metrics.itemTotalPx / columns
        let remainder = metrics.itemTotalPx % columns
        var columnX: [CGFloat] = []
        var columnWidth: [CGFloat] = []
        var xPx = metrics.edgePx
        for column in 0..<columns {
            let widthPx = basePx + (column < remainder ? 1 : 0)
            columnX.append(CGFloat(metrics.gridOffsetPx + xPx) / scale)
            columnWidth.append(CGFloat(widthPx) / scale)
            xPx += widthPx + metrics.spacingPx
        }
        /// The gallery's cell heights: the poster from the exact average column width, plus the
        /// subtitle band (the year, runtime and rating) under every poster but the featured pick's.
        let heroHeight = metrics.itemHeight(hasSubtitles: false)
        let subtitledHeight = metrics.itemHeight(hasSubtitles: true)
        let gridX = metrics.gridOffsetX + edgeInset
        let gridWidth = max(0, metrics.gridWidth - 2 * edgeInset)
        let padding = GalleryTileGeometry.posterPadding

        var y = edgeInset
        func item(_ index: Int, column: Int, rowY: CGFloat, height: CGFloat) {
            let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
            attributes.frame = NSRect(x: columnX[column], y: rowY, width: columnWidth[column], height: height)
            itemAttributes.append(attributes)
        }
        /// A card over columns `first...last` of the row at `rowY`, drawn where a poster would be: inside
        /// the cells' 2 pt margins, from the top, and exactly one poster tall
        /// (GalleryTileGeometry.posterRect for the first column's cell).
        func card(_ bannerItem: Int, from first: Int, to last: Int, rowY: CGFloat) {
            let x = columnX[first] + padding
            let right = columnX[last] + columnWidth[last] - padding
            let posterHeight = (columnWidth[first] - 2 * padding) * GalleryTileGeometry.posterHeightMultiplier
            let attributes = NSCollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.bannerKind,
                                                              with: IndexPath(item: bannerItem, section: 0))
            attributes.frame = NSRect(x: x, y: rowY + padding, width: max(0, right - x), height: posterHeight)
            bannerAttributes[bannerItem] = attributes
        }
        /// Posters in columns from 0, then the card: beside them when enough columns are spare, else on
        /// the next row across the whole grid. One column stacks the posters too.
        func featureRow(_ range: Range<Int>, bannerItem: Int, cellHeight: CGFloat) {
            let stacksPosters = columns == 1
            for (offset, index) in range.enumerated() {
                if stacksPosters, offset > 0 { y += cellHeight + lineSpacing }
                item(index, column: stacksPosters ? 0 : offset, rowY: y, height: cellHeight)
            }
            let used = stacksPosters ? 1 : range.count
            if columns - used >= Self.minimumCardColumns {
                card(bannerItem, from: used, to: columns - 1, rowY: y)
            } else {
                y += cellHeight + lineSpacing
                card(bannerItem, from: 0, to: columns - 1, rowY: y)
            }
            y += cellHeight
        }

        for (ordinal, section) in content.sections.enumerated() {
            if ordinal > 0 { y += lineSpacing }
            let divider = SectionDividerLayoutAttributes(forDecorationViewOfKind: sectionDividerDecorationKind,
                                                         with: IndexPath(item: ordinal, section: 0))
            divider.frame = NSRect(x: gridX, y: y, width: gridWidth, height: dividerHeight)
            divider.section = section.section
            divider.filmCount = section.range.count
            divider.subtitle = section.subtitle
            decorationAttributes.append(divider)
            y += dividerHeight + lineSpacing

            switch content.entries[section.range.lowerBound].role {
            case .hero:
                featureRow(section.range, bannerItem: Self.heroBannerItem, cellHeight: heroHeight)
            case .pairFirst, .pairSecond:
                featureRow(section.range, bannerItem: Self.pairBannerItem, cellHeight: subtitledHeight)
            case .pick, .wildcard:
                let cellHeight = subtitledHeight
                let rows = (section.range.count + columns - 1) / columns
                for (offset, index) in section.range.enumerated() {
                    item(index, column: offset % columns, rowY: y + CGFloat(offset / columns) * (cellHeight + lineSpacing),
                         height: cellHeight)
                }
                y += CGFloat(rows) * cellHeight + CGFloat(max(0, rows - 1)) * lineSpacing
            }
        }
        /// Items are looked up by index; build order follows the sections, which follow the entries.
        itemAttributes.sort { ($0.indexPath?.item ?? 0) < ($1.indexPath?.item ?? 0) }
        contentSize = NSSize(width: width, height: y + edgeInset)
    }

    override var collectionViewContentSize: NSSize { contentSize }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let all = itemAttributes + decorationAttributes + bannerAttributes.values
        return buildsEveryElement ? all : all.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        itemAttributes.indices.contains(indexPath.item) ? itemAttributes[indexPath.item] : nil
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: NSCollectionView.SupplementaryElementKind,
                                                       at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        elementKind == Self.bannerKind ? bannerAttributes[indexPath.item] : nil
    }

    override func layoutAttributesForDecorationView(ofKind elementKind: NSCollectionView.DecorationElementKind,
                                                     at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard elementKind == sectionDividerDecorationKind, decorationAttributes.indices.contains(indexPath.item) else { return nil }
        return decorationAttributes[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(newBounds.width - preparedWidth) > 0.01
    }
}

// MARK: - Item

enum RecOverlayAction { case why, moreLikeThis, lessLikeThis, notNow, never }

/// A gallery cell (GalleryItem, unchanged, as a child) with the view's overlay above the poster.
final class RecGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("RecGridItem")

    private let tile = GalleryItem()
    fileprivate let overlay = RecPosterOverlay()
    private let subtitle = RecSubtitleRow()

    override func loadView() {
        let container = RecGridItemView()
        container.item = self
        view = container
        addChild(tile)
        let tileView = tile.view
        tileView.frame = container.bounds
        tileView.autoresizingMask = [.width, .height]
        container.addSubview(tileView)
        container.addSubview(subtitle)
        container.addSubview(overlay)
    }

    override var isSelected: Bool {
        didSet { tile.isSelected = isSelected }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tile.prepareForReuse()
        overlay.setControlsVisible(false, animated: false)
    }

    func configure(pick: RecPick, film: FilmSnapshot?, isLiked: Bool, showsSubtitle: Bool,
                   onAction: @escaping @MainActor (RecOverlayAction, NSView) -> Void) {
        if let film { tile.configure(with: film, subtitleProvider: nil) }
        subtitle.isHidden = !showsSubtitle
        if showsSubtitle { subtitle.configure(pick: pick) }
        tile.isSelected = isSelected
        overlay.configure(pick: pick, isLiked: isLiked, onAction: onAction)
        view.setAccessibilityLabel(pick.year.isEmpty ? pick.name : "\(pick.name), \(pick.year)")
        view.needsLayout = true
    }

    func setLiked(_ liked: Bool) { overlay.setLiked(liked) }

    /// Called by RecHoverRouter only, which keeps at most one cell hovered.
    func setHovered(_ hovered: Bool) {
        overlay.setControlsVisible(hovered)
    }

    /// Lays the overlay over the poster. The container is unflipped, as GalleryItem's own view is,
    /// so GalleryTileGeometry's rect applies unchanged.
    fileprivate func layoutExtras(in bounds: NSRect) {
        guard let poster = GalleryTileGeometry.posterRect(inCellBounds: bounds) else { return }
        overlay.frame = poster
        /// The gallery's subtitle band: the same gap below the poster (clear of the selection ring).
        let height = RecSubtitleRow.height
        subtitle.frame = NSRect(x: poster.minX, y: max(0, poster.minY - RecSubtitleRow.topGap - height),
                                width: poster.width, height: height)
    }
}

private final class RecGridItemView: NSView {
    weak var item: RecGridItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        /// The tile's shadow and selection ring reach past the cell, as in the gallery.
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        item?.layoutExtras(in: bounds)
    }

    /// The cell answers for every point inside it, so NSCollectionView.indexPathForItem(at:), which
    /// hit-tests, finds this cell rather than the GalleryItem nested in it (see the file's
    /// HIT-TESTING note). A visible overlay control is the one exception and takes its own clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = unsafe convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let item, let control = item.overlay.hitTest(local) { return control }
        return self
    }
}

// MARK: - Subtitle

/// The year and runtime under a poster: the year at the poster's left edge, the runtime at its
/// right edge, led by the unwatched glyph for a film never watched. In the gallery's subtitle type
/// and color (GalleryTileContentView), with monospaced digits so equal values line up across posters.
private final class RecSubtitleRow: NSView {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    /// GalleryTileContentView.subtitleTopGap: the selection ring's full overhang.
    static let topGap: CGFloat = GalleryTileGeometry.ringGap + Preferences.selectionLineWidth
    static let height: CGFloat = ceil(font.ascender - font.descender + font.leading) + 1
    static let unwatchedGlyph = "eye.slash.fill"
    /// Between the glyph's right edge and the runtime's first digit.
    private static let glyphGap: CGFloat = 2

    private let unwatched = NSImageView()
    private let yearLabel = RecSubtitleRow.label(.left)
    private let runtimeLabel = RecSubtitleRow.label(.right)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        unwatched.imageScaling = .scaleNone
        unwatched.contentTintColor = .secondaryLabelColor
        unwatched.image = Self.unwatchedImage
        for view in [unwatched, yearLabel, runtimeLabel] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func label(_ alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = .secondaryLabelColor
        label.alignment = alignment
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        return label
    }

    /// Built once: the glyph is the same for every poster.
    private static let unwatchedImage = NSImage(systemSymbolName: unwatchedGlyph, accessibilityDescription: "Not watched yet")?
        .withSymbolConfiguration(.init(pointSize: 8.5, weight: .semibold))

    func configure(pick: RecPick) {
        unwatched.isHidden = pick.watched
        yearLabel.stringValue = pick.year.isEmpty ? "—" : pick.year
        runtimeLabel.stringValue = pick.runtimeMinutes.map(recCompactRuntime) ?? "—"
        var parts = [pick.year.isEmpty ? "No release year" : "Released in \(pick.year)"]
        if !pick.watched { parts.append("Not watched yet") }
        parts.append(pick.runtimeMinutes.map(recRuntime) ?? "No runtime")
        toolTip = parts.joined(separator: ", ")
        setAccessibilityLabel(toolTip)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        let labelHeight = ceil(yearLabel.intrinsicContentSize.height)
        let labelY = ((height - labelHeight) / 2).rounded()
        /// The year and the runtime each take an outer half, so neither moves with the other's length.
        yearLabel.frame = NSRect(x: 0, y: labelY, width: width / 2, height: labelHeight)
        runtimeLabel.frame = NSRect(x: width / 2, y: labelY, width: width / 2, height: labelHeight)
        guard !unwatched.isHidden else { return }
        /// The glyph just left of the runtime's text, centered on the digits' cap height and a point
        /// high so it reads level with them (as the slashed star it replaces was).
        let glyphSize = unwatched.image?.size ?? .zero
        let baseline = labelY + labelHeight - runtimeLabel.firstBaselineOffsetFromTop
        let glyphY = (baseline + (Self.font.capHeight - glyphSize.height) / 2 + 1).rounded()
        /// The label's own 2 pt inset (NSTextField's line fragment padding) sits right of its text.
        let textWidth = ceil(runtimeLabel.intrinsicContentSize.width)
        let textX = runtimeLabel.frame.maxX - textWidth
        unwatched.frame = NSRect(x: (textX + 2 - Self.glyphGap - glyphSize.width).rounded(), y: glyphY,
                                 width: glyphSize.width, height: glyphSize.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Poster Overlay

/// What sits on the poster: one pill (top right) with the kind of pick and the taste match, and, on
/// hover, five round controls in two rows: More Like This and Less Like This above; Why (the brain),
/// Not Now and Never below. Every shape is a dark tint over a blur of the poster beneath it, with a
/// soft shadow around it (RecBlurBacking). Only the controls take clicks. The year, runtime and
/// rating are the cell's subtitle, under the poster.
private final class RecPosterOverlay: NSView {
    fileprivate static let inset: CGFloat = 7
    /// The pill: 20% larger than the two badges it replaced (20 pt tall, 10 pt type).
    fileprivate static let pillHeight: CGFloat = 24
    fileprivate static let pillFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
    private static let pillGlyphPoints: CGFloat = 12
    /// Glyphs drawn wider than the others at 12 pt, at the size that fits them in the 16 pt
    /// slot like the rest: the Queue glyph is 18 pt wide at 12 pt and ran into the padding.
    private static let pillGlyphPointOverrides: [String: CGFloat] = [ViewGlyphs.filmQueue.outline: 10]
    private static let pillGlyphWidth: CGFloat = 16
    private static let pillPadding: CGFloat = 9
    private static let pillGap: CGFloat = 4
    /// Fixed for any score (20…99), so the pill never changes size and one mask serves every cell.
    private static let matchTextWidth: CGFloat = {
        let label = RecPlate.label(font: pillFont)
        label.stringValue = "99%"
        return ceil(label.intrinsicContentSize.width) + 2
    }()
    fileprivate static let pillWidth: CGFloat = pillPadding + pillGlyphWidth + pillGap + matchTextWidth + pillPadding - 2

    /// The controls: twice their former 24 pt where the poster has room for three across, smaller
    /// on narrower posters so the bottom row always fits.
    private static let maxButtonSize: CGFloat = 48
    private static let buttonSpacing: CGFloat = 8
    /// Between the two rows: room enough to aim a click.
    private static let rowSpacing: CGFloat = 10
    private static let controlsBottomInset: CGFloat = 12
    /// Clear space around the circles inside the controls' container, so neither the blur's mask nor
    /// the container's edge can shave the antialiased rim off a circle (the bottom row lost its
    /// lowest pixel row where the circles touched the container's edge).
    private static let controlsMargin: CGFloat = 2

    private let backing = RecBlurBacking(mask: RecBlurBacking.pillMask)
    private let pill = RecPlate()
    private let laneImage = NSImageView()
    private let matchLabel = RecPlate.label(font: RecPosterOverlay.pillFont)

    private let controls = RecControlsView()
    private let controlsBacking = RecBlurBacking(mask: nil)
    /// Thumbs up, thumbs down, Why (brain), Not Now, Never.
    private var buttons: [RecOverlayButton] = []
    private var onAction: (@MainActor (RecOverlayAction, NSView) -> Void)?
    private var controlsVisible = false
    /// The overlay size and button size the shadows were last cut for.
    private var shadowsCutFor: (bounds: NSSize, button: CGFloat)?
    private var controlsButtonSize: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        addSubview(backing)
        laneImage.contentTintColor = .white
        laneImage.imageScaling = .scaleNone
        matchLabel.alignment = .left
        pill.addSubview(laneImage)
        pill.addSubview(matchLabel)
        addSubview(pill)

        controls.wantsLayer = true
        controls.alphaValue = 0
        controls.addSubview(controlsBacking)
        for (action, glyph, help) in [
            (RecOverlayAction.moreLikeThis, "hand.thumbsup", "More like this"),
            (.lessLikeThis, "hand.thumbsdown", "Less like this (and hide it for 90 days)"),
            (.why, "brain", "Why this film was picked"),
            (.notNow, "moon.zzz", "Not now (hide it for 30 days)"),
            (.never, "xmark", "Never recommend this film"),
        ] {
            let button = RecOverlayButton(glyph: glyph, help: help) { [weak self] sender in self?.onAction?(action, sender) }
            buttons.append(button)
            controls.addSubview(button)
        }
        addSubview(controls)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(pick: RecPick, isLiked: Bool, onAction: @escaping @MainActor (RecOverlayAction, NSView) -> Void) {
        self.onAction = onAction
        laneImage.image = RecOverlayButton.image(pick.lane.glyph,
                                                 points: Self.pillGlyphPointOverrides[pick.lane.glyph] ?? Self.pillGlyphPoints)
        laneImage.image?.accessibilityDescription = pick.lane.title
        matchLabel.stringValue = "\(pick.match)%"
        pill.toolTip = "\(pick.lane.title). Taste match \(pick.match)%: How well the film fits what the engine has learned you like"
        setLiked(isLiked)
        needsLayout = true
    }

    func setLiked(_ isLiked: Bool) {
        buttons.first?.setGlyph(isLiked ? "hand.thumbsup.fill" : "hand.thumbsup",
                                help: isLiked ? "Forget “More Like This”" : "More like this")
    }

    /// A hidden control is transparent and, through hitTest, unclickable.
    func setControlsVisible(_ visible: Bool, animated: Bool = true) {
        guard visible != controlsVisible else { return }
        controlsVisible = visible
        guard animated else {
            controls.alphaValue = visible ? 1 : 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.12 : 0.1
            controls.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// Every frame is set here, in one pass, each label centered by its own measured height.
    override func layout() {
        super.layout()
        let scale = unsafe window?.backingScaleFactor ?? 2
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let inset = Self.inset, height = Self.pillHeight

        pill.frame = NSRect(x: bounds.width - inset - Self.pillWidth, y: inset, width: Self.pillWidth, height: height)
        backing.frame = pill.frame
        laneImage.frame = NSRect(x: Self.pillPadding - 2, y: 0, width: Self.pillGlyphWidth, height: height)
        let matchHeight = ceil(matchLabel.intrinsicContentSize.height)
        matchLabel.frame = NSRect(x: laneImage.frame.maxX + Self.pillGap, y: snap((height - matchHeight) / 2),
                                  width: Self.matchTextWidth, height: matchHeight)
        pill.updateCorners()

        let spacing = Self.buttonSpacing, margin = Self.controlsMargin
        let size = max(16, min(Self.maxButtonSize, floor((bounds.width - 2 * inset - 2 * spacing) / 3)))
        let width = 3 * size + 2 * spacing, controlsHeight = 2 * size + Self.rowSpacing
        /// On whole backing pixels: a container on a fractional row cut its bottom pixel row.
        controls.frame = NSRect(x: snap((bounds.width - width) / 2) - margin,
                                y: snap(bounds.height - Self.controlsBottomInset - controlsHeight) - margin,
                                width: width + 2 * margin, height: controlsHeight + 2 * margin)
        if size != controlsButtonSize { layoutControls(size: size) }

        /// The shadows fall on the poster only, never past its rounded edge onto the window: each is
        /// cut to the poster's shape, given in its own backing's space.
        if shadowsCutFor?.bounds != bounds.size || shadowsCutFor?.button != size {
            shadowsCutFor = (bounds.size, size)
            backing.setShadowShapes([backing.bounds], clip: bounds.offsetBy(dx: -pill.frame.minX, dy: -pill.frame.minY))
            controlsBacking.setShadowShapes(buttons.map(\.frame),
                                            clip: bounds.offsetBy(dx: -controls.frame.minX, dy: -controls.frame.minY))
        }
    }

    /// Two on top, centered over the three below: the lower two rows of a pyramid.
    private func layoutControls(size: CGFloat) {
        controlsButtonSize = size
        let frames = Self.controlFrames(size: size)
        for (button, frame) in zip(buttons, frames) {
            button.frame = frame
            button.glyphPoints = (size * 0.42).rounded()
            button.updateCorners()
        }
        controlsBacking.frame = controls.bounds
        controlsBacking.setMask(RecBlurBacking.circlesMask(size: size, canvas: controls.bounds.size, frames: frames))
    }

    /// The five controls' frames in the controls' flipped space, in `buttons` order, inside the
    /// container's clear margin.
    private static func controlFrames(size: CGFloat) -> [NSRect] {
        let spacing = buttonSpacing, margin = controlsMargin
        let topX = margin + (size + spacing) / 2
        let lowerY = margin + size + rowSpacing
        return [
            NSRect(x: topX, y: margin, width: size, height: size),
            NSRect(x: topX + size + spacing, y: margin, width: size, height: size),
            NSRect(x: margin, y: lowerY, width: size, height: size),
            NSRect(x: margin + size + spacing, y: lowerY, width: size, height: size),
            NSRect(x: margin + 2 * (size + spacing), y: lowerY, width: size, height: size),
        ]
    }

    /// Only a visible control takes a click; the poster's own clicks, drags and menu belong to the grid.
    /// `point` is in the superview's coordinates, as for any hitTest.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard controlsVisible else { return nil }
        let local = controls.convert(unsafe convert(point, from: superview), from: self)
        return buttons.first { button in
            let frame = button.frame
            let dx = local.x - frame.midX, dy = local.y - frame.midY, radius = frame.width / 2
            return dx * dx + dy * dy <= radius * radius
        }
    }
}

/// The controls' container: flipped, like the overlay.
private final class RecControlsView: NSView {
    override var isFlipped: Bool { true }
}

/// The blur and shadow under an overlay's shapes. One NSVisualEffectView (as PhotoGallery's hover bar
/// uses: `.withinWindow`, so it blurs the poster drawn beneath it) is masked to all of the shapes at
/// once, so a poster costs one blur, not one per shape. The shadow is a layer below the blur with
/// its interior cut away, so it darkens around a shape, never inside it.
private final class RecBlurBacking: NSView {
    /// A plain CALayer, not a view's layer: AppKit owns the shadow properties of a view's backing
    /// layer (NSView.shadow) and reset the ones set here, which is why no shadow ever showed.
    private let shadowLayer = CALayer()
    private let shadowMask = CAShapeLayer()
    private let effect = NSVisualEffectView()
    /// The shadow, strong enough to lift the shapes off a busy or light poster. Tuned together:
    /// the reach must cover the blur (about twice the radius) plus the offset.
    private static let shadowOpacity: Float = 0.9
    private static let shadowRadius: CGFloat = 8
    private static let shadowOffset = CGSize(width: 0, height: -2)
    /// How far past the shapes the shadow can reach; the mask covers all of it.
    private static let shadowReach: CGFloat = 2 * shadowRadius + abs(shadowOffset.height) + 4

    /// Unflipped, so its layers and the mask image share AppKit's y-up space.
    override var isFlipped: Bool { false }

    init(mask: NSImage?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        shadowLayer.masksToBounds = false
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = Self.shadowOpacity
        shadowLayer.shadowRadius = Self.shadowRadius
        shadowLayer.shadowOffset = Self.shadowOffset
        shadowLayer.actions = ["shadowPath": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        shadowMask.fillRule = .evenOdd
        shadowMask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        shadowLayer.mask = shadowMask
        /// Added before the blur's view, so it sits beneath the blur's layer.
        layer?.addSublayer(shadowLayer)

        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.maskImage = mask
        addSubview(effect)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = bounds
        CATransaction.commit()
        effect.frame = bounds
    }

    func setMask(_ mask: NSImage) { effect.maskImage = mask }

    /// The shapes' frames, each a capsule or circle, and `clip`, the poster the shadow may fall on,
    /// both in this view's flipped space (the overlay's, moved to this view's origin).
    func setShadowShapes(_ frames: [NSRect], clip: NSRect) {
        let height = bounds.height
        let reach = Self.shadowReach
        let path = CGMutablePath()
        let maskFrame = bounds.insetBy(dx: -reach, dy: -reach)
        let maskPath = CGMutablePath()
        /// The poster's rounded shape, unflipped and in the mask's space; the shapes are cut out of it.
        let clipRect = NSRect(x: clip.minX + reach, y: height - clip.maxY + reach, width: clip.width, height: clip.height)
        maskPath.addPath(CGPath.continuousRoundedRect(clipRect, cornerRadius: Preferences.cornerRadius))
        for frame in frames {
            let rect = NSRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
            let radius = min(rect.width, rect.height) / 2
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
            maskPath.addRoundedRect(in: rect.offsetBy(dx: reach, dy: reach), cornerWidth: radius, cornerHeight: radius)
        }
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = path
        /// The mask's own frame covers the shadow's whole reach, so no part of the shadow falls
        /// outside the mask layer's bounds (where it would be cut off): the path is drawn in the
        /// mask's space, offset by the reach.
        shadowMask.frame = maskFrame
        shadowMask.path = maskPath
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Masks

    /// The pill at exactly its own size: the blur's frame is the pill's, so nothing stretches. (A
    /// stretched mask, as before, smeared the pill's edge down the poster and left it nearly clear.)
    static let pillMask: NSImage = {
        let size = NSSize(width: RecPosterOverlay.pillWidth, height: RecPosterOverlay.pillHeight)
        return NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                         xRadius: size.height / 2, yRadius: size.height / 2).fill()
            return true
        }
    }()

    /// The controls' circles at their current size, in the controls' flipped space. Drawn lazily
    /// (a drawing handler). Every poster in a grid shares one button size, so the last mask made is
    /// kept and handed to every cell of that size rather than drawn again for each.
    static func circlesMask(size: CGFloat, canvas: NSSize, frames: [NSRect]) -> NSImage {
        if let cached = lastCirclesMask, cached.size == size, cached.canvas == canvas { return cached.image }
        let image = NSImage(size: canvas, flipped: true) { _ in
            NSColor.black.setFill()
            for frame in frames { NSBezierPath(ovalIn: frame).fill() }
            return true
        }
        lastCirclesMask = (size, canvas, image)
        return image
    }
    @MainActor private static var lastCirclesMask: (size: CGFloat, canvas: NSSize, image: NSImage)?
}

/// A shape's tint and hairline edge, over RecBlurBacking's blur.
private final class RecPlate: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        RecPlate.style(layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static let tint = NSColor.black.withAlphaComponent(0.3).cgColor
    /// A control's tint while it is held down: darker, as a pressed button darkens elsewhere.
    static let pressedTint = NSColor.black.withAlphaComponent(0.6).cgColor

    static func style(_ layer: CALayer?) {
        guard let layer else { return }
        layer.backgroundColor = tint
        layer.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer.borderWidth = 0.5
        layer.cornerCurve = .continuous
        layer.actions = ["cornerRadius": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
    }

    func updateCorners() {
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    static func label(font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        return label
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A feedback control on a poster: a real round NSButton with a glyph, tinted over the
/// controls' blur.
private final class RecOverlayButton: NSButton {
    private let handler: @MainActor (NSView) -> Void

    private init(help: String, handler: @escaping @MainActor (NSView) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        /// First, before any other setting: replacing the cell resets the button's.
        let cell = RecOverlayButtonCell()
        cell.onHighlight = { [weak self] pressed in self?.showPressed(pressed) }
        self.cell = cell
        isBordered = false
        bezelStyle = .regularSquare
        imageScaling = .scaleNone
        contentTintColor = .white
        focusRingType = .none
        wantsLayer = true
        RecPlate.style(layer)
        target = self
        action = #selector(fire)
        toolTip = help
        setAccessibilityLabel(help)
    }

    convenience init(glyph: String, help: String, handler: @escaping @MainActor (NSView) -> Void) {
        self.init(help: help, handler: handler)
        imagePosition = .imageOnly
        setGlyph(glyph, help: help)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var glyph = ""
    /// Scales with the control (RecPosterOverlay.layoutControls).
    var glyphPoints: CGFloat = 11 {
        didSet { if glyphPoints != oldValue { setGlyph(glyph, help: toolTip ?? "") } }
    }

    func setGlyph(_ glyph: String, help: String) {
        self.glyph = glyph
        image = RecOverlayButton.image(glyph, points: glyphPoints)
        image?.accessibilityDescription = help
        toolTip = help
        setAccessibilityLabel(help)
    }

    func updateCorners() {
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    /// Built once per glyph and size and shared by every poster's controls, so a new cell copies
    /// a reference instead of building ten symbol images.
    private static var images: [String: NSImage] = [:]
    static func image(_ glyph: String, points: CGFloat) -> NSImage? {
        let key = "\(glyph)@\(points)"
        if let image = images[key] { return image.copy() as? NSImage }
        guard let image = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: points, weight: .semibold)) else { return nil }
        images[key] = image
        return image.copy() as? NSImage
    }

    /// Held down: the plate darkens and the glyph dims, until the button is let go or the pointer
    /// leaves it (AppKit's own tracking calls the cell's highlight either way).
    private func showPressed(_ pressed: Bool) {
        layer?.backgroundColor = pressed ? RecPlate.pressedTint : RecPlate.tint
        contentTintColor = pressed ? NSColor.white.withAlphaComponent(0.65) : .white
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func fire() { handler(self) }
}

/// Reports AppKit's press highlight, which a borderless, layer-tinted button otherwise never shows.
private final class RecOverlayButtonCell: NSButtonCell {
    var onHighlight: (@MainActor (Bool) -> Void)?

    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        super.highlight(flag, withFrame: cellFrame, in: controlView)
        onHighlight?(flag)
    }
}

// MARK: - Why? Popover

/// A pick's reasons as a bulleted list, at one size for every pick.
struct RecWhyPopover: View {
    static let size = NSSize(width: 300, height: 220)
    let pick: RecPick

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                /// The year here too: the popover can cover the poster's own.
                (Text(pick.name) + Text(pick.year.isEmpty ? "" : " (\(pick.year))").foregroundStyle(.secondary))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                /// Not a Label: its icon-to-title gap is wider than this small line wants.
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: pick.lane.glyph)
                    Text("\(pick.lane.title) · \(pick.match)% taste match")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 9)

            Divider()
                .padding(.horizontal, 14)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 7) {
                    if pick.reasons.isEmpty {
                        Text("Nothing in particular stood out. It scores well across the board.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(pick.reasons, id: \.self) { reason in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text(reason.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
    }
}

/// A popover's SwiftUI content in a view that reports the pointer leaving it.
private final class RecExitTrackingController: NSViewController {
    private let rootView: RecWhyPopover
    private let onExit: @MainActor () -> Void

    init(rootView: RecWhyPopover, onExit: @escaping @MainActor () -> Void) {
        self.rootView = rootView
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let container = RecExitTrackingView(onExit: onExit)
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        view = container
    }
}

private final class RecExitTrackingView: NSView {
    private let onExit: @MainActor () -> Void

    init(onExit: @escaping @MainActor () -> Void) {
        self.onExit = onExit
        super.init(frame: NSRect(origin: .zero, size: RecWhyPopover.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseExited(with event: NSEvent) { onExit() }
}

// MARK: - Hover Router

/// PhotoGallery's GridHoverRouter (32.00 GallerySubview.swift there), for this grid: one tracking
/// area on the collection view, following the pointer and finding the cell beneath it. Exactly
/// one cell is hovered at a time, and the router, not the cell, decides which, so a cell can never
/// be left showing its controls by a mouseExited that never came. The view calls resync() after a
/// scroll or a reload, which move cells under a pointer that has not moved.
@MainActor
final class RecHoverRouter: NSResponder {
    private weak var collectionView: NSCollectionView?
    private var trackingArea: NSTrackingArea?
    private weak var hoveredCell: RecGridItem?
    private var hoveredIndexPath: IndexPath?
    private var resignObserver: (any NSObjectProtocol)?
    /// True while the pointer is over something that belongs to the hovered cell outside the grid
    /// (its open Why popover): the cell stays hovered rather than clearing.
    var keepsHover: (() -> Bool)?
    /// Each change of hovered cell, nil when none.
    var onHoverChange: ((IndexPath?) -> Void)?

    func install(on collectionView: NSCollectionView) {
        guard trackingArea == nil else { return }
        self.collectionView = collectionView
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        collectionView.addTrackingArea(area)
        trackingArea = area
        /// `.activeInKeyWindow` stops events when the window resigns key, with no exit to follow.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let resigned = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let window = unsafe self.collectionView?.window,
                      resigned == ObjectIdentifier(window) else { return }
                self.clear()
            }
        }
    }

    func uninstall() {
        if let trackingArea { collectionView?.removeTrackingArea(trackingArea) }
        trackingArea = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        clear()
    }

    override func mouseEntered(with event: NSEvent) { track(event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { track(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { if keepsHover?() != true { clear() } }

    func clear() { setHovered(nil, at: nil) }

    /// Re-aims at whatever is under the pointer now.
    func resync() {
        guard trackingArea != nil, let collectionView, let window = unsafe collectionView.window,
              window.isKeyWindow || keepsHover?() == true else { clear(); return }
        track(window.convertPoint(fromScreen: NSEvent.mouseLocation))
    }

    /// indexPathForItem(at:) hit-tests, which RecGridItemView answers for its whole cell.
    private func track(_ windowPoint: NSPoint) {
        guard let collectionView else { return clear() }
        let point = collectionView.convert(windowPoint, from: nil)
        guard collectionView.visibleRect.contains(point),
              let indexPath = collectionView.indexPathForItem(at: point),
              let cell = collectionView.item(at: indexPath) as? RecGridItem
        else {
            if keepsHover?() == true { return }
            return clear()
        }
        setHovered(cell, at: indexPath)
    }

    private func setHovered(_ cell: RecGridItem?, at indexPath: IndexPath?) {
        guard cell !== hoveredCell || indexPath != hoveredIndexPath else { return }
        hoveredCell?.setHovered(false)
        hoveredCell = cell
        hoveredIndexPath = indexPath
        cell?.setHovered(true)
        onHoverChange?(indexPath)
    }
}

// MARK: - Cards

/// The supplementary view holding a row's card: SwiftUI, one or two per grid.
final class RecBannerView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("RecBannerView")
    private var hostingView: NSHostingView<AnyView>?

    func show(_ view: AnyView) {
        if let hostingView {
            hostingView.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.sizingOptions = []
            hosting.frame = bounds
            hosting.autoresizingMask = [.width, .height]
            addSubview(hosting)
            hostingView = hosting
        }
    }
}

/// A card's shape: the field edge the right sidebar and FilmSheet fields wear, rounded to the
/// gallery's poster corner so the card matches the poster beside it.
private struct RecCardBackground: ViewModifier {
    private static let style: FieldEdgeStyle = {
        var style = FieldEdgeStyle.standard
        style.cornerRadius = Preferences.cornerRadius
        return style
    }()

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .fieldEdgeChrome(Self.style, clipsContent: true)
    }
}

/// The featured pick's card, one poster tall beside its poster. The details give way to the height
/// in steps, longest synopsis first, so the card reads whole from two posters wide upward.
private struct RecHeroPanel: View {
    let pick: RecPick
    var model: RecommendationsModel
    let dataCoordinator: DataCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                /// The year as the Why popover's title shows it: secondary, in parentheses.
                (Text(pick.name) + Text(pick.year.isEmpty ? "" : " (\(pick.year))").foregroundStyle(.secondary))
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if let metaLine {
                    metaLine
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ViewThatFits(in: .vertical) {
                details(synopsisLines: 6, reasonLines: 2, reasons: pick.reasons.count)
                details(synopsisLines: 4, reasonLines: 2, reasons: pick.reasons.count)
                details(synopsisLines: 2, reasonLines: 1, reasons: pick.reasons.count)
                details(synopsisLines: 0, reasonLines: 1, reasons: pick.reasons.count)
                details(synopsisLines: 0, reasonLines: 1, reasons: 2)
                details(synopsisLines: 0, reasonLines: 1, reasons: 1)
                Color.clear.frame(height: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(alignment: .center, spacing: 10) {
                addButton
                if upNextIsFull {
                    Text("“Up Next” already holds the maximum of \(FilmQueue.upNextCapacity) films")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .modifier(RecCardBackground())
    }

    private func details(synopsisLines: Int, reasonLines: Int, reasons: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if synopsisLines > 0, !pick.synopsis.isEmpty {
                Text(pick.synopsis)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(synopsisLines)
                    .frame(maxWidth: 640, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(pick.reasons.prefix(reasons), id: \.self) { reason in
                    RecReasonRow(reason: reason)
                        .lineLimit(reasonLines)
                }
            }
        }
    }

    /// The certification, genre, runtime and director. An unwatched film's runtime is led by the
    /// unwatched glyph, as under the other posters; with no runtime known, the glyph stands alone.
    private var metaLine: Text? {
        var parts: [Text] = []
        if !pick.certification.isEmpty { parts.append(Text(pick.certification)) }
        if !pick.genre.isEmpty { parts.append(Text(pick.genre)) }
        let runtime = pick.runtimeMinutes.map(recRuntime)
        if !pick.watched {
            let glyph = Text(Image(systemName: RecSubtitleRow.unwatchedGlyph)).accessibilityLabel("Not watched yet")
            parts.append(runtime.map { glyph + Text(" \($0)") } ?? glyph)
        } else if let runtime {
            parts.append(Text(runtime))
        }
        if !pick.byline.isEmpty { parts.append(Text(pick.byline)) }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + Text("  ·  ") + $1 }
    }

    /// Up Next has no room for this film: the button is off and the note beside it says why.
    private var upNextIsFull: Bool {
        pick.queueSection != .upNext && FilmQueue.upNextOverflow(adding: [pick.id], coordinator: dataCoordinator) > 0
    }

    /// Edit and the rest are the selected film's, as in any gallery: a click on the poster selects it.
    private var addButton: some View {
        let section = pick.queueSection
        return Button {
            guard section != .upNext else { return }
            model.addToUpNext(pick.id, coordinator: dataCoordinator)
        } label: {
            Text(section == .upNext ? "In “Up Next”" : "Add to “Up Next”")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(section == .upNext || upNextIsFull)
    }
}

/// The double feature's card, one poster tall beside the pair.
private struct RecPairPanel: View {
    let pair: RecDoubleFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Label(pair.link, systemImage: pair.linkGlyph)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ViewThatFits(in: .vertical) {
                films(reasonLines: 2)
                films(reasonLines: 1)
                films(reasonLines: 0)
                Color.clear.frame(height: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(14)
        .modifier(RecCardBackground())
    }

    private var summary: String {
        var parts: [String] = []
        if let total = pair.totalMinutes { parts.append("\(recRuntime(total)) together") }
        parts.append("start with the \(pair.first.year.isEmpty ? "first" : pair.first.year) film")
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private func films(reasonLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            film(pair.first, label: "First", reasonLines: reasonLines)
            film(pair.second, label: "Then", reasonLines: reasonLines)
        }
    }

    private func film(_ pick: RecPick, label: String, reasonLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.tertiary)
                Text(pick.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            if reasonLines > 0, let reason = pick.reasons.first {
                RecReasonRow(reason: reason)
                    .lineLimit(reasonLines)
            }
        }
    }
}

struct RecReasonRow: View {
    let reason: RecReason
    var size: CGFloat = 12

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: reason.glyph)
                .font(.system(size: size - 1))
                .frame(width: size + 3)
                .foregroundStyle(.secondary)
            Text(reason.text)
                .font(.system(size: size))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Formatting

/// "2 hr 10 min", "95 min".
func recRuntime(_ minutes: Int) -> String {
    guard minutes >= 60 else { return "\(minutes) min" }
    let hours = minutes / 60, rest = minutes % 60
    return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
}

/// "2h 10m", "95m": for a subtitle under a poster.
func recCompactRuntime(_ minutes: Int) -> String {
    guard minutes >= 60 else { return "\(minutes)m" }
    let hours = minutes / 60, rest = minutes % 60
    return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
}
