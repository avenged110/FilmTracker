// MARK: - GalleryListView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// List-style alternative to the grid, shown when ViewState.isListView is true for the current view.
//
// DraggableListView is an NSViewRepresentable that owns a DraggableListTableView (an NSTableView subclass),
// as GallerySubview does for the grid. That gives full control over mouse events and lets NSTableView's
// native drag-as-source machinery trigger GalleryDragEngine's list-path preview.
//
// A manual mouseDown and mouseDragged bypass, like the grid's, does not work here.
// NSTableView.mouseDown(with:) runs its own blocking tracking loop and consumes the drag and mouse-up events
// for any row it hits. So the native pipeline below is the only usable hook.
//
// The list's visible preview is a separate, manually positioned borderless NSWindow (the "flyback window").
// The grid uses the native dragging image instead. The native list preview does not track the cursor for
// NSTableView sessions. See GalleryDragEngine's class doc for the full rationale.
//
// Drag pipeline:
//   1. tableView(_:pasteboardWriterForRow:) registers the film payload, so NSTableView detects the drag natively.
//   2. dragImageForRows(with:tableColumns:event:offset:) on DraggableListTableView replaces the default row snapshot with an
//      invisible 1x1 image. That native image is never shown.
//   3. tableView(_:draggingSession:willBeginAt:forRowIndexes:) re-asserts the placeholder and calls GalleryDragEngine.prepareDrag,
//      which arms the flyback window at the drag's start point.
//   4. DraggableListTableView.draggingSession(_:movedTo:) forwards each move to GalleryDragEngine.dragMoved(to:), which moves the
//      flyback window.
//   5. endedAt forwards the session end to GalleryDragEngine.draggingSessionEnded. The window either animates back on cancel or
//      dismisses at once on drop, and then .dragSessionDidEnd is posted.

import AppKit
import SwiftUI
import Combine

// MARK: - Scroll range

private extension NSScrollView {
    /// The largest valid vertical `contentView` bounds origin for a document of `contentHeight`. That is the
    /// position where the document is scrolled as far up as AppKit allows. Every programmatic scroll in this
    /// file clamps to it.
    ///
    /// The bottom content inset (29 pt while the StatusBar overlay shows) extends the scrollable range past
    /// the document's bottom edge. So the last row can scroll clear of the overlay. Omitting the inset would
    /// stop programmatic scrolls 29 pt short of where the user can drag.
    ///
    /// This matches NSClipView's constraint for a flipped document, which NSTableView is. The viewport height
    /// is contentView.bounds.height, since the clip view spans the whole scroll view and is not inset.
    func maxVerticalScrollOffset(forContentHeight contentHeight: CGFloat) -> CGFloat {
        max(0, contentHeight + contentInsets.bottom - contentView.bounds.height)
    }
}

// MARK: - Drag placeholder image

private extension NSImage {
    /// The invisible 1x1 image that suppresses the list's native drag preview. It is supplied in two places:
    /// dragImageForRows, which is the definitive point, and willBeginAt, as a second assertion. Defining it
    /// once keeps the two the same. The visible preview is the flyback window (see GalleryDragEngine).
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

/// Height of a section-divider band's own CONTENT in the list gallery — the label/count line plus the
/// hairline rule beneath it. Deliberately shorter than the grid's full-row divider band (see
/// SectionDividerDecorationView in GalleryViewUI.swift): a list row is 44pt tall rather than a whole poster
/// tile, so a grid-proportioned band would dwarf the content it separates.
let kListSectionDividerBandHeight: CGFloat = 38

/// Vertical breathing room added above AND below the band content, separating a divider from the film rows on
/// either side of it so the section break reads unmistakably rather than as just another row.
let kListSectionDividerVerticalPadding: CGFloat = 16

/// The total row height a section divider occupies. Derived rather than stated, so the band content and its
/// padding can be retuned independently without the row height and the view's own frame ever falling out of
/// agreement — they are the same number by construction, which matters because the scroll-restore math sums
/// these heights arithmetically (see Coordinator.listContentHeight).
let kListSectionDividerHeight: CGFloat =
    kListSectionDividerBandHeight + 2 * kListSectionDividerVerticalPadding

// MARK: - Row Item Model
//
// The list gallery's table is addressed in ROW space, which is not necessarily the same as FILM space: a
// sectioned view interleaves labeled section-divider rows between its groups, exactly as the grid does with
// its decoration-view bands. `ListRowItem` is the single mapping between the two spaces, and every row↔film
// conversion in this file goes through it (or through the Coordinator.filmRowMap it is built alongside).
//
// Whenever no bands apply — the Film Queue's "All" tab always has them, every other view only while this
// view's ViewState.showSectionDividers is on — the row model is built as a strict 1:1 `.film(index:)`
// sequence with no dividers whatsoever, so row index == film index and the mapping is an exact identity. The
// divider machinery therefore contributes nothing at all in that case, and cannot affect the gallery's
// behavior.
enum ListRowItem: Equatable {
    /// A labeled section band. `filmCount` is the number of film rows in the section. It is the span to the
    /// next divider, or to the end, computed by GallerySectioning.bandFilmCount, the same call the grid uses.
    case divider(section: GallerySection, filmCount: Int)
    /// A real film row, carrying its index into the Coordinator's `films` array.
    case film(index: Int)
    /// An empty "Up Next" placeholder slot (1-based number), shown only on the Film Queue's "All" tab after
    /// the "Up Next" films. Never selectable; see UpNextSlots.swift.
    case slot(number: Int)

    var isFilm: Bool {
        if case .film = self { return true }
        return false
    }

    var isDivider: Bool {
        if case .divider = self { return true }
        return false
    }

    /// The row's own height, used by both `heightOfRow` and the pure-arithmetic content height the
    /// scroll-restore math depends on, so the two can never disagree.
    var rowHeight: CGFloat {
        isDivider ? kListSectionDividerHeight : kListRowHeight
    }
}

// MARK: - List Scroll View

/// NSScrollView subclass for the list. It resolves a pending scroll target, handed off from
/// GalleryScrollIntent, in viewWillDraw(). At that point AppKit has laid out the view with real geometry, and
/// the frame has not yet been drawn.
///
/// It mirrors WidthObservingScrollView in GallerySubview. Resolving here, rather than in makeNSView, matters.
/// Setting the origin before the view has a real frame is unreliable, since AppKit's own layout can reset it.
/// So every deferred scroll resolves in viewWillDraw(), and the origin is set before the first frame paints.
private final class ListScrollView: NSScrollView, Loggable {
    nonisolated static let logTag = "[DraggableListView]"

    /// Pending post-layout scroll target, transferred here from GalleryScrollIntent by
    /// DraggableListView.makeNSView (mirrors WidthObservingScrollView's identical field).
    var pendingScrollFilmID: UUID?
    /// How pendingScrollFilmID is applied once geometry is available (see PendingScrollBehavior in
    /// ViewState.swift). Every handoff uses the default, .forceTop. Only the post-edit keep-in-view sets
    /// .ifNeeded, and it resets to the default after resolving, so no handoff inherits it.
    var pendingScrollBehavior: PendingScrollBehavior = .forceTop
    /// Pending post-layout scroll origin restore for maintainScrollPositionOnViewSwitch. It is armed by
    /// DraggableListView.updateNSView's view-switch branch, and it is resolved and cleared in viewWillDraw(),
    /// as pendingScrollFilmID is. It is mutually exclusive with pendingScrollFilmID, since updateNSView arms
    /// it only when no film target is pending. If both are set, the film target wins.
    var pendingScrollPosition: GalleryScrollPosition?
    /// Pending keyboard-focus claim, transferred here from GalleryFocusIntent by DraggableListView.makeNSView
    /// (mirrors WidthObservingScrollView's identical field). Honored — and cleared — in viewWillDraw() below.
    var pendingKeyboardFocus = false
    /// Weak back-reference so viewWillDraw() can reach scrollFilmToTop(_:) and isRowVisible(_:). Wired in
    /// makeNSView.
    weak var listCoordinator: DraggableListView.Coordinator?

    override func viewWillDraw() {
        super.viewWillDraw()

        // Film-target resolution takes precedence; an origin armed alongside one can only be a superseded
        // leftover from an earlier pass and is discarded when the film target resolves. Mirrors
        // WidthObservingScrollView.viewWillDraw().
        if pendingScrollFilmID != nil {
            resolvePendingFilmTarget()
        } else if pendingScrollPosition != nil {
            resolvePendingOriginRestore()
        }

        resolvePendingKeyboardFocus()
    }

    /// Keyboard-focus claim for the search-exit handoff. Mirrors
    /// WidthObservingScrollView.resolvePendingKeyboardFocus — see there for why it is independent of the
    /// scroll resolution and deferred one turn.
    private func resolvePendingKeyboardFocus() {
        guard pendingKeyboardFocus, let window = unsafe window, let target = documentView else { return }
        pendingKeyboardFocus = false
        DispatchQueue.main.async { [weak window, weak target] in
            guard let window, let target, unsafe target.window === window else { return }
            window.makeFirstResponder(target)
        }
    }

