// MARK: - GalleryListView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// SwiftUI List-based alternative to the NSCollectionView gallery grid.
// Activated when ViewState.isListView is true for the current view.
//
// Architecture: DraggableListView is a full NSViewRepresentable that owns a
// DraggableListTableView (an NSTableView subclass) directly — the same pattern
// GallerySubview uses for GalleryCollectionView. This gives us complete control
// over mouse events and allows NSTableView's native drag-as-source machinery
// to be used to trigger GalleryDragEngine's list-path drag preview.
//
// A manual, GalleryCollectionView-style mouseDown/mouseDragged/mouseUp bypass of
// this native machinery was tried and does NOT work: NSTableView.mouseDown(with:)
// runs its own internal, blocking event-tracking loop that consumes every
// subsequent mouseDragged/mouseUp event itself whenever a row is hit — those
// events never reach a subclass's own overrides at all, drag-eligible row or
// not. (NSCollectionView has no equivalent blocking behavior for an item hit,
// which is why GalleryCollectionView's manual approach works for the grid but
// has no NSTableView analog.) The native pipeline below is the only viable
// hook point.
//
// Unlike the grid, which uses the session's own NATIVE dragging-item image as
// its visible preview (window-server-driven; see GalleryDragEngine's class doc
// comment), the list path's visible preview is a separate, manually positioned
// borderless NSWindow (the "flyback window") — this app's original list-view
// drag mechanism, reinstated after the native per-item preview proved unable to
// track the cursor correctly for an NSTableView-originated session across
// several independent fix attempts. See GalleryDragEngine's class-level doc
// comment for the full rationale.
//
// Drag pipeline:
//   1. Coordinator implements tableView(_:pasteboardWriterForRow:), which registers
//      the film payload and causes NSTableView to detect drag gestures natively from
//      within its own mouseDown event-tracking loop — the only reliable hook point.
//   2. dragImageForRows(with:tableColumns:event:offset:) on DraggableListTableView
//      suppresses NSTableView's default row-snapshot drag image with an invisible
//      1×1 image (the `offset` value doesn't matter — this native item is never
//      actually shown).
//   3. tableView(_:draggingSession:willBeginAt:forRowIndexes:) fires when the drag
//      begins. We reconfirm the invisible 1×1 placeholder (belt-and-suspenders)
//      and call GalleryDragEngine.prepareDrag, which arms the flyback window at
//      the drag's starting screen point.
//   4. DraggableListTableView's own draggingSession(_:movedTo:) override (NSTableView
//      already conforms to NSDraggingSource) forwards each cursor move to
//      GalleryDragEngine.dragMoved(to:), which repositions the flyback window by
//      direct screen-point arithmetic.
//   5. The Coordinator's endedAt delegate callback forwards session end to
//      GalleryDragEngine.draggingSessionEnded, which animates the flyback window
//      back to its start point on cancel/fail, or dismisses it immediately on a
//      successful drop, then posts .dragSessionDidEnd (DragSessionMonitor bookkeeping).

import AppKit
import SwiftUI
import Combine

// MARK: - Scroll range

private extension NSScrollView {
    /// The largest valid vertical `contentView` bounds origin for a document of
    /// `contentHeight` — i.e. the position at which the document is scrolled as far up as
    /// AppKit will allow. Every programmatic scroll in this file clamps against it.
    ///
    /// Defined once because it is subtle in one specific way: `contentInsets.bottom` (29pt
    /// while the StatusBar overlay is shown) EXTENDS the scrollable range past the
    /// document's natural bottom edge. That is the entire reason the inset is set — so the
    /// last real row can scroll clear of the overlay instead of being stranded underneath
    /// it — and omitting the term capped every programmatic scroll 29pt short of where the
    /// user can drag the scroller by hand.
    ///
    /// The expression is NSClipView's own constraint, verified against
    /// `constrainBoundsRect` for a flipped document view (which NSTableView is): a
    /// 1000pt document in a 400pt viewport constrains to 600 with no insets and to 629
    /// with a 29pt bottom inset. `contentView.bounds.height` is the viewport height
    /// proper — the clip view is NOT itself inset by `contentInsets`, it spans the whole
    /// scroll view — so it is the direct statement of the quantity this needs, rather than
    /// `documentVisibleRect.height`, which merely happens to equal it.
    func maxVerticalScrollOffset(forContentHeight contentHeight: CGFloat) -> CGFloat {
        max(0, contentHeight + contentInsets.bottom - contentView.bounds.height)
    }
}

// MARK: - Drag placeholder image

private extension NSImage {
    /// The invisible 1×1 image used to suppress the list path's NATIVE drag preview, in
    /// both places AppKit offers to supply one: `dragImageForRows` (the definitive
    /// suppression point, called during session construction) and the belt-and-suspenders
    /// re-assertion in `willBeginAt`. Defined once so the two can never diverge — the
    /// real, visible preview is GalleryDragEngine's flyback window (see this file's
    /// header).
    ///
    /// Computed rather than a stored `static let`: a shared NSImage instance would be
    /// non-Sendable global state, and the object is a 1×1 bitmap constructed at most twice
    /// per drag gesture, so there is nothing worth caching.
    static var transparentDragPlaceholder: NSImage {
        NSImage(size: NSSize(width: 1, height: 1), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            return true
        }
    }
}

// MARK: - Row height constants
// Thumbnail height (36) + top padding (4) + bottom padding (4) = 44.
let kListRowHeight: CGFloat = 44

/// Height of a section-divider band's own CONTENT in the list gallery —
/// the label/count line plus the hairline rule beneath it. Deliberately shorter than the
/// grid's full-row divider band (see SectionDividerDecorationView in GalleryViewUI.swift):
/// a list row is 44pt tall rather than a whole poster tile, so a grid-proportioned band
/// would dwarf the content it separates.
let kListSectionDividerBandHeight: CGFloat = 38

/// Vertical breathing room added above AND below the band content, separating a divider
/// from the film rows on either side of it so the section break reads unmistakably rather
/// than as just another row.
let kListSectionDividerVerticalPadding: CGFloat = 16

/// The total row height a section divider occupies. Derived rather than stated, so the
/// band content and its padding can be retuned independently without the row height and
/// the view's own frame ever falling out of agreement — they are the same number by
/// construction, which matters because the scroll-restore math sums these heights
/// arithmetically (see Coordinator.listContentHeight).
let kListSectionDividerHeight: CGFloat =
    kListSectionDividerBandHeight + 2 * kListSectionDividerVerticalPadding

// MARK: - Row Item Model
//
// The list gallery's table is addressed in ROW space, which is not necessarily the same
// as FILM space: a sectioned view interleaves labeled section-divider rows between its
// groups, exactly as the grid does with its decoration-view bands. `ListRowItem` is the
// single mapping between the two spaces, and every row↔film conversion in this file goes
// through it (or through the Coordinator.filmRowMap it is built alongside).
//
// Whenever no bands apply — the Film Queue's "All" tab always has them, every other view
// only while this view's ViewState.showSectionDividers is on — the row model is built as a
// strict 1:1 `.film(index:)` sequence with no dividers whatsoever, so row index == film
// index and the mapping is an exact identity. The divider machinery therefore contributes
// nothing at all in that case, and cannot affect the gallery's behavior.
enum ListRowItem: Equatable {
    /// A labeled section band. `filmCount` is the number of real film rows
    /// that belong to this section, computed as the span to the next divider (or to the
    /// end of the film set) via GallerySectioning.bandFilmCount — the same call the grid's
    /// SmoothResizingGridLayout.filmCount(atOrdinal:) makes.
    case divider(section: GallerySection, filmCount: Int)
    /// A real film row, carrying its index into the Coordinator's `films` array.
    case film(index: Int)
    /// An empty "Up Next" placeholder slot (1-based number), shown only on the Film
    /// Queue's "All" tab after the "Up Next" films. Never selectable; see UpNextSlots.swift.
    case slot(number: Int)

    var isFilm: Bool {
        if case .film = self { return true }
        return false
    }

    var isDivider: Bool {
        if case .divider = self { return true }
        return false
    }

    /// The row's own height, used by both `heightOfRow` and the pure-arithmetic content
    /// height the scroll-restore math depends on, so the two can never disagree.
    var rowHeight: CGFloat {
        isDivider ? kListSectionDividerHeight : kListRowHeight
    }
}

// MARK: - List Scroll View

/// NSScrollView subclass for the list gallery, used to resolve a pending scroll target —
/// transferred from GalleryScrollIntent (ViewState.swift) — in viewWillDraw(), after
/// AppKit has laid out the view with real geometry, immediately before the first
/// frame is drawn.
///
/// Mirrors WidthObservingScrollView's identical technique in GallerySubview.swift
/// (see GalleryScrollIntent's and PendingScrollBehavior's doc comments in
/// ViewState.swift for the full rationale). Resolving here rather than directly in makeNSView
/// matters even though the table's row geometry is pure arithmetic on a fixed row
/// height: setting contentView bounds origin before the scroll view has been inserted
/// into the window and given a real frame is unreliable — AppKit's own layout pass can
/// silently reset it once the view acquires real geometry, which is exactly why every
/// deferred scroll in GallerySubview — the scroll-intent handoffs and the
/// "maintainScrollPositionOnViewSwitch" origin restore alike — resolves in
/// WidthObservingScrollView.viewWillDraw() rather than scrolling immediately, with
/// no pre-scroll flash frame because the origin is applied before the frame paints.
private final class ListScrollView: NSScrollView, Loggable {
    nonisolated static let logTag = "[DraggableListView]"

    /// Pending post-layout scroll target, transferred here from GalleryScrollIntent by
    /// DraggableListView.makeNSView (mirrors WidthObservingScrollView's identical field).
    var pendingScrollFilmID: UUID?
    /// How pendingScrollFilmID should be applied once geometry is available. See
    /// PendingScrollBehavior's doc comment (ViewState.swift) for the two cases. Every
    /// handoff uses the default, `.forceTop`; only the post-edit keep-in-view sets
    /// `.ifNeeded`, right before resolving. Reset to the default whenever a target resolves,
    /// so a handoff can never inherit a post-edit `.ifNeeded`.
    var pendingScrollBehavior: PendingScrollBehavior = .forceTop
    /// Pending post-layout scroll ORIGIN restore for the
    /// maintainScrollPositionOnViewSwitch feature, armed by
    /// DraggableListView.updateNSView's view-switch branch and resolved — and cleared —
    /// in viewWillDraw() below, exactly like pendingScrollFilmID. Mirrors
    /// WidthObservingScrollView's identically named field. Mutually exclusive with
    /// pendingScrollFilmID by construction (updateNSView only arms this when no film
    /// target is pending); should both ever be set, the film target wins and the
    /// superseded origin is discarded when it resolves.
    var pendingScrollPosition: GalleryScrollPosition?
    /// Pending keyboard-focus claim, transferred here from GalleryFocusIntent by
    /// DraggableListView.makeNSView (mirrors WidthObservingScrollView's identical field).
    /// Honored — and cleared — in viewWillDraw() below.
    var pendingKeyboardFocus = false
    /// Weak back-reference so viewWillDraw() can reach scrollFilmToTop(_:) and
    /// isRowVisible(_:). Wired in makeNSView.
    weak var listCoordinator: DraggableListView.Coordinator?

    override func viewWillDraw() {
        super.viewWillDraw()

        // Film-target resolution takes precedence; an origin armed alongside one can only
        // be a superseded leftover from an earlier pass and is discarded when the film
        // target resolves. Mirrors WidthObservingScrollView.viewWillDraw().
        if pendingScrollFilmID != nil {
            resolvePendingFilmTarget()
        } else if pendingScrollPosition != nil {
            resolvePendingOriginRestore()
        }

        resolvePendingKeyboardFocus()
    }

    /// Keyboard-focus claim for the search-exit handoff. Mirrors
    /// WidthObservingScrollView.resolvePendingKeyboardFocus — see there for why it is
    /// independent of the scroll resolution and deferred one turn.
    private func resolvePendingKeyboardFocus() {
        guard pendingKeyboardFocus, let window = unsafe window, let target = documentView else { return }
        pendingKeyboardFocus = false
        DispatchQueue.main.async { [weak window, weak target] in
            guard let window, let target, unsafe target.window === window else { return }
            window.makeFirstResponder(target)
        }
    }

    /// Film-target resolution for every scroll handoff (see GalleryScrollIntent in
    /// ViewState.swift for the producers) and for the post-edit keep-in-view. Mirrors
    /// WidthObservingScrollView.resolvePendingFilmTarget.
    private func resolvePendingFilmTarget() {
        guard let filmID = pendingScrollFilmID else { return }
        // If geometry isn't ready yet, this guard fails and pendingScrollFilmID is left
        // set — viewWillDraw fires again on the next display pass, so the target is
        // retained and retried automatically (matches WidthObservingScrollView's
        // identical guard-and-retry pattern).
        guard bounds.width > 0, documentVisibleRect.height > 0,
              let coordinator = listCoordinator else { return }

        guard let row = coordinator.rowIndex(for: filmID) else {
            // Film no longer present in this view's data — drop the stale target.
            pendingScrollFilmID = nil
            return
        }

        pendingScrollFilmID = nil
        // Discard any superseded origin restore (see viewWillDraw's precedence note),
        // both the copy armed here and the intent it was armed from — otherwise the
        // intent would simply be re-armed on the next update pass and fight this scroll.
        pendingScrollPosition = nil
        ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)
        let behavior = pendingScrollBehavior
        pendingScrollBehavior = .forceTop

        switch behavior {
        case .forceTop:
            // Every handoff: the film's row goes to the top of the viewport (as far as the
            // content allows), like Cmd+L, even when the film is already visible.
            coordinator.scrollFilmToTop(filmID)
            Self.log("Scroll handoff resolved pre-draw: film \(filmID) → row \(row)")
        case .ifNeeded:
            // Post-edit keep-in-view: a film still on screen is left alone.
            if !coordinator.isRowVisible(row) {
                coordinator.scrollFilmToTop(filmID)
                Self.log("Post-edit scroll resolved pre-draw: film \(filmID) → row \(row)")
            }
        }
    }

    /// Applies an armed origin restore immediately, if geometry already allows it.
    /// Mirrors WidthObservingScrollView.applyPendingOriginRestoreIfPossible() — see that
    /// method for why viewWillDraw alone is not sufficient on a reused gallery.
    func applyPendingOriginRestoreIfPossible() {
        resolvePendingOriginRestore()
    }

    /// Applies an armed film target immediately, if geometry already allows it. The list's
    /// copy of WidthObservingScrollView.applyPendingFilmTargetIfPossible() — see that
    /// method for why viewWillDraw alone is not sufficient on a reused gallery.
    func applyPendingFilmTargetIfPossible() {
        resolvePendingFilmTarget()
    }

    /// Saved-origin restore for the maintainScrollPositionOnViewSwitch feature, armed by
    /// DraggableListView.updateNSView's view-switch branch. Applied pre-draw (from
    /// viewWillDraw, or directly via applyPendingOriginRestoreIfPossible), so the first
    /// painted frame for the new view is already at the restored position.
    private func resolvePendingOriginRestore() {
        guard let position = pendingScrollPosition else { return }
        guard bounds.width > 0, documentVisibleRect.height > 0,
              let coordinator = listCoordinator else { return }

        // Content height is summed from the row model (see Coordinator.listContentHeight,
        // which accounts for the taller section-divider rows) rather than taken from the
        // document view's frame height, for exactly the reason spelled out in
        // Coordinator.scrollFilmToTop(_:): NSTableView's frame can still read 0 or stale
        // on the first viewWillDraw pass after a reload, which would collapse the clamp
        // below to 0 and force every restore back to the top. Pure arithmetic has no
        // dependency on AppKit's internal layout timing.
        let contentHeight = coordinator.listContentHeight
        guard contentHeight > 0 else {
            // No rows laid out yet — viewWillDraw fires again on the next display pass,
            // so the origin is retained and retried automatically (matching
            // resolvePendingFilmTarget's guard-and-retry pattern).
            return
        }

        pendingScrollPosition = nil
        // Retire the intent now that it has genuinely been applied against real geometry.
        // Until this point it stays live in ViewStateManager on purpose, so a reload that
        // lands between arming and resolution re-arms it rather than losing it.
        ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)

        let target = applyClampedOrigin(CGPoint(x: 0, y: coordinator.restoreY(for: position)),
                                        contentHeight: coordinator.scrollableContentHeight)
        Self.log("Saved scroll origin restored pre-draw: \(target)")
    }

    /// Moves the viewport to `origin`, clamped to the current valid scroll range: the
    /// view's content may have shrunk since the origin was saved (films deleted, filters
    /// changed before returning), and an out-of-range origin would leave the viewport in
    /// over-scrolled blank space.
    @discardableResult
    private func applyClampedOrigin(_ origin: CGPoint, contentHeight: CGFloat) -> NSPoint {
        let maxScrollY = maxVerticalScrollOffset(forContentHeight: contentHeight)
        let target = NSPoint(x: 0, y: min(max(0, origin.y), maxScrollY))
        appViewportMove {
            contentView.setBoundsOrigin(target)
            reflectScrolledClipView(contentView)
        }
        return target
    }
}

// StatusBar overlay height — mirrors the private kStatusBarHeight in GallerySubview.
private let kListStatusBarHeight: CGFloat = 29

// MARK: - GalleryListView

struct GalleryListView: View {
    /// The active ViewIdentifier from ViewStateManager, passed down so the Coordinator
    /// can address itself when consuming a pending GalleryScrollIntent (the search-exit
    /// and grid⟷list toggle scroll-position handoffs). Mirrors GallerySubview.activeViewID.
    let activeViewID: ViewIdentifier

    /// The film whose position may have changed in the reload this pass is about to
    /// perform, or nil. Produced by GalleryView's `.film(.updated)` handler, exactly as for
    /// the grid — this style previously did not receive it at all, so a film that an edit
    /// pushed out of the viewport (a rating change under a rating sort, say) stayed off
    /// screen with no indication of where it had gone. See the Priority 1 branch in
    /// updateNSView.
    let scrollRequest: FilmScrollRequest?
    /// The same subtitle provider GalleryView hands the grid (a Recents date, or nil for
    /// every other view). The list renders it as a by-line under the title, so the two
    /// styles show the same secondary information for the same view.
    let subtitleProvider: GallerySubtitleProvider?
    /// This view's section-dividers setting, read from its ViewState by GalleryView and
    /// passed down, mirroring the identical handoff to GallerySubview. The value reaches
    /// the Coordinator before its `films` assignment, whose didSet rebuilds the row model —
    /// so the bands appear or disappear in place, with no film-set change of any kind.
    let showSectionDividers: Bool

    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SelectionState.self) private var selectionState
    @AppStorage(preference: Preferences.showStatusBarKey) private var showStatusBar: Bool
    // NOTE: maintainScrollPositionOnViewSwitch is deliberately NOT read here any more.
    // ViewStateManager.prepareScrollHandoff is now the single gate for the feature: it
    // consults the preference at the moment of each switch and simply arms nothing when
    // the preference is off, so this layer has no decision left to make. Mirrors the
    // identical removal in GallerySubview.

    var body: some View {
        DraggableListView(
            films: dataCoordinator.films,
            // Handed down so the Coordinator can resolve Film Queue section membership
            // when building its row model — the list's counterpart to the identical
            // handoff GallerySubview performs for its own section-divider computation.
            dataCoordinator: dataCoordinator,
            selectionState: selectionState,
            showStatusBar: showStatusBar,
            showSectionDividers: showSectionDividers,
            activeViewID: activeViewID,
            scrollRequest: scrollRequest,
            subtitleProvider: subtitleProvider
        )
    }
}

// MARK: - DraggableListView

/// Full NSViewRepresentable replacement for SwiftUI's List.
/// Owns a DraggableListTableView directly so NSTableView's native drag detection
/// fires correctly from within its own mouseDown event-tracking loop.
private struct DraggableListView: NSViewRepresentable, Loggable {
    nonisolated static let logTag = "[DraggableListView]"

    let films: [FilmSnapshot]
    let dataCoordinator: DataCoordinator
    let selectionState: SelectionState
    let showStatusBar: Bool
    let showSectionDividers: Bool
    let activeViewID: ViewIdentifier
    let scrollRequest: FilmScrollRequest?
    let subtitleProvider: GallerySubtitleProvider?

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        #if DEBUG
        ViewSwitchProbe.record("list.make \(activeViewID) films=\(films.count)")
        #endif
        // A request already standing when this list mounts belongs to an edit some earlier
        // instance handled (the grid, before a style toggle); seeding it keeps this one from
        // acting on it again.
        context.coordinator.lastScrollRequest = scrollRequest
        let scrollView = ListScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.scrollerStyle = .overlay
        // Prevent macOS from overwriting contentInsets with its own safe-area values.
        // We set contentInsets manually in updateNSView to create StatusBar scroll headroom.
        scrollView.automaticallyAdjustsContentInsets = false
        // Layer-backed rendering for smooth compositing, matching GallerySubview.
        scrollView.wantsLayer = true
        scrollView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Allow the scroll view to grow to fill all available horizontal space
        // and resist compression so the table is never clipped on narrow windows.
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let tableView = DraggableListTableView()
        // Do NOT set wantsLayer = true on the table view. When the table is
        // layer-backed, reloadData does not synchronously repaint the layer bitmap —
        // the stale (pre-deletion) bitmap remains visible until the next display cycle,
        // which exposes the old row backgrounds below the new content boundary as a
        // phantom partial-row artifact. The scroll view itself is layer-backed (set
        // above), which is sufficient for compositing; the table draws synchronously
        // via the display cycle and avoids any stale-bitmap window.
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        // Set the table's own background color to the first alternating content color.
        // NSTableView fills its entire frame with row backgrounds — including the area
        // below the last data row when the frame height is not an exact multiple of
        // rowHeight. Setting backgroundColor to colors[0] ensures that sub-row-height
        // band at the bottom is invisible (it matches the first stripe color), preventing
        // the fractional-row visual artifact that would otherwise appear after deletions.
        tableView.backgroundColor = NSColor.alternatingContentBackgroundColors[0]
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.headerView = nil
        tableView.rowHeight = kListRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = []
        tableView.rowSizeStyle = .custom
        tableView.floatsGroupRows = false
        // Enable drag as source. Without this, pasteboardWriterForRow is never called.
        tableView.setDraggingSourceOperationMask([.copy], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        scrollView.documentView = tableView

        let coordinator = context.coordinator
        coordinator.tableView = tableView
        coordinator.scrollView = scrollView
        // Must be assigned BEFORE any `coordinator.films` write: the row model rebuilt in
        // that property's didSet consults dataCoordinator.loadedFilmQueueFilter to decide
        // whether section-divider rows apply. The scroll-handoff branch further down this
        // method performs exactly such a write.
        coordinator.dataCoordinator = dataCoordinator
        coordinator.showSortingSections = showSectionDividers
        coordinator.subtitleProvider = subtitleProvider

        // Give the table view a back-reference to its coordinator so the
        // NSDraggingSource callbacks can delegate to GalleryDragEngine.
        tableView.coordinator = coordinator

        // Secondary-click contextual menu. DraggableListTableView.menu(for:) has already
        // established that the click landed on a real row (and not in the inset side
        // margins) before this runs.
        tableView.getContextMenu = { [weak coordinator] in coordinator?.contextMenu(forRow: $0) }

        // Register this coordinator as the source of "what's on top" for the active
        // view — read by ViewStateManager.updateListViewStyle when the grid⟷list toggle
        // is about to switch AWAY from the list. Unregistered in dismantleNSView below.
        ViewStateManager.shared.registerScrollPositionProvider(coordinator)

        // MARK: Scroll-Position Handoff (Search Exit / Grid⟷List Toggle)
        //
        // Mirrors GallerySubview's identical preload path for its own copy of this
        // handoff — see that type's makeNSView for the fuller rationale. Both
        // producers (search exit and the view-style toggle) share the identical
        // sequence here. Preloading coordinator.films
        // and reloading here (rather than letting the normal updateNSView reload
        // branch run) ensures the very next updateNSView pass sees no change and does
        // not reload a second time, which would otherwise reset scroll to y=0 after
        // this arming has already taken effect. The scroll itself runs in
        // ListScrollView.viewWillDraw(), once real geometry is available; see that
        // type's doc comment for why resolving here, in makeNSView, is unreliable.
        scrollView.listCoordinator = coordinator

        // Keep this view's saved scroll origin current as the user scrolls — see the
        // method's doc comment in GallerySubview.Coordinator for the full rationale;
        // this is the list's copy of the identical mechanism.
        coordinator.installScrollOriginRecorder(on: scrollView)
        #if DEBUG
        coordinator.installViewportJumpTracer(on: scrollView)
        #endif

        if let filmID = GalleryScrollIntent.shared.consume(ifTargeting: activeViewID) {
            coordinator.films = films
            // Seed both view identifiers so the very next updateNSView pass does not read
            // this mount as a view switch and re-zero (or origin-restore over) the scroll
            // position this handoff is about to establish. Mirrors GallerySubview's
            // identical seeding on its own intent path.
            coordinator.currentViewID = activeViewID
            coordinator.prevViewID = activeViewID
            // See GallerySubview.makeNSView's identical seeding.
            coordinator.lastFilmQueueFilter = dataCoordinator.loadedFilmQueueFilter
            coordinator.withSuppressedCallbacks {
                tableView.reloadData()
            }
            scrollView.pendingScrollFilmID = filmID
            // This path deliberately bypasses updateNSView's reload branch, which is where
            // an origin restore would otherwise be picked up. The film handoff outranks it,
            // so retire the intent here rather than leaving it to be armed by a later pass
            // and fight the scroll this path exists to perform. Mirrors GallerySubview.
            ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)
            Self.log("Scroll handoff armed in makeNSView for film \(filmID) (view: \(activeViewID))")
        } else {
            // No film handoff claims this mount, so a saved origin may. Mirrors
            // GallerySubview.makeNSView — see armScrollOriginRestoreOnMount.
            ViewStateManager.shared.armScrollOriginRestoreOnMount(
                for: GalleryScrollKey(viewID: activeViewID,
                                      subTab: dataCoordinator.loadedFilmQueueFilter?.rawValue))
        }