    /// Film-target resolution for every scroll handoff (see GalleryScrollIntent in ViewState.swift for the
    /// producers) and for the post-edit keep-in-view. Mirrors
    /// WidthObservingScrollView.resolvePendingFilmTarget.
    private func resolvePendingFilmTarget() {
        guard let filmID = pendingScrollFilmID else { return }
        // If geometry is not ready, this guard fails and pendingScrollFilmID stays set. viewWillDraw runs
        // again on the next pass, so the target is retried, as in WidthObservingScrollView.
        guard bounds.width > 0, documentVisibleRect.height > 0,
              let coordinator = listCoordinator else { return }

        guard let row = coordinator.rowIndex(for: filmID) else {
            // Film no longer present in this view's data — drop the stale target.
            pendingScrollFilmID = nil
            return
        }

        pendingScrollFilmID = nil
        // Discard any superseded origin restore (see viewWillDraw's precedence note), both the copy armed
        // here and the intent it was armed from — otherwise the intent would simply be re-armed on the next
        // update pass and fight this scroll.
        pendingScrollPosition = nil
        ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)
        let behavior = pendingScrollBehavior
        pendingScrollBehavior = .forceTop

        switch behavior {
        case .forceTop:
            // Every handoff: the film's row goes to the top of the viewport (as far as the content allows),
            // like Cmd+L, even when the film is already visible.
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

    /// Applies an armed origin restore immediately, if geometry already allows it. Mirrors
    /// WidthObservingScrollView.applyPendingOriginRestoreIfPossible() — see that method for why viewWillDraw
    /// alone is not sufficient on a reused gallery.
    func applyPendingOriginRestoreIfPossible() {
        resolvePendingOriginRestore()
    }

    /// Applies an armed film target immediately, if geometry already allows it. The list's copy of
    /// WidthObservingScrollView.applyPendingFilmTargetIfPossible() — see that method for why viewWillDraw
    /// alone is not sufficient on a reused gallery.
    func applyPendingFilmTargetIfPossible() {
        resolvePendingFilmTarget()
    }

    /// Saved-origin restore for maintainScrollPositionOnViewSwitch. It is armed by
    /// DraggableListView.updateNSView's view-switch branch and applied before the draw, so the first painted
    /// frame is already at the restored position.
    private func resolvePendingOriginRestore() {
        guard let position = pendingScrollPosition else { return }
        guard bounds.width > 0, documentVisibleRect.height > 0,
              let coordinator = listCoordinator else { return }

        // Content height is summed from the row model, which includes the taller divider rows. It is not
        // taken from the document frame, which can read 0 or stale on the first pass after a reload. That
        // would collapse the clamp to zero and force every restore to the top. Pure arithmetic does not
        // depend on AppKit's layout timing.
        let contentHeight = coordinator.listContentHeight
        guard contentHeight > 0 else {
            // No rows laid out yet — viewWillDraw fires again on the next display pass, so the origin is
            // retained and retried automatically (matching resolvePendingFilmTarget's guard-and-retry
            // pattern).
            return
        }

        pendingScrollPosition = nil
        // Retire the intent now that it has genuinely been applied against real geometry. Until this point it
        // stays live in ViewStateManager on purpose, so a reload that lands between arming and resolution
        // re-arms it rather than losing it.
        ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)

        let target = applyClampedOrigin(CGPoint(x: 0, y: coordinator.restoreY(for: position)),
                                        contentHeight: coordinator.scrollableContentHeight)
        Self.log("Saved scroll origin restored pre-draw: \(target)")
    }

    /// Moves the viewport to `origin`, clamped to the current valid scroll range. The content may have shrunk
    /// since the origin was saved, and an out-of-range origin would leave blank space.
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

// StatusBar overlay height.
private let kListStatusBarHeight: CGFloat = StatusBar.height

// MARK: - GalleryListView

struct GalleryListView: View {
    /// The active ViewIdentifier from ViewStateManager, passed down so the Coordinator can address itself
    /// when consuming a pending GalleryScrollIntent (the search-exit and grid⟷list toggle scroll-position
    /// handoffs). Mirrors GallerySubview.activeViewID.
    let activeViewID: ViewIdentifier

    /// The film whose position may have changed in the reload this pass is about to perform, or nil.
    /// GalleryView's `.film(.updated)` handler produces it, as it does for the grid. Without it, a film
    /// pushed off screen by an edit, such as a rating change under a rating sort, would stay off screen with
    /// no clue where it went. See Priority 1 in updateNSView.
    let scrollRequest: FilmScrollRequest?
    /// The same subtitle provider GalleryView hands the grid (a Recents date, or nil for every other view).
    /// The list renders it as a by-line under the title, so the two styles show the same secondary
    /// information for the same view.
    let subtitleProvider: GallerySubtitleProvider?
    /// This view's section-dividers setting, read from its ViewState by GalleryView and passed down, as for
    /// GallerySubview. It reaches the Coordinator before the `films` assignment, whose didSet rebuilds the
    /// row model, so bands appear or disappear in place.
    let showSectionDividers: Bool

    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SelectionState.self) private var selectionState
    @AppStorage(preference: Preferences.showStatusBarKey) private var showStatusBar: Bool
    // maintainScrollPositionOnViewSwitch is not read here. ViewStateManager.prepareScrollHandoff checks the
    // preference at each switch and arms nothing when it is off, so this layer has no decision to make.
    // GallerySubview removed its read for the same reason.