        // Outside the scroll-handoff branch, mirroring GallerySubview.makeNSView — see
        // GalleryFocusIntent for why the two handoffs are independent.
        if GalleryFocusIntent.shared.consume(ifTargeting: activeViewID) {
            scrollView.pendingKeyboardFocus = true
            Self.log("Keyboard-focus handoff armed in makeNSView (view: \(activeViewID))")
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        #if DEBUG
        ViewSwitchProbe.record("list.update \(activeViewID)")
        #endif
        guard let tableView = scrollView.documentView as? DraggableListTableView else { return }
        let coordinator = context.coordinator
        // Refreshed on every pass (the environment object is a stable singleton, but the
        // assignment is free and keeps the invariant "dataCoordinator is set before films
        // is written" true on every path through this method). See makeNSView.
        coordinator.dataCoordinator = dataCoordinator
        // Refreshed before any row is (re)configured below. A change of subtitle KIND
        // always coincides with a view-identity change (the Recents category is part of
        // the ViewIdentifier), which forces the full reload; and the else-branch's
        // visible-row refresh re-resolves the string through this provider on every
        // same-view pass, with ListRowHostCell comparing the resolved text so an
        // unchanged by-line costs no rootView reassignment.
        coordinator.subtitleProvider = subtitleProvider

        // Bottom inset for the StatusBar overlay. contentInsets extends the scrollable
        // range below the document view's natural bottom edge, allowing the last real
        // row to scroll fully above the StatusBar without injecting a phantom row into
        // the data source. scrollerInsets keeps the scroll thumb track above the overlay.
        // automaticallyAdjustsContentInsets must be false (set in makeNSView) so macOS
        // does not overwrite contentInsets with its own safe-area calculation.
        let bottomInset: CGFloat = showStatusBar ? kListStatusBarHeight : 0
        if scrollView.contentInsets.bottom != bottomInset {
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }
        if scrollView.scrollerInsets.bottom != bottomInset {
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }

        // Stale-pass guard. GalleryListView's body reads dataCoordinator.films, so SwiftUI
        // also runs this when the films change on their own — carrying the activeViewID of
        // the LAST GalleryView body pass. After a view switch that is a pass in
        // which the films belong to the new view while activeViewID still names the old
        // one, and it can only come from one of two places:
        //
        //  • An instance that is about to be removed. AppState.navigate switches before it
        //    flips the sidebar, so the outgoing gallery sees the destination's films one
        //    last time. Treating them as a same-view refresh reloaded it for nothing, and
        //    kept its viewport clamped to the new, often shorter, content — which its
        //    dismantleNSView then banked over the correct origin prepareScrollHandoff had
        //    just saved for the view being left.
        //  • An instance that stays (a sub-tab switch, a deleted list falling back to All
        //    Films). Its enclosing GalleryView reads activeView, so a body pass carrying
        //    the new activeViewID follows in the same update, and that pass performs the
        //    reload with the correct identity.
        //
        // Either way nothing here is owed until activeViewID agrees with the view the films
        // were loaded for, so the pass is skipped.
        guard activeViewID == ViewStateManager.shared.activeView else { return }

        // Style guard — see the identical guard in GallerySubview.updateNSView.
        if case .filmQueue = activeViewID,
           !ViewStateManager.shared.displayedGalleryState(
               loadedQueueFilter: dataCoordinator.loadedFilmQueueFilter).isListView {
            return
        }

        // MARK: View-Switch Detection
        //
        // The list previously had none, which produced two divergences from the grid:
        //
        //  • NSTableView.reloadData() — unlike NSCollectionView's — does NOT reset the
        //    scroll position. Every view change that reuses this same mounted table (all
        //    Recents sub-tabs, both Unwatched tabs, and every smart-list variant, since
        //    the enclosing GalleryView's .id is unchanged for those) therefore carried the
        //    OUTGOING view's scroll offset straight into the incoming one, dropping the
        //    user into the middle of an unrelated film set. The grid zeroes on the same
        //    transition; the list now does too.
        //  • maintainScrollPositionOnViewSwitch was silently grid-only, despite the
        //    preference reading "Remember prior scroll positions across view changes" and
        //    saying nothing about display style.
        //
        // prevViewID is Optional for the same two reasons as its counterpart in
        // GallerySubview.Coordinator: nil compares unequal to every case, so a fresh mount
        // is correctly treated as a transition (and can restore its saved origin) whatever
        // view it lands on, and it marks "nothing displayed yet" so the outgoing-origin
        // save below cannot file a synthetic zero under an unrelated view's key.
        coordinator.currentViewID = activeViewID
        let viewIdentityChanged = coordinator.prevViewID != coordinator.currentViewID
        if viewIdentityChanged {
            if let outgoingViewID = coordinator.prevViewID {
                ViewStateManager.shared.saveScrollPosition(
                    coordinator.scrollPosition(of: scrollView),
                    under: GalleryScrollKey(viewID: outgoingViewID,
                                            subTab: coordinator.lastFilmQueueFilter?.rawValue))
            }
            coordinator.prevViewID = coordinator.currentViewID
        }

        // The Film Queue's segmented filter narrows/widens the SAME view (currentViewID
        // stays .filmQueue throughout), so viewIdentityChanged above can never detect a
        // switch between "All" and a single section. The grid has always synthesized this
        // signal; the list did not, and the omission was visible rather than theoretical.
        // NSTableView.reloadData() — unlike NSCollectionView's — does not reset the scroll
        // position, and the zeroing block below was gated on the identity test alone, so a
        // Queue tab change in list style carried the outgoing tab's offset straight into
        // the incoming one. AppKit then clamped that offset against the (usually shorter)
        // new content, landing the user at the BOTTOM of the section they had just
        // selected. The same omission skipped the `pendingScrollPosition = nil` reset below,
        // leaving an origin armed for one tab free to resolve against another's rows when
        // tabs were switched faster than a restore could apply.
        //
        // Compared against dataCoordinator.loadedFilmQueueFilter — the filter the films
        // handed to this pass were actually produced with — and NOT against
        // FilmQueueFilterState.shared.selectedFilter, which is the live intent: the live
        // filter flips synchronously inside selectFilter while the narrowed film set only
        // arrives with the deferred reload that follows. See the fuller rationale on
        // GallerySubview's identical computation.
        //
        // A nil last-seen value never counts as a change: a fresh mount's transition is
        // already covered by viewIdentityChanged, and reporting a filter change there would
        // additionally discard a scroll handoff armed by makeNSView. The value resets to nil
        // whenever a non-Queue film set is displayed, so returning to the Queue is treated
        // as that same first observation rather than compared against a stale section.
        let filmQueueFilterChanged: Bool
        if let loadedQueueFilter = dataCoordinator.loadedFilmQueueFilter {
            filmQueueFilterChanged = coordinator.lastFilmQueueFilter != nil &&
                                     coordinator.lastFilmQueueFilter != loadedQueueFilter
            coordinator.lastFilmQueueFilter = loadedQueueFilter
        } else {
            coordinator.lastFilmQueueFilter = nil
            filmQueueFilterChanged = false
        }

        // Drives the reload and the scroll-to-zero below. The outgoing-origin save above is
        // deliberately NOT included: currentViewID is still .filmQueue across a filter
        // change, so saving there would file one section's position under the key all four
        // share. Banking for a Queue tab change is handled authoritatively by
        // FilmQueueFilterState.selectFilter, which calls prepareScrollHandoff with explicit
        // per-section keys before the filter flips.
        let isViewSwitch = viewIdentityChanged || filmQueueFilterChanged

        let newFilms = films
        let oldFilms = coordinator.films

        // A same-view refresh that empties the list is about to take it off screen; bank
        // the position first. See the identical step in GallerySubview.updateNSView.
        if !isViewSwitch && newFilms.isEmpty && !oldFilms.isEmpty {
            ViewStateManager.shared.saveScrollPosition(coordinator.scrollPosition(of: scrollView),
                                                       under: coordinator.displayedScrollKey)
        }

        // Launch pre-paint poster warm + restore-priority registration — one-shot per
        // session, shared with GallerySubview via PosterCache's internal flag, so
        // whichever gallery style renders first at launch performs it and the other's
        // call is a single Bool read. Must precede the reloadData below so the first
        // rows configured find their posters already resident. See
        // PosterCache.registerLaunchDisplayOrder.
        if PosterCache.shared.needsLaunchWarm, !newFilms.isEmpty {
            PosterCache.shared.registerLaunchDisplayOrder(newFilms.map(\.posterUID))
        }
        if !newFilms.isEmpty { LaunchReveal.shared.galleryWillAppear(scrollView) }

        // MARK: Change Detection
        //
        // `Array ==` short-circuits on CoW buffer identity, so when `dataCoordinator.films`
        // has not been reassigned since the last pass — every status-bar toggle, every
        // scroll-request change, every ancestor re-render — this is an O(1) pointer
        // comparison that decides the whole block below without touching an element. When
        // the contents DO differ it exits at the first difference, and only a genuine
        // "reloaded to an equal-but-distinct array" costs a full walk (measured at ~10ms
        // per 200k elements, i.e. tens of microseconds at this app's scale, and it buys a
        // skipped rebuild).
        //
        // This gate is what keeps rebuildRowModel() off the no-op passes. It is not
        // micro-optimization: with section dividers on, that rebuild runs
        // GallerySectioning.displayedSectionBreaks — an O(films) scan doing a MetadataCache
        // lookup and constructing a GallerySection (two Strings) per film — and then builds
        // a fresh row array and a fresh film→row dictionary. The list used to assign
        // coordinator.films unconditionally, so it paid all of that on every pass. (The
        // grid assigns its films only inside its own needsReload branch, and gates its
        // section-break recompute on the same inputs — see its updateSectionDividers.)
        //
        // Deep equality — not an ID-sequence comparison — is required here. An edit that
        // changes a rendered field without moving the film (renaming a film under a Date
        // Added sort, say) leaves the ID sequence identical, and skipping the assignment on
        // that basis would leave the visible-row refresh below re-rendering STALE films.
        let filmsChanged = oldFilms != newFilms

        // The row model depends on more than `films`. Everything else it reads is captured
        // here, so a change to any of them rebuilds even when the film array is untouched:
        //
        //  • showSortingSections — this view's own dividers setting, toggled with no
        //    film-set change of any kind (updateShowSectionDividers passes `reload: false`
        //    for exactly that reason). This is the entire mechanism by which the bands
        //    appear and disappear in real time.
        //  • the three `loaded*` values — the gates inside
        //    GallerySectioning.displayedSectionBreaks. A sort change that happens to
        //    produce the identical film ORDER still re-bands the view (Date Added ⇄ Date
        //    Modified over a set where both agree), and `films` alone cannot see it.
        //
        // Read from dataCoordinator's `loaded*` properties, never the live `current*`
        // intent, for the reason spelled out on rebuildRowModel(): they are written in the
        // same synchronous statement group as `films` itself, which makes the banding a
        // pure function of the films actually being displayed.
        let sectionInputs = Coordinator.SectionInputs(
            showSortingSections: showSectionDividers,
            queueFilter: dataCoordinator.loadedFilmQueueFilter,
            sortOption: dataCoordinator.loadedSortOption,
            recentsCategory: dataCoordinator.loadedRecentsCategory,
            queueMembership: GallerySectioning.filmQueueMembership(for: dataCoordinator))
        // nil on the first pass, so a fresh mount always rebuilds.
        let sectionInputsChanged = coordinator.lastSectionInputs != sectionInputs
        coordinator.lastSectionInputs = sectionInputs

        // The Film Queue's "All" tab is the ONE banding whose inputs are not derivable from
        // the films array, which is why its section memberships are part of sectionInputs
        // (see GallerySectioning.filmQueueMembership) rather than left to `filmsChanged`.
        //
        // Its bands come from GallerySectioning.filmQueueSectionBreaks, which resolves each
        // film's Up Next / Soon / Later membership through
        // DataCoordinator.filmQueueSection(forFilm:) → MemoryStore list membership. No
        // FilmSnapshot field mirrors that, and the array does not necessarily reorder when
        // it changes: promoting the first film of "Soon" to "Up Next" leaves it in the same
        // position (still after every Up Next film, still before every remaining Soon film)
        // with every snapshot byte-identical, while deleting the "Soon" band above it. Both
        // `filmsChanged` and the sort-derived inputs are blind to that; the memberships are
        // not.
        //
        // Every other view's bands are sort-derived, and GallerySectioning resolves those
        // from MetadataCache values that are themselves derived from FilmSnapshot fields
        // (titleKey←name/sortName, year←releaseYear, effectiveDuration←edited/editedDuration
        // /duration, the parsed dates←dateAdded/lastModified/lastWatched, rating←userRating,
        // viewCount, and both Recents dates←lastWatched/rotationThresholdOverride and
        // `releases`). A change to any of them moves a FilmSnapshot field, so `filmsChanged`
        // sees it and the skip is sound there.

        // Whether the ROW ORDER changed, which is what the table's cached row views cannot
        // survive. Guarded by filmsChanged so the O(films) walk is never reached on a pass
        // the O(1) comparison above already settled. Subsumes the previous
        // count/first/last heuristics exactly — elementsEqual is false whenever the counts
        // differ or either endpoint moved — and additionally catches the INTERIOR reorder
        // they were blind to, which is the same ambiguity GallerySubview guards with its
        // own `interiorReordered` scan: two sort options can share a count and both
        // endpoints (Date Added ⇄ Date Modified when the newest and oldest coincide) and
        // still permute everything between them.
        let idSequenceChanged = filmsChanged &&
            !oldFilms.elementsEqual(newFilms) { $0.id == $1.id }

        // Captured BEFORE the rebuild below, so rowModelChanged compares against it.
        let oldRowItems = coordinator.rowItems
        // Must precede any rebuild: computeSectionBreaks() reads it.
        coordinator.showSortingSections = showSectionDividers
        if filmsChanged {
            coordinator.films = newFilms      // didSet rebuilds the row model
        } else if sectionInputsChanged {
            coordinator.rebuildRowModel()     // same films, possibly different banding
        }

        // Section-divider structure change. Moving a film between two Film Queue
        // sections — or, under sort-derived bands, an edit that moves a film from one band
        // to another — leaves the film COUNT, the first film, and the last film all
        // unchanged, yet can add, remove, reorder, or re-count a divider row. None of the
        // three checks above can see that. Comparing the row models catches all of it, and
        // is the list's equivalent of the grid recomputing its section breaks on every
        // reload pass.
        //
        // `ListRowItem` is Equatable over the band's identity AND its film count, so a band
        // whose label is unchanged but whose membership shifted still compares unequal and
        // still forces the full reload the row heights and labels need.
        //
        // Wherever no bands apply at all — every view with the sorting-sections preference
        // off, outside the Film Queue's "All" tab — the row model is a strict 1:1
        // `.film(index:)` sequence, so this comparison is true exactly when the film COUNT
        // changed and it can never introduce an extra reload.
        let rowModelChanged = coordinator.rowItems != oldRowItems

        if isViewSwitch || idSequenceChanged || rowModelChanged {
            #if DEBUG
            ViewSwitchProbe.record("list.reload \(activeViewID) films=\(films.count)")
            #endif
            coordinator.withSuppressedCallbacks {
                tableView.reloadData()
            }
        } else if filmsChanged {
            // Refresh the existing rows in place for metadata/poster updates, preserving
            // scroll position and selection (avoids full reloadData bounce).
            //
            // Reachable only for a SAME-view refresh in which every film kept its row:
            // a view switch is forced down the full-reload path above, and so now is any
            // reorder, interior ones included. What remains here is the in-place metadata
            // edit this branch exists for — a renamed film, a new rating, a release marked
            // purchased.
            //
            // Every row view the table currently holds is updated, not just the visible
            // ones: NSTableView keeps rows prepared just outside the viewport and does not
            // ask for them again when they scroll in, so a film edited there would otherwise
            // show its old values. (The grid reconfigures its prepared cells for the same
            // reason.) Rows the table holds no view for need nothing — it asks the delegate
            // when one is needed, and that reads the films array assigned above.
            //
            // In place rather than through reloadData(forRowIndexes:), which swapped each
            // row's cell view through the reuse queue: the swap relaid the row out, and the
            // cell it got back could be one last configured for another film, which
            // reassigned that cell's rootView even when the row's own film had not changed.
            // `update` compares what the row displays, so a row whose film is unchanged
            // costs a few comparisons and no hosting-view work.
            //
            // Gated on filmsChanged: on every other pass (a selection change, a status-bar
            // toggle, a banding-only rebuild that kept the row model) the rows already show
            // the current films, and refreshing them was pure waste. A banding change that
            // alters rows is caught by rowModelChanged above.
            tableView.enumerateAvailableRowViews { rowView, row in
                guard let cell = rowView.view(atColumn: 0) as? ListRowHostCell,
                      let film = coordinator.film(forRow: row) else { return }
                #if DEBUG
                GalleryRefreshProbe.listRowsRefreshed += 1
                #endif
                cell.update(film: film, subtitle: coordinator.subtitleProvider?.subtitle(film.id))
            }
        }

        // Post-reload scroll placement for a view switch. Runs after the reload above so
        // the row count the clamp depends on is already current.
        if let listScrollView = scrollView as? ListScrollView {
            if isViewSwitch {
                // Zero first, unconditionally: this is the position the new view opens at
                // when nothing else claims it, and it is what replaces the offset
                // reloadData() would otherwise have carried over from the outgoing view.
                appViewportMove {
                    scrollView.contentView.setBoundsOrigin(.zero)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }

                // Discard any origin armed by an earlier pass that this transition
                // supersedes, so it cannot resolve against the wrong view's content. The
                // block below re-arms it for the incoming view when one is available.
                listScrollView.pendingScrollPosition = nil
            }

            // Arm this view's own saved origin for pre-draw restore — on EVERY pass, not
            // just the one that detected the transition above. That coupling is what broke
            // the preference across a view's own sub-tabs: this same table is reused for
            // them (the enclosing GalleryView's .id is unchanged), so the pass that
            // consumes the prevViewID → currentViewID transition need not be the pass that
            // reloads with the destination's films, and a restore armed only on the former
            // had nothing to restore against. The intent is armed once, authoritatively, by
            // ViewStateManager at the moment of the switch, is addressed to a specific view,
            // and is retired only once actually applied — so it is picked up by whichever
            // pass genuinely reloads, and is inert on all the others. The preference itself
            // is checked at arming time; nothing is ever armed while it is off.
            //
            // The pendingScrollFilmID == nil condition keeps the search-exit /
            // view-style-toggle film handoff authoritative: if makeNSView armed a
            // scroll-to-film for this same mount, the origin restore must not fight it
            // (mirrors the identical condition in GallerySubview.updateNSView).
            // A reuse-path film handoff outranks the origin restore below and is claimed
            // first. By construction this can only be a ShowInListNavigation redirection to
            // a smart-list sub-variant of the parent already on screen — see
            // GalleryScrollIntent.consumableOnReuse. Mirrors the identical Priority 0 branch
            // in GallerySubview.updateNSView.
            if let handoffFilmID = GalleryScrollIntent.shared.consumeOnReuse(ifTargeting: coordinator.currentViewID) {
                ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)
                listScrollView.pendingScrollPosition = nil
                listScrollView.pendingScrollFilmID = handoffFilmID
                listScrollView.pendingScrollBehavior = .forceTop
                // Apply now rather than waiting for a viewWillDraw that will never arrive on
                // a reused gallery. The list resolver's geometry needs are pure arithmetic
                // on the fixed row height, so no forced layout pass is required first.
                listScrollView.applyPendingFilmTargetIfPossible()
                Self.log("Scroll handoff armed on reuse path for film \(handoffFilmID) (view: \(coordinator.currentViewID))")

            } else if let scrollRequest, scrollRequest != coordinator.lastScrollRequest,
                      coordinator.rowIndex(for: scrollRequest.filmID) != nil {
                let filmID = scrollRequest.filmID
                // Priority 1 — an intentional post-edit reposition, the list's counterpart
                // to the identically-ranked branch in GallerySubview.updateNSView. It
                // outranks the origin restore below, so any intent armed for this view is
                // retired first rather than being left live to undo the placement.
                //
                // Unlike the grid, there is no origin to restore first: NSTableView's
                // reloadData() does not reset the scroll position, so the viewport is still
                // exactly where the user left it and the `.ifNeeded` resolution below can
                // test visibility against it directly. A film still on screen is left alone;
                // one the edit pushed out of view is placed in the top row.
                ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)
                listScrollView.pendingScrollPosition = nil
                listScrollView.pendingScrollFilmID = filmID
                listScrollView.pendingScrollBehavior = .ifNeeded
                listScrollView.applyPendingFilmTargetIfPossible()

            } else if listScrollView.pendingScrollFilmID == nil,
               let restoredPosition = ViewStateManager.shared
                   .pendingScrollOriginRestore(for: coordinator.displayedScrollKey) {
                listScrollView.pendingScrollPosition = restoredPosition
                Self.log("Scroll-origin restore armed for \(coordinator.currentViewID): \(restoredPosition.origin)")
                // Apply now rather than waiting for a viewWillDraw that will never arrive
                // on a reused gallery — see applyPendingOriginRestoreIfPossible. The list
                // resolver clamps against coordinator.scrollableContentHeight (row-model
                // arithmetic, no AppKit layout dependency), so no forced layout pass is needed.
                listScrollView.applyPendingOriginRestoreIfPossible()
            }
        }

        // Every pass records the request, acted on or not, so it can fire only once.
        coordinator.lastScrollRequest = scrollRequest

        coordinator.syncSelectionToView()
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        // Backstop scroll-origin save, mirroring GallerySubview.dismantleNSView — see that
        // method for why the y > 0 condition is deliberate and must not be relaxed to an
        // unconditional save at this particular call site.
        let position = coordinator.scrollPosition(of: nsView)
        if position.origin.y > 0 {
            ViewStateManager.shared.saveScrollPosition(position, under: coordinator.displayedScrollKey)
            Self.log("Saved scroll origin \(position.origin) for \(coordinator.currentViewID)")
        }
        // Identity-checked: only clears the registry if this coordinator is still the
        // registered provider, so an out-of-order mount/dismantle sequence during the
        // grid⟷list toggle can never clear the freshly-mounted opposite style's registration.
        ViewStateManager.shared.unregisterScrollPositionProvider(coordinator)
        coordinator.cancelSubscriptions()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selectionState: selectionState)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource,
                              GalleryScrollPositionProviding {
        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?

        // Current and previous view identifiers, for the same authoritative view-switch
        // detection GallerySubview.Coordinator performs. See the "View-Switch Detection"
        // block in updateNSView for why prevViewID is Optional.
        var currentViewID: ViewIdentifier = .allFilms
        fileprivate var prevViewID: ViewIdentifier?

        /// The last post-edit scroll request this Coordinator has seen, acted on or not.
        fileprivate var lastScrollRequest: FilmScrollRequest?

        /// The Film Queue section filter this coordinator last displayed a film set for, or
        /// nil when the last set displayed was not a Film Queue result at all.
        ///
        /// The Queue's four segmented tabs share the single `.filmQueue` ViewIdentifier, so
        /// the `prevViewID != currentViewID` test above can never see a switch between them.
        /// This is compared against `dataCoordinator.loadedFilmQueueFilter` on every pass to
        /// synthesize the equivalent signal — see its use site in updateNSView, and the
        /// identical field on GallerySubview.Coordinator, for why the comparison is against
        /// the LOADED filter rather than the live one in FilmQueueFilterState.
        fileprivate var lastFilmQueueFilter: FilmQueueFilter?

        /// Everything rebuildRowModel()'s section-break computation reads OTHER than the
        /// `films` array itself. Compared as a unit against `lastSectionInputs` so a change
        /// to any of them rebuilds the row model even when the film array is byte-identical
        /// — see the Change Detection block in updateNSView for why each one is here.
        fileprivate struct SectionInputs: Equatable {
            let showSortingSections: Bool
            let queueFilter: FilmQueueFilter?
            let sortOption: SortOption?
            let recentsCategory: RecentsCategory?
            /// See GallerySectioning.filmQueueMembership.
            let queueMembership: [Set<UUID>]?
        }

        /// The section inputs the current row model was built from, or nil before the first
        /// update pass — which is what makes a fresh mount always rebuild.
        fileprivate var lastSectionInputs: SectionInputs?

        /// Resolves Film Queue section membership when building the row model. Weak, and
        /// assigned by DraggableListView.makeNSView/updateNSView before any `films` write.
        /// Mirrors GallerySubview.Coordinator.dataCoordinator.
        weak var dataCoordinator: DataCoordinator?
        /// Mirror of the active view's ViewState.showSectionDividers, pushed here by
        /// makeNSView/updateNSView before any `films` assignment — its didSet is what
        /// rebuilds the row model, and computeSectionBreaks() reads this while doing so.
        var showSortingSections: Bool = false
        /// The active subtitle provider, pushed by makeNSView/updateNSView and resolved
        /// per film when a row is configured. Mirrors GallerySubview.Coordinator.
        var subtitleProvider: GallerySubtitleProvider?

        var films: [FilmSnapshot] = [] {
            didSet { rebuildRowModel() }
        }
        let selectionState: SelectionState

        /// The table's row model — the single mapping between row space and film space.
        /// See ListRowItem. Rebuilt (together with filmRowMap and listContentHeight) in
        /// `films.didSet`, so it is never out of step with the films it describes.
        private(set) var rowItems: [ListRowItem] = []

        /// Total document height of the table, derived from the row model rather than the
        /// document view's frame. See scrollFilmToTop(_:) for why the frame is unreliable
        /// at the moments this is needed. Stored rather than computed so the scroll paths
        /// that read it never pay an O(rows) walk.
        private(set) var listContentHeight: CGFloat = 0

        /// The table's full document height, for clamping programmatic scrolls: the row
        /// model's height plus the padding the `.inset` table style puts above the first row
        /// and below the last (10 pt each on macOS 15; row 0 starts at y = 10). Clamping
        /// against listContentHeight alone stopped every placement near the end of a list
        /// 20 pt short of where AppKit (and the user's own scrolling) can go, so the last
        /// rows could never be brought fully up. The padding is measured from the table — the
        /// first row's offset, which comes from the style, not the frame — rather than
        /// restated, and is symmetric (table height = rows + 2 × that offset).
        var scrollableContentHeight: CGFloat {
            guard listContentHeight > 0, let tv = tableView, tv.numberOfRows > 0 else { return listContentHeight }
            return listContentHeight + 2 * tv.rect(ofRow: 0).minY
        }

        /// Film ID → TABLE ROW index (not film index). Every selection, drag, and scroll
        /// path in this file works in row space, so storing rows directly removes any need
        /// for a second conversion at the point of use.
        private var filmRowMap: [UUID: Int] = [:]
        private var isSuppressingCallbacks = false
        private var isUpdatingSelection = false
        private var cancellables = Set<AnyCancellable>()
        private var observationTask: Task<Void, Never>?

        /// The row index the user pressed on at mouseDown time.
        /// Set by DraggableListTableView.mouseDown before super enters its drag-detection
        /// loop. Read by willBeginAt to select the correct poster for the drag preview.
        /// Cleared after use so a stale value never leaks into a subsequent drag.
        var pendingDragSourceRow: Int? = nil

        // Drag engine — owns the native drag preview and NSDraggingSource state.
        lazy var dragEngine = GalleryDragEngine()

        init(selectionState: SelectionState) {
            self.selectionState = selectionState
            super.init()
            setupSubscriptions()
        }

        func cancelSubscriptions() {
            cancellables.removeAll()
            observationTask?.cancel()
            observationTask = nil
            // Remove the live-scroll origin recorder installed by makeNSView.
            removeScrollOriginRecorder()
            #if DEBUG
            removeViewportJumpTracer()
            #endif
        }

        /// Rebuilds `rowItems`, `filmRowMap`, and `listContentHeight` from the current
        /// `films` array. Runs synchronously inside `films.didSet`, so the three can never
        /// be observed out of step with the film set they describe.
        ///
        /// Also called directly by updateNSView for the one case `films.didSet` cannot
        /// cover: the banding inputs changed while the film array did not (this view's
        /// section-dividers setting toggled, or a re-sort that produced the identical
        /// order). Calling it is equivalent to re-assigning `films` with the same value and
        /// says what is actually happening.
        ///
        /// Which section-divider rows are emitted (if any) is decided by
        /// computeSectionBreaks() below. Both of its gates —
        /// `dataCoordinator.loadedFilmQueueFilter` and `dataCoordinator.loadedSortOption` —
        /// are read from the DataCoordinator deliberately, rather than from the live
        /// FilmQueueFilterState / ViewStateManager intent or this Coordinator's own
        /// currentViewID, for exactly the reason spelled out in
        /// GallerySubview.Coordinator.updateSectionDividers(): both are written in the same
        /// synchronous pass as `films` itself, which makes the divider state a pure
        /// function of the films actually being displayed and therefore impossible to
        /// desync from them. When no bands apply the row model is a strict 1:1 identity
        /// mapping and the divider machinery contributes nothing at all.
        fileprivate func rebuildRowModel() {
            // Divider insertion points, in FILM index space. Empty whenever no bands apply
            // at all, which collapses the loop below to a plain 1:1 build.
            let breaks = computeSectionBreaks()
            var nextBreak = 0

            var items: [ListRowItem] = []
            var map: [UUID: Int] = [:]
            items.reserveCapacity(films.count + breaks.count)
            map.reserveCapacity(films.count)

            // The Queue's "All" tab follows its "Up Next" films with empty slot rows (and,
            // when "Up Next" has no films, its own band first). Nil everywhere else.
            var slotPlan = dataCoordinator.flatMap {
                UpNextSlots.plan(breaks: breaks, filmCount: films.count, coordinator: $0)
            }
            func appendSlots(at index: Int) {
                guard let plan = slotPlan, plan.afterIndex == index else { return }
                slotPlan = nil
                if plan.needsOwnBand {
                    items.append(.divider(section: FilmQueueSection.upNext.gallerySection, filmCount: 0))
                }
                for number in plan.firstNumber..<(plan.firstNumber + plan.count) {
                    items.append(.slot(number: number))
                }
            }

            for (index, film) in films.enumerated() {
                appendSlots(at: index)
                if nextBreak < breaks.count, breaks[nextBreak].index == index {
                    // Section film count is the span from this break to the next one (or to
                    // the end of the film set for the final section) — the same real-item
                    // index space the breaks themselves use, so it always matches the number
                    // of film rows actually rendered beneath the band. The arithmetic is
                    // GallerySectioning.bandFilmCount, the same call
                    // SmoothResizingGridLayout.filmCount(atOrdinal:) makes, so the two
                    // gallery styles share one definition rather than two matching ones.
                    let next = (nextBreak + 1) < breaks.count ? breaks[nextBreak + 1].index : nil
                    items.append(.divider(
                        section: breaks[nextBreak].section,
                        filmCount: GallerySectioning.bandFilmCount(
                            from: index, nextBandIndex: next, totalCount: films.count)))
                    nextBreak += 1
                }
                // Last-wins on a duplicate film ID, matching the deliberate
                // `uniquingKeysWith` reliability choice this replaces (and
                // GallerySubview.Coordinator.rebuildFilmIndexMap): a repeated ID degrades to
                // "maps to its last row" rather than trapping. Plain subscript assignment is
                // last-wins by construction.
                map[film.id] = items.count
                items.append(.film(index: index))
            }
            appendSlots(at: films.count)

            rowItems = items
            filmRowMap = map
            listContentHeight = items.reduce(0) { $0 + $1.rowHeight }
        }

        /// The list's divider insertion points — the identical call the grid's
        /// updateSectionDividers() makes, so the two styles cannot disagree about which
        /// bands a film set has: they are not two implementations kept in agreement, they
        /// are one. Returns an empty array when no bands apply, which leaves the row model
        /// a strict 1:1 identity mapping.
        private func computeSectionBreaks() -> [(index: Int, section: GallerySection)] {
            guard let dc = dataCoordinator else { return [] }
            return GallerySectioning.displayedSectionBreaks(
                films: films, coordinator: dc, showSortingSections: showSortingSections)
        }

        // MARK: - Row ⟷ Film Conversion

        /// The film index a table row displays, or nil when the row is a section divider
        /// (or out of range). The single funnel every row→film conversion goes through.
        func filmIndex(forRow row: Int) -> Int? {
            guard row >= 0, row < rowItems.count else { return nil }
            guard case .film(let index) = rowItems[row], index < films.count else { return nil }
            return index
        }

        /// The film a table row displays, or nil for a divider / out-of-range row.
        func film(forRow row: Int) -> FilmSnapshot? {
            guard let index = filmIndex(forRow: row) else { return nil }
            return films[index]
        }

        // MARK: - Drag Support (NSTableViewDataSource)

        /// Returning a writer here causes NSTableView to detect drag gestures from
        /// within its own mouseDown event-tracking loop — the only reliable trigger
        /// point (a manual mouseDown/mouseDragged/mouseUp bypass, mirroring
        /// GalleryCollectionView's approach for the grid, was tried and does not
        /// work: NSTableView.mouseDown(with:) runs its own internal, blocking
        /// event-tracking loop that consumes every subsequent mouseDragged/mouseUp
        /// event itself, so a subclass's own overrides of those methods never see
        /// them at all). The writer serializes the film IDs for drop destinations.
        ///
        /// Critical: NSTableView calls this once per row in the selection. Each
        /// non-nil return value becomes one NSDraggingItem, and the OS renders a
        /// count badge equal to NSDraggingSession.draggingItems.count — independent
        /// of draggingFormation and the drag image. To suppress the badge entirely,
        /// we return a writer only for the *lowest-index selected row* (computed
        /// below), encoding the full set of dragged IDs in that single item. All
        /// other selected rows return nil, so the session has exactly one item and
        /// the OS never shows a badge.
        func tableView(_ tableView: NSTableView,
                       pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            // Divider rows resolve to nil here, so they never produce a pasteboard writer
            // and can never originate a drag.
            guard let clickedID = film(forRow: row)?.id else { return nil }

            // The AUTHORITATIVE, synchronous AppKit selection — deliberately not
            // selectionState.selectedFilmIDs, exactly as
            // GallerySubview.Coordinator.filmIDsForDrag(clickedAt:) reads
            // collectionView.selectionIndexPaths for the grid. SelectionState.select(_:)
            // commits through a deferred DispatchQueue.main.async, and NSTableView begins a
            // drag from inside the same synchronous mouseDown tracking loop that changed
            // the selection — so the main queue has not drained yet and the model set can
            // still be one gesture behind. Reading it here made a Cmd-click (or
            // Shift-click) followed immediately by a drag produce a writer for the newly
            // added row AND a separate writer for the stale set, giving the session more
            // than one dragging item: the OS count badge this method exists to suppress
            // reappeared, and the payload was split across items.
            //
            // Divider rows are unselectable (tableView(_:shouldSelectRow:)), so every index
            // here is a film row and `first` is the lowest-index selected row.
            let selectedRows = tableView.selectedRowIndexes

            if selectedRows.contains(row) {
                // Multi-selection drag: only produce a writer for the lowest-index
                // selected row. All other selected rows return nil, keeping the
                // NSDraggingSession at exactly one item (= no OS count badge).
                guard row == selectedRows.first else { return nil }
                let selectedIDs = Set(selectedRows.compactMap { film(forRow: $0)?.id })
                guard !selectedIDs.isEmpty else { return nil }
                return FilmDragPasteboardWriter(filmIDs: selectedIDs)
            } else {
                // Single-row drag (row was not part of the prior selection).
                return FilmDragPasteboardWriter(filmIDs: [clickedID])
            }
        }

        func tableView(_ tableView: NSTableView,
                       draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint,
                       forRowIndexes rowIndexes: IndexSet) {
            // Use the row the user actually grabbed (recorded at mouseDown time) as
            // the source for the poster preview. Fall back to rowIndexes.first only
            // if the stored value is somehow absent — which should never occur in
            // normal flow since mouseDown fires before this delegate callback.
            let sourceRow = pendingDragSourceRow ?? rowIndexes.first ?? 0
            pendingDragSourceRow = nil  // Consume immediately; must not persist.

            // dragPreviewImage (cache-only) is used here deliberately, NOT
            // getImageWithFallback. See PosterCache.dragPreviewImage for rationale.
            // Resolved through the row model: `sourceRow` is a TABLE row index, which is
            // only the same as a film index when no divider rows are present.
            let sourceFilm = film(forRow: sourceRow)
            let posterImage: NSImage? = sourceFilm.flatMap {
                PosterCache.shared.dragPreviewImage(for: $0.posterUID)
            }

            // dragCount: if the source row is part of the selection, the full
            // selection count is dragged; otherwise just this single row. Read from the
            // table's own selection for the same reason pasteboardWriterForRow above does
            // — see that method's note on the deferred SelectionState write, which made
            // this badge report the pre-click count for a Cmd/Shift-click-then-drag.
            let selectedRows = tableView.selectedRowIndexes
            let dragCount = selectedRows.contains(sourceRow) ? selectedRows.count : rowIndexes.count

            // Disable the built-in cancel animation — the flyback window handles
            // the fly-back itself (see GalleryDragEngine.performFlyBack).
            session.animatesToStartingPositionsOnCancelOrFail = false

            // The session always has exactly one dragging item because
            // pasteboardWriterForRow returns nil for all rows except the lowest-index
            // selected one. draggingFormation = .none is kept as a belt-and-suspenders
            // guard against any future code path that might introduce a second item.
            session.draggingFormation = .none

            // Replace the single dragging item's (already-suppressed, per
            // dragImageForRows) image with an explicit 1×1 transparent placeholder
            // too — belt-and-suspenders, matching this app's original list-view
            // drag implementation. The REAL visible preview is the separate
            // flyback window armed by dragEngine.prepareDrag below, positioned by
            // direct screen-point arithmetic and kept in sync via
            // DraggableListTableView's own draggingSession(_:movedTo:) override —
            // deliberately not the native per-item frame AppKit tracks here, which
            // proved unreliable for this session type across several fix attempts
            // (see GalleryDragEngine's class-level doc comment).
            let transparent = NSImage.transparentDragPlaceholder
            unsafe session.enumerateDraggingItems(
                options: .clearNonenumeratedImages,
                for: nil,
                classes: [NSPasteboardItem.self],
                searchOptions: [:]
            ) { item, _, _ in
                item.setDraggingFrame(
                    NSRect(origin: item.draggingFrame.origin,
                           size: NSSize(width: 1, height: 1)),
                    contents: transparent
                )
            }

            // Arm the drag engine: marks the session live in DragSessionMonitor and
            // prepares the flyback window at the drag's starting screen point.
            dragEngine.prepareDrag(
                filmCount: dragCount,
                posterImage: posterImage,
                startScreenPoint: screenPoint,
                sourceView: tableView
            )
        }

        func tableView(_ tableView: NSTableView,
                       draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint,
                       operation: NSDragOperation) {
            dragEngine.draggingSessionEnded(at: screenPoint, operation: operation)
        }

        // MARK: - Selection

        func withSuppressedCallbacks(_ block: () -> Void) {
            isSuppressingCallbacks = true
            defer { isSuppressingCallbacks = false }
            block()
        }

        func syncSelectionToView() {
            guard let tv = tableView, !isUpdatingSelection else { return }
            isUpdatingSelection = true
            defer { isUpdatingSelection = false }

            // Untracked: this also runs inside updateNSView — see untrackedSelectedFilmIDs.
            let selectedIDs = selectionState.untrackedSelectedFilmIDs
            guard !selectedIDs.isEmpty else {
                // Only call deselectAll if rows are actually selected; calling it on an
                // already-empty selection fires tableViewSelectionDidChange needlessly.
                if !tv.selectedRowIndexes.isEmpty {
                    tv.deselectAll(nil)
                }
                return
            }

            let validIDs = selectedIDs.filter { filmRowMap[$0] != nil }
            if validIDs.count != selectedIDs.count {
                if validIDs.isEmpty {
                    selectionState.selectImmediate(Set<UUID>())
                    tv.deselectAll(nil)
                    return
                }
                selectionState.selectImmediate(validIDs)
            }

            let rows = IndexSet(validIDs.compactMap { filmRowMap[$0] })
            if tv.selectedRowIndexes != rows {
                tv.selectRowIndexes(rows, byExtendingSelection: false)
            }
        }

        // MARK: - Contextual Menu

        /// Resolves the film set a secondary-click contextual menu should act on, and
        /// builds the menu for it. Called from DraggableListTableView.menu(for:), which
        /// has already verified the click landed on an actual row.
        ///
        /// SELECTION SEMANTICS. Identical to the grid's — see
        /// GallerySubview.Coordinator.contextMenu(forItemAt:) for the full rationale.
        /// In short: a secondary-click on an already-selected row leaves the selection
        /// untouched and the menu acts on the whole group; a secondary-click on an
        /// unselected row must select it, because "Edit Metadata…" / "Edit Releases…"
        /// are resolved downstream against SelectionState rather than against an ID
        /// carried in the command.
        ///
        /// `selectRowIndexes` fires tableViewSelectionDidChange synchronously, so the
        /// `isUpdatingSelection` guard is held across it to suppress the redundant
        /// updateSelectionFromView echo; the model write is then performed directly,
        /// immediately, via selectImmediate — the menu's tracking loop starts as soon as
        /// this method returns, so the deferred select() path would be too late.
        func contextMenu(forRow row: Int) -> NSMenu? {
            // A secondary-click on a section-divider row resolves to nil here and therefore
            // shows no menu at all — matching the grid, where the divider band is purely
            // decorative and non-interactive (SectionDividerDecorationView.hitTest).
            guard let tv = tableView, let clickedID = film(forRow: row)?.id else { return nil }

            var targetIDs = Set(tv.selectedRowIndexes.compactMap { row -> UUID? in
                film(forRow: row)?.id
            })

            if !targetIDs.contains(clickedID) {
                isUpdatingSelection = true
                tv.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                isUpdatingSelection = false
                selectionState.selectImmediate([clickedID], inputKind: .fromCurrentAppKitEvent())
                targetIDs = [clickedID]
            }

            return GalleryContextMenu.makeMenu(for: targetIDs)
        }

        private func updateSelectionFromView() {
            guard let tv = tableView,
                  !isUpdatingSelection,
                  !isSuppressingCallbacks else { return }
            isUpdatingSelection = true
            defer { isUpdatingSelection = false }

            let rows = tv.selectedRowIndexes
            let ids = Set(rows.compactMap { row -> UUID? in
                film(forRow: row)?.id
            })
            // Classify the input authoritatively from NSApp.currentEvent: a mouse
            // press/release is a deliberate discrete click, so RightSidebar resolves it
            // instantly instead of tripping the `.unspecified` timing fallback (75 ms
            // debounce) when clicks land < 0.15 s apart. NSTableView's native arrow-key
            // navigation reaches this method with a keyboard current event and therefore
            // still classifies `.unspecified` — preserving the existing timing-heuristic
            // debounce for held arrow keys in the list view, exactly as documented on
            // SelectionInputKind. See SelectionInputKind.fromCurrentAppKitEvent.
            selectionState.select(ids, inputKind: .fromCurrentAppKitEvent())
        }

        // MARK: - Observation

        private func setupSubscriptions() {
            observeSelectionState()

            // Switched over exhaustively, with no `default` clause: SelectionEvent has
            // exactly these two cases, so a `default` was unreachable (and warned as
            // such). Leaving it off is also the safer shape — a third event added later
            // becomes a compile error here rather than a silently ignored no-op.
            // Mirrors the identical switch in GallerySubview.Coordinator.
            AppEventBus.shared.selectionEvents
                .receive(on: RunLoop.main)
                .sink { [weak self] event in
                    guard let self else { return }
                    switch event {
                    case .selectAllFilms:
                        guard let tv = self.tableView, !self.films.isEmpty else { return }
                        // Set isUpdatingSelection before modifying the table view so
                        // tableViewSelectionDidChange → updateSelectionFromView is blocked.
                        // This mirrors the GallerySubview.selectAll() pattern: the visual
                        // selection happens here, not through the observation round-trip.
                        guard !self.isUpdatingSelection else { return }
                        self.isUpdatingSelection = true
                        // Row space, and film rows only: a contiguous 0..<films.count range
                        // would sweep any interleaved section-divider rows into the
                        // selection request. (They are unselectable, so AppKit would drop
                        // them — but building the set from the film rows themselves keeps
                        // the request itself honest rather than relying on that filtering.)
                        let all = IndexSet(self.filmRowMap.values)
                        self.withSuppressedCallbacks {
                            tv.selectRowIndexes(all, byExtendingSelection: false)
                        }
                        self.selectionState.selectImmediate(Set(self.films.map(\.id)))
                        DispatchQueue.main.async { [weak self] in self?.isUpdatingSelection = false }
                    case .clearFocusRings:
                        // Suppress tableViewSelectionDidChange so it doesn't schedule a
                        // redundant deferred selectionState.select(Set()) alongside the
                        // observation loop's own syncSelectionToView pass.
                        self.withSuppressedCallbacks {
                            self.tableView?.deselectAll(nil)
                        }
                    }
                }
                .store(in: &cancellables)

            // Cmd+L - Scroll the table so the topmost selected film sits in the top
            // visible row, exactly as the grid does. Works for both single and
            // multi-selection: IndexSet.first is the smallest index, i.e. the row nearest
            // the top, and divider rows are unselectable, so it is always a film row.
            //
            // This used scrollRowToVisible, which scrolls only as far as it must, so a film
            // below the viewport landed on the BOTTOM row — while the grid, and the
            // search-exit handoff that documents itself as matching Cmd+L, place it at the
            // top.
            AppEventBus.shared.uiCommands
                .receive(on: RunLoop.main)
                .sink { [weak self] command in
                    guard let self, command == .scrollToSelection else { return }
                    guard let row = self.tableView?.selectedRowIndexes.first,
                          let filmID = self.film(forRow: row)?.id else { return }
                    // Through the stopper, as the grid does. See CoastingScrollStopper.
                    self.coastStopper.jump { [weak self] stoppedCoast in
                        guard let self else { return }
                        self.scrollFilmToTop(filmID)
                        // The stop's didEndLiveScroll banked the pre-jump position.
                        if stoppedCoast { self.claimViewportForUser() }
                    }
                }
                .store(in: &cancellables)
        }

        // MARK: - Scroll-Origin Persistence

        /// Begins recording this view's scroll origin each time a user-driven scroll
        /// gesture ends. The list's copy of
        /// GallerySubview.Coordinator.installScrollOriginRecorder(on:) — see that method's
        /// doc comment for why the transition-time saves alone are not sufficient, why a
        /// notification that fires only for genuine user scrolling is immune to the
        /// mis-attribution those saves must guard against, and why delivery is deliberately
        /// left synchronous.
        func installScrollOriginRecorder(on scrollView: NSScrollView) {
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleLiveScrollEnded(_:)),
                name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            coastStopper.install(on: scrollView)
        }

        /// Lets Cmd+L stop a trackpad coast in flight. The grid's identical member
        /// (23.20) explains it; installed and removed with the scroll-origin recorder.
        private let coastStopper = CoastingScrollStopper()

        /// Removes the live-scroll observer. Idempotent. Called from cancelSubscriptions().
        private func removeScrollOriginRecorder() {
            NotificationCenter.default.removeObserver(
                self, name: NSScrollView.didEndLiveScrollNotification, object: nil)
            coastStopper.remove()
        }

        #if DEBUG
        // MARK: Viewport-Jump Tracer (DEBUG only)
        // The shared `ViewportJumpTracer` (23.20 GallerySubview.swift) — see it for the
        // rationale. Logs any clip-view move larger than three viewport heights, with the
        // call stack that made it.
        private let viewportJumpTracer = ViewportJumpTracer(owner: "list")

        func installViewportJumpTracer(on scrollView: NSScrollView) {
            viewportJumpTracer.install(on: scrollView) { [weak self] in
                self.map { "\($0.currentViewID)" } ?? "?"
            }
        }

        private func removeViewportJumpTracer() {
            viewportJumpTracer.remove()
        }
        #endif

        @objc private func handleLiveScrollEnded(_ notification: Notification) {
            guard let scrollView else { return }
            // The user has taken the viewport over by hand. Retired BEFORE the save for
            // the reason spelled out in GallerySubview.Coordinator's identical recorder:
            // bankScrollOrigin refuses to overwrite a key with an outstanding restore.
            ViewStateManager.shared.finishScrollOriginRestore(for: displayedScrollKey)
            ViewStateManager.shared.saveScrollPosition(scrollPosition(of: scrollView),
                                                       under: displayedScrollKey)
        }

        /// The scroll-bank key of the films this list is showing. See
        /// GallerySubview.Coordinator.displayedScrollKey.
        var displayedScrollKey: GalleryScrollKey {
            GalleryScrollKey(viewID: currentViewID, subTab: lastFilmQueueFilter?.rawValue)
        }

        /// See GalleryScrollPositionProviding.currentScrollState(). `prevViewID` is nil
        /// until this Coordinator's first update pass has run, which is exactly the
        /// "nothing rendered yet, currentViewID is still its default" condition the
        /// protocol requires be reported as nil rather than as a real identity.
        func currentScrollState() -> (key: GalleryScrollKey, position: GalleryScrollPosition)? {
            guard prevViewID != nil, let scrollView else { return nil }
            return (displayedScrollKey, scrollPosition(of: scrollView))
        }

        /// The scroll position of `scrollView` (this list's): its origin, anchored on the
        /// topmost visible film row. The list's counterpart to the grid's; see
        /// GalleryScrollPosition.
        func scrollPosition(of scrollView: NSScrollView) -> GalleryScrollPosition {
            let origin = scrollView.documentVisibleRect.origin
            guard origin.y > 0, let tv = tableView else { return GalleryScrollPosition(origin: origin) }
            let visible = tv.rows(in: tv.visibleRect)
            guard visible.length > 0, visible.location >= 0 else { return GalleryScrollPosition(origin: origin) }
            // The first FILM row in view; the topmost row can be a divider band.
            for row in visible.location..<(visible.location + visible.length) {
                guard let index = filmIndex(forRow: row) else { continue }
                let frame = tv.rect(ofRow: row)
                guard frame.height > 0 else { break }
                return GalleryScrollPosition(origin: origin, anchor: .init(
                    filmID: films[index].id, index: index, filmCount: films.count,
                    fraction: (origin.y - frame.minY) / frame.height))
            }
            return GalleryScrollPosition(origin: origin)
        }

        /// The content y a banked position resolves to in this list's current rows. See
        /// GalleryScrollPosition.restoreY.
        func restoreY(for position: GalleryScrollPosition) -> CGFloat {
            position.restoreY(
                filmCount: films.count,
                indexOf: { filmRowMap[$0].flatMap(filmIndex(forRow:)) },
                frameOfFilm: { index in
                    guard index < films.count, let tv = tableView,
                          let row = filmRowMap[films[index].id] else { return nil }
                    return tv.rect(ofRow: row)
                })
        }

        // MARK: - Search-Exit / Grid⟷List View-Style Toggle Scroll Handoff

        /// Returns the current row index for the given film ID, or nil if the film is
        /// not present in this view's data. Used by ListScrollView.viewWillDraw() to
        /// resolve a pending scroll target without exposing filmRowMap itself. Returns a
        /// TABLE row index, which is what both isRowVisible(_:) and rect(ofRow:) expect.
        func rowIndex(for filmID: UUID) -> Int? {
            filmRowMap[filmID]
        }

        /// Returns whether the given row is fully or partially visible in the current
        /// scroll viewport. Mirrors GallerySubview.Coordinator.isFilmVisible(at:) — used
        /// by ListScrollView.viewWillDraw() to decide whether a search-exit handoff
        /// needs to scroll at all, or whether the target is already on screen.
        func isRowVisible(_ row: Int) -> Bool {
            guard let tv = tableView else { return false }
            return tv.visibleRect.intersects(tv.rect(ofRow: row))
        }

        /// Returns the film in the row currently topmost in the visible viewport, for the
        /// GalleryScrollPositionProviding conformance used to capture a list→grid handoff
        /// target. `rows(in:)` returns an empty range (location == -1) when no rows
        /// intersect the given rect, which the guard below rejects.
        func topmostVisibleFilmID() -> UUID? {
            guard let tv = tableView, !films.isEmpty else { return nil }
            let visible = tv.rows(in: tv.visibleRect)
            guard visible.length > 0, visible.location >= 0 else { return nil }
            // Walk forward to the first FILM row in the visible range: the topmost visible
            // row can be a section-divider band, which has no film to hand off.
            for row in visible.location..<(visible.location + visible.length) {
                if let id = film(forRow: row)?.id { return id }
            }
            return nil
        }

        /// Scrolls the table so the given film's row becomes the topmost visible row,
        /// clamped to the table's maximum scroll extent. Does not alter selection.
        /// Mirrors GallerySubview.Coordinator.scrollToTopRow — see that method's doc
        /// comment for the general top-row-placement and clamping rationale. A film
        /// no longer present in this view's data (e.g. a stale handoff target) is
        /// silently ignored, matching the equivalent guard in the grid's search-exit
        /// and view-style-toggle handoff paths.
        func scrollFilmToTop(_ filmID: UUID) {
            guard let tv = tableView, let scrollView, let row = filmRowMap[filmID] else { return }

            let rowRect = tv.rect(ofRow: row)
            // Content height is computed directly from the row model's summed heights
            // rather than from tv.bounds.height. NSTableView's document-view frame can still reflect
            // its pre-reload (or entirely unestablished) size on the very first
            // viewWillDraw pass for a freshly-created table — exactly when this method
            // is called from the search-exit / view-style-toggle scroll handoff — so
            // tv.bounds.height can read 0 or stale at that moment. When it does, the old
            // clamp (content height minus viewport height) collapsed to 0, forcing
            // targetY to 0 for every row regardless of its real position: the symptom
            // was a list that always lands back at the top instead of at the preserved
            // selection. Row count × row height is pure arithmetic with no dependency on
            // AppKit's internal layout timing — mirrors why rowRect above (also pure
            // arithmetic via rect(ofRow:)) never had this problem in the first place.
            //
            // Sourced from scrollableContentHeight (listContentHeight, summed once per
            // row-model rebuild, plus the inset style's padding) rather than restated as
            // films.count × kListRowHeight, so it stays correct when the taller
            // section-divider rows are interleaved. The clamp arithmetic itself
            // is NSScrollView.maxVerticalScrollOffset(forContentHeight:) — shared with
            // scrollToSectionBand and ListScrollView.resolvePendingOriginRestore(), so the
            // three can never drift apart, and inset-aware so a target near the end of the
            // table is not capped short of the StatusBar overlay.
            let maxScrollY = scrollView.maxVerticalScrollOffset(forContentHeight: scrollableContentHeight)
            let targetY = max(0, min(rowRect.origin.y, maxScrollY))

            appViewportMove {
                scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        /// Declares that the user has taken this viewport over by hand, so nothing the app
        /// armed earlier may still move it. The list's counterpart to
        /// GallerySubview.Coordinator.claimViewportForUser() — see that method for the full
        /// rationale and the failure it prevents.
        func claimViewportForUser() {
            ViewStateManager.shared.finishScrollOriginRestore(for: displayedScrollKey)
            // The coordinator holds this as a plain NSScrollView; the two armed-target
            // properties live on the ListScrollView subclass that actually resolves them.
            if let listScrollView = scrollView as? ListScrollView {
                listScrollView.pendingScrollPosition = nil
                listScrollView.pendingScrollFilmID = nil
            }
            guard let scrollView else { return }
            ViewStateManager.shared.saveScrollPosition(scrollPosition(of: scrollView),
                                                       under: displayedScrollKey)
        }

        /// Places the section band beginning with `firstFilmID` at the top of the viewport.
        ///
        /// The list's bands are real rows, and `rebuildRowModel` always emits one
        /// immediately before the first film of its section — so the band is the row at
        /// `filmRow - 1`, verified rather than assumed via `rowItems`. Scrolling to the film
        /// itself would push the very label the user clicked just off the top edge; when no
        /// band precedes the film (the bands were switched off between the menu being built
        /// and the item being chosen) the film row is the correct target anyway.
        func scrollToSectionBand(firstFilmID: UUID) {
            guard let tv = tableView, let scrollView, let filmRow = filmRowMap[firstFilmID] else { return }

            let bandRow = filmRow - 1
            let targetRow = (bandRow >= 0 && rowItems[bandRow].isDivider) ? bandRow : filmRow

            // Same clamp as scrollFilmToTop above, and for the same reasons — see that
            // method's comment on why contentHeight comes from scrollableContentHeight.
            let maxScrollY = scrollView.maxVerticalScrollOffset(forContentHeight: scrollableContentHeight)
            let targetY = max(0, min(tv.rect(ofRow: targetRow).origin.y, maxScrollY))

            appViewportMove {
                scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            scrollView.flashScrollers()
            // See the identical call in the grid's scrollToSectionBand: a programmatic jump
            // emits no didEndLiveScroll, so the new position must be banked explicitly or
            // the pre-jump origin survives to be restored later.
            claimViewportForUser()
        }

        private func observeSelectionState() {
            observationTask = Task(priority: .userInitiated) { @MainActor [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        withObservationTracking {
                            _ = self.selectionState.selectedFilmIDs
                        } onChange: {
                            continuation.resume()
                        }
                    }
                    // A dismantled list's loop wakes once more on the next change; it must
                    // stop without syncing. See GallerySubview.Coordinator.observeSelectionState.
                    guard !Task.isCancelled else { break }
                    guard !self.isUpdatingSelection else { continue }
                    self.syncSelectionToView()
                }
            }
        }

        // MARK: - NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            rowItems.count
        }

        // MARK: - NSTableViewDelegate

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard row >= 0, row < rowItems.count else { return nil }

            switch rowItems[row] {
            case .divider(let section, let filmCount):
                let id = NSUserInterfaceItemIdentifier("ListSectionDivider")
                if let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ListDividerHostCell {
                    cell.update(section: section, filmCount: filmCount)
                    return cell
                }
                let cell = ListDividerHostCell()
                cell.identifier = id
                cell.update(section: section, filmCount: filmCount)
                return cell

            case .film(let index):
                guard index < films.count else { return nil }
                let film = films[index]
                let id = NSUserInterfaceItemIdentifier("ListRow")
                let subtitle = subtitleProvider?.subtitle(film.id)

                if let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ListRowHostCell {
                    cell.update(film: film, subtitle: subtitle)
                    return cell
                }

                let cell = ListRowHostCell()
                cell.identifier = id
                cell.update(film: film, subtitle: subtitle)
                return cell

            case .slot(let number):
                let id = NSUserInterfaceItemIdentifier("ListUpNextSlot")
                let cell = tableView.makeView(withIdentifier: id, owner: nil) as? UpNextSlotListCell
                    ?? { let fresh = UpNextSlotListCell(); fresh.identifier = id; return fresh }()
                cell.update(slotNumber: number)
                return cell
            }
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row >= 0, row < rowItems.count else { return kListRowHeight }
            return rowItems[row].rowHeight
        }

        /// Section-divider bands are purely decorative and must never take the selection —
        /// matching the grid, whose divider decoration view is excluded from hit-testing
        /// entirely (SectionDividerDecorationView.hitTest). NSTableView also honors this
        /// for its own native arrow-key navigation, stepping straight over a divider row
        /// to the next selectable film row, which is precisely the "divider is transparent
        /// to navigation" behavior GallerySubview implements by hand for the grid.
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard row >= 0, row < rowItems.count else { return false }
            // Empty "Up Next" slots are no more selectable than divider bands.
            return rowItems[row].isFilm
        }

        /// Supplies a background- and selection-free row view for section-divider rows, so
        /// a divider band renders against the table's plain backdrop rather than picking up
        /// an alternating content stripe (which would read as a content row). Film rows
        /// return nil and therefore keep NSTableView's stock row view, leaving the existing
        /// alternating-stripe and `.inset` selection appearance completely untouched.
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            // Empty "Up Next" slots draw their own outline, so they take the plain row too.
            guard row >= 0, row < rowItems.count, !rowItems[row].isFilm else { return nil }
            let id = NSUserInterfaceItemIdentifier("ListSectionDividerRowView")
            if let existing = tableView.makeView(withIdentifier: id, owner: nil) as? ListDividerRowView {
                return existing
            }
            let rowView = ListDividerRowView()
            rowView.identifier = id
            return rowView
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            updateSelectionFromView()
        }
    }
}

// MARK: - DraggableListTableView

/// NSTableView subclass used as the backing table for GalleryListView.
/// Overrides the NSDraggingSource sourceOperationMaskFor and movedTo callbacks
/// inherited from NSTableView: the former restricts drag operations to .copy
/// within the application, the latter keeps GalleryDragEngine's flyback window
/// (the visible drag preview) in sync with the cursor. Also overrides
/// dragImageForRowsWithIndexes to suppress the native row-content drag image
/// with an invisible placeholder — the flyback window is the sole visible
/// preview, armed separately via willBeginAt → GalleryDragEngine.prepareDrag.
///
/// A manual mouseDown/mouseDragged/mouseUp bypass of this native pipeline
/// (mirroring GalleryCollectionView's approach for the grid) was tried and does
/// NOT work: NSTableView.mouseDown(with:) runs its own internal, blocking
/// event-tracking loop that consumes every subsequent mouseDragged/mouseUp event
/// itself whenever a row is hit, so a subclass's own overrides of those methods
/// never see them — regardless of whether a pasteboardWriter is available. The
/// native pipeline below (pasteboardWriterForRow / willBeginAt / dragImageForRows)
/// is therefore the only viable hook point for this view.
#if DEBUG
extension DraggableListTableView {
    /// Row → the rating each film row the table currently holds a view for is displaying,
    /// prepared off-screen rows included. For harness checks of in-place row refresh.
    func debugDisplayedRatings() -> [Int: Int] {
        var ratings: [Int: Int] = [:]
        enumerateAvailableRowViews { rowView, row in
            if let cell = rowView.view(atColumn: 0) as? ListRowHostCell,
               let rating = cell.currentUserRating {
                ratings[row] = rating
            }
        }
        return ratings
    }
}
#endif