    var body: some View {
        DraggableListView(
            films: dataCoordinator.films,
            // Handed down so the Coordinator can resolve Film Queue section membership when building its row
            // model — the list's counterpart to the identical handoff GallerySubview performs for its own
            // section-divider computation.
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

/// Full NSViewRepresentable replacement for SwiftUI's List. Owns a DraggableListTableView directly so
/// NSTableView's native drag detection fires correctly from within its own mouseDown event-tracking loop.
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
        // A request already standing when this list mounts belongs to an edit some earlier instance handled
        // (the grid, before a style toggle); seeding it keeps this one from acting on it again.
        context.coordinator.lastScrollRequest = scrollRequest
        let scrollView = ListScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.scrollerStyle = .overlay
        // Prevent macOS from overwriting contentInsets with its own safe-area values. We set contentInsets
        // manually in updateNSView to create StatusBar scroll headroom.
        scrollView.automaticallyAdjustsContentInsets = false
        // Layer-backed rendering for smooth compositing, matching GallerySubview.
        scrollView.wantsLayer = true
        scrollView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Allow the scroll view to grow to fill all available horizontal space and resist compression so the
        // table is never clipped on narrow windows.
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let tableView = DraggableListTableView()
        // Do not set wantsLayer = true on the table view. A layer-backed table does not repaint synchronously
        // on reloadData. The stale bitmap of the deleted rows would show until the next display cycle. The
        // scroll view is already layer-backed, which is enough for compositing.
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        // The table background is the first alternating row color. NSTableView fills its whole frame with row
        // backgrounds, including the strip below the last row when the height is not a multiple of the row
        // height. Matching that color hides the strip, which would otherwise show a fractional-row artifact
        // after deletions.
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
        // Must be assigned before any `coordinator.films` write. The row model rebuilt in that didSet checks
        // loadedFilmQueueFilter to decide whether divider rows apply. The scroll-handoff branch below writes
        // films.
        coordinator.dataCoordinator = dataCoordinator
        coordinator.showSortingSections = showSectionDividers
        coordinator.subtitleProvider = subtitleProvider

        // Give the table view a back-reference to its coordinator so the NSDraggingSource callbacks can
        // delegate to GalleryDragEngine.
        tableView.coordinator = coordinator

        // Secondary-click contextual menu. DraggableListTableView.menu(for:) has already established that the
        // click landed on a real row (and not in the inset side margins) before this runs.
        tableView.getContextMenu = { [weak coordinator] in coordinator?.contextMenu(forRow: $0) }

        // Register this coordinator as the source of "what's on top" for the active view — read by
        // ViewStateManager.updateListViewStyle when the grid⟷list toggle is about to switch AWAY from the
        // list. Unregistered in dismantleNSView below.
        ViewStateManager.shared.registerScrollPositionProvider(coordinator)

        // MARK: Scroll-Position Handoff (Search Exit / Grid⟷List Toggle)
        // Mirrors GallerySubview's preload path. Search exit and the view-style toggle share this sequence.
        // Preloading the films and reloading here keeps the next updateNSView pass from reloading a second
        // time, which would reset the scroll to y=0. The scroll itself runs in ListScrollView.viewWillDraw(),
        // once geometry exists.
        scrollView.listCoordinator = coordinator

        // Keep this view's saved scroll origin current as the user scrolls — see the method's doc comment in
        // GallerySubview.Coordinator for the full rationale; this is the list's copy of the identical
        // mechanism.
        coordinator.installScrollOriginRecorder(on: scrollView)
        #if DEBUG
        coordinator.installViewportJumpTracer(on: scrollView)
        #endif

        if let filmID = GalleryScrollIntent.shared.consume(ifTargeting: activeViewID) {
            coordinator.films = films
            // Seeds both view identifiers, so the next updateNSView pass does not read this mount as a view
            // switch and reset the scroll. This mirrors GallerySubview.
            coordinator.currentViewID = activeViewID
            coordinator.prevViewID = activeViewID
            // See GallerySubview.makeNSView's identical seeding.
            coordinator.lastFilmQueueFilter = dataCoordinator.loadedFilmQueueFilter
            coordinator.withSuppressedCallbacks {
                tableView.reloadData()
            }
            scrollView.pendingScrollFilmID = filmID
            // This path bypasses updateNSView's reload branch, where an origin restore would otherwise be
            // picked up. The film handoff outranks it, so the intent is retired here, rather than being armed
            // later and fighting this scroll. This mirrors GallerySubview.
            ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)
            Self.log("Scroll handoff armed in makeNSView for film \(filmID) (view: \(activeViewID))")
        } else {
            // No film handoff claims this mount, so a saved origin may. Mirrors GallerySubview.makeNSView —
            // see armScrollOriginRestoreOnMount.
            ViewStateManager.shared.armScrollOriginRestoreOnMount(
                for: GalleryScrollKey(viewID: activeViewID,
                                      subTab: dataCoordinator.loadedFilmQueueFilter?.rawValue))
        }

        // Outside the scroll-handoff branch, mirroring GallerySubview.makeNSView — see GalleryFocusIntent for
        // why the two handoffs are independent.
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
        // Refreshed on every pass (the environment object is a stable singleton, but the assignment is free
        // and keeps the invariant "dataCoordinator is set before films is written" true on every path through
        // this method). See makeNSView.
        coordinator.dataCoordinator = dataCoordinator
        // Refreshed before any row is (re)configured below. A change of subtitle KIND always coincides with a
        // view-identity change (the Recents category is part of the ViewIdentifier), which forces the full
        // reload; and the else-branch's visible-row refresh re-resolves the string through this provider on
        // every same-view pass, with ListRowHostCell comparing the resolved text so an unchanged by-line
        // costs no rootView reassignment.
        coordinator.subtitleProvider = subtitleProvider

        // Bottom inset for the StatusBar overlay. contentInsets extends the scrollable range below the
        // document's bottom edge, so the last row can scroll above the StatusBar without adding a phantom
        // row. scrollerInsets keeps the thumb above the overlay. automaticallyAdjustsContentInsets must be
        // false, set in makeNSView, so macOS does not overwrite the insets.
        let bottomInset: CGFloat = showStatusBar ? kListStatusBarHeight : 0
        if scrollView.contentInsets.bottom != bottomInset {
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }
        if scrollView.scrollerInsets.bottom != bottomInset {
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }

        // Stale-pass guard. GalleryListView's body reads dataCoordinator.films, so SwiftUI also runs this
        // when the films change on their own — carrying the activeViewID of the LAST GalleryView body pass.
        // After a view switch that is a pass in which the films belong to the new view while activeViewID
        // still names the old one, and it can only come from one of two places:
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
        // Either way nothing here is owed until activeViewID agrees with the view the films were loaded for,
        // so the pass is skipped.
        guard activeViewID == ViewStateManager.shared.activeView else { return }

        // Style guard — see the identical guard in GallerySubview.updateNSView.
        if case .filmQueue = activeViewID,
           !ViewStateManager.shared.displayedGalleryState(
               loadedQueueFilter: dataCoordinator.loadedFilmQueueFilter).isListView {
            return
        }

        // MARK: View-Switch Detection
        //
        // NSTableView.reloadData() does not reset the scroll position, unlike NSCollectionView's. So a switch
        // that reuses this table (every Recents and Unwatched tab, and every smart-list variant) would carry
        // the outgoing offset into the new view. The list zeroes on a view change, as the grid does.
        // maintainScrollPositionOnViewSwitch also applies to the list.
        //
        // prevViewID is optional for the reasons given in GallerySubview.Coordinator. nil means nothing has
        // been displayed yet, so a fresh mount counts as a transition, and the outgoing-origin save cannot
        // file a synthetic zero under another view.
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

        // The Film Queue's segment filter narrows the same view, so viewIdentityChanged cannot see a switch
        // between All and one section. The grid synthesizes this signal, and the list needed it too. Without
        // it, the offset carries over, AppKit clamps it against the shorter content, and the user lands at
        // the bottom of the new section. The pendingScrollPosition reset is also skipped, so an origin armed
        // for one tab could resolve against another's rows.
        //
        // It compares against dataCoordinator.loadedFilmQueueFilter, the filter the films were produced with,
        // and not the live FilmQueueFilterState.shared.selectedFilter. The live filter changes before the
        // films arrive. A nil last-seen value is not a change, since a fresh mount is already covered by
        // viewIdentityChanged. It resets to nil when a non-Queue set is shown.
        let filmQueueFilterChanged: Bool
        if let loadedQueueFilter = dataCoordinator.loadedFilmQueueFilter {
            filmQueueFilterChanged = coordinator.lastFilmQueueFilter != nil &&
                                     coordinator.lastFilmQueueFilter != loadedQueueFilter
            coordinator.lastFilmQueueFilter = loadedQueueFilter
        } else {
            coordinator.lastFilmQueueFilter = nil
            filmQueueFilterChanged = false
        }

        // Drives the reload and scroll-to-zero below. The outgoing-origin save above is not used here.
        // currentViewID stays .filmQueue across a filter change, so saving there would file one section's
        // position under the key all four share. FilmQueueFilterState.selectFilter banks each tab's position
        // with explicit keys, before the filter flips.
        let isViewSwitch = viewIdentityChanged || filmQueueFilterChanged

        let newFilms = films
        let oldFilms = coordinator.films

        // A same-view refresh that empties the list is about to take it off screen; bank the position first.
        // See the identical step in GallerySubview.updateNSView.
        if !isViewSwitch && newFilms.isEmpty && !oldFilms.isEmpty {
            ViewStateManager.shared.saveScrollPosition(coordinator.scrollPosition(of: scrollView),
                                                       under: coordinator.displayedScrollKey)
        }

        // Launch pre-paint poster warm and restore-priority registration. It runs once per session, shared
        // with GallerySubview through a flag in PosterCache. Whichever style renders first at launch does it,
        // and the other's call reads one Bool. It must come before reloadData, so the first cells find their
        // posters loaded. See PosterCache.registerLaunchDisplayOrder.
        if PosterCache.shared.needsLaunchWarm, !newFilms.isEmpty {
            PosterCache.shared.registerLaunchDisplayOrder(newFilms.map(\.posterUID))
        }
        if !newFilms.isEmpty { LaunchReveal.shared.galleryWillAppear(scrollView) }

        // MARK: Change Detection
        //
        // Array == returns quickly when the buffer is the same. So when films has not been reassigned, which
        // is most passes, this is an O(1) check that skips everything below. When the contents differ it
        // stops at the first difference. Only an equal-but-distinct array costs a full walk, which is cheap
        // at this app's scale.
        //
        // This gate keeps rebuildRowModel() off no-op passes. That rebuild, with dividers on, scans every
        // film through GallerySectioning.displayedSectionBreaks and builds fresh row and index arrays.
        //
        // The comparison is deep equality, not an ID check. A rename that leaves the IDs in place still needs
        // a visible-row refresh, so skipping on IDs alone would leave stale rows.
        let filmsChanged = oldFilms != newFilms

        // The row model depends on more than `films`. A change to any of these rebuilds it, even when the
        // array is unchanged:
        //
        //  • showSortingSections, this view's dividers setting. It can change with no film change, and it is how bands appear and disappear.
        //  • The three loaded* values, which gate GallerySectioning.displayedSectionBreaks. A sort change can re-band a view while keeping
        //    the same film order, which films alone cannot show.
        //
        // They are read from dataCoordinator's loaded* values, not the live current* intent, so the bands
        // always match the films shown.
        let sectionInputs = Coordinator.SectionInputs(
            showSortingSections: showSectionDividers,
            queueFilter: dataCoordinator.loadedFilmQueueFilter,
            sortOption: dataCoordinator.loadedSortOption,
            recentsCategory: dataCoordinator.loadedRecentsCategory,
            queueMembership: GallerySectioning.filmQueueMembership(for: dataCoordinator))
        // nil on the first pass, so a fresh mount always rebuilds.
        let sectionInputsChanged = coordinator.lastSectionInputs != sectionInputs
        coordinator.lastSectionInputs = sectionInputs

        // The Film Queue's All tab is the only banding whose inputs are not derivable from the films array.
        // Its bands come from each film's membership in Up Next, Soon, or Later, which is list membership in
        // MemoryStore. No FilmSnapshot field carries it. Promoting the first Soon film to Up Next can leave
        // every snapshot identical and the order the same, while still changing the bands. So the memberships
        // are part of sectionInputs (see GallerySectioning.filmQueueMembership).
        //
        // Every other view's bands derive from MetadataCache values, and those derive from FilmSnapshot
        // fields. A change to any of those fields moves the snapshot, so filmsChanged sees it. The skip is
        // therefore sound for those views.

        // Whether the row order changed. The table's cached row views cannot survive a reorder. The O(films)
        // walk runs only when filmsChanged is set. elementsEqual covers the old count, first, and last
        // checks, and it also catches an interior reorder. Two sorts can share a count and both endpoints and
        // still permute the middle, as Date Added and Date Modified can when the newest and oldest coincide.
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

        // Section-divider structure change. Moving a film between two Film Queue sections, or an edit that
        // moves a film between sort bands, leaves the count, first, and last films unchanged. The three
        // checks above miss it, but comparing the row models catches it. This is the list's equivalent of the
        // grid recomputing its breaks each reload.
        //
        // ListRowItem is Equatable over the band's identity and film count, so a changed membership still
        // compares unequal. With no bands at all, the model is a strict one-to-one sequence, and the
        // comparison matches the film count alone.
        let rowModelChanged = coordinator.rowItems != oldRowItems

        if isViewSwitch || idSequenceChanged || rowModelChanged {
            #if DEBUG
            ViewSwitchProbe.record("list.reload \(activeViewID) films=\(films.count)")
            #endif
            coordinator.withSuppressedCallbacks {
                tableView.reloadData()
            }
        } else if filmsChanged {
            // Refreshes the existing rows in place for metadata and poster updates, keeping scroll and
            // selection. It runs only for a same-view refresh where every film kept its row. A view switch,
            // or any reorder, takes the full reload above.
            //
            // It updates every row view the table holds, not just visible ones. NSTableView keeps prepared
            // rows just outside the viewport and does not ask for them again, so an edit there would
            // otherwise show stale values. It updates in place rather than through
            // reloadData(forRowIndexes:). That swap could hand back a cell last used for another film, and it
            // would reassign that cell's rootView even when the row's own film had not changed. `update`
            // compares what the row displays, so unchanged rows cost little.
            //
            // It is gated on filmsChanged, so passes that only change selection or the status bar do no work.
            // Banding changes are caught by rowModelChanged above.
            tableView.enumerateAvailableRowViews { rowView, row in
                guard let cell = rowView.view(atColumn: 0) as? ListRowHostCell,
                      let film = coordinator.film(forRow: row) else { return }
                #if DEBUG
                GalleryRefreshProbe.listRowsRefreshed += 1
                #endif
                cell.update(film: film, subtitle: coordinator.subtitleProvider?.subtitle(film.id))
            }
        }

        // Post-reload scroll placement for a view switch. Runs after the reload above so the row count the
        // clamp depends on is already current.
        if let listScrollView = scrollView as? ListScrollView {
            if isViewSwitch {
                // Zero first, unconditionally. This is where the new view opens when nothing else claims it,
                // and it replaces the offset that reloadData() would otherwise carry over from the outgoing
                // view.
                appViewportMove {
                    scrollView.contentView.setBoundsOrigin(.zero)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }

                // Discard any origin armed by an earlier pass that this transition supersedes, so it cannot
                // resolve against the wrong view's content. The block below re-arms it for the incoming view
                // when one is available.
                listScrollView.pendingScrollPosition = nil
            }

            // Arms this view's saved origin for a pre-draw restore on every pass, not only the one that
            // detected the transition. The restore intent is armed once by ViewStateManager at the switch,
            // addressed to a view, and retired only when applied. So whichever pass reloads the films picks
            // it up. Nothing is armed while the preference is off.
            //
            // The pendingScrollFilmID == nil check keeps the search-exit and style-toggle film handoff
            // authoritative. A reuse-path film handoff outranks the origin restore and is claimed first. It
            // is only a ShowInListNavigation redirect to a smart-list sub-variant (see
            // GalleryScrollIntent.consumableOnReuse). This mirrors Priority 0 in GallerySubview.updateNSView.
            if let handoffFilmID = GalleryScrollIntent.shared.consumeOnReuse(ifTargeting: coordinator.currentViewID) {
                ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)
                listScrollView.pendingScrollPosition = nil
                listScrollView.pendingScrollFilmID = handoffFilmID
                listScrollView.pendingScrollBehavior = .forceTop
                // Apply now rather than waiting for a viewWillDraw that will never arrive on a reused
                // gallery. The list resolver's geometry needs are pure arithmetic on the fixed row height, so
                // no forced layout pass is required first.
                listScrollView.applyPendingFilmTargetIfPossible()
                Self.log("Scroll handoff armed on reuse path for film \(handoffFilmID) (view: \(coordinator.currentViewID))")

            } else if let scrollRequest, scrollRequest != coordinator.lastScrollRequest,
                      coordinator.rowIndex(for: scrollRequest.filmID) != nil {
                let filmID = scrollRequest.filmID
                // Priority 1: an intentional post-edit reposition, the list's counterpart to the grid's. It
                // outranks the origin restore, so any intent for this view is retired first. There is no
                // origin to restore: reloadData() does not reset the list's scroll position, so the viewport
                // is still where the user left it. The .ifNeeded resolution tests visibility directly. A film
                // still on screen is left alone, and one the edit pushed out of view goes to the top row.
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
                // Apply now rather than waiting for a viewWillDraw that will never arrive on a reused gallery
                // — see applyPendingOriginRestoreIfPossible. The list resolver clamps against
                // coordinator.scrollableContentHeight (row-model arithmetic, no AppKit layout dependency), so
                // no forced layout pass is needed.
                listScrollView.applyPendingOriginRestoreIfPossible()
            }
        }

        // Every pass records the request, acted on or not, so it can fire only once.
        coordinator.lastScrollRequest = scrollRequest

        coordinator.syncSelectionToView()
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        // Backstop scroll-origin save, mirroring GallerySubview.dismantleNSView — see that method for why the
        // y > 0 condition is deliberate and must not be relaxed to an unconditional save at this particular
        // call site.
        let position = coordinator.scrollPosition(of: nsView)
        if position.origin.y > 0 {
            ViewStateManager.shared.saveScrollPosition(position, under: coordinator.displayedScrollKey)
            Self.log("Saved scroll origin \(position.origin) for \(coordinator.currentViewID)")
        }
        // Identity-checked: only clears the registry if this coordinator is still the registered provider, so
        // an out-of-order mount/dismantle sequence during the grid⟷list toggle can never clear the
        // freshly-mounted opposite style's registration.
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

        // Current and previous view identifiers, for the same view-switch detection
        // GallerySubview.Coordinator uses. See the View-Switch Detection block in updateNSView for why
        // prevViewID is optional.
        var currentViewID: ViewIdentifier = .allFilms
        fileprivate var prevViewID: ViewIdentifier?

        /// The last post-edit scroll request this Coordinator has seen, acted on or not.
        fileprivate var lastScrollRequest: FilmScrollRequest?

        /// The Film Queue section filter this coordinator last displayed a film set for, or nil if the last
        /// set was not a Queue result.
        ///
        /// The four Queue tabs share one ViewIdentifier, so the prevViewID test cannot see a switch between
        /// them. This is compared against dataCoordinator.loadedFilmQueueFilter on each pass to produce the
        /// same signal. It uses the loaded filter, not the live one (see updateNSView and
        /// GallerySubview.Coordinator).
        fileprivate var lastFilmQueueFilter: FilmQueueFilter?

        /// Everything that rebuildRowModel()'s section-break computation reads besides `films`. It is
        /// compared as a unit against `lastSectionInputs`, so a change rebuilds the row model even when the
        /// film array is identical. See Change Detection in updateNSView.
        fileprivate struct SectionInputs: Equatable {
            let showSortingSections: Bool
            let queueFilter: FilmQueueFilter?
            let sortOption: SortOption?
            let recentsCategory: RecentsCategory?
            /// See GallerySectioning.filmQueueMembership.
            let queueMembership: [Set<UUID>]?
        }

        /// The section inputs the current row model was built from, or nil before the first update pass —
        /// which is what makes a fresh mount always rebuild.
        fileprivate var lastSectionInputs: SectionInputs?

        /// Resolves Film Queue section membership when building the row model. It is weak, and assigned by
        /// makeNSView and updateNSView before any `films` write. It mirrors
        /// GallerySubview.Coordinator.dataCoordinator.
        weak var dataCoordinator: DataCoordinator?
        /// Mirror of the active view's ViewState.showSectionDividers, pushed by makeNSView and updateNSView
        /// before any `films` assignment. The didSet of `films` rebuilds the row model, and
        /// computeSectionBreaks() reads this value.
        var showSortingSections: Bool = false
        /// The active subtitle provider, pushed by makeNSView/updateNSView and resolved per film when a row
        /// is configured. Mirrors GallerySubview.Coordinator.
        var subtitleProvider: GallerySubtitleProvider?

        var films: [FilmSnapshot] = [] {
            didSet { rebuildRowModel() }
        }
        let selectionState: SelectionState

        /// The table's row model, the one mapping between row space and film space. See ListRowItem. It is
        /// rebuilt, along with filmRowMap and listContentHeight, in `films.didSet`, so it always matches the
        /// films.
        private(set) var rowItems: [ListRowItem] = []

        /// The total document height of the table, derived from the row model, not the document frame. The
        /// frame is unreliable at the moments it is needed (see scrollFilmToTop). It is stored, so scroll
        /// paths do not walk the rows.
        private(set) var listContentHeight: CGFloat = 0

        /// The table's full document height, used to clamp programmatic scrolls. It is the row model's height
        /// plus the padding of the .inset table style, which is 10 pt above the first row and 10 pt below the
        /// last. Clamping to listContentHeight alone would stop placements short of the end by that padding, so the last
        /// rows could not be fully scrolled up. The padding is read from the table's first row offset, not
        /// restated, and it is symmetric.
        var scrollableContentHeight: CGFloat {
            guard listContentHeight > 0, let tv = tableView, tv.numberOfRows > 0 else { return listContentHeight }
            return listContentHeight + 2 * tv.rect(ofRow: 0).minY
        }

        /// Film ID to table row index (not film index). Every selection, drag, and scroll path works in row
        /// space, so no conversion is needed.
        private var filmRowMap: [UUID: Int] = [:]
        private var isSuppressingCallbacks = false
        private var isUpdatingSelection = false
        private var cancellables = Set<AnyCancellable>()
        private var observationTask: Task<Void, Never>?