final class DraggableListTableView: NSTableView {

    /// Set by DraggableListView.makeNSView immediately after construction.
    /// fileprivate because DraggableListView is a private type in this file.
    fileprivate weak var coordinator: DraggableListView.Coordinator?

    /// Supplies the contextual (secondary-click) menu for a given row. Wired to
    /// `DraggableListView.Coordinator.contextMenu(forRow:)`, which resolves the target
    /// film set — and, when required, adjusts the selection — before building the menu.
    /// Returning nil suppresses the menu entirely.
    fileprivate var getContextMenu: ((Int) -> NSMenu?)?

    // MARK: - Contextual Menu

    /// Supplies the gallery contextual menu for a secondary-click (or Control-click,
    /// which AppKit delivers as a right mouse event) that lands on an actual row.
    ///
    /// The hit test deliberately matches the one `mouseDown(with:)` below already
    /// applies: a valid row AND a valid column. With the `.inset` table style, the
    /// horizontal margins flanking the row highlight belong to no column even though
    /// `row(at:)` still resolves a row there, and a primary click in that dead zone is
    /// already treated as "clicking on nothing." Requiring `clickedCol >= 0` keeps the
    /// two gestures consistent, so the padding around and below the rows is a no-op for
    /// the contextual menu too.
    ///
    /// Deliberately does not call `super.menu(for:)` — NSTableView's own implementation
    /// would surface the table's `menu` property for non-row points, which is precisely
    /// the no-op case we want.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedCol = column(at: point)
        guard clickedRow >= 0, clickedCol >= 0 else { return nil }
        return getContextMenu?(clickedRow)
    }

    // MARK: - Side-padding deselect

    /// Deselects the current selection when the user clicks in the horizontal
    /// padding between the row highlight's edges and the view's left/right edges.
    ///
    /// With the `.inset` table style, rows are drawn with inset horizontal margins.
    /// NSTableView's own hit-testing considers those margins part of no column
    /// (column(at:) returns -1) even when row(at:) finds a valid row. A click in
    /// this dead zone previously did nothing when a row was selected. This override
    /// converts such clicks into a deselect, matching the behavior of clicking in
    /// the empty space below the last row — both are "clicking on nothing".
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedCol = column(at: point)

        // Defensive self-heal: close-and-flush any click window a prior gesture
        // somehow left open (see GalleryCollectionView.mouseDown for the identical
        // guard). Internally guarded — a free no-op in every normal flow.
        DragSessionMonitor.shared.clickWindowDidClose()

        // The user is acting on this viewport directly, so retire anything still armed to
        // move it. Mirrors the identical call at the top of GalleryCollectionView.mouseDown
        // — see Coordinator.claimViewportForUser() for what it prevents.
        coordinator?.claimViewportForUser()

        // If the click lands on a valid row but outside any column (i.e., in the
        // left or right inset padding), deselect and absorb the event. Do not call
        // super, which would let NSTableView treat it as a row selection gesture.
        if clickedRow >= 0 && clickedCol < 0 {
            if !selectedRowIndexes.isEmpty {
                deselectAll(nil)
            }
            return
        }

        // Record which row the user pressed on before super.mouseDown enters its
        // drag-detection loop. pasteboardWriterForRow is called during that loop,
        // but the call order across multiple selected rows is not guaranteed to
        // start with the grabbed row. Storing it here — at the definitive click
        // moment — gives willBeginAt the authoritative source for the poster image.
        // Film rows only. A section-divider row can never originate a drag
        // (pasteboardWriterForRow returns nil for it), so recording one here could only
        // ever seed willBeginAt with a row that resolves to no film.
        if clickedRow >= 0, coordinator?.filmIndex(forRow: clickedRow) != nil {
            coordinator?.pendingDragSourceRow = clickedRow
        }

        // Open the click-ambiguity deferral window around NSTableView's synchronous
        // internal tracking loop (super.mouseDown returns only once the gesture has
        // resolved — after mouseUp for a plain click, or right after the drag session
        // is begun for a drag). Selection commits — and the sidebar's deferred
        // selection write can drain — inside that loop, so without this window a fast
        // drag's session start contends with the sidebar content rebuild. Row hits
        // only: empty-space clicks never commit an item selection this way. On
        // return, clickWindowDidClose() posts the plain-click flush notification, or
        // no-ops if a session began (sessionWillBegin absorbed the window — the
        // flush then belongs to session end) — see DragSessionMonitor.
        let opensClickWindow = clickedRow >= 0
        if opensClickWindow {
            DragSessionMonitor.shared.clickWindowDidOpen()
        }
        super.mouseDown(with: event)
        if opensClickWindow {
            DragSessionMonitor.shared.clickWindowDidClose()
        }
    }

    // MARK: - Drag image suppression

    /// Returns a 1×1 transparent image, suppressing the native row-content drag
    /// preview entirely. Called by NSTableView during drag-session construction,
    /// before willBeginAt fires. This is the definitive suppression point —
    /// delegate hooks fire too late since the image is already composited by then.
    ///
    /// The `offset` parameter doesn't matter here — it governs the native item's
    /// own cursor anchor, but that item is never actually displayed: the real,
    /// visible preview is the separate flyback window armed by
    /// GalleryDragEngine.prepareDrag and kept in sync by this class's own
    /// draggingSession(_:movedTo:) override below. `.zero` matches this app's
    /// original, proven-reliable list-view drag implementation.
    override func dragImageForRows(with dragRows: IndexSet,
                                   tableColumns: [NSTableColumn],
                                   event dragEvent: NSEvent,
                                   offset dragImageOffset: NSPointPointer) -> NSImage {
        unsafe dragImageOffset.pointee = .zero
        return NSImage.transparentDragPlaceholder
    }

    // MARK: - NSDraggingSource overrides
    // NSTableView already conforms to NSDraggingSource. We override here to:
    //   sourceOperationMaskFor — restrict the allowed operations to .copy only.
    //   movedTo               — keep the flyback window in sync with the cursor.
    // Begin/end are handled via NSTableViewDelegate callbacks in Coordinator.

    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }

    override func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        coordinator?.dragEngine.dragMoved(to: screenPoint)
    }
}