        /// The row the user pressed at mouseDown. DraggableListTableView.mouseDown sets it before the drag
        /// loop, and willBeginAt reads it to pick the drag preview's poster. It is cleared after use, so a
        /// stale value cannot leak into a later drag.
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

        /// Rebuilds `rowItems`, `filmRowMap`, and `listContentHeight` from the current `films`. It runs
        /// inside `films.didSet`, so the three cannot fall out of step.
        ///
        /// updateNSView also calls it directly when only the banding inputs change, such as the dividers
        /// setting or a re-sort that keeps the order. That is the same as reassigning `films` with the same
        /// value.
        ///
        /// computeSectionBreaks() decides which divider rows apply. It reads dataCoordinator's
        /// loadedFilmQueueFilter and loadedSortOption, not the live intent, for the same reason the grid
        /// does: those are written in the same pass as `films`, so the bands always match the films shown.
        /// With no bands, the row model is a one-to-one identity mapping.
        fileprivate func rebuildRowModel() {
            // Divider insertion points, in FILM index space. Empty whenever no bands apply at all, which
            // collapses the loop below to a plain 1:1 build.
            let breaks = computeSectionBreaks()
            var nextBreak = 0

            var items: [ListRowItem] = []
            var map: [UUID: Int] = [:]
            items.reserveCapacity(films.count + breaks.count)
            map.reserveCapacity(films.count)

            // The Queue's "All" tab follows its "Up Next" films with empty slot rows (and, when "Up Next" has
            // no films, its own band first). Nil everywhere else.
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
                    // A section's film count is the span from this break to the next one, or to the end for
                    // the last section. It uses the same index space as the breaks, so it matches the rows
                    // rendered. It is GallerySectioning.bandFilmCount, the same call the grid uses.
                    let next = (nextBreak + 1) < breaks.count ? breaks[nextBreak + 1].index : nil
                    items.append(.divider(
                        section: breaks[nextBreak].section,
                        filmCount: GallerySectioning.bandFilmCount(
                            from: index, nextBandIndex: next, totalCount: films.count)))
                    nextBreak += 1
                }
                // On a duplicate film ID, the last row wins. This matches
                // GallerySubview.Coordinator.rebuildFilmIndexMap, so a repeated ID does not trap.
                map[film.id] = items.count
                items.append(.film(index: index))
            }
            appendSlots(at: films.count)

            rowItems = items
            filmRowMap = map
            listContentHeight = items.reduce(0) { $0 + $1.rowHeight }
        }

        /// The list's divider insertion points, from the same call the grid makes. The two styles share one
        /// definition, so they agree about which bands apply. It returns an empty array when no bands apply,
        /// leaving the row model one to one.
        private func computeSectionBreaks() -> [(index: Int, section: GallerySection)] {
            guard let dc = dataCoordinator else { return [] }
            return GallerySectioning.displayedSectionBreaks(
                films: films, coordinator: dc, showSortingSections: showSortingSections)
        }

        // MARK: - Row ⟷ Film Conversion

        /// The film index a table row displays, or nil when the row is a section divider (or out of range).
        /// The single funnel every row→film conversion goes through.
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

        /// Returning a writer lets NSTableView detect drag gestures from inside its mouseDown tracking loop.
        /// That is the only reliable trigger. A manual mouseDown and mouseDragged bypass does not work,
        /// because NSTableView's own blocking loop consumes those events. The writer serializes the film IDs
        /// for drop destinations.
        ///
        /// NSTableView calls this once per selected row. Each non-nil writer becomes a dragging item, and the
        /// OS draws a count badge for the item count. To avoid the badge, only the lowest-index selected row
        /// returns a writer, and it carries the whole set of IDs. The other rows return nil, so the session
        /// has one item.
        func tableView(_ tableView: NSTableView,
                       pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            // Divider rows resolve to nil here, so they never produce a pasteboard writer and can never
            // originate a drag.
            guard let clickedID = film(forRow: row)?.id else { return nil }

            // Reads the synchronous AppKit selection, not selectionState.selectedFilmIDs, as GallerySubview's
            // filmIDsForDrag does. SelectionState writes through a deferred dispatch, so right after a
            // Cmd-click the model can still be one gesture behind. Reading it there could produce two writers and
            // bring back the count badge.
            //
            // Divider rows cannot be selected (shouldSelectRow), so every index here is a film row.
            let selectedRows = tableView.selectedRowIndexes

            if selectedRows.contains(row) {
                // Multi-selection drag: only the lowest-index selected row gets a writer, keeping the session
                // at one item and no count badge.
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
            // The poster preview uses the row recorded at mouseDown. rowIndexes.first is a fallback, which
            // should not be needed.
            let sourceRow = pendingDragSourceRow ?? rowIndexes.first ?? 0
            pendingDragSourceRow = nil  // Consume immediately; must not persist.

            // dragPreviewImage is cache-only by design, so it never reads disk during a drag. See
            // PosterCache.dragPreviewImage. The row is a table row index, which equals a film index only when
            // there are no divider rows.
            let sourceFilm = film(forRow: sourceRow)
            let posterImage: NSImage? = sourceFilm.flatMap {
                PosterCache.shared.dragPreviewImage(for: $0.posterUID)
            }

            // dragCount is the full selection when the source row is selected, and otherwise 1. It reads the
            // table's own selection, as the writer does, because the deferred SelectionState write would
            // report the pre-click count after a Cmd-click followed by a drag.
            let selectedRows = tableView.selectedRowIndexes
            let dragCount = selectedRows.contains(sourceRow) ? selectedRows.count : rowIndexes.count

            // Disable the built-in cancel animation — the flyback window handles the fly-back itself (see
            // GalleryDragEngine.performFlyBack).
            session.animatesToStartingPositionsOnCancelOrFail = false

            // The session has one dragging item, since pasteboardWriterForRow returns a writer only for the
            // lowest-index selected row. draggingFormation is
            // .none as a guard against a future second item.
            session.draggingFormation = .none

            // Replaces the dragging item's image with an explicit transparent 1x1 placeholder, as a second
            // suppression. The visible preview is the flyback window armed by dragEngine.prepareDrag,
            // positioned by screen-point arithmetic. The native per-item frame is unreliable for this
            // session type, so the list does not use it. See GalleryDragEngine.
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

            // Arm the drag engine: marks the session live in DragSessionMonitor and prepares the flyback
            // window at the drag's starting screen point.
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
            // A deferred selection is about to land and will sync again; see hasPendingSelection.
            guard !selectionState.hasPendingSelection else { return }
            isUpdatingSelection = true
            defer { isUpdatingSelection = false }

            // Untracked: this also runs inside updateNSView — see untrackedSelectedFilmIDs.
            let selectedIDs = selectionState.untrackedSelectedFilmIDs
            guard !selectedIDs.isEmpty else {
                // Only call deselectAll if rows are actually selected; calling it on an already-empty
                // selection fires tableViewSelectionDidChange needlessly.
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

        /// Resolves the films a secondary-click context menu should act on, and builds the menu. It is called
        /// from DraggableListTableView.menu(for:), which has already confirmed the click landed on a row.
        ///
        /// Selection rules match the grid (see GallerySubview.Coordinator.contextMenu(forItemAt:)). A click
        /// on a selected row leaves the selection alone and the menu acts on the group. A click on an
        /// unselected row selects it, since the Edit commands resolve against the selection.
        ///
        /// selectRowIndexes fires the selection callback synchronously, so isUpdatingSelection is held across
        /// it to suppress the echo. The model is then written at once with selectImmediate, since the menu's
        /// tracking loop starts as soon as this returns.
        func contextMenu(forRow row: Int) -> NSMenu? {
            // A secondary-click on a divider row returns no menu, as the grid's decorative divider bands do.
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
            // Classifies the input from NSApp.currentEvent. A mouse press or release is a deliberate click,
            // and RightSidebar resolves it at once. Arrow keys arrive with a key event, so they stay
            // `.unspecified` and keep the timing debounce for held keys. See
            // SelectionInputKind.fromCurrentAppKitEvent.
            selectionState.select(ids, inputKind: .fromCurrentAppKitEvent())
        }

        // MARK: - Observation

        private func setupSubscriptions() {
            observeSelectionState()

            // Switched exhaustively, with no default. SelectionEvent has two cases, so a default would be
            // unreachable. A third case added later becomes a compile error here rather than being ignored.
            // This mirrors GallerySubview.Coordinator.
            AppEventBus.shared.selectionEvents
                .receive(on: RunLoop.main)
                .sink { [weak self] event in
                    guard let self else { return }
                    switch event {
                    case .selectAllFilms:
                        guard let tv = self.tableView, !self.films.isEmpty else { return }
                        // Sets isUpdatingSelection before changing the table, so tableViewSelectionDidChange
                        // does not run. This follows GallerySubview.selectAll(): the visual selection changes
                        // here, not through the observation round-trip.
                        guard !self.isUpdatingSelection else { return }
                        self.isUpdatingSelection = true
                        // Row space, and film rows only: a contiguous 0..<films.count range would sweep any
                        // interleaved section-divider rows into the selection request. (They are
                        // unselectable, so AppKit would drop them — but building the set from the film rows
                        // themselves keeps the request itself honest rather than relying on that filtering.)
                        let all = IndexSet(self.filmRowMap.values)
                        self.withSuppressedCallbacks {
                            tv.selectRowIndexes(all, byExtendingSelection: false)
                        }
                        self.selectionState.selectImmediate(Set(self.films.map(\.id)))
                        DispatchQueue.main.async { [weak self] in self?.isUpdatingSelection = false }
                    case .clearFocusRings:
                        // Suppress tableViewSelectionDidChange so it doesn't schedule a redundant deferred
                        // selectionState.select(Set()) alongside the observation loop's own
                        // syncSelectionToView pass.
                        self.withSuppressedCallbacks {
                            self.tableView?.deselectAll(nil)
                        }
                    }
                }
                .store(in: &cancellables)

            // Cmd+L scrolls the table so the topmost selected film sits in the top visible row, as the grid
            // does. IndexSet.first is the smallest index, so it is the row nearest the top. Divider rows are
            // unselectable, so it is always a film row.
            //
            // This scrolls the row to the top rather than calling scrollRowToVisible, which stops as soon as
            // the row is visible. That would leave a film below the viewport on the bottom row, while the grid
            // places it at the top.
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

        /// Records this view's scroll origin each time a user scroll gesture ends. It is the list's copy of
        /// GallerySubview.Coordinator.installScrollOriginRecorder. Only user scrolling posts this
        /// notification, so it cannot save a programmatic zero. Delivery is synchronous.
        func installScrollOriginRecorder(on scrollView: NSScrollView) {
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleLiveScrollEnded(_:)),
                name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            coastStopper.install(on: scrollView)
        }

        /// Lets Cmd+L stop a trackpad coast in flight. The grid's identical member (23.20) explains it;
        /// installed and removed with the scroll-origin recorder.
        private let coastStopper = CoastingScrollStopper()

        /// Removes the live-scroll observer. Idempotent. Called from cancelSubscriptions().
        private func removeScrollOriginRecorder() {
            NotificationCenter.default.removeObserver(
                self, name: NSScrollView.didEndLiveScrollNotification, object: nil)
            coastStopper.remove()
        }

        #if DEBUG
        // MARK: Viewport-Jump Tracer (DEBUG only)
        // The shared `ViewportJumpTracer` (23.20 GallerySubview.swift) — see it for the rationale. Logs any
        // clip-view move larger than three viewport heights, with the call stack that made it.
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
            // The user has taken the viewport over by hand. Retired BEFORE the save for the reason spelled
            // out in GallerySubview.Coordinator's identical recorder: bankScrollOrigin refuses to overwrite a
            // key with an outstanding restore.
            ViewStateManager.shared.finishScrollOriginRestore(for: displayedScrollKey)
            ViewStateManager.shared.saveScrollPosition(scrollPosition(of: scrollView),
                                                       under: displayedScrollKey)
        }

        /// The scroll-bank key of the films this list is showing. See
        /// GallerySubview.Coordinator.displayedScrollKey.
        var displayedScrollKey: GalleryScrollKey {
            GalleryScrollKey(viewID: currentViewID, subTab: lastFilmQueueFilter?.rawValue)
        }

        /// See GalleryScrollPositionProviding.currentScrollState(). `prevViewID` is nil until this
        /// Coordinator's first update pass has run, which is exactly the "nothing rendered yet, currentViewID
        /// is still its default" condition the protocol requires be reported as nil rather than as a real
        /// identity.
        func currentScrollState() -> (key: GalleryScrollKey, position: GalleryScrollPosition)? {
            guard prevViewID != nil, let scrollView else { return nil }
            return (displayedScrollKey, scrollPosition(of: scrollView))
        }

        /// The scroll position of `scrollView` (this list's): its origin, anchored on the topmost visible
        /// film row. The list's counterpart to the grid's; see GalleryScrollPosition.
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

        /// Returns the current row index for the given film ID, or nil if the film is not present in this
        /// view's data. Used by ListScrollView.viewWillDraw() to resolve a pending scroll target without
        /// exposing filmRowMap itself. Returns a TABLE row index, which is what both isRowVisible(_:) and
        /// rect(ofRow:) expect.
        func rowIndex(for filmID: UUID) -> Int? {
            filmRowMap[filmID]
        }

        /// Returns whether the given row is fully or partially visible in the current scroll viewport.
        /// Mirrors GallerySubview.Coordinator.isFilmVisible(at:) — used by ListScrollView.viewWillDraw() to
        /// decide whether a search-exit handoff needs to scroll at all, or whether the target is already on
        /// screen.
        func isRowVisible(_ row: Int) -> Bool {
            guard let tv = tableView else { return false }
            return tv.visibleRect.intersects(tv.rect(ofRow: row))
        }

        /// Returns the film in the row currently topmost in the visible viewport, for the
        /// GalleryScrollPositionProviding conformance used to capture a list→grid handoff target. `rows(in:)`
        /// returns an empty range (location == -1) when no rows intersect the given rect, which the guard
        /// below rejects.
        func topmostVisibleFilmID() -> UUID? {
            guard let tv = tableView, !films.isEmpty else { return nil }
            let visible = tv.rows(in: tv.visibleRect)
            guard visible.length > 0, visible.location >= 0 else { return nil }
            // Walk forward to the first FILM row in the visible range: the topmost visible row can be a
            // section-divider band, which has no film to hand off.
            for row in visible.location..<(visible.location + visible.length) {
                if let id = film(forRow: row)?.id { return id }
            }
            return nil
        }

        /// Scrolls the table so the given film's row becomes the topmost visible row, clamped to the maximum
        /// scroll extent. It does not change selection. A film no longer in this view is ignored, as in the
        /// grid's handoff paths. See GallerySubview.Coordinator.scrollToTopRow.
        func scrollFilmToTop(_ filmID: UUID) {
            guard let tv = tableView, let scrollView, let row = filmRowMap[filmID] else { return }

            let rowRect = tv.rect(ofRow: row)
            // Content height comes from the row model's summed heights, not tv.bounds.height. On a freshly
            // created table, the frame can read 0 or stale on the first viewWillDraw pass, so the clamp could
            // collapse to zero and send every target to the top. Row arithmetic does not depend on AppKit
            // layout timing.
            //
            // It uses scrollableContentHeight (summed once per rebuild, plus the inset padding). That stays
            // correct with divider rows interleaved. The clamp is
            // NSScrollView.maxVerticalScrollOffset(forContentHeight:), shared with scrollToSectionBand and
            // resolvePendingOriginRestore. It is inset-aware, so a target near the end is not capped short of
            // the StatusBar.
            let maxScrollY = scrollView.maxVerticalScrollOffset(forContentHeight: scrollableContentHeight)
            let targetY = max(0, min(rowRect.origin.y, maxScrollY))

            appViewportMove {
                scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        /// Declares that the user has taken this viewport over by hand, so nothing the app armed earlier may
        /// still move it. The list's counterpart to GallerySubview.Coordinator.claimViewportForUser() — see
        /// that method for the full rationale and the failure it prevents.
        func claimViewportForUser() {
            ViewStateManager.shared.finishScrollOriginRestore(for: displayedScrollKey)
            // The coordinator holds this as a plain NSScrollView; the two armed-target properties live on the
            // ListScrollView subclass that actually resolves them.
            if let listScrollView = scrollView as? ListScrollView {
                listScrollView.pendingScrollPosition = nil
                listScrollView.pendingScrollFilmID = nil
            }
            guard let scrollView else { return }
            ViewStateManager.shared.saveScrollPosition(scrollPosition(of: scrollView),
                                                       under: displayedScrollKey)
        }

        /// Places the section band that begins with `firstFilmID` at the top of the viewport.
        ///
        /// Bands are real rows. rebuildRowModel always emits one just before a section's first film, so the
        /// band is the row at filmRow - 1, checked against rowItems. Scrolling to the film would push the
        /// clicked label off the top. If no band precedes the film, because bands were turned off after the
        /// menu was built, the film row is the target.
        func scrollToSectionBand(firstFilmID: UUID) {
            guard let tv = tableView, let scrollView, let filmRow = filmRowMap[firstFilmID] else { return }

            let bandRow = filmRow - 1
            let targetRow = (bandRow >= 0 && rowItems[bandRow].isDivider) ? bandRow : filmRow

            // Same clamp as scrollFilmToTop above, and for the same reasons — see that method's comment on
            // why contentHeight comes from scrollableContentHeight.
            let maxScrollY = scrollView.maxVerticalScrollOffset(forContentHeight: scrollableContentHeight)
            let targetY = max(0, min(tv.rect(ofRow: targetRow).origin.y, maxScrollY))

            appViewportMove {
                scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            scrollView.flashScrollers()
            // See the identical call in the grid's scrollToSectionBand: a programmatic jump emits no
            // didEndLiveScroll, so the new position must be banked explicitly or the pre-jump origin survives
            // to be restored later.
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
                    // A dismantled list's loop wakes once more on the next change; it must stop without
                    // syncing. See GallerySubview.Coordinator.observeSelectionState.
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

        /// Section-divider bands are purely decorative and must never take the selection — matching the grid,
        /// whose divider decoration view is excluded from hit-testing entirely
        /// (SectionDividerDecorationView.hitTest). NSTableView also honors this for its own native arrow-key
        /// navigation, stepping straight over a divider row to the next selectable film row, which is
        /// precisely the "divider is transparent to navigation" behavior GallerySubview implements by hand
        /// for the grid.
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard row >= 0, row < rowItems.count else { return false }
            // Empty "Up Next" slots are no more selectable than divider bands.
            return rowItems[row].isFilm
        }

        /// Supplies a background- and selection-free row view for section-divider rows, so a divider band
        /// renders against the table's plain backdrop rather than picking up an alternating content stripe
        /// (which would read as a content row). Film rows return nil and therefore keep NSTableView's stock
        /// row view, leaving the existing alternating-stripe and `.inset` selection appearance completely
        /// untouched.
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

/// The NSTableView subclass behind GalleryListView. It overrides the drag-source mask, limiting drops to copy
/// within the app. It forwards each move to GalleryDragEngine, so the flyback window tracks the cursor. It
/// also suppresses the native row image (see dragImageForRows). A manual mouseDown bypass does not work,
/// because NSTableView's own tracking loop consumes the drag events. The native pipeline
/// (pasteboardWriterForRow, willBeginAt, dragImageForRows) is the only hook.
#if DEBUG
extension DraggableListTableView {
    /// Row → the rating each film row the table currently holds a view for is displaying, prepared off-screen
    /// rows included. For harness checks of in-place row refresh.
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

    /// Set by DraggableListView.makeNSView immediately after construction. fileprivate because
    /// DraggableListView is a private type in this file.
    fileprivate weak var coordinator: DraggableListView.Coordinator?

    /// Supplies the contextual (secondary-click) menu for a given row. Wired to
    /// `DraggableListView.Coordinator.contextMenu(forRow:)`, which resolves the target film set — and, when
    /// required, adjusts the selection — before building the menu. Returning nil suppresses the menu
    /// entirely.
    fileprivate var getContextMenu: ((Int) -> NSMenu?)?

    // MARK: - Contextual Menu

    /// Supplies the gallery context menu for a secondary-click or Control-click on a row. The hit test
    /// matches mouseDown: a valid row and a valid column. With the .inset style, the margins beside a row
    /// belong to no column, and a primary click there counts as clicking nothing. Requiring a column keeps
    /// the two consistent. It does not call super, since NSTableView's own menu would appear for non-row
    /// points.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedCol = column(at: point)
        guard clickedRow >= 0, clickedCol >= 0 else { return nil }
        return getContextMenu?(clickedRow)
    }

    // MARK: - Side-padding deselect

    /// Deselects the selection when the user clicks the horizontal margin beside a row. With the .inset
    /// style, row(at:) finds the row there but column(at:) returns -1, so the click is treated as clicking
    /// nothing, the same as the empty space below the rows.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedCol = column(at: point)

        // Defensive self-heal: close-and-flush any click window a prior gesture somehow left open (see
        // GalleryCollectionView.mouseDown for the identical guard). Internally guarded — a free no-op in
        // every normal flow.
        DragSessionMonitor.shared.clickWindowDidClose()

        // The user is acting on this viewport directly, so retire anything still armed to move it. Mirrors
        // the identical call at the top of GalleryCollectionView.mouseDown — see
        // Coordinator.claimViewportForUser() for what it prevents.
        coordinator?.claimViewportForUser()

        // If the click lands on a valid row but outside any column (i.e., in the left or right inset
        // padding), deselect and absorb the event. Do not call super, which would let NSTableView treat it as
        // a row selection gesture.
        if clickedRow >= 0 && clickedCol < 0 {
            if !selectedRowIndexes.isEmpty {
                deselectAll(nil)
            }
            return
        }

        // Records the pressed row before super.mouseDown enters the drag loop. Call order across multiple
        // rows is not guaranteed to start with the grabbed row. Only film rows matter, since a divider row
        // can never start a drag.
        if clickedRow >= 0, coordinator?.filmIndex(forRow: clickedRow) != nil {
            coordinator?.pendingDragSourceRow = clickedRow
        }

        // Opens the click-ambiguity window around NSTableView's synchronous tracking loop. Selection commits,
        // and the sidebar's deferred write, can run inside that loop. Without the window, a fast drag's start
        // contends with the sidebar rebuild. Row hits only. On return, clickWindowDidClose() flushes a plain
        // click, or does nothing if a session began. See DragSessionMonitor.
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

    /// Returns a 1x1 transparent image, suppressing the native row drag preview. NSTableView calls this while
    /// building the session, before willBeginAt. Delegate hooks are too late, because the image is composited
    /// by then. The offset is irrelevant, since the native item is never shown. The visible preview is the
    /// flyback window, armed by GalleryDragEngine.prepareDrag and moved by draggingSession(_:movedTo:).
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

/// The NSView subclass that hosts a GalleryListRow through NSHostingView. NSTableView reuses it through its
/// cell queue. Like GalleryItem, it tracks each rendered field, so rootView is reassigned only when something
/// visible changes.
private final class ListRowHostCell: NSView {

    private var hostingView: NSHostingView<GalleryListRow>?

    // Change tracking covers every field GalleryListRow renders: posterUID (poster), name, hasPurchased (disc
    // badge), durationParts, userRating, releaseYear, and subtitle (Recents only). Tracking all of them keeps
    // in-place edits visible even when the film's sort position and the table's count and endpoints have not
    // changed.
    //
    // The derived fields are tracked by rendered value, not by their raw sources. A release edit that does
    // not change the displayed result correctly skips the reassignment. Both are computed once and passed to
    // the row, so the comparison and the render always agree.
    private var currentFilmID: UUID?
    private var currentPosterUID: String?
    private var currentName: String?
    private var currentHasPurchased: Bool?
    private var currentDurationParts: DurationParts?
    private(set) var currentUserRating: Int?
    private var currentReleaseYear: String?
    // Double-optional on purpose: nil means "never configured", .some(nil) means "configured with no
    // subtitle", so a first configuration can never be mistaken for an unchanged one.
    private var currentSubtitle: String??

    // Both initializers are required, and neither is redundant: declaring init?(coder:) suppresses
    // initializer inheritance, so init(frame:) has to be restated for the no-argument construction the
    // cell-reuse paths above use.
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

        // Update all tracking fields before the (conditional) hosting-view update so the next call has the
        // correct baseline regardless of whether we render.
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
            // Skip the rootView assignment entirely when nothing displayed changed. SwiftUI still diffs on
            // assignment even when the value is identical, so avoiding the assignment is the only way to
            // guarantee zero CPU cost.
            if needsUpdate {
                #if DEBUG
                GalleryRefreshProbe.listRowRootViewAssignments += 1
                #endif
                host.rootView = rootView
            }
        } else {
            let host = NSHostingView(rootView: rootView)
            host.translatesAutoresizingMaskIntoConstraints = false
            // Disable SwiftUI intrinsic-size participation. The hosting view is fully constraint-driven
            // (pinned to all four edges below), so Auto Layout must never invoke a SwiftUI layout pass to
            // satisfy its size. Without this, NSHostingView performs a full SwiftUI layout on every cell
            // recycle during scrolling. Matches GalleryItem behavior.
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

/// The row view for section-divider rows only. NSTableView draws stripes and the selection highlight in the
/// row view, so a divider must have neither. A stripe would make it look like a content row. Overriding both
/// drawing entry points to no-ops is the narrowest fix. It affects divider rows only, since rowViewForRow
/// returns nil for film rows, which keep the stock inset selection.
private final class ListDividerRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        // Deliberately empty: the divider band sits directly on the table's own backgroundColor, matching the
        // grid, where the divider decoration draws no background of its own either (see
        // SectionDividerDecorationView).
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // Deliberately empty. Unreachable in normal operation — a divider row can never become selected — but
        // a no-op here means even a future path that somehow marked one selected could not paint a highlight
        // over a decorative band.
    }
}

// MARK: - ListDividerHostCell

/// NSView subclass that hosts a SwiftUI `GalleryListSectionDivider` via NSHostingView. The divider
/// counterpart to ListRowHostCell, with the identical reuse and change-tracking discipline: `rootView` is
/// reassigned only when the section or its film count actually changed, so a recycled instance neither
/// re-renders needlessly nor shows a stale section name.
private final class ListDividerHostCell: NSView {

    private var hostingView: NSHostingView<GalleryListSectionDivider>?

    private var currentSection: GallerySection?
    private var currentFilmCount: Int?

    // Both initializers are required, and neither is redundant: declaring init?(coder:) suppresses
    // initializer inheritance, so init(frame:) has to be restated for the no-argument construction the
    // cell-reuse paths above use.
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
            // Constraint-driven, exactly as in ListRowHostCell — Auto Layout must never invoke a SwiftUI
            // sizing pass to satisfy this view's dimensions.
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

/// The list's section band: a bold, left-aligned label with a live film count on the right, above a hairline
/// separator. It matches the grid's SectionDividerDecorationView in order and composition, with smaller type
/// to fit a 44 pt row.
private struct GalleryListSectionDivider: View {
    let section: GallerySection
    let filmCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(section.displayName)
                    // 20pt bold, matching SectionDividerDecorationView's sectionLabel in the grid style
                    // exactly, so the two gallery styles label the Film Queue's sections identically rather
                    // than at two different scales. The count label beside it was already 10pt in both.
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

            // Color, not a Divider(): a plain Divider draws at the system hairline thickness and cannot be
            // thickened, whereas the grid's band uses an explicit 2pt rule. Matching it keeps the two styles
            // visually consistent. Color also resolves for light/dark automatically, unlike the raw CALayer
            // background the AppKit decoration view has to re-resolve by hand.
            Color(nsColor: .separatorColor)
                .frame(height: 2)
        }
        // The band content keeps its own fixed height; the vertical padding is added around it, so the extra
        // space appears BETWEEN the divider and the film rows above and below rather than being absorbed into
        // the band's internal layout.
        .frame(height: kListSectionDividerBandHeight)
        // Aligned with the film rows' own symmetric horizontal inset so the label shares a left edge with the
        // poster column and the count shares a right edge with the year.
        .padding(.horizontal, GalleryListRow.contentInset)
        .padding(.vertical, kListSectionDividerVerticalPadding)
        .frame(height: kListSectionDividerHeight)
    }
}

// MARK: - GalleryListRow

/// One film row: poster thumbnail, title, then four fixed-width trailing columns (purchased badge, duration,
/// rating, and year).
///
/// Columns have fixed widths, so they line up down the table, and each row's layout is simple arithmetic with
/// no measuring pass. The title is the only flexible element. It truncates when the window is narrow, so no
/// column clips or wraps.
struct GalleryListRow: View {
    let film: FilmSnapshot
    /// Precomputed by ListRowHostCell so the same value drives both its change tracking and this render — see
    /// that type's tracking comment.
    let hasPurchasedRelease: Bool
    /// Precomputed abbreviated runtime, split into separately aligned components. Either or both may be empty
    /// (no runtime recorded, or a whole number of hours/minutes).
    let durationParts: DurationParts
    /// Optional by-line under the title -- the same string the grid shows beneath the poster (a Recents
    /// date), nil everywhere the grid shows none. Resolved once by the Coordinator so the host cell's change
    /// tracking and this render agree.
    let subtitle: String?

    /// The row's symmetric horizontal content inset. Applied as the poster's leading padding and as the
    /// metadata block's trailing padding, so the space between the content and the view's edge is identical
    /// on both sides. The left side is the reference: this is the poster's 8 pt leading inset, named here.
    static let contentInset: CGFloat = 8

    // Fixed trailing-column geometry.
    //
    // Each column's box fits its own content, and all visible separation comes from `columnGap`. Slack inside
    // a box shows up as a gap on whichever side the alignment pushes it, so unused box width makes one
    // separator look wider than the others.
    //
    //   discColumnWidth   -- the 15 pt symbol, centered.
    //   hoursBoxWidth     -- "12 hr." at 11 pt, right-aligned, sized for two digits.
    //   minutesBoxWidth   -- "59 min." at 11 pt, right-aligned.
    //   durationInnerGap  -- the gap between hours and minutes, smaller than columnGap because the two halves read as one value.
    //   ratingColumnWidth -- the star and a two-digit rating.
    //   yearColumnWidth   -- four 12 pt monospaced digits.
    private static let columnGap: CGFloat = 16
    // The gap after the disc badge is half of columnGap. The hours box is right-aligned and sized for two
    // digits, so a one-digit runtime leaves empty box on the leading side. Trimming this gap compensates, so
    // the separator still reads as the others.
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

            // The title, with the subtitle beneath it when there is one. Each line truncates on its own, and
            // both are leading-aligned. They fit in the 44 pt row with the same vertical centering as a lone
            // title.
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

            // minLength 8 guarantees a visible gap between a truncated title and the metadata columns instead
            // of the two running together.
            Spacer(minLength: 8)

            // spacing is 0 and each boundary carries its own explicit leading padding: the disc -> duration
            // gap has to differ from the other two (see discToDurationGap), which a single uniform HStack
            // spacing cannot express.
            HStack(spacing: 0) {
                // Purchased badge: shown when ANY associated release is marked purchased, regardless of
                // format. Rendered as a fixed-width slot in both states (a 1pt-tall clear filler when absent)
                // so the columns to its right hold the same x-position on every row whether or not the badge
                // is present.
                Group {
                    if hasPurchasedRelease {
                        Image(systemName: ContentGlyphs.disc)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
                .frame(width: Self.discColumnWidth, alignment: .center)
                // The glyph alone doesn't convey its meaning, so name it; the empty placeholder state is
                // hidden from assistive technology entirely rather than announced as a blank element.
                .accessibilityLabel(Text("Purchased"))
                .accessibilityHidden(!hasPurchasedRelease)

                // Hours and minutes each get their own fixed-width box, right-aligned. So each right edge
                // stays on one vertical line, and the gap between them is set by durationInnerGap, not by the
                // values. The boxes are sized to their content, so no leftover slack adds to the gap.
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
                            // Belt-and-suspenders against the double-digit wrap: the column is sized
                            // snugly to "star + 10", so this keeps a two-digit rating on one line
                            // even if the fit is marginal.
                            .lineLimit(1)
                            .fixedSize()
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
                .frame(width: Self.ratingColumnWidth, alignment: .leading)
                .padding(.leading, Self.columnGap)

                // Trailing-aligned, and now sized to its own content: the alignment puts the year's right
                // edge exactly `contentInset` from the view's right edge (matching the poster's left inset),
                // and the tight width means there is no surplus left over to pile up on its leading side as a
                // false gap.
                Text(film.releaseYear)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: Self.yearColumnWidth, alignment: .trailing)
                    .padding(.leading, Self.columnGap)
            }
            // The trailing columns are fixed-size and must never be the element that gives way when the row
            // is narrow — the title is. Without this, SwiftUI is free to compress the fixed frames instead of
            // truncating the Text.
            .layoutPriority(1)
            // Mirrors the poster's leading inset exactly, so the gap between the year's right edge and the
            // view's right edge equals the gap between the poster's left edge and the view's left edge. Both
            // read from GalleryListRow.contentInset, so the two sides cannot drift apart.
            .padding(.trailing, Self.contentInset)
        }
        .frame(height: kListRowHeight)
    }

    // MARK: - Derived Column Values
    //
    // Static and `nonisolated` so ListRowHostCell can compute them once and use the results for both its
    // change comparison and this row's rendered content, which is what guarantees the two can never disagree
    // about what is on screen.

    /// True when at least one associated release is marked purchased, in any format. Uses `contains(where:)`
    /// rather than FilmSnapshot.purchasedReleases so no intermediate array is allocated per row during
    /// scrolling.
    nonisolated static func hasPurchasedRelease(_ film: FilmSnapshot) -> Bool {
        film.releases.contains { $0.purchased }
    }

    /// The film's runtime split into abbreviated hour and minute parts (e.g. "1 hr." and "50 min."). It uses
    /// the edited runtime when one applies. Both parts are empty when there is no runtime. The hour part is
    /// empty under an hour, and the minute part is empty for a whole number of hours.
    ///
    /// The test for an edited runtime is FilmSnapshot.effectiveDuration, the same value MetadataCache sorts
    /// by, so the column agrees with the sort. The `edited` check matters because FilmSheet blanks
    /// editedDuration only on save, and a stale value must not appear here. The split uses
    /// RSBHelpers.hoursAndMinutes, so "no duration" means the same thing as in the sidebar.
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

/// The two separately aligned halves of the list gallery's duration column. Equatable so ListRowHostCell can
/// use it directly as a change-tracking value.
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
                // The full-resolution poster is drawn into a 24 by 36 pt slot, a large downscale. The default
                // interpolation point-samples at that ratio and produces harsh, aliased edges. .high
                // resamples with filtering, and .antialiased(true) smooths the shape's edge. Both are
                // draw-time flags on an image that is already cached, so they add no decode and no memory.
                // They apply before scaledToFill, so they govern that scaling.
                .interpolation(.high)
                .antialiased(true)
                .scaledToFill()
                .frame(width: thumbnailWidth, height: thumbnailHeight)
                .clipped()
                // Soft inner-shadow band along the edges -- see PosterEdgeSheen in 23.50 GalleryItemView.swift.
                .overlay { PosterEdgeSheen.overlay() }
                // `.continuous` matches every other poster site and the sheen's own corner profile; at a 2pt
                // radius it is indistinguishable from circular, so this is purely for consistency.
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

/// The result list in the sheets: the Up Next slot sheet (UpNextSlots.swift) and the Saved Search sheet
/// (SavedSearchSheet.swift). It is not GalleryListView, which is wired to the library, selection, scroll
/// handoffs, and the drag engine. It is the same table style, with the same stripes, row height, and row
/// views, but without that wiring. It has no drag source and no context menu.
///
/// Rows are selectable only when onSelect is given. Selection commits on mouse-down, as NSTableView does
/// natively. The table refuses first responder so the sheet's search field keeps the keyboard. Its selection
/// is always the emphasized accent color, since a table without first responder would otherwise show gray.
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
        /// True while updateNSView drives the table, so its own selection changes are not echoed back as user
        /// selections.
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

/// The sheets' table, with room below the last row as wide as the `.inset` style's side margins. The room is
/// part of the document itself, since a scroll-view content inset would shorten the scroller. So the
/// scroller spans the whole box. The stripes run on through the band unchanged, as AppKit draws them below
/// any striped table's rows: painting the band plain would cut short the stripe that follows it during overscroll.
private final class SheetResultsTableView: NSTableView {
    /// The `.inset` style's side margin around the stripes (10 pt), so the
    /// band below the rows reads as the same margin.
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

/// Stock row drawing (stripe, `.inset` selection), but always in the active window's emphasized state, since
/// the table never holds first responder.
private final class UpNextResultRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set { }
    }
}