// MARK: - ListRowHostCell

/// NSView subclass that hosts a SwiftUI GalleryListRow via NSHostingView.
/// Reused across rows via NSTableView's cell-reuse queue.
///
/// Mirrors GalleryItem's change-tracking pattern: all fields rendered by
/// GalleryListRow are tracked individually so that rootView is only reassigned
/// when something the view actually displays has changed.
private final class ListRowHostCell: NSView {

    private var hostingView: NSHostingView<GalleryListRow>?

    // Change tracking covers every field that GalleryListRow renders:
    //   posterUID      → PosterThumbnailView
    //   name           → title Text
    //   hasPurchased   → purchased-disc badge
    //   durationParts  → abbreviated duration (hour + minute items)
    //   userRating     → star + rating Text
    //   releaseYear    → year Text (monospaced)
    //   subtitle       → by-line Text under the title (Recents views only)
    // Tracking all of them ensures that in-place metadata edits (e.g. correcting a
    // film's name, adjusting its rating, marking a release purchased, or entering an
    // edited runtime) are reflected immediately in visible rows, even when the film's
    // sort position — and therefore the table's count and first/last anchors — has not
    // changed.
    //
    // The two derived fields are tracked as their RENDERED values rather than as the
    // raw snapshot fields they come from (`releases`, and `edited`/`editedDuration`/
    // `duration`), so a change that does not alter what the row actually shows — a
    // release edited in some unrelated way, say — correctly skips the rootView
    // reassignment. Both are computed once here, then handed to the row, so the
    // comparison and the render can never disagree about what is displayed.
    private var currentFilmID: UUID?
    private var currentPosterUID: String?
    private var currentName: String?
    private var currentHasPurchased: Bool?
    private var currentDurationParts: DurationParts?
    private(set) var currentUserRating: Int?
    private var currentReleaseYear: String?
    // Double-optional on purpose: nil means "never configured", .some(nil) means
    // "configured with no subtitle", so a first configuration can never be mistaken
    // for an unchanged one.
    private var currentSubtitle: String??

    // Both initializers are required, and neither is redundant: declaring
    // init?(coder:) suppresses initializer inheritance, so init(frame:) has to be
    // restated for the no-argument construction the cell-reuse paths above use.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(film: FilmSnapshot, subtitle: String?) {
        // Derived once, up front: used for both the change comparison and the render.
        let hasPurchased = GalleryListRow.hasPurchasedRelease(film)
        let durationParts = GalleryListRow.durationParts(film)

        let needsUpdate = currentFilmID       != film.id          ||
                          currentPosterUID    != film.posterUID   ||
                          currentName         != film.name        ||
                          currentHasPurchased != hasPurchased     ||
                          currentDurationParts != durationParts   ||
                          currentUserRating   != film.userRating  ||
                          currentReleaseYear  != film.releaseYear ||
                          currentSubtitle     != .some(subtitle)

        // Update all tracking fields before the (conditional) hosting-view update
        // so the next call has the correct baseline regardless of whether we render.
        currentFilmID        = film.id
        currentPosterUID     = film.posterUID
        currentName          = film.name
        currentHasPurchased  = hasPurchased
        currentDurationParts = durationParts
        currentUserRating    = film.userRating
        currentReleaseYear   = film.releaseYear
        currentSubtitle      = .some(subtitle)

        let rootView = GalleryListRow(film: film,
                                      hasPurchasedRelease: hasPurchased,
                                      durationParts: durationParts,
                                      subtitle: subtitle)

        if let host = hostingView {
            // Skip the rootView assignment entirely when nothing displayed changed.
            // SwiftUI still diffs on assignment even when the value is identical,
            // so avoiding the assignment is the only way to guarantee zero CPU cost.
            if needsUpdate {
                #if DEBUG
                GalleryRefreshProbe.listRowRootViewAssignments += 1
                #endif
                host.rootView = rootView
            }
        } else {
            let host = NSHostingView(rootView: rootView)
            host.translatesAutoresizingMaskIntoConstraints = false
            // Disable SwiftUI intrinsic-size participation. The hosting view is
            // fully constraint-driven (pinned to all four edges below), so Auto
            // Layout must never invoke a SwiftUI layout pass to satisfy its size.
            // Without this, NSHostingView performs a full SwiftUI layout on every
            // cell recycle during scrolling. Matches GalleryItem behavior.
            host.sizingOptions = []
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            hostingView = host
        }
    }
}

// MARK: - ListDividerRowView

/// Row view used for section-divider rows only.
///
/// NSTableView draws a row's alternating-stripe background and its selection highlight in
/// the row view, not the cell view. A divider band must have neither: a stripe would make
/// it read as a content row, and the band is unselectable anyway
/// (`tableView(_:shouldSelectRow:)` returns false for it). Overriding the two drawing
/// entry points to no-ops is the narrowest way to achieve that, and — critically — it
/// touches ONLY divider rows: `tableView(_:rowViewForRow:)` returns nil for every film
/// row, which leaves them on NSTableView's stock row view with its stock `.inset`
/// selection appearance entirely unchanged.
private final class ListDividerRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        // Deliberately empty: the divider band sits directly on the table's own
        // backgroundColor, matching the grid, where the divider decoration draws no
        // background of its own either (see SectionDividerDecorationView).
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // Deliberately empty. Unreachable in normal operation — a divider row can never
        // become selected — but a no-op here means even a future path that somehow marked
        // one selected could not paint a highlight over a decorative band.
    }
}

// MARK: - ListDividerHostCell

/// NSView subclass that hosts a SwiftUI `GalleryListSectionDivider` via NSHostingView.
/// The divider counterpart to ListRowHostCell, with the identical reuse and
/// change-tracking discipline: `rootView` is reassigned only when the section or its film
/// count actually changed, so a recycled instance neither re-renders needlessly nor shows
/// a stale section name.
private final class ListDividerHostCell: NSView {

    private var hostingView: NSHostingView<GalleryListSectionDivider>?

    private var currentSection: GallerySection?
    private var currentFilmCount: Int?

    // Both initializers are required, and neither is redundant: declaring
    // init?(coder:) suppresses initializer inheritance, so init(frame:) has to be
    // restated for the no-argument construction the cell-reuse paths above use.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(section: GallerySection, filmCount: Int) {
        let needsUpdate = currentSection != section || currentFilmCount != filmCount
        currentSection = section
        currentFilmCount = filmCount

        let rootView = GalleryListSectionDivider(section: section, filmCount: filmCount)

        if let host = hostingView {
            if needsUpdate {
                host.rootView = rootView
            }
        } else {
            let host = NSHostingView(rootView: rootView)
            host.translatesAutoresizingMaskIntoConstraints = false
            // Constraint-driven, exactly as in ListRowHostCell — Auto Layout must never
            // invoke a SwiftUI sizing pass to satisfy this view's dimensions.
            host.sizingOptions = []
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            hostingView = host
        }
    }
}

// MARK: - GalleryListSectionDivider

/// The list gallery's section band: a bold, left-aligned section label with a
/// right-aligned live film count, sitting just above a hairline separator that is
/// bottom-anchored within the band — deliberately the same composition, in the same
/// order, as the grid's SectionDividerDecorationView, so the two gallery styles present
/// the Film Queue's sections identically. Only the type sizes differ, scaled down to suit
/// a 44pt list row rather than a poster tile.
private struct GalleryListSectionDivider: View {
    let section: GallerySection
    let filmCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(section.displayName)
                    // 20pt bold, matching SectionDividerDecorationView's sectionLabel in
                    // the grid style exactly, so the two gallery styles label the Film
                    // Queue's sections identically rather than at two different scales.
                    // The count label beside it was already 10pt in both.
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                Text(UpNextSlots.sectionCountText(section: section, filmCount: filmCount))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Color, not a Divider(): a plain Divider draws at the system hairline
            // thickness and cannot be thickened, whereas the grid's band uses an explicit
            // 2pt rule. Matching it keeps the two styles visually consistent. Color also
            // resolves for light/dark automatically, unlike the raw CALayer background
            // the AppKit decoration view has to re-resolve by hand.
            Color(nsColor: .separatorColor)
                .frame(height: 2)
        }
        // The band content keeps its own fixed height; the vertical padding is added
        // around it, so the extra space appears BETWEEN the divider and the film rows
        // above and below rather than being absorbed into the band's internal layout.
        .frame(height: kListSectionDividerBandHeight)
        // Aligned with the film rows' own symmetric horizontal inset so the label shares a
        // left edge with the poster column and the count shares a right edge with the year.
        .padding(.horizontal, GalleryListRow.contentInset)
        .padding(.vertical, kListSectionDividerVerticalPadding)
        .frame(height: kListSectionDividerHeight)
    }
}

// MARK: - GalleryListRow

/// One film row: poster thumbnail, title, then the four fixed-width trailing metadata
/// columns — purchased badge, abbreviated duration, user rating, and release year.
///
/// COLUMN WIDTHS. The four trailing columns are fixed-width and the gap between them is a
/// single shared constant, rather than the per-column ad-hoc padding this row previously
/// used. Fixed widths are what makes the columns line up vertically down the table at all
/// (a self-sizing column would jitter from row to row as its content changed), and they
/// are what keeps the row cheap: every row's layout is then pure arithmetic, with no
/// measurement pass and no dependency on the enclosing width — which matters when the
/// table is recycling cells during a fast scroll.
///
/// The two new columns add roughly 90pt to the trailing block. The title absorbs that: it
/// is the only flexible element in the row and truncates with an ellipsis, so a narrow
/// window shortens the title rather than clipping or wrapping any column. The column
/// constants below were tightened (rating 30→28, year 60→40, and the rating column's
/// 20pt trailing pad folded into the shared gap) specifically to claw back width for the
/// title, so the net cost at small window sizes is smaller than the two new columns'
/// own footprint.
struct GalleryListRow: View {
    let film: FilmSnapshot
    /// Precomputed by ListRowHostCell so the same value drives both its change tracking
    /// and this render — see that type's tracking comment.
    let hasPurchasedRelease: Bool
    /// Precomputed abbreviated runtime, split into separately aligned components. Either
    /// or both may be empty (no runtime recorded, or a whole number of hours/minutes).
    let durationParts: DurationParts
    /// Optional by-line under the title -- the same string the grid shows beneath the
    /// poster (a Recents date), nil everywhere the grid shows none. Resolved once by the
    /// Coordinator so the host cell's change tracking and this render agree.
    let subtitle: String?

    /// The row's symmetric horizontal content inset. Applied as the poster's leading
    /// padding and as the metadata block's trailing padding, so the space between the
    /// content and the view's edge is identical on both sides. The left side is the
    /// reference: this is the poster's long-standing 8pt leading inset, now named.
    static let contentInset: CGFloat = 8

    // Fixed trailing-column geometry.
    //
    // GOVERNING RULE: every column's box is sized to fit its own content and no more, and
    // ALL visible separation comes from `columnGap`. That rule is what makes the gaps look
    // even, and breaking it is exactly what made the rating -> year gap read as roughly
    // twice the others: the year box was 40pt holding ~29pt of digits, and because it was
    // trailing-aligned, all ~11pt of that surplus sat on its LEFT, invisibly stacking on
    // top of columnGap. Slack inside a box is never neutral -- it always surfaces as a gap
    // on whichever side the alignment pushes it to.
    //
    //   discColumnWidth   -- the 15pt symbol, centered.
    //   hoursBoxWidth     -- "12 hr." at 11pt, right-aligned. Sized for two digits so an
    //                        unusually long runtime cannot truncate mid-word.
    //   minutesBoxWidth   -- "59 min." at 11pt, right-aligned.
    //   durationInnerGap  -- hour/minute separation. Deliberately smaller than columnGap:
    //                        the two halves are one value and should read as closer
    //                        together than two independent columns are.
    //   ratingColumnWidth -- the star glyph plus a double-digit rating, and no more.
    //   yearColumnWidth   -- four monospaced 12pt digits, and no more (was 40).
    private static let columnGap: CGFloat = 16
    // The disc badge's own gap, half of columnGap. It needs its own value because the
    // hours box that follows is right-aligned and sized for a two-digit hour, so a
    // typical one-digit runtime leaves ~7pt of empty box on the duration column's
    // LEADING side. Per the GOVERNING RULE above that slack surfaces as a gap, and it
    // lands precisely here -- stacked on top of columnGap, which made this one
    // separation read as roughly double the others. It is unavoidable without giving
    // up the hours' fixed right edge, so the gap is trimmed to compensate instead.
    private static let discToDurationGap: CGFloat = 8
    private static let discColumnWidth: CGFloat = 18
    private static let hoursBoxWidth: CGFloat = 30
    private static let minutesBoxWidth: CGFloat = 40
    private static let durationInnerGap: CGFloat = 4
    private static let ratingColumnWidth: CGFloat = 28
    private static let yearColumnWidth: CGFloat = 30

    var body: some View {
        HStack(spacing: 10) {
            PosterThumbnailView(posterUID: film.posterUID)
                .padding(.leading, Self.contentInset)

            // Title, with the subtitle double-stacked beneath it when the view has one.
            // Both lines truncate independently and the stack is leading-aligned, so a
            // short by-line sits flush under the title's first character. The two lines
            // (12pt + 10pt, 2pt apart) fit inside the unchanged 44pt row height with the
            // same vertical centering the lone title had, so no row geometry, scroll
            // arithmetic, or divider math is affected.
            VStack(alignment: .leading, spacing: 2) {
                Text(film.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            // minLength 8 guarantees a visible gap between a truncated title and the
            // metadata columns instead of the two running together.
            Spacer(minLength: 8)

            // spacing is 0 and each boundary carries its own explicit leading padding:
            // the disc -> duration gap has to differ from the other two (see
            // discToDurationGap), which a single uniform HStack spacing cannot express.
            HStack(spacing: 0) {
                // Purchased badge: shown when ANY associated release is marked purchased,
                // regardless of format. Rendered as a fixed-width slot in both states (a
                // 1pt-tall clear filler when absent) so the columns to its right hold the
                // same x-position on every row whether or not the badge is present.
                Group {
                    if hasPurchasedRelease {
                        Image(systemName: "opticaldisc.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
                .frame(width: Self.discColumnWidth, alignment: .center)
                // The glyph alone doesn't convey its meaning, so name it; the empty
                // placeholder state is hidden from assistive technology entirely rather
                // than announced as a blank element.
                .accessibilityLabel(Text("Purchased"))
                .accessibilityHidden(!hasPurchasedRelease)

                // Hour and minute components each get their OWN fixed-width box, and each
                // is right-aligned within it. That gives two guarantees a single string
                // cannot: the hours' right edge and the minutes' right edge each hold one
                // fixed vertical line down the table, so neither half shifts as digit
                // counts change (a 5-minute value and a 50-minute value end at the same
                // x), and the visible gap between the halves is a constant set by the box
                // widths rather than something that varies with the values.
                //
                // The gap is `durationInnerGap` and nothing else — the boxes are sized to
                // their own content, so no leftover box slack contributes to it. This is
                // the same trap the year column fell into (see below).
                HStack(spacing: Self.durationInnerGap) {
                    Text(durationParts.hours)
                        .lineLimit(1)
                        .frame(width: Self.hoursBoxWidth, alignment: .trailing)

                    Text(durationParts.minutes)
                        .lineLimit(1)
                        .frame(width: Self.minutesBoxWidth, alignment: .trailing)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, Self.discToDurationGap)

                HStack(spacing: 2) {
                    if film.userRating > 0 {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("\(film.userRating)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            // Belt-and-suspenders against the double-digit wrap: the column
                            // is now sized snugly to "star + 10", so this guarantees a
                            // two-digit rating stays on one line rather than stacking its
                            // digits vertically if the fit is ever marginal.
                            .lineLimit(1)
                            .fixedSize()
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
                .frame(width: Self.ratingColumnWidth, alignment: .leading)
                .padding(.leading, Self.columnGap)

                // Trailing-aligned, and now sized to its own content: the alignment puts
                // the year's right edge exactly `contentInset` from the view's right edge
                // (matching the poster's left inset), and the tight width means there is no
                // surplus left over to pile up on its leading side as a false gap. See the
                // GOVERNING RULE note on the constants above.
                Text(film.releaseYear)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: Self.yearColumnWidth, alignment: .trailing)
                    .padding(.leading, Self.columnGap)
            }
            // The trailing columns are fixed-size and must never be the element that
            // gives way when the row is narrow — the title is. Without this, SwiftUI is
            // free to compress the fixed frames instead of truncating the Text.
            .layoutPriority(1)
            // Mirrors the poster's leading inset exactly, so the gap between the year's
            // right edge and the view's right edge equals the gap between the poster's
            // left edge and the view's left edge. Both read from kListRowContentInset,
            // so the two sides cannot drift apart.
            .padding(.trailing, Self.contentInset)
        }
        .frame(height: kListRowHeight)
    }

    // MARK: - Derived Column Values
    //
    // Static and `nonisolated` so ListRowHostCell can compute them once and use the
    // results for both its change comparison and this row's rendered content, which is
    // what guarantees the two can never disagree about what is on screen.

    /// True when at least one associated release is marked purchased, in any format.
    /// Uses `contains(where:)` rather than FilmSnapshot.purchasedReleases so no
    /// intermediate array is allocated per row during scrolling.
    nonisolated static func hasPurchasedRelease(_ film: FilmSnapshot) -> Bool {
        film.releases.contains { $0.purchased }
    }

    /// The film's runtime split into abbreviated hour and minute components (e.g. "1 hr."
    /// and "50 min."), preferring the edited runtime when one applies. Both components are
    /// empty when no runtime is recorded at all; the hour component alone is empty for a
    /// sub-hour runtime, and the minute component alone for a whole number of hours.
    ///
    /// The "edited runtime applies" test — `edited` is set AND `editedDuration` parses to
    /// a positive millisecond count — is `FilmSnapshot.effectiveDuration`, the same one
    /// MetadataCache sorts by, so the runtime shown in this column always agrees with the
    /// runtime the gallery sorts by. The
    /// `edited` term matters on its own: FilmSheet blanks `editedDuration` on save when
    /// the film is not marked as edited, but a stale non-empty value from an older record
    /// must not resurface here.
    ///
    /// Decomposition goes through RSBHelpers.hoursAndMinutes rather than a local parse, so
    /// this column's notion of "no duration" cannot drift from the one the sidebar's
    /// duration formatters use.
    nonisolated static func durationParts(_ film: FilmSnapshot) -> DurationParts {
        guard let parts = RSBHelpers.hoursAndMinutes(from: film.effectiveDuration) else {
            return DurationParts(hours: "", minutes: "")
        }
        // A zero component renders as empty rather than "0 hr."/"0 min.", matching
        // RSBHelpers.formattedDurationAbbreviated's own suppression of the zero term.
        return DurationParts(
            hours:   parts.hours   > 0 ? "\(parts.hours) hr."    : "",
            minutes: parts.minutes > 0 ? "\(parts.minutes) min." : ""
        )
    }
}

// MARK: - DurationParts

/// The two separately aligned halves of the list gallery's duration column. Equatable so
/// ListRowHostCell can use it directly as a change-tracking value.
struct DurationParts: Equatable {
    let hours: String
    let minutes: String
}

// MARK: - PosterThumbnailView

private struct PosterThumbnailView: View {
    let posterUID: String

    private let thumbnailWidth: CGFloat = 24
    private let thumbnailHeight: CGFloat = 36

    var body: some View {
        if posterUID.isEmpty {
            placeholderView
        } else if let image = PosterCache.shared.getImageWithFallback(for: posterUID) {
            Image(nsImage: image)
                .resizable()
                // PosterCache hands back the full-resolution decoded poster, which is then
                // drawn into a 24×36pt slot — a very large downscale ratio. SwiftUI's
                // default interpolation point-samples aggressively at that ratio, which is
                // what produces the harsh, aliased edges: fine poster detail lands on or
                // between sample points essentially at random, so nearby pixels along an
                // edge pick up wildly different source values. `.high` switches to a
                // properly filtered resampling that averages the source neighborhood
                // instead, and `.antialiased(true)` smooths the shape's own boundary.
                //
                // Both are draw-time flags on an image that is already decoded and cached,
                // so this costs a slightly more expensive blit of a 24×36pt region and
                // nothing else — no extra decode, no additional memory, and no change to
                // the cache. Applied before `.scaledToFill()` so they govern the scaling
                // operation itself rather than a subsequent one.
                .interpolation(.high)
                .antialiased(true)
                .scaledToFill()
                .frame(width: thumbnailWidth, height: thumbnailHeight)
                .clipped()
                // Soft inner-shadow band along the edges -- see 23.55 PosterEdgeSheen.swift.
                .overlay { PosterEdgeSheen.overlay() }
                // `.continuous` matches every other poster site and the sheen's own corner
                // profile; at a 2pt radius it is indistinguishable from circular, so this is
                // purely for consistency.
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color(NSColor.separatorColor).opacity(0.4))
            .frame(width: thumbnailWidth, height: thumbnailHeight)
            .overlay {
                Image(systemName: "film")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
    }
}

// MARK: - UpNextResultsTable

/// The sheets' result list: the "Up Next" slot sheet (UpNextSlots.swift) and the Saved
/// Search sheet (SavedSearchSheet.swift), each inside `sheetBoxChrome`. It cannot be the
/// gallery's own GalleryListView: that view is wired to the library's film set, the shared
/// selection, the scroll-position handoffs and the drag engine. It is instead the same
/// table — the same `.inset` style, alternating stripes, row height, stock row views and
/// ListRowHostCell rows — with none of that wiring, so colors, stripes and the selection
/// highlight come from the same AppKit drawing. No drag source, no contextual menu.
///
/// Rows are selectable only when `onSelect` is given. Selection then commits on mouse-down,
/// as NSTableView does natively. The table refuses first responder so a sheet's search field
/// keeps the keyboard, and its rows always draw the emphasized (accent) selection, which a
/// table that is not first responder would otherwise show gray.
struct UpNextResultsTable: NSViewRepresentable {
    let films: [FilmSnapshot]
    var selectedID: UUID? = nil
    var onSelect: ((UUID?) -> Void)? = nil
    var onActivate: ((UUID) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay

        let tableView = SheetResultsTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.backgroundColor = NSColor.alternatingContentBackgroundColors[0]
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.headerView = nil
        tableView.rowHeight = kListRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = []
        tableView.rowSizeStyle = .custom
        tableView.refusesFirstResponder = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let coordinator = context.coordinator
        coordinator.tableView = tableView
        tableView.delegate = coordinator
        tableView.dataSource = coordinator
        tableView.target = coordinator
        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let tableView = coordinator.tableView else { return }
        coordinator.onSelect = onSelect
        coordinator.onActivate = onActivate
        tableView.doubleAction = onActivate == nil ? nil : #selector(Coordinator.doubleClicked(_:))

        coordinator.isSyncing = true
        defer { coordinator.isSyncing = false }

        if coordinator.films.map(\.id) != films.map(\.id) {
            coordinator.films = films
            tableView.reloadData()
            tableView.scrollRowToVisible(0)
        }
        let wanted = selectedID.flatMap { id in films.firstIndex { $0.id == id } } ?? -1
        if tableView.selectedRow != wanted {
            if wanted >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: wanted), byExtendingSelection: false)
                tableView.scrollRowToVisible(wanted)
            } else {
                tableView.deselectAll(nil)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        weak var tableView: NSTableView?
        var films: [FilmSnapshot] = []
        var onSelect: ((UUID?) -> Void)?
        var onActivate: ((UUID) -> Void)?
        /// True while updateNSView drives the table, so its own selection changes are not
        /// echoed back as user selections.
        var isSyncing = false

        func numberOfRows(in tableView: NSTableView) -> Int { films.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard row >= 0, row < films.count else { return nil }
            let id = NSUserInterfaceItemIdentifier("ListRow")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ListRowHostCell
                ?? { let fresh = ListRowHostCell(); fresh.identifier = id; return fresh }()
            cell.update(film: films[row], subtitle: nil)
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("UpNextResultRowView")
            if let existing = tableView.makeView(withIdentifier: id, owner: nil) as? UpNextResultRowView {
                return existing
            }
            let rowView = UpNextResultRowView()
            rowView.identifier = id
            return rowView
        }

        /// A read-only list (no `onSelect`) never takes a click as a selection.
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            onSelect != nil
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let tableView, let onSelect else { return }
            let row = tableView.selectedRow
            onSelect(row >= 0 && row < films.count ? films[row].id : nil)
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < films.count else { return }
            onActivate?(films[row].id)
        }
    }
}

/// The sheets' table, with room below the last row as wide as the `.inset` style's side
/// margins. The room is part of the document itself — not a scroll-view content inset,
/// which shortened the scroller — so the scroller spans the whole box. The stripes run on
/// through the band unchanged, as AppKit draws them below any striped table's rows:
/// painting the band plain cut short the stripe that follows it during overscroll.
private final class SheetResultsTableView: NSTableView {
    /// The `.inset` style's side margin around the stripes (10 pt, measured on an offscreen
    /// render), so the band below the rows reads as the same margin.
    static let bottomPadding: CGFloat = 10

    /// The rows' bottom edge, or nil with no rows.
    private var rowsMaxY: CGFloat? {
        numberOfRows > 0 ? rect(ofRow: numberOfRows - 1).maxY : nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let rowsMaxY { size.height = max(size.height, rowsMaxY + Self.bottomPadding) }
        super.setFrameSize(size)
    }
}

/// Stock row drawing (stripe, `.inset` selection), but always in the active window's
/// emphasized state, since the table never holds first responder.
private final class UpNextResultRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set { }
    }
}

// MARK: - Sheet Box Chrome

extension View {
    /// The FilmSheet and right-sidebar tables' outline (`listContainerChrome`), for a box of
    /// any content in a sheet — UpNextResultsTable, its placeholders, the Saved Search rules:
    /// fill, the content clipped one border-width inside the outline — so scrolled rows never
    /// paint into the translucent stroke — then the stroke.
    ///
    /// The shadow is cast by the fill shape alone, behind the content. On the whole box it
    /// was derived from the content's pixels, so a scrolling table under it re-rendered the
    /// shadow offscreen on every frame of a scroll; the shape's never changes. The box is
    /// opaque, so the two cast the same shadow.
    func sheetBoxChrome(fill: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: FieldEdgeTreatment.cornerRadius, style: .continuous)
        return self
            .clipShape(shape.inset(by: FieldEdgeTreatment.borderWidth))
            .background(shape.inset(by: FieldEdgeTreatment.borderWidth).fill(fill)
                .shadow(color: .black.opacity(FieldEdgeTreatment.shadowOpacity),
                        radius: FieldEdgeTreatment.shadowRadius, x: 0, y: FieldEdgeTreatment.shadowOffsetY))
            .overlay(shape.strokeBorder(FieldEdgeTreatment.borderGradient,
                                        lineWidth: FieldEdgeTreatment.borderWidth)
                .allowsHitTesting(false))
    }
}
