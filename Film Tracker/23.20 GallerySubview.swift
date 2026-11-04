// MARK: - GallerySubview.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Grid-based gallery with smooth item resizing, a column limit of six or seven, and a centered maximum width
/// set by Preferences.galleryMaxGridWidth.

import SwiftUI
import Combine
import UniformTypeIdentifiers
import QuartzCore

#if DEBUG
/// Counters for harness measurements of the gallery's per-update refresh work.
@MainActor
enum GalleryRefreshProbe {
    /// Grid updates that forced a collection-view layout to relabel divider bands.
    static var forcedDividerLayouts = 0
    /// Grid updates that skipped that forced layout because no band can exist.
    static var skippedDividerLayouts = 0
    /// List rows refreshed in place after a same-order film edit.
    static var listRowsRefreshed = 0
    /// List row hosting views whose rootView was actually reassigned.
    static var listRowRootViewAssignments = 0
    /// Grid cells whose selection ring was re-stroked (GalleryItem.updateRingVisibility).
    static var ringRefreshes = 0
}
#endif

/// The search-exit scroll is gated only by Preferences.maintainSelectionOnSearchExit, at its one producer
/// (MainView.handleSearchContentChange). Neither gallery style adds a gate. The scroll intent (GalleryScrollIntent
/// and PendingScrollBehavior, in ViewState.swift) serves the search exit and the grid-list toggle for both styles.

// MARK: - Width Observing Scroll View

final class WidthObservingScrollView: NSScrollView, Loggable {
    nonisolated static let logTag = "[GallerySubview]"

    /// Pending scroll target, set by GallerySubview.makeNSView when the grid is the destination. The list equivalent
    /// is DraggableListView.makeNSView. It is resolved and cleared in viewWillDraw().
    var pendingScrollFilmID: UUID?
    /// Pending scroll origin restore for maintainScrollPositionOnViewSwitch. It is armed by updateNSView's view-switch
    /// branch and resolved in viewWillDraw(). It never coexists with a film target. If both are set, the film target wins.
    var pendingScrollPosition: GalleryScrollPosition?
    /// Pending keyboard-focus claim, set by GallerySubview.makeNSView (the list equivalent is DraggableListView). It is
    /// honored and cleared in viewWillDraw(), the first hook that runs with the view in a window.
    var pendingKeyboardFocus = false
    /// Weak reference to the Coordinator, for viewWillDraw(). It is wired in makeNSView.
    weak var galleryCoordinator: GallerySubview.Coordinator?

    override func layout() {
        /// Sampling point for the live-resize profiler. It does nothing unless the app is launched with -FTDebugLiveResize.
        #if DEBUG
        DebugLiveResizeProfiler.shared.beginPass(width: bounds.width)
        #endif
        /// Disables implicit Core Animation transitions during this layout pass, so resizing does not pulse.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        super.layout()
        CATransaction.commit()

        /// Applies any pending scroll correction from the layout's viewport anchoring. This runs after super.layout(),
        /// once prepare() has computed the correction.
        if let cv = documentView as? NSCollectionView,
           let layout = cv.collectionViewLayout as? SmoothResizingGridLayout,
           let correction = layout.pendingScrollCorrection {
            layout.pendingScrollCorrection = nil
            appViewportMove {
                contentView.setBoundsOrigin(correction)
                reflectScrolledClipView(contentView)
            }
        }
    }

    /// Resolves any pending scroll (a film target or a saved origin) immediately before the view is drawn.
    ///
    /// viewWillDraw runs after layout and before drawing, so the bounds origin set here reaches the compositor in the same
    /// frame. The first painted frame is already scrolled, with no flicker. Resolving in layout() fails because the item
    /// attributes are still nil there. Resolving on the next main-queue turn paints a pre-scroll frame first. Because this
    /// runs before every draw, resolution retries until geometry exists.
    override func viewWillDraw() {
        super.viewWillDraw()

        /// A film target takes precedence. An armed origin restore is stale while a film target is pending, so it is
        /// discarded when the film target resolves.
        if pendingScrollFilmID != nil {
            resolvePendingFilmTarget()
        } else if pendingScrollPosition != nil {
            resolvePendingOriginRestore()
        }

        resolvePendingKeyboardFocus()
    }

    /// Keyboard-focus claim for the search-exit handoff (see GalleryFocusIntent in ViewState.swift). It needs a window,
    /// not geometry, so it is independent of the scroll above.
    ///
    /// makeFirstResponder is deferred one turn, since becoming first responder restyles selected items and belongs outside
    /// the display pass. The selection is already in place, so the view does not seed item 0.
    private func resolvePendingKeyboardFocus() {
        guard pendingKeyboardFocus, let window = unsafe window, let target = documentView else { return }
        pendingKeyboardFocus = false
        DispatchQueue.main.async { [weak window, weak target] in
            guard let window, let target, unsafe target.window === window else { return }
            window.makeFirstResponder(target)
        }
    }

    /// Film-target resolution for every scroll handoff (see GalleryScrollIntent in ViewState.swift). The film's row goes
    /// to the top of the viewport, as far as the content allows, as with Cmd+L. This happens even if the film is visible,
    /// because a film left at the bottom edge could be cut off.
    private func resolvePendingFilmTarget() {
        guard let filmID = pendingScrollFilmID else { return }
        guard bounds.width > 0, documentVisibleRect.height > 0,
              let coordinator = galleryCoordinator else { return }

        guard let index = coordinator.filmIndexMap[filmID] else {
            /// The film is no longer in this view's data, so the stale target is dropped.
            pendingScrollFilmID = nil
            return
        }

        let indexPath = IndexPath(item: index, section: 0)
        guard let cv = documentView as? NSCollectionView,
              let layout = cv.collectionViewLayout as? SmoothResizingGridLayout,
              layout.layoutAttributesForItem(at: indexPath) != nil else {
            /// Geometry is not ready. viewWillDraw runs again, so the target stays and is retried.
            return
        }

        pendingScrollFilmID = nil
        /// Discards any superseded origin restore, along with the intent it came from. Otherwise the intent would be
        /// re-armed on the next update and fight this scroll.
        pendingScrollPosition = nil
        ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)

        coordinator.scrollToTopRow(at: indexPath)
        Self.log("Scroll handoff resolved pre-draw: film \(filmID) → index \(index)")
    }

    /// Applies an armed origin restore immediately, if geometry allows it. updateNSView calls this right after arming,
    /// because viewWillDraw is not reliable here. In a layer-backed hierarchy, viewWillDraw reaches only views whose layer
    /// needs display. A fresh mount dirties the whole hierarchy, but a reused gallery's sub-tab switch dirties only the
    /// collection view, so an origin armed there would never apply.
    ///
    /// If geometry is not ready, this is a no-op and the origin stays armed for viewWillDraw to retry.
    func applyPendingOriginRestoreIfPossible() {
        resolvePendingOriginRestore()
    }

    /// Applies an armed film target immediately, if geometry allows it.
    ///
    /// The film-target counterpart of applyPendingOriginRestoreIfPossible(), and it exists
    /// for exactly the same reason: on a REUSED gallery — a smart-list sub-variant switch,
    /// where the enclosing GalleryView keeps its `.id` — the reload dirties the collection
    /// view and its items but never this scroll view's own layer, so AppKit sends no
    /// viewWillDraw and a target armed there would sit untouched forever. The fresh-mount
    /// producers are unaffected and continue to resolve pre-draw.
    ///
    /// If geometry is not ready yet this is a no-op and the target stays armed, so
    /// viewWillDraw remains the automatic retry path.
    func applyPendingFilmTargetIfPossible() {
        resolvePendingFilmTarget()
    }

    /// Saved-origin restore for the maintainScrollPositionOnViewSwitch feature, armed by
    /// GallerySubview.updateNSView's view-switch reload branch after reloadData() has
    /// reset the scroll position to zero. Applied pre-draw (from viewWillDraw, or directly
    /// via applyPendingOriginRestoreIfPossible), so the first painted post-reload frame is
    /// already at the restored position — replacing the previous alpha-hide +
    /// DispatchQueue.main.async restore, whose hide/unhide window this mechanism makes
    /// unnecessary.
    private func resolvePendingOriginRestore() {
        guard let position = pendingScrollPosition else { return }
        guard bounds.width > 0, documentVisibleRect.height > 0,
              let coordinator = galleryCoordinator else { return }
        guard let cv = documentView as? NSCollectionView,
              let layout = cv.collectionViewLayout as? SmoothResizingGridLayout,
              layout.collectionViewContentSize.height > 0 else {
            /// Geometry not ready yet — viewWillDraw fires again on the next display
            /// pass, so the origin is retained and retried automatically (matching
            /// resolvePendingFilmTarget's guard-and-retry pattern).
            return
        }

        pendingScrollPosition = nil
        /// Retire the intent now that it has genuinely been applied against real geometry.
        /// Until this point it stays live in ViewStateManager on purpose, so a reload that
        /// lands between arming and resolution re-arms it rather than losing it.
        ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)

        let target = applyClampedOrigin(CGPoint(x: 0, y: coordinator.restoreY(for: position)),
                                        layout: layout)
        Self.log("Saved scroll origin restored pre-draw: \(target)")
    }

    /// Moves the viewport to `origin`, clamped to the valid scroll range. The content may have shrunk since the origin was
    /// saved, and an out-of-range origin would show blank space. Same clamping as scrollToTopRow.
    @discardableResult
    private func applyClampedOrigin(_ origin: CGPoint, layout: SmoothResizingGridLayout) -> CGPoint {
        let contentHeight = layout.collectionViewContentSize.height
        let maxScrollY = max(0, contentHeight - documentVisibleRect.height)
        let target = CGPoint(x: origin.x, y: min(max(0, origin.y), maxScrollY))
        appViewportMove {
            contentView.setBoundsOrigin(target)
            reflectScrolledClipView(contentView)
        }
        return target
    }
}

// MARK: - GallerySubview

/// StatusBar overlay height, for the bottom inset. It is file-scope so it is not redeclared on every update.
private let kStatusBarHeight: CGFloat = StatusBar.height

/// There is no local grid-padding constant. The scroll helpers read `layout.lineSpacing` from the live layout, so
/// they cannot drift from the grid geometry.

/// Reusable cell identifier for GalleryItem, created once.
private let kGalleryItemID = NSUserInterfaceItemIdentifier("GalleryItem")

struct GallerySubview: NSViewRepresentable, Loggable {
    nonisolated static let logTag = "[GallerySubview]"

    /// There is no forceReloadID. Reloads depend only on the films (see needsReload in updateNSView).
    /// A post-edit "keep this film in view" request from GalleryView. It is one-shot: the Coordinator acts on each
    /// request once, so GalleryView never has to clear it.
    let scrollRequest: FilmScrollRequest?
    /// The active ViewIdentifier from ViewStateManager. It lets the Coordinator detect view switches exactly.
    let activeViewID: ViewIdentifier
    /// The subtitle provider for the active view, built by GalleryView and passed down. GalleryItem's tile content is pure
    /// AppKit and has no SwiftUI environment, so it cannot read one. The Coordinator forwards it to each cell on configure.
    let subtitleProvider: GallerySubtitleProvider?
    /// Whether section dividers are shown. GalleryView reads it from the films on screen (ViewStateManager.displayedGalleryState)
    /// and passes it down, so the style and dividers always match the same Film Queue tab. A change is a value change, which
    /// schedules the update pass that adds or removes the bands.
    let showSectionDividers: Bool

    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SelectionState.self) private var selectionState
    /// Observes the StatusBar preference, for bottom padding.
    @AppStorage(preference: Preferences.showStatusBarKey) private var showStatusBar: Bool
    /// Observes the large grid preference, for the column maximum: false is 7 columns, true is 6.
    @AppStorage(preference: Preferences.largeGalleryGridKey) private var largeGalleryGrid: Bool
    /// maintainScrollPositionOnViewSwitch is not read here. ViewStateManager.prepareScrollHandoff checks the preference
    /// and arms nothing when it is off. Keeping a second reader here could let the two disagree.

    func makeNSView(context: Context) -> NSScrollView {
        #if DEBUG
        ViewSwitchProbe.record("grid.make \(activeViewID) films=\(dataCoordinator.films.count)")
        #endif
        let scrollView = WidthObservingScrollView()
        configureScrollView(scrollView)

        let collectionView = GalleryCollectionView()
        configureCollectionView(collectionView)

        let layout = SmoothResizingGridLayout()
        /// edgeInset, itemSpacing, and lineSpacing are `let` on the layout, so they are not set here.
        /// Reserves space for StatusBar when it is visible.
        layout.bottomInset = showStatusBar ? kStatusBarHeight : 0
        layout.hasSubtitles = subtitleProvider != nil
        /// Applies the column maximum from the preference: 7 by default, 6 for the large grid.
        layout.maxColumns = largeGalleryGrid ? Preferences.galleryMaxColumnsLargeGrid
                                             : Preferences.galleryMaxColumns
        collectionView.collectionViewLayout = layout

        collectionView.register(GalleryItem.self,
            forItemWithIdentifier: kGalleryItemID)

        /// Registers the section-divider decoration view. AppKit creates and recycles its instances. Other gallery views
        /// publish no section breaks, so this view is never created there.
        layout.register(SectionDividerDecorationView.self,
            forDecorationViewOfKind: sectionDividerDecorationKind)
        /// The "Up Next" placeholder slots exist only on the Film Queue's "All" tab (see updateSectionDividers).
        layout.register(UpNextSlotDecorationView.self,
            forDecorationViewOfKind: upNextSlotDecorationKind)

        let coordinator = context.coordinator
        collectionView.delegate = coordinator
        collectionView.dataSource = coordinator
        scrollView.documentView = collectionView

        coordinator.collectionView = collectionView
        coordinator.scrollView = scrollView
        coordinator.dataCoordinator = dataCoordinator
        coordinator.showSortingSections = showSectionDividers
        coordinator.subtitleProvider = subtitleProvider

        /// Arms the warming scroll prefetch, unless the startup population has already finished.
        coordinator.installWarmingScrollPrefetch(on: scrollView)
        #if DEBUG
        coordinator.installViewportJumpTracer(on: scrollView)
        #endif

        /// Keeps the saved scroll origin current as the user scrolls. The teardown-time save alone is not enough.
        collectionView.onUserViewportInteraction = { [weak coordinator] in
            coordinator?.claimViewportForUser()
        }
        coordinator.installScrollOriginRecorder(on: scrollView)

        /// Wires up callbacks. The layout computes itself, so no width callback is needed.
        collectionView.onMarqueeSelectionChanged = { [weak coordinator] in coordinator?.handleMarqueeSelection($0) }
        collectionView.onArrowNavigation = { [weak coordinator] in coordinator?.handleArrowKey($0, withShift: $1, isRepeat: $2) }
        /// Gated the same way as KeyboardManager and the Select All menu item. Without this gate, Cmd+A selected every film in
        /// Recents, Unwatched, and the Film Queue.
        collectionView.onSelectAll = { [weak coordinator] in
            guard let coordinator,
                  AppDelegate.appState?.selectedSidebarItem.capabilities.supportsMultiSelection == true
            else { return false }
            coordinator.selectAll()
            return true
        }
        collectionView.getDragFilmIDs = { [weak coordinator] in coordinator?.filmIDsForDrag(clickedAt: $0) ?? [] }
        collectionView.getFilmID = { [weak coordinator] in coordinator?.filmID(at: $0) }
        collectionView.getPosterImage = { [weak coordinator] in coordinator?.posterImage(for: $0) }
        /// Seeds the cursor at item 0 when focus arrives by Tab or programmatic transfer with no selection, so arrow keys
        /// work without a prior click.
        collectionView.onKeyboardFocusWithNoSelection = { [weak coordinator] in coordinator?.seedInitialCursor() }
        /// Secondary-click contextual menu. GalleryCollectionView.menu(for:) has already confirmed a real item was clicked.
        collectionView.getContextMenu = { [weak coordinator] in coordinator?.contextMenu(forItemAt: $0) }

        // MARK: Scroll-Position Handoff (Search Exit / Grid-List Toggle)
        ///
        /// If a scroll intent is pending and addressed to this view's activeViewID, the targeting stops a stale search view from
        /// consuming it (see GalleryScrollIntent in ViewState.swift). Then:
        ///
        /// 1. Preload the destination films and reloadData(). The first updateNSView pass sees identical films and does not
        ///    reload again, since a second reloadData() would reset the scroll to the top. MainView switches the view before the
        ///    sidebar flip, so the films are already there.
        /// 2. Hand the film ID to the scroll view. The scroll runs in WidthObservingScrollView.viewWillDraw(), after layout and
        ///    before the first frame, so the first visible frame is already on the film. There is no hiding and no interstitial frame.
        scrollView.galleryCoordinator = coordinator
        /// A request already pending when this gallery mounts belongs to an earlier edit, so it is seeded here and not acted on again.
        coordinator.lastScrollRequest = scrollRequest

        /// Registers this coordinator as the "what's on top" source for the active view. The grid-list toggle reads it before
        /// switching away from the grid. It is unregistered in dismantleNSView (see registerScrollPositionProvider).
        ViewStateManager.shared.registerScrollPositionProvider(coordinator)

        /// Consumes a pending scroll intent addressed to this view. This is the search-exit handoff or the grid-list toggle
        /// handoff, and both share the preload sequence below. Each producer has already applied its own gating (see the note at
        /// the top of this file).
        if let filmID = GalleryScrollIntent.shared.consume(ifTargeting: activeViewID) {
            coordinator.films = dataCoordinator.films
            /// This preload path bypasses updateNSView's reload branch, so it must recompute the section dividers itself. Without that,
            /// a fresh Film Queue instance would show no dividers until some later reload. The recomputation reads dataCoordinator, whose
            /// identity and filter already match the destination, because switchToViewSync ran earlier (see the dataCoordinator.films note
            /// above). Here the divider work is real, not a no-op, since the Queue's view-style toggle is enabled.
            ///
            /// currentViewID is set from activeViewID here, so it agrees with the preloaded data. prevViewID is seeded too, or it would
            /// stay nil. The next updateNSView would then see a view switch, reload again, clear the selection, and arm a restore on top
            /// of the film handoff. Both fields are seeded together, as updateNSView's own reload branch does when it advances prevViewID.
            ///
            /// The preloaded films were built with the loaded Queue filter, so that filter is seeded too. displayedScrollKey then describes
            /// them from the start, and the filter-change test reads it as unchanged.
            ///
            /// This path bypasses updateNSView's origin restore, and the film handoff outranks it. Any armed origin restore is retired here,
            /// so a later pass cannot fight this scroll.
            ///
            /// If no film handoff claims this mount, a saved origin may be armed (see armScrollOriginRestoreOnMount). It yields to any
            /// in-flight switch intent. updateNSView's reload branch performs the restore once the destination's films are in place.
            coordinator.currentViewID = activeViewID
            coordinator.prevViewID = activeViewID
            coordinator.lastFilmQueueFilter = dataCoordinator.loadedFilmQueueFilter
            coordinator.updateSectionDividers()
            coordinator.withSuppressedCallbacks {
                collectionView.reloadData()
            }
            scrollView.pendingScrollFilmID = filmID
            ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)
            Self.log("Scroll handoff armed in makeNSView for film \(filmID) (view: \(activeViewID))")
        } else {
            /// No film handoff claims this mount, so a saved origin may. This covers arrivals that
            /// switchToViewSync does not see as a change (see armScrollOriginRestoreOnMount). It yields to
            /// any in-flight switch intent. updateNSView's reload branch performs the restore once the films are in place.
            ViewStateManager.shared.armScrollOriginRestoreOnMount(
                for: GalleryScrollKey(viewID: activeViewID,
                                      subTab: dataCoordinator.loadedFilmQueueFilter?.rawValue))
        }

        /// Runs outside the scroll-handoff branch, since the two intents are independent. See GalleryFocusIntent.
        if GalleryFocusIntent.shared.consume(ifTargeting: activeViewID) {
            scrollView.pendingKeyboardFocus = true
            Self.log("Keyboard-focus handoff armed in makeNSView (view: \(activeViewID))")
        }

        return scrollView
    }

    private func configureScrollView(_ scrollView: NSScrollView) {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .allowed
        /// Uses overlay scrollers, as DraggableListView does. The layout takes its width from the scroll view's bounds. Under
        /// legacy scrollers, AppKit reserves scroller space from the clip view, and the grid would be wider than the visible
        /// area. With no horizontal scroller, the trailing column would be clipped with no way to reach it.
        scrollView.scrollerStyle = .overlay
        scrollView.usesPredominantAxisScrolling = false
        scrollView.wantsLayer = true
        scrollView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: showStatusBar ? kStatusBarHeight : 0, right: 0)
    }

    private func configureCollectionView(_ collectionView: NSCollectionView) {
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.wantsLayer = true
        collectionView.layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        #if DEBUG
        ViewSwitchProbe.record("grid.update \(activeViewID)")
        #endif
        guard let collectionView = scrollView.documentView as? GalleryCollectionView else { return }
        let coordinator = context.coordinator
        coordinator.dataCoordinator = dataCoordinator
        /// Must come before every updateSectionDividers() call in this pass, since the bands depend on it.
        coordinator.showSortingSections = showSectionDividers
        /// Passes the current view identity, so the Coordinator can detect real view switches.
        coordinator.currentViewID = activeViewID

        /// Calculates the StatusBar inset once.
        let bottomInset: CGFloat = showStatusBar ? kStatusBarHeight : 0
        
        coordinator.isStatusBarVisible = showStatusBar

        /// Updates the scroller insets so the scrollbar is not hidden behind the StatusBar.
        if scrollView.scrollerInsets.bottom != bottomInset {
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }

        /// Batches all layout changes into one invalidation, so multiple changes cause one layout pass.
        let previousKind = coordinator.subtitleProvider?.kind
        let hadProvider = previousKind != nil
        let hasProvider = subtitleProvider != nil
        /// Presence change: the layout needs this, to reserve a subtitle line's height.
        let providerChanged = hadProvider != hasProvider
        /// Kind change: the cells need this. A Recents sub-tab switch swaps one provider for another, so providerChanged is
        /// false, but each cell's text is now wrong. The kind is compared because closures have no identity.
        let subtitleKindChanged = previousKind != subtitleProvider?.kind
        coordinator.subtitleProvider = subtitleProvider

        let desiredMaxColumns = largeGalleryGrid ? Preferences.galleryMaxColumnsLargeGrid
                                                 : Preferences.galleryMaxColumns

        if let layout = collectionView.collectionViewLayout as? SmoothResizingGridLayout {
            var layoutNeedsInvalidation = false

            if layout.bottomInset != bottomInset {
                layout.bottomInset = bottomInset
                layoutNeedsInvalidation = true
            }
            if providerChanged {
                layout.hasSubtitles = hasProvider
                layoutNeedsInvalidation = true
            }
            if layout.maxColumns != desiredMaxColumns {
                layout.maxColumns = desiredMaxColumns
                layoutNeedsInvalidation = true
            }

            if layoutNeedsInvalidation {
                layout.invalidateLayout()
            }
        }

        /// First update: clears any stale selection from the previous view.
        if !coordinator.hasCompletedFirstUpdate {
            coordinator.hasCompletedFirstUpdate = true
            Self.log("First update - clearing NSCollectionView selection")
            coordinator.withSuppressedCallbacks { collectionView.selectionIndexPaths = [] }
        }

        /// Stale-pass guard. SwiftUI can run this when the films change alone, with the stored activeViewID still naming the
        /// old view. That happens in two cases:
        ///
        ///  • An outgoing instance that is about to be removed. It sees the destination's films, and reloading it would only
        ///    clamp its viewport and overwrite the origin just saved.
        ///  • An instance that stays, such as a sub-tab switch. A pass with the new activeViewID follows and does the reload.
        ///
        /// Until activeViewID matches the films, nothing is owed, so the pass is skipped.
        guard activeViewID == ViewStateManager.shared.activeView else { return }

        /// Style guard for a Film Queue tab switch between tabs of different styles. The outgoing gallery's pass could reload
        /// the incoming films in the outgoing style for a frame. A gallery whose style differs from the one GalleryView presents is
        /// about to be removed, so the pass is skipped. GalleryView uses the same check, so the two always agree.
        if case .filmQueue = activeViewID,
           ViewStateManager.shared.displayedGalleryState(
               loadedQueueFilter: dataCoordinator.loadedFilmQueueFilter).isListView {
            return
        }

        let newFilms = dataCoordinator.films

        // MARK: Launch Pre-Paint Warm Registration
        /// Runs once per session, so the O(N) map is skipped on later passes. It gives PosterCache the launch view's order before
        /// the first reloadData(). That warms the leading posters synchronously and sets the order as the restore's priority, so
        /// the first cells find their images already loaded. The background restore then fills in from the top. See
        /// PosterCache.registerLaunchDisplayOrder.
        if PosterCache.shared.needsLaunchWarm, !newFilms.isEmpty {
            PosterCache.shared.registerLaunchDisplayOrder(newFilms.map(\.posterUID))
        }
        if !newFilms.isEmpty { LaunchReveal.shared.galleryWillAppear(scrollView) }

        /// Exits early if both are empty.
        guard !newFilms.isEmpty || !coordinator.films.isEmpty else {
            coordinator.syncSelectionToView()
            return
        }

        /// A reload is needed when: 1. the view identity changed; 2. the count changed; 3. the first or last film changed; or
        /// 4. an interior reorder with stable endpoints (the ambiguous case below).

        /// Identity check, independent of the film heuristics. currentViewID is already set to activeViewID, and prevViewID
        /// advances only in the reload branch. A mismatch means the view changed since the last reload, even when the count and
        /// endpoints happen to match.
        let viewIdentityChanged = coordinator.isLikelyViewSwitch()

        /// The Film Queue's segment filter narrows the same view (currentViewID stays .filmQueue), so viewIdentityChanged misses
        /// a switch between "All" and one section. The same-view path would keep scroll position and leave the excluded sections
        /// on screen for one frame before the narrower layout commits.
        ///
        /// This compares against dataCoordinator.loadedFilmQueueFilter, the filter the films were produced with, and not the
        /// live FilmQueueFilterState.shared.selectedFilter. The live filter changes first, and a pass in that window would reload
        /// the stale union with the wrong dividers. Keying on the loaded filter fires once, on the pass that installs the new films.
        ///
        /// A nil last-seen value is not a change. A fresh mount is already covered by viewIdentityChanged, and reporting a change
        /// here would discard a scroll handoff. The value resets to nil when a non-Queue film set is shown, so returning to the Queue
        /// counts as a first observation.
        /// The key of what was on screen before this pass, captured before the filter is advanced. Only the outgoing-origin save uses it.
        let outgoingQueueFilter = coordinator.lastFilmQueueFilter
        let filmQueueFilterChanged: Bool
        if let loadedQueueFilter = dataCoordinator.loadedFilmQueueFilter {
            filmQueueFilterChanged = coordinator.lastFilmQueueFilter != nil &&
                                     coordinator.lastFilmQueueFilter != loadedQueueFilter
            coordinator.lastFilmQueueFilter = loadedQueueFilter
        } else {
            coordinator.lastFilmQueueFilter = nil
            filmQueueFilterChanged = false
        }

        let countChanged = coordinator.films.count != newFilms.count
        let firstOrLastChanged = (!coordinator.films.isEmpty && !newFilms.isEmpty) &&
                                 (coordinator.films.first?.id != newFilms.first?.id ||
                                  coordinator.films.last?.id != newFilms.last?.id)

        /// When the count and both endpoints match, the cheap heuristics above cannot tell
        /// whether the interior order changed — e.g. switching between two sort options that
        /// share the same first and last film (Date Added ⇄ Date Modified when the newest and
        /// oldest films coincide under both orderings). A sort change routes through
        /// loadFilms() (which reassigns dataCoordinator.films but emits no event), so without
        /// this check the reordered interior would never be
        /// drawn and the gallery would keep displaying the prior order.
        ///
        /// The O(N) ordered-ID scan is only reached in this ambiguous branch and is negligible
        /// next to the reloadData() it gates. On a genuine no-op re-render (identical order —
        /// e.g. a status-bar toggle) it returns false, preserving the existing skip-reload
        /// behavior. Identity comparison on FilmSnapshot value types only; no managed-object access.
        ///
        /// `==` first: Array equality is O(1) when the buffers are identical, which is every
        /// pass where dataCoordinator.films was not reassigned (selection, status-bar toggle,
        /// dividers setting), so the O(N) ID walk is only reached after a real reload.
        ///
        /// A film edit or a smart-list recalculation is held to the same test rather than
        /// reloading unconditionally: when the ID sequence survived, the edit changed only
        /// what the tiles show, and the in-place branch below reconfigures
        /// them without the reloadData() that rebuilt every visible tile and reset the scroll.
        let structuralChange = viewIdentityChanged || countChanged || firstOrLastChanged ||
                               filmQueueFilterChanged
        let interiorReordered =
            !structuralChange && !newFilms.isEmpty && coordinator.films != newFilms &&
            !coordinator.films.elementsEqual(newFilms) { $0.id == $1.id }

        let needsReload = structuralChange || interiorReordered

        /// The request is acted on by whichever branch below runs on this pass, and only on
        /// this pass — see `scrollRequest`.
        let scrollToFilmID: UUID?
        if let scrollRequest, scrollRequest != coordinator.lastScrollRequest {
            scrollToFilmID = scrollRequest.filmID
        } else {
            scrollToFilmID = nil
        }
        coordinator.lastScrollRequest = scrollRequest

        if needsReload {
            /// isViewSwitch reuses the identity signal computed above, OR'd with the
            /// Film-Queue-filter signal — prevViewID has not been advanced since, so the
            /// comparison still reflects the transition. Treating a Film Queue filter change
            /// A film queue filter change counts as a view switch here, so it gets the same scroll-to-zero before reload (see
            /// filmQueueFilterChanged).
            let isViewSwitch = viewIdentityChanged || filmQueueFilterChanged

            /// Records the outgoing view's scroll position before the scroll-to-zero and reloadData(). dismantleNSView covers only
            /// teardown. Sub-tabs and smart-list variants keep the same GalleryView identity, so the same GallerySubview is reused
            /// and only activeViewID changes. Their outgoing position would otherwise never be saved.
            ///
            /// The save is unconditional, including y == 0. Leaving an old deeper entry in place would reopen a view at the wrong depth.
            ///
            /// The save depends on viewIdentityChanged and a non-nil prevViewID. A Film Queue filter change keeps currentViewID at
            /// .filmQueue, so saving there would file one section's position under a shared key. A first pass has no previous view,
            /// so its synthetic zero must not be filed against anything.
            if viewIdentityChanged, let outgoingViewID = coordinator.prevViewID {
                ViewStateManager.shared.saveScrollPosition(
                    coordinator.scrollPosition(of: scrollView),
                    under: GalleryScrollKey(viewID: outgoingViewID, subTab: outgoingQueueFilter?.rawValue))
            }

            /// A same-view reload that empties the grid takes the gallery off screen. A placeholder replaces it, and the next film
            /// mounts a fresh gallery that restores this banked origin. Bank the current position now, while this pass knows its key.
            /// dismantleNSView cannot record y == 0, and a scroll to the top posts no live-scroll end, so the remount would restore a
            /// deeper position.
            if !isViewSwitch && newFilms.isEmpty {
                ViewStateManager.shared.saveScrollPosition(coordinator.scrollPosition(of: scrollView),
                                                           under: coordinator.displayedScrollKey)
            }

            /// Advances prevViewID now that the transition is consumed.
            coordinator.prevViewID = coordinator.currentViewID

            /// For view switches, zero the scroll position before reloading to prevent flicker. For same-view reloads (e.g. film
            /// edits), capture the origin to restore after reloadData(). reloadData() resets the scroll to zero, which would otherwise
            /// move the user to the top on every save.
            let savedScrollOrigin: CGPoint?

            /// The scroll intent is not consumed here. Each destination has its own stable .id, so a search exit always mounts a
            /// fresh GallerySubview, and makeNSView is the only place that consumes the intent. Consuming it here would be harmful. The
            /// search instance still re-renders during the exit, with the destination's activeViewID already set, so it would consume
            /// the intent and arm a scroll on a view about to be dismantled. The real destination would then find nothing.

            if isViewSwitch {
                /// Discards any origin restore armed by an earlier pass that this transition supersedes. Otherwise a rapid sub-tab
                /// switch could leave B's origin armed and resolve it against C's content. The restore below re-arms it for the incoming view.
                coordinator.scrollView?.pendingScrollPosition = nil
                appViewportMove {
                    scrollView.contentView.scroll(to: .zero)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
                savedScrollOrigin = nil
            } else {
                savedScrollOrigin = scrollView.documentVisibleRect.origin
            }

            coordinator.films = newFilms
            /// Recomputes the section-divider breaks from the new films and pushes them to the layout before reloadData(), so the
            /// relayout sees current breaks. Where no bands apply, this does nothing.
            coordinator.updateSectionDividers()
            #if DEBUG
            ViewSwitchProbe.record("grid.reload \(coordinator.currentViewID) films=\(newFilms.count)")
            #endif
            coordinator.withSuppressedCallbacks {
                collectionView.selectionIndexPaths = []
                collectionView.reloadData()
            }
            if !newFilms.isEmpty { LaunchTimeline.mark("galleryReloadReturned") }
            coordinator.dividerBandsNeedRefresh = true

            /// Decides how to handle scroll position after the reload, in this order:
            ///   0. A reuse-path film handoff, which is a "Show in List" redirect to a sub-variant.
            ///   1. scrollToFilmID, for an intentional post-edit reposition.
            ///   2. The saved origin, for a view-switch restore (maintainScrollPositionOnViewSwitch).
            ///   3. The same-view origin, to restore the viewport for in-place edits.
            ///
            /// The search-exit scroll is handled in makeNSView.
            if let handoffFilmID = GalleryScrollIntent.shared.consumeOnReuse(ifTargeting: coordinator.currentViewID) {
                /// Priority 0: a reuse-path film handoff. It can only be a ShowInListNavigation redirect to a sub-variant of the parent
                /// already on screen (see GalleryScrollIntent.consumableOnReuse). It outranks the origin restores, so the intent is
                /// retired and the armed origin discarded before the target is placed.
                ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)
                coordinator.scrollView?.pendingScrollPosition = nil
                coordinator.scrollView?.pendingScrollFilmID = handoffFilmID
                /// Forces a layout against the films just installed, so the target resolves in this pass, before the first painted frame.
                /// If layout is still not ready, the target stays armed and viewWillDraw retries.
                collectionView.layoutSubtreeIfNeeded()
                coordinator.scrollView?.applyPendingFilmTargetIfPossible()
                Self.log("Scroll handoff armed on reuse path for film \(handoffFilmID) (view: \(coordinator.currentViewID))")

            } else if let filmID = scrollToFilmID,
               let index = coordinator.filmIndexMap[filmID] {

                Self.log("Checking scroll for film \(filmID): newIndex=\(index)")

                /// An explicit post-edit reposition outranks a saved-origin restore. Retires any intent for this view, so a later pass
                /// cannot undo the placement below.
                ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)

                /// Step 1: restores the pre-reload origin, or leaves it at zero for view switches with no saved origin. This undoes the
                /// scroll-to-zero that reloadData() applies.
                if let origin = savedScrollOrigin {
                    appViewportMove {
                        scrollView.contentView.setBoundsOrigin(origin)
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                    }
                }

                /// Step 2: if the film is visible in the restored viewport, nothing else is needed. If it moved out of view after a
                /// sort change, it is scrolled to the top row so it stays in focus.
                let indexPath = IndexPath(item: index, section: 0)
                if !coordinator.isFilmVisible(at: indexPath) {
                    coordinator.scrollToTopRow(at: indexPath)
                    Self.log("Film not visible after origin restore — scrolled to index \(index)")
                } else {
                    Self.log("Film visible at index \(index) — origin restored, no additional scroll")
                }

            } else if coordinator.scrollView?.pendingScrollFilmID == nil,
                      let restoredPosition = ViewStateManager.shared
                          .pendingScrollOriginRestore(for: coordinator.displayedScrollKey) {
                /// Priority 2: restores this view's saved scroll origin (maintainScrollPositionOnViewSwitch).
                ///
                /// This branch does not test isViewSwitch. That flag is true only on the pass that consumes the prevViewID transition. On a
                /// sub-tab switch the Coordinator is reused, and the pass that reloads with the destination's films may be a different
                /// pass. The restore would then be armed with nothing to restore against.
                ///
                /// The addressed intent avoids this. ViewStateManager arms it once at the switch, and it stays live until a gallery
                /// showing that exact view applies it. This branch therefore fires on whichever pass does the reload, and is inert on others.
                /// The preference is checked at arming time, so nothing is armed while it is off.
                ///
                /// The origin is armed on the scroll view and then applied by an explicit call below. viewWillDraw alone is not enough, since
                /// a reused gallery's scroll view is not dirtied by a sub-tab reload. viewWillDraw remains the retry for a fresh mount.
                /// Either way the origin lands before the first painted frame.
                ///
                /// The pendingScrollFilmID == nil condition lets a film handoff from makeNSView take precedence over the origin restore.
                coordinator.scrollView?.pendingScrollPosition = restoredPosition
                Self.log("Scroll-origin restore armed for \(coordinator.currentViewID): \(restoredPosition.origin)")
                /// Forces a layout against the films just installed, then applies the origin now. Waiting for viewWillDraw would not
                /// work on a reused gallery (see applyPendingOriginRestoreIfPossible). The first painted frame is then at the restored offset.
                collectionView.layoutSubtreeIfNeeded()
                coordinator.scrollView?.applyPendingOriginRestoreIfPossible()
            } else {
                /// No scroll-to-film was requested (add/delete path, or filmID not in map).
                /// Restore the pre-reload scroll origin to prevent an unintended jump to the top.
                /// On a view switch this is a no-op because savedScrollOrigin is nil.
                if scrollToFilmID != nil {
                    Self.log("scrollToFilmID set but film not found in filmIndexMap - restoring scroll origin")
                }
                if let origin = savedScrollOrigin {
                    appViewportMove {
                        scrollView.contentView.setBoundsOrigin(origin)
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                    }
                }
            }
        } else {
            /// Same films in the same order, possibly with new content (an edited film's
            /// poster, or a Recents date). Install them and reconfigure the cells that exist:
            /// GalleryItem.configure diffs the film, poster, and subtitle, so only a tile
            /// whose display actually changed is rebuilt. Cells created later read the
            /// installed films through the data source.
            if coordinator.films != newFilms {
                let oldFilms = coordinator.films
                coordinator.films = newFilms
                var touched = Set<Int>()
                for case let item as GalleryItem in collectionView.visibleItems() {
                    guard let indexPath = collectionView.indexPath(for: item),
                          let film = coordinator.film(at: indexPath) else { continue }
                    item.configure(with: film, subtitleProvider: subtitleProvider)
                    touched.insert(indexPath.item)
                }
                /// Prepared cells just outside the viewport are kept by NSCollectionView and
                /// are not re-requested when they scroll in, so any of them showing a film
                /// that changed is reconfigured too.
                for index in newFilms.indices where !touched.contains(index) && oldFilms[index] != newFilms[index] {
                    let indexPath = IndexPath(item: index, section: 0)
                    if let item = collectionView.item(at: indexPath) as? GalleryItem {
                        item.configure(with: newFilms[index], subtitleProvider: subtitleProvider)
                    }
                }
                #if DEBUG
                ViewSwitchProbe.record("grid.inPlace \(coordinator.currentViewID) films=\(newFilms.count)")
                #endif
            }

            /// A reuse-path film handoff is claimed here too, not only by the reload branch.
            /// A Film Queue section move that leaves the film at the same index (the last Up
            /// Next film moved to the head of Soon, say) changes no film order, so no reload
            /// runs. The intent must not stay pending, or the next reload (a later tab switch)
            /// would claim it and throw away that tab's restore.
            if let handoffFilmID = GalleryScrollIntent.shared.consumeOnReuse(ifTargeting: coordinator.currentViewID) {
                ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)
                coordinator.scrollView?.pendingScrollPosition = nil
                coordinator.scrollView?.pendingScrollFilmID = handoffFilmID
                coordinator.scrollView?.applyPendingFilmTargetIfPossible()
                Self.log("Scroll handoff applied in place for film \(handoffFilmID) (view: \(coordinator.currentViewID))")
            }

            /// The post-edit reposition, minus the origin restore the reload branch needs:
            /// nothing reloaded, so the viewport is still where the user left it. A film
            /// still on screen is left alone; one that is not is brought to the top row.
            if let filmID = scrollToFilmID, let index = coordinator.filmIndexMap[filmID] {
                ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)
                let indexPath = IndexPath(item: index, section: 0)
                if !coordinator.isFilmVisible(at: indexPath) {
                    coordinator.scrollToTopRow(at: indexPath)
                    Self.log("Film not visible after in-place update — scrolled to index \(index)")
                }
            }

            /// No reload was judged necessary by the heuristics above, but the section-divider
            /// breaks must still be reconciled against the CURRENT view, filter, and sort state
            /// on every pass — not just when a reload happens to fire. This is also the only
            /// path by which a change to this view's section-dividers setting reaches the
            /// grid: ViewStateManager.updateShowSectionDividers deliberately passes
            /// `reload: false`, because the setting changes nothing about the film set
            /// itself, so no reload will fire for it and this pass is the whole mechanism. Without
            /// this, a transient render pass with stale data (e.g. the brief window between a
            /// fresh GalleryView's first body evaluation and its onAppear-triggered view-switch
            /// Recomputes the breaks for the new view. Stale breaks would otherwise persist if a later reload did not detect the change.
            /// The call invalidates the layout only when the breaks differ. It does nothing where no bands apply.
            coordinator.updateSectionDividers()

            /// The subtitle KIND changed but the film heuristics found no reason to reload. Every configured cell still shows text from
            /// the previous provider. That happens when two views share a film set the heuristics cannot tell apart, such as two Recents
            /// categories with the same films in the same order.
            ///
            /// Reconfiguring is deliberate. The films, order, scroll, and selection stay the same, and reloadData() would reset them.
            /// GalleryItem.configure compares the resolved text, so unchanged cells do no work. visibleItems() limits the cost to cells
            /// on screen. Cells scrolled in later take the current provider through the normal path.
            if subtitleKindChanged {
                for case let item as GalleryItem in collectionView.visibleItems() {
                    guard let indexPath = collectionView.indexPath(for: item),
                          let film = coordinator.film(at: indexPath) else { continue }
                    item.configure(with: film, subtitleProvider: subtitleProvider)
                }
                Self.log("Subtitle kind changed without reload — reconfigured \(collectionView.visibleItems().count) visible cells")
            }
        }

        coordinator.syncSelectionToView()

        /// Re-primes the look-ahead band after a data change while the startup population is still running. It is a no-op once
        /// that finishes, and it only reads state and dispatches background work.
        coordinator.prefetchAroundVisibleRectIfPopulating()

        /// Final reconciliation of the divider bands' text against the layout this pass produced. It runs last, when the collection
        /// view holds the current films and breaks. See refreshVisibleSectionDividers.
        coordinator.refreshVisibleSectionDividers()
    }

    /// Explicit teardown. It cancels the Coordinator's subscriptions when the representable is removed. It also saves the scroll
    /// origin for maintainScrollPositionOnViewSwitch, because this is the last point the old scroll view is still valid.
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        /// Backstop save, used only when neither the end of a user scroll nor updateNSView's outgoing-view save has run.
        ///
        /// The y > 0 condition is deliberate. This call site cannot verify its key. During navigation the outgoing gallery may
        /// receive one final render carrying the destination's activeViewID. That render also zeroes the scroll, so an unconditional
        /// save would overwrite the destination's real origin. A scroll back to the top is covered by the other two saves.
        let position = coordinator.scrollPosition(of: nsView)
        if position.origin.y > 0 {
            ViewStateManager.shared.saveScrollPosition(position, under: coordinator.displayedScrollKey)
            Self.log("Saved scroll origin \(position.origin) for \(coordinator.currentViewID)")
        }
        /// Clears the registry only if this coordinator is still the registered provider. The grid-list toggle can mount the
        /// opposite style first, and its registration must not be cleared.
        ViewStateManager.shared.unregisterScrollPositionProvider(coordinator)
        coordinator.cancelSubscriptions()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selectionState: selectionState)
    }

    // MARK: - Coordinator
    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate, NSCollectionViewDataSource,
                              GalleryScrollPositionProviding, Loggable {
        nonisolated static let logTag = "[GallerySubview]"

        weak var collectionView: NSCollectionView?
        weak var scrollView: WidthObservingScrollView?
        weak var dataCoordinator: DataCoordinator?
        /// Mirror of the active view's ViewState.showSectionDividers, pushed by makeNSView and updateNSView. It gates the sort-derived
        /// bands in updateSectionDividers. The Film Queue's own bands ignore it.
        var showSortingSections: Bool = false
        /// The active subtitle provider, pushed by makeNSView and updateNSView, and passed to each cell in itemForRepresentedObjectAt.
        /// Cells are pure AppKit and have no SwiftUI environment. updateNSView also checks for nil to detect when the layout must
        /// reserve or release the subtitle row.
        var subtitleProvider: GallerySubtitleProvider?

        /// Tracks StatusBar visibility for layout.
        var isStatusBarVisible: Bool = false

        /// The current and previous view identifiers, for detecting view switches. updateNSView updates them on every pass.
        /// prevViewID is nil until the Coordinator has rendered a view. A non-optional default would compare equal on a fresh mount
        /// whose activeViewID matched it. Then the switch branch, including the origin restore, would be skipped. nil compares
        /// unequal to every case, so the first pass always counts as a transition. The nil value also means the outgoing-origin save
        /// is skipped on a first pass, so the synthetic zero is not filed under an unrelated view.
        var currentViewID: ViewIdentifier = .allFilms
        fileprivate var prevViewID: ViewIdentifier?

        /// The Film Queue segment filter (All, Up Next, Soon, Later) that the displayed films were built from. It is nil when no
        /// Queue films are shown. currentViewID never changes for a filter switch, so isLikelyViewSwitch cannot detect it. updateNSView
        /// compares this with dataCoordinator.loadedFilmQueueFilter on each pass and treats a mismatch as a view switch. See the use
        /// site for why the loaded filter is compared and not the live one.
        fileprivate var lastFilmQueueFilter: FilmQueueFilter?

        /// The property observer rebuilds the index map. Films are FilmSnapshot value types, so no model objects are referenced.
        var films: [FilmSnapshot] = [] { didSet { rebuildFilmIndexMap() } }
        let selectionState: SelectionState

        var hasCompletedFirstUpdate = false
        /// The last scroll request this Coordinator has seen, whether or not it acted on it.
        fileprivate var lastScrollRequest: FilmScrollRequest?
        private var isSuppressingCallbacks = false
        private var isUpdatingSelection = false
        /// Prevents races during rapid arrow-key navigation.
        private var hasScheduledSelectionReset = false
        /// Set by syncSelectionToView() when a non-empty selection is cleared because every selected film left the view, such as
        /// a film removed from the list while its FilmSheet was open. seedInitialCursor() uses it to tell that clear from a
        /// selection that never existed. Without it, the focus return after closing the FilmSheet would reseed item 0.
        private var selectionClearedByPrune = false
        private var anchorIndexPath: IndexPath?
        /// Tracks the moving end of the selection during shift+arrow navigation. anchorIndexPath is the fixed end. Set<IndexPath>
        /// has no reliable first element, so the moving end is stored here.
        private var cursorIndexPath: IndexPath?
        private var cancellables = Set<AnyCancellable>()
        /// Task handle for the observation loop that watches selectionState.selectedFilmIDs. cancelSubscriptions() cancels it.
        private var observationTask: Task<Void, Never>?

        /// Cached index map for fast selection lookups. It is rebuilt whenever the films change.
        fileprivate var filmIndexMap: [UUID: Int] = [:]

        init(selectionState: SelectionState) {
            self.selectionState = selectionState
            super.init()
            setupSubscriptions()
        }

        /// Cancels all Combine subscriptions and the observation task. dismantleNSView calls it.
        func cancelSubscriptions() {
            /// removeAll() cancels each subscription through AnyCancellable.deinit, so no explicit loop is needed.
            cancellables.removeAll()
            /// Cancels the observation task for SelectionState.
            observationTask?.cancel()
            observationTask = nil
            /// Removes the warming scroll-prefetch observer if it is still installed. It normally removes itself after the first
            /// tick once the startup population finishes (see handleWarmingScrollPrefetchTick).
            removeWarmingScrollPrefetch()
            #if DEBUG
            removeViewportJumpTracer()
            #endif
            /// Remove the live-scroll origin recorder installed by makeNSView.
            removeScrollOriginRecorder()
        }

        /// Starts a recursive withObservationTracking loop on selectionState.selectedFilmIDs.
        /// Each iteration registers a one-shot observation: when selectedFilmIDs changes,
        /// the onChange handler fires on MainActor, syncs the collection view, then calls
        /// observeSelectionState() again to re-register for the next change. The task is
        /// canceled in cancelSubscriptions() when the NSViewRepresentable is dismantled.
        private func observeSelectionState() {
            /// .userInitiated priority matches the QoS at which AppKit delivers mouse and
            /// keyboard events (user-interactive). Without an explicit priority the Task
            /// defaults to .default, which is lower than user-interactive. When
            /// super.mouseDown enters its event-tracking run loop and that loop services
            /// the continuation resume triggered by a selection change, the runtime detects
            /// that a user-interactive thread is waiting on a default-QoS Task and warns:
            /// "[Internal] Thread running at User-interactive quality-of-service class
            /// waiting on a lower QoS thread running at Default quality-of-service class."
            /// Elevating to .userInitiated eliminates the inversion. .userInitiated is the
            /// correct Swift 6–compatible spelling: Swift concurrency has no .userInteractive
            /// priority; .userInitiated maps to DISPATCH_QUEUE_PRIORITY_HIGH at the GCD layer,
            /// which is equivalent to the user-interactive tier for tasks of this kind.
            observationTask = Task(priority: .userInitiated) { @MainActor [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    /// withObservationTracking registers a one-shot observation on the
                    /// properties accessed inside the apply closure. When any of those
                    /// properties change, onChange is called once, then tracking stops.
                    /// We loop to re-register after each delivery.
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        withObservationTracking {
                            /// Access the property to register this loop iteration as an observer.
                            _ = self.selectionState.selectedFilmIDs
                        } onChange: {
                            continuation.resume()
                        }
                    }
                    /// Cancellation cannot interrupt the wait above — only the next change
                    /// resumes it — so a dismantled gallery's loop wakes here once more. It
                    /// must stop without acting: its films are the outgoing view's, and a sync
                    /// would prune a selection made in the view that replaced it.
                    guard !Task.isCancelled else { break }
                    /// onChange fired — selectedFilmIDs changed. Sync the collection view
                    /// unless we are mid-update (which means this change was self-initiated).
                    guard !self.isUpdatingSelection else { continue }
                    self.syncSelectionToView()
                }
            }
        }

        // MARK: - Subscriptions
        private func setupSubscriptions() {
            /// Sync external selection changes to the collection view.
            ///
            /// SelectionState is @Observable and exposes no @Published
            /// projected-value publisher ($selectedFilmIDs). The correct replacement for
            /// imperative observation of @Observable properties outside a SwiftUI view body
            /// is withObservationTracking(_:onChange:). The pattern below schedules a
            /// recursive @MainActor task: each iteration reads the property (registering
            /// a one-shot observation), then re-schedules itself inside the onChange
            /// handler. This delivers exactly one callback per change — the same contract
            /// as the former Combine sink — and the task handle on `observationTask` lets
            /// dismantleNSView cancel it cleanly.
            observeSelectionState()

            /// Handle select all and clear focus rings
            /// selectAllFilms must be handled here for menu bar Select All to work
            /// The onSelectAll callback only fires for Cmd+A typed directly in the collection view
            ///
            /// Switched over exhaustively, with no `default` clause: SelectionEvent has
            /// exactly these two cases, so a `default` was unreachable (and warned as
            /// such). Leaving it off is also the safer shape — a third event added later
            /// becomes a compile error here rather than a silently ignored no-op.
            AppEventBus.shared.selectionEvents
                .receive(on: RunLoop.main)
                .sink { [weak self] event in
                    guard let self else { return }
                    switch event {
                    case .selectAllFilms: self.selectAll()
                    case .clearFocusRings:
                        self.collectionView?.selectionIndexPaths = []
                        self.cursorIndexPath = nil
                        self.anchorIndexPath = nil
                    }
                }
                .store(in: &cancellables)

            /// Cmd+L scrolls so the topmost selected film sits in the top visible row. With several selected, the one with the
            /// smallest indexPath is used, which is the leftmost item in the first row.
            AppEventBus.shared.uiCommands
                .receive(on: RunLoop.main)
                .sink { [weak self] command in
                    guard let self, command == .scrollToSelection else { return }
                    guard let collectionView = self.collectionView else { return }
                    let selected = collectionView.selectionIndexPaths
                    guard let indexPath = selected.min() else { return }
                    /// Goes through the stopper, so a trackpad coast in flight ends at the jump. See CoastingScrollStopper.
                    self.coastStopper.jump { [weak self] stoppedCoast in
                        guard let self else { return }
                        self.scrollToTopRow(at: indexPath)
                        /// The stop's didEndLiveScroll banks the pre-jump position.
                        if stoppedCoast { self.claimViewportForUser() }
                    }
                }
                .store(in: &cancellables)

            /// No filmEvents subscription is needed. Each film change reaches this view as a change of dataCoordinator.films. updateNSView
            /// answers it with a reloadData() or an in-place reconfigure, so a separate refresh would duplicate the work.
        }

        // MARK: - Scroll-Origin Persistence

        /// Records this view's scroll origin each time a user-driven scroll gesture ends, so ViewStateManager's store reflects the
        /// user's last position.
        ///
        /// The other two save points run on transitions. This one depends only on user scrolling, since didEndLiveScroll never fires
        /// for programmatic moves like the zero-before-reload step, the origin restore, or scrollToTopRow. A doomed instance
        /// therefore cannot emit it and attribute a synthetic zero to the destination.
        ///
        /// It uses the target/selector API instead of a Combine sink. A sink would add a run-loop hop, and a view change in between
        /// could file the origin under the wrong view.
        ///
        /// Called once per Coordinator, from makeNSView. Overscroll can leave a slightly negative y. The restore clamps it, so no guard is needed.
        func installScrollOriginRecorder(on scrollView: NSScrollView) {
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleLiveScrollEnded(_:)),
                name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            coastStopper.install(on: scrollView)
        }

        /// Lets Cmd+L stop a trackpad coast in flight. It is installed and removed with the scroll-origin recorder.
        private let coastStopper = CoastingScrollStopper()

        /// Removes the live-scroll observer. It is idempotent, and it removes the observation for any scroll view. Called from
        /// cancelSubscriptions().
        private func removeScrollOriginRecorder() {
            NotificationCenter.default.removeObserver(
                self, name: NSScrollView.didEndLiveScrollNotification, object: nil)
            coastStopper.remove()
        }

        @objc private func handleLiveScrollEnded(_ notification: Notification) {
            guard let scrollView else { return }
            /// The user has taken over the viewport. Any pending restore is retired before the save, since bankScrollOrigin refuses to
            /// overwrite a key with an outstanding restore. Retiring it later would discard the position the user just reached. It is
            /// addressed, so it cannot cancel another view's intent.
            ViewStateManager.shared.finishScrollOriginRestore(for: displayedScrollKey)
            ViewStateManager.shared.saveScrollPosition(scrollPosition(of: scrollView),
                                                       under: displayedScrollKey)
        }

        /// The scroll-bank key for the films this gallery shows. For the Film Queue, the sub-tab comes from the filter the films were
        /// loaded with, not the live filter. The live one changes two turns before the films arrive.
        var displayedScrollKey: GalleryScrollKey {
            GalleryScrollKey(viewID: currentViewID, subTab: lastFilmQueueFilter?.rawValue)
        }

        /// See GalleryScrollPositionProviding.currentScrollState(). prevViewID is nil until the first update pass, and that nil is reported
        /// as nil, not as a real identity.
        func currentScrollState() -> (key: GalleryScrollKey, position: GalleryScrollPosition)? {
            guard prevViewID != nil, let scrollView else { return nil }
            return (displayedScrollKey, scrollPosition(of: scrollView))
        }

        /// The scroll position of `scrollView`, anchored on the topmost visible film. See GalleryScrollPosition.
        func scrollPosition(of scrollView: NSScrollView) -> GalleryScrollPosition {
            let origin = scrollView.documentVisibleRect.origin
            guard origin.y > 0,
                  let index = topmostVisibleItemIndex(),
                  let layout = collectionView?.collectionViewLayout as? SmoothResizingGridLayout,
                  let frame = layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame,
                  frame.height > 0 else {
                return GalleryScrollPosition(origin: origin)
            }
            return GalleryScrollPosition(origin: origin, anchor: .init(
                filmID: films[index].id, index: index, filmCount: films.count,
                fraction: (origin.y - frame.minY) / frame.height))
        }

        /// The content y that a banked position resolves to in the current films and geometry. See GalleryScrollPosition.restoreY.
        func restoreY(for position: GalleryScrollPosition) -> CGFloat {
            let layout = collectionView?.collectionViewLayout as? SmoothResizingGridLayout
            return position.restoreY(
                filmCount: films.count,
                indexOf: { filmIndexMap[$0] },
                frameOfFilm: { layout?.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame })
        }

        // MARK: - Helper Methods
        /// Runs a block with selection callbacks suppressed. A defer resets the flag even if the block throws.
        func withSuppressedCallbacks(_ block: () -> Void) {
            isSuppressingCallbacks = true
            defer { isSuppressingCallbacks = false }
            block()
        }

        /// Detects whether the new films belong to a different view than the last reload. It uses the prevViewID-to-currentViewID
        /// transition from updateNSView, not content sampling, so a large sort change does not reset the scroll. A nil prevViewID
        /// counts as a transition.
        func isLikelyViewSwitch() -> Bool {
            return prevViewID != currentViewID
        }

        /// Returns the film snapshot at an index path, or nil if out of bounds. It is fileprivate, so updateNSView can resolve a visible
        /// cell's film through the same checked accessor the data source uses.
        fileprivate func film(at indexPath: IndexPath) -> FilmSnapshot? {
            guard indexPath.item < films.count else { return nil }
            return films[indexPath.item]
        }

        /// Returns film ID at index path
        func filmID(at indexPath: IndexPath) -> UUID? {
            film(at: indexPath)?.id
        }

        /// Rebuilds the film index map for fast selection lookups. It runs on every films change and uses a lazy sequence,
        /// avoiding an intermediate array.
        ///
        /// It uses uniquingKeysWith (last wins) instead of Dictionary(uniqueKeysWithValues:), which traps on a duplicate key.
        /// A repeated film ID then maps to its last index, and the app does not crash. For unique IDs the result is the same.
        fileprivate func rebuildFilmIndexMap() {
            filmIndexMap = Dictionary(
                films.enumerated().lazy.map { ($1.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
        }

        /// Returns the poster for a film ID, for the flyback drag preview. It runs on the main thread during drag detection,
        /// so it reads only from the cache and never from disk. See PosterCache.dragPreviewImage.
        ///
        /// The lookup is O(1) through filmIndexMap. An index from that map is always in range, since the map is rebuilt whenever films
        /// changes, and the Coordinator is main-actor isolated.
        func posterImage(for filmID: UUID) -> NSImage? {
            guard let index = filmIndexMap[filmID] else { return nil }
            let film = films[index]
            return PosterCache.shared.dragPreviewImage(for: film.posterUID)
        }

        // MARK: - Warming-Scoped Scroll Prefetch
        ///
        /// Scroll prefetch runs only during the launch population window. An always-on prefetch caused a steady micro-stutter
        /// once images were in memory, but removing it made scrolling during the window worse. So the prefetch is limited to
        /// that window:
        ///
        ///  • NSCollectionView has no scroll callback, so the observer uses NSView.boundsDidChangeNotification on the scroll
        ///    view's NSClipView. GalleryCollectionView already observes that clip view, and the two coexist.
        ///  • While PosterCache.isPopulating is true, each bounds change, throttled to 180 ms, warms the band one viewport
        ///    ahead and 25% behind, in a background prefetchPosters load. A fast fling then finds its posters already loaded.
        ///  • The first tick after isPopulating goes false removes the observer, so there is no cost for the rest of the session.

        /// Keys with a prefetch load in flight. This prevents duplicate background loads across ticks for the same band.
        private var inFlightPrefetchUIDs: Set<String> = []
        /// The clip view the observer is registered on. It is held weakly, for removal.
        private weak var prefetchClipView: NSClipView?
        private var isWarmingPrefetchObserverInstalled = false
        private var lastWarmingPrefetchTick: ContinuousClock.Instant?
        /// The throttle interval: frequent enough to stay ahead of a fling, and light enough to avoid main-thread cost.
        private static let warmingPrefetchThrottleInterval: Duration = .milliseconds(180)

        /// Installs the warming bounds-change observer. It is called once from makeNSView. It does nothing if the startup
        /// population has already finished, so later grids register no observer.
        func installWarmingScrollPrefetch(on scrollView: NSScrollView) {
            guard PosterCache.shared.isPopulating,
                  !isWarmingPrefetchObserverInstalled else { return }
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            prefetchClipView = clip
            /// Uses selector-based observation, as GalleryCollectionView does. The notification posts synchronously on the main thread.
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleWarmingScrollPrefetchTick(_:)),
                name: NSView.boundsDidChangeNotification, object: clip)
            isWarmingPrefetchObserverInstalled = true
        }

        #if DEBUG
        // MARK: Viewport-Jump Tracer (DEBUG only)
        ///
        /// Reports viewport moves the app did not request. Programmatic scrolls in this file go through appViewportMove, which the
        /// tracer skips, as it skips live scrolls. Any jump it still reports came from elsewhere, and its call stack names the caller.
        /// It logs a bounds change whose vertical delta exceeds three viewport heights. It is compiled out of release builds.
        private let viewportJumpTracer = ViewportJumpTracer(owner: "grid")

        func installViewportJumpTracer(on scrollView: NSScrollView) {
            viewportJumpTracer.install(on: scrollView) { [weak self] in
                self.map { "\($0.currentViewID)" } ?? "?"
            }
        }

        private func removeViewportJumpTracer() {
            viewportJumpTracer.remove()
        }
        #endif

        /// Removes the observer and clears all prefetch bookkeeping. It is idempotent. It is called when population completes and
        /// from cancelSubscriptions.
        private func removeWarmingScrollPrefetch() {
            guard isWarmingPrefetchObserverInstalled else { return }
            if let clip = prefetchClipView {
                NotificationCenter.default.removeObserver(
                    self, name: NSView.boundsDidChangeNotification, object: clip)
            }
            isWarmingPrefetchObserverInstalled = false
            prefetchClipView = nil
            lastWarmingPrefetchTick = nil
            inFlightPrefetchUIDs.removeAll()
        }

        /// Throttled tick handler. It checks isPopulating first, and runs the full prefetch at most once per throttle interval.
        @objc private func handleWarmingScrollPrefetchTick(_ notification: Notification) {
            guard PosterCache.shared.isPopulating else {
                removeWarmingScrollPrefetch()
                return
            }
            let now = ContinuousClock.now
            if let last = lastWarmingPrefetchTick,
               now - last < Self.warmingPrefetchThrottleInterval { return }
            lastWarmingPrefetchTick = now
            prefetchAroundVisibleRect()
        }

        /// Population-gated wrapper for the updateNSView call site. It does nothing once the startup pipeline has finished.
        func prefetchAroundVisibleRectIfPopulating() {
            guard PosterCache.shared.isPopulating else { return }
            prefetchAroundVisibleRect()
        }

        /// Warms posters for the rows just beyond the visible rect in both directions. A tile is then decoded before it scrolls
        /// into view, so the synchronous disk fallback in GalleryItem.refreshTileContent does not run mid-scroll. It runs on the
        /// main actor, and all disk work goes to a detached background task.
        private func prefetchAroundVisibleRect() {
            guard let collectionView, let scrollView,
                  let layout = collectionView.collectionViewLayout as? SmoothResizingGridLayout,
                  !films.isEmpty
            else { return }

            let visible = scrollView.documentVisibleRect
            guard visible.height > 0 else { return }

            /// One viewport ahead, plus a 25% trailing margin for reversals.
            let lookahead = visible.height
            let trailing = visible.height * 0.25
            let expanded = NSRect(
                x: visible.minX,
                y: max(0, visible.minY - trailing),
                width: visible.width,
                height: visible.height + lookahead + trailing)

            let attributesInRange = layout.layoutAttributesForElements(in: expanded)
            guard !attributesInRange.isEmpty else { return }

            var uidsToLoad: [String] = []
            uidsToLoad.reserveCapacity(attributesInRange.count)
            var seenUIDs = Set<String>()
            for attrs in attributesInRange {
                /// Excludes section-divider decoration attributes. Their IndexPaths share the item namespace.
                /// See the matching filter in GalleryCollectionView.updateLiveSelection().
                guard attrs.representedElementCategory == .item,
                      let indexPath = attrs.indexPath,
                      indexPath.item >= 0, indexPath.item < films.count
                else { continue }
                let posterUID = films[indexPath.item].posterUID
                guard !posterUID.isEmpty,
                      seenUIDs.insert(posterUID).inserted,
                      PosterCache.shared.getImageSync(for: posterUID) == nil,
                      !inFlightPrefetchUIDs.contains(posterUID)
                else { continue }
                uidsToLoad.append(posterUID)
            }
            guard !uidsToLoad.isEmpty else { return }

            inFlightPrefetchUIDs.formUnion(uidsToLoad)

            /// One weak self capture, with one await back onto the main actor through a dedicated method. A second captured self in a
            /// nested MainActor closure would be flagged as a race under Swift 6 strict concurrency.
            Task.detached(priority: .utility) { [weak self] in
                await PosterCache.shared.prefetchPosters(uidsToLoad)
                await self?.finishPrefetch(uidsToLoad)
            }
        }

        /// Main-actor completion step. It clears finished keys from the in-flight set, so a later tick can re-request any that still are not cached.
        private func finishPrefetch(_ posterUIDs: [String]) {
            inFlightPrefetchUIDs.subtract(posterUIDs)
        }

        /// Returns film IDs for drag operation.
        ///
        /// `indexPath` is now always the ORIGINAL mouseDown location (see
        /// GalleryDragEngine.startManualDrag), so this always resolves the film the
        /// user actually clicked, never one the live cursor drifted onto afterward.
        func filmIDsForDrag(clickedAt indexPath: IndexPath?) -> Set<UUID> {
            let clickedID = indexPath.flatMap { filmID(at: $0) }

            /// Read the authoritative, synchronous AppKit selection directly, rather
            /// than selectionState.selectedFilmIDs — the latter is written via a
            /// deferred DispatchQueue.main.async in SelectionState.select(_:) and can
            /// therefore still reflect the PREVIOUS selection for one run-loop turn
            /// after a click has already committed a new one (e.g. a Cmd-click toggle
            /// immediately followed by a drag). collectionView.selectionIndexPaths is
            /// the same source mouseDown itself consults when deciding whether a click
            /// landed on an already-selected item, so this keeps a single, always-
            /// current source of truth for both decisions.
            let selection = Set((collectionView?.selectionIndexPaths ?? []).compactMap { filmID(at: $0) })

            /// If clicked item is in selection, drag all selected
            if let id = clickedID, selection.contains(id) {
                Self.log("Drag: \(selection.count) selected film(s)")
                return selection
            }

            /// Otherwise drag just the clicked item
            if let id = clickedID {
                Self.log("Drag: single unselected film")
                return [id]
            }

            return []
        }

        // MARK: - Layout
        /// Grid layout is self-computing: prepare() reads current bounds and
        /// calculates all parameters in integer backing pixels. No manual
        /// recalculation needed — shouldInvalidateLayout drives it through AppKit.

        // MARK: - Selection
        func handleMarqueeSelection(_ indexPaths: Set<IndexPath>) {
            guard !isUpdatingSelection else { return }
            isUpdatingSelection = true
            defer { isUpdatingSelection = false }

            /// A marquee starts a new selection, so the keyboard cursor is cleared and the next arrow press starts from the selection.
            cursorIndexPath = nil
            anchorIndexPath = nil
            /// A real marquee selection overrides any stale prune flag.
            selectionClearedByPrune = false

            let ids = Set(indexPaths.compactMap { filmID(at: $0) })
            selectionState.select(ids)
        }

        func syncSelectionToView() {
            guard let collectionView, !isUpdatingSelection else { return }
            /// A deferred selection is about to land and will sync again; see hasPendingSelection.
            guard !selectionState.hasPendingSelection else { return }
            isUpdatingSelection = true
            defer { isUpdatingSelection = false }

            /// Untracked, because this also runs inside updateNSView. See untrackedSelectedFilmIDs.
            let selectedIDs = selectionState.untrackedSelectedFilmIDs
            guard !selectedIDs.isEmpty else {
                collectionView.selectionIndexPaths = []
                cursorIndexPath = nil
                return
            }

            /// Uses the cached index map, which is rebuilt when the films change, for fast lookups.
            let validIDs = selectedIDs.filter { filmIndexMap[$0] != nil }

            /// Prunes invalid selections. selectImmediate is safe here, because this runs from the main-actor observation task rather
            /// than a view update. A deferred select() would land after isUpdatingSelection resets and make the loop re-run this.
            if validIDs.count != selectedIDs.count {
                if validIDs.isEmpty {
                    Self.log("No selected films in current view - clearing selection")
                    selectionState.selectImmediate(Set<UUID>())
                    collectionView.selectionIndexPaths = []
                    cursorIndexPath = nil
                    /// Every previously selected film left the view, such as a removal from the list being viewed. The flag stops a later
                    /// becomeFirstResponder, typically after a FilmSheet closes, from reseeding item 0 over the deliberate clear.
                    selectionClearedByPrune = true
                    return
                }
                Self.log("Pruning \(selectedIDs.count - validIDs.count) invalid selection IDs")
                selectionState.selectImmediate(validIDs)
            }

            let newSelection = Set(validIDs.compactMap { filmIndexMap[$0] }.map { IndexPath(item: $0, section: 0) })
            if collectionView.selectionIndexPaths != newSelection {
                collectionView.selectionIndexPaths = newSelection
            }

            /// Re-anchors the keyboard cursor to the film's current visual position. After a reload that reorders the grid, the
            /// selection highlight moves to the new index, but cursorIndexPath and anchorIndexPath still hold the old one. Arrow keys
            /// would then navigate from the old index. Both are set to match the post-reload selection.
            ///
            /// For one selected item, cursor and anchor are its new index. For several, the minimum is the anchor and the maximum
            /// is the cursor, which keeps the direction of any earlier shift-selection.
            if newSelection.count == 1, let singlePath = newSelection.first {
                cursorIndexPath = singlePath
                anchorIndexPath = singlePath
            } else if newSelection.count > 1 {
                let sorted = newSelection.sorted { $0.item < $1.item }
                anchorIndexPath = sorted.first
                cursorIndexPath = sorted.last
            }
            /// An empty selection is handled by the early exit above.
        }

        // MARK: - Contextual Menu

        /// Resolves the films a secondary-click context menu should act on, and builds the menu for them. It is called from
        /// GalleryCollectionView.menu(for:), which has already confirmed the click landed on an item.
        ///
        /// A click on an already-selected item leaves the selection unchanged, so the menu acts on the whole group.
        ///
        /// A click on an unselected item must select it. "Edit Metadata…" and "Edit Releases…" are bare commands that
        /// SheetHostView resolves against the selection, with no film ID. A menu for an unselected film would otherwise open
        /// the sheet for whatever was selected. Selecting on click is also standard macOS behavior.
        ///
        /// The commit mirrors the plain-click path in didSelectItemsAt. Selection, cursor, and model update together, with
        /// selectImmediate, since the menu's tracking loop starts as soon as this returns.
        func contextMenu(forItemAt indexPath: IndexPath) -> NSMenu? {
            guard let collectionView, let clickedID = filmID(at: indexPath) else { return nil }

            var targetIDs = Set(collectionView.selectionIndexPaths.compactMap { filmID(at: $0) })

            if !targetIDs.contains(clickedID) {
                isUpdatingSelection = true
                collectionView.selectionIndexPaths = [indexPath]
                anchorIndexPath = indexPath
                cursorIndexPath = indexPath
                /// A deliberate selection overrides any stale prune flag, as in updateSelectionFromView.
                selectionClearedByPrune = false
                isUpdatingSelection = false
                selectionState.selectImmediate([clickedID], inputKind: .fromCurrentAppKitEvent())
                targetIDs = [clickedID]
            }

            return GalleryContextMenu.makeMenu(for: targetIDs)
        }

        private func updateSelectionFromView() {
            guard !isSuppressingCallbacks else { return }
            /// Entry is not gated on isUpdatingSelection. This runs only for AppKit selection callbacks from direct user input. The
            /// arrow-key path holds isUpdatingSelection open to suppress its own echo. A click that lands during that hold would be
            /// dropped if gated, leaving the model out of step with the screen. An AppKit-confirmed change is the source of truth.
            isUpdatingSelection = true
            defer {
                isUpdatingSelection = false
                /// Also clears any pending reset flag, so a stale async reset from arrow-key handling cannot run after this click.
                hasScheduledSelectionReset = false
            }

            /// An AppKit-confirmed selection change, from a click, Cmd/Shift-click, or marquee, overrides any stale prune flag.
            selectionClearedByPrune = false

            let ids = Set((collectionView?.selectionIndexPaths ?? []).compactMap { filmID(at: $0) })
            /// Classifies the input from NSApp.currentEvent. This runs synchronously inside the triggering event, so a mouse press is a
            /// discrete click, and RightSidebar resolves it immediately, as the arrow-key path does. Other origins, such as drags, are
            /// unspecified and keep the timing debounce. See SelectionInputKind.fromCurrentAppKitEvent.
            selectionState.select(ids, inputKind: .fromCurrentAppKitEvent())
        }

        // MARK: - Data Source

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            films.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            guard let item = collectionView.makeItem(
                withIdentifier: kGalleryItemID,
                for: indexPath
            ) as? GalleryItem else { return NSCollectionViewItem() }

            if let film = film(at: indexPath) { item.configure(with: film, subtitleProvider: subtitleProvider) }
            return item
        }

        // MARK: - Selection Delegate
        ///
        /// This method is the sole authority for resolving a click's selection
        /// result. GalleryCollectionView (23.10 GalleryViewUI.swift) calls it
        /// directly rather than calling super.mouseDown(with:) and letting
        /// NSCollectionView's own internal tracking loop compute the result and
        /// invoke this delegate at mouseUp. It is invoked from one of two places:
        ///   - mouseDown, synchronously, for any click that changes the selection
        ///     (a not-yet-selected item, or a Shift/Cmd-click).
        ///   - mouseUp, for a plain click on an item already part of the selection
        ///     that did NOT turn into a drag — see GalleryCollectionView's
        ///     `pendingPlainClickCollapse` and its SELECTION TIMING comment.
        /// Either way, there is no AppKit-side computation happening — this method
        /// must fully resolve the result itself. In particular, the Shift-click-
        /// with-no-anchor branch below can no longer trust "AppKit has already
        /// computed the resulting full selection" and derives its own fallback
        /// anchor instead. The Cmd-click toggle branch is unaffected: mouseDown
        /// already stages the toggle against selectionIndexPaths itself before
        /// calling here, as AppKit's internal tracking does.
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            let shiftHeld = NSEvent.modifierFlags.contains(.shift)
            let commandHeld = NSEvent.modifierFlags.contains(.command)

            if shiftHeld, let clicked = indexPaths.first {
                /// Extend from the tracked anchor (the fixed end of the shift-range) to
                /// the clicked item. If no anchor is tracked — e.g. right after a
                /// marquee drag, which intentionally nils anchorIndexPath, or this is
                /// the first shift-click of a session — fall back to the nearest edge
                /// of whatever is currently selected (its lowest index), so the
                /// extension still reads as "select everything between the existing
                /// selection and the clicked item" rather than silently doing nothing.
                /// If nothing is selected at all, the clicked item anchors itself.
                let anchor = anchorIndexPath
                    ?? collectionView.selectionIndexPaths.min(by: { $0.item < $1.item })
                    ?? clicked
                let range = min(anchor.item, clicked.item)...max(anchor.item, clicked.item)
                collectionView.selectionIndexPaths = Set(range.map { IndexPath(item: $0, section: 0) })
                anchorIndexPath = anchor
                cursorIndexPath = clicked
            } else if commandHeld {
                /// Cmd-click toggle: already performed against selectionIndexPaths in
                /// mouseDown, before this method was invoked, so trust that result
                /// completely rather than forcing a single-item override, which would
                /// incorrectly collapse a legitimate multi-item selection. Re-derive
                /// anchor/cursor from the actual resulting selection (sorted, not from
                /// the unordered `indexPaths` parameter), so keyboard navigation starts from a deterministic endpoint.
                let full = collectionView.selectionIndexPaths
                if full.count == 1, let only = full.first {
                    anchorIndexPath = only
                    cursorIndexPath = only
                } else if !full.isEmpty {
                    let sorted = full.sorted { $0.item < $1.item }
                    anchorIndexPath = sorted.first
                    cursorIndexPath = sorted.last
                } else {
                    /// Cmd-click toggled the only selected item off.
                    anchorIndexPath = nil
                    cursorIndexPath = nil
                }
            } else if let first = indexPaths.first {
                /// Forces the collection view's selection to exactly this item. mouseDown resolves plain clicks itself now, so this is a
                /// defensive invariant: a plain click never leaves more than one focus ring. It does not re-invoke this delegate, since
                /// programmatic assignments do not call back. Only plain clicks reach this branch, so multi-select gestures are unaffected.
                collectionView.selectionIndexPaths = [first]
                anchorIndexPath = first
                cursorIndexPath = first
            }
            updateSelectionFromView()
        }

        /// Kept for NSCollectionViewDelegate completeness. Ordinary clicks no longer reach it, because GalleryCollectionView.mouseDown
        /// assigns selectionIndexPaths and calls didSelectItemsAt directly, and programmatic assignments do not call this. It fires
        /// only if a future AppKit-driven action, such as deselectAll, is added.
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            updateSelectionFromView()
        }

        // MARK: - Section Dividers

        /// Recomputes the section-divider breaks from `films` and pushes them to the layout. GallerySectioning.displayedSectionBreaks
        /// decides which bands apply: the Film Queue's three fixed sections, bands from the sort option, or none. When it yields
        /// nothing, the breaks are cleared, and the divider machinery is inert.
        ///
        /// Called from updateNSView on every reload, before reloadData(). This settles only the layout's geometry. The band text
        /// is reconciled at the end of the same pass (see refreshVisibleSectionDividers).
        private struct SectionBreakInputs: Equatable {
            let films: [FilmSnapshot]
            let showSortingSections: Bool
            let queueFilter: FilmQueueFilter?
            let sortOption: SortOption?
            let recentsCategory: RecentsCategory?
            /// See GallerySectioning.filmQueueMembership.
            let queueMembership: [Set<UUID>]?
        }

        /// What the layout's current breaks were computed from; see updateSectionDividers.
        private var lastSectionBreakInputs: SectionBreakInputs?

        /// True when the band labels may lag the layout, because the breaks or slot run changed, or the collection view reloaded.
        /// The sweep is skipped on every other pass.
        fileprivate var dividerBandsNeedRefresh = true

        func updateSectionDividers() {
            guard let layout = collectionView?.collectionViewLayout as? SmoothResizingGridLayout else { return }
            /// This runs on every update pass, and computing the breaks scans every film when bands apply. It is skipped when no input
            /// has changed. films compares in O(1) when it is the same buffer. The Film Queue's "All" tab also depends on queue
            /// membership, which no FilmSnapshot field reflects, so that membership is an input too.
            let inputs = SectionBreakInputs(films: films,
                                            showSortingSections: showSortingSections,
                                            queueFilter: dataCoordinator?.loadedFilmQueueFilter,
                                            sortOption: dataCoordinator?.loadedSortOption,
                                            recentsCategory: dataCoordinator?.loadedRecentsCategory,
                                            queueMembership: dataCoordinator.flatMap(GallerySectioning.filmQueueMembership))
            if inputs == lastSectionBreakInputs { return }
            lastSectionBreakInputs = inputs
            /// All the gates live in GallerySectioning.displayedSectionBreaks, which the list style and the Sort menu also call, so
            /// every consumer gets the same answer. Its DataCoordinator inputs (loadedFilmQueueFilter and loadedSortOption) are written
            /// in the same pass as `films`, so the divider state always matches the films shown. Reading the live filter or sort instead
            /// caused the original flicker: those change as soon as a control is tapped, before the reload lands.
            let rawBreaks = dataCoordinator.map { dc in
                GallerySectioning.displayedSectionBreaks(
                    films: films, coordinator: dc,
                    showSortingSections: showSortingSections)
            } ?? []
            let breaks: [SmoothResizingGridLayout.SectionBreak] =
                rawBreaks.map { .init(index: $0.index, section: $0.section) }
            /// Only the Queue's "All" tab also gets its empty "Up Next" slots.
            let slotRun = dataCoordinator.flatMap { dc in
                UpNextSlots.plan(breaks: rawBreaks, filmCount: films.count, coordinator: dc)
            }.map {
                SmoothResizingGridLayout.SlotRun(
                    itemIndex: $0.afterIndex, firstNumber: $0.firstNumber, count: $0.count,
                    leadingSection: $0.needsOwnBand ? FilmQueueSection.upNext.gallerySection : nil)
            }
            guard breaks != layout.sectionBreaks || slotRun != layout.slotRun else { return }
            layout.sectionBreaks = breaks
            layout.slotRun = slotRun
            layout.invalidateLayout()
            dividerBandsNeedRefresh = true
        }

        /// Declares that the user has taken over the viewport, so nothing armed earlier may still move it.
        ///
        /// Three mechanisms can move a gallery after the fact: a saved-origin restore in ViewStateManager, an origin armed on the
        /// scroll view, and an armed scroll-to-film target. Each resolves on a later layout or draw pass. That is fine while the app
        /// owns the viewport. Once the user clicks, the next draw can jump the gallery out from under them.
        ///
        /// That caused a reported jump from the top to the bottom. A section jump uses a programmatic setBoundsOrigin, which emits no
        /// didEndLiveScroll, so the origin was never banked, and a click later resolved a stale restore. This is the body of
        /// handleLiveScrollEnded: retire first, then bank, so a pending restore cannot block the save. It also clears the two arms
        /// that only a programmatic jump can leave behind.
        func claimViewportForUser() {
            ViewStateManager.shared.finishScrollOriginRestore(for: displayedScrollKey)
            scrollView?.pendingScrollPosition = nil
            scrollView?.pendingScrollFilmID = nil
            guard let scrollView else { return }
            ViewStateManager.shared.saveScrollPosition(scrollPosition(of: scrollView),
                                                       under: displayedScrollKey)
        }

        /// Pushes the current layout's section identities into every live divider view, so a band's label never lags the breaks.
        ///
        /// Each step is a pure function of the one before it: the breaks come from the films and sort, the layout rows from the
        /// breaks, and the attributes from the rows. AppKit does not reliably re-apply attributes when only a label changed. A sort
        /// change can leave ordinals and positions the same, so a view AppKit skips keeps the old sort's label. This sweep makes the
        /// refresh the gallery's responsibility.
        ///
        /// It runs only when the breaks changed or the collection view reloaded. It visits only bands in the hierarchy, and each one
        /// returns early when its text is unchanged.
        func refreshVisibleSectionDividers() {
            guard let collectionView,
                  let layout = collectionView.collectionViewLayout as? SmoothResizingGridLayout
            else { return }
            /// Nothing the sweep reconciles has moved since it last ran. Forcing a layout on such a pass, such as a selection change or
            /// a status-bar toggle, would be wasted work.
            guard dividerBandsNeedRefresh else {
                #if DEBUG
                GalleryRefreshProbe.skippedDividerLayouts += 1
                #endif
                return
            }
            dividerBandsNeedRefresh = false
            /// No bands to label. Without breaks there are no divider rows, and the slot run is the only other thing that places a band.
            /// That covers every view without dividers. Forcing a layout there would add a pass on every update, including the one that
            /// resizes the gallery when the right sidebar mounts. Cleared breaks need no sweep either, since their bands are removed.
            guard !layout.sectionBreaks.isEmpty || layout.slotRun != nil else {
                #if DEBUG
                GalleryRefreshProbe.skippedDividerLayouts += 1
                #endif
                return
            }
            #if DEBUG
            GalleryRefreshProbe.forcedDividerLayouts += 1
            #endif
            /// The breaks were pushed to the layout earlier, but prepare() runs lazily and builds the dividerRows that bands resolve
            /// against. Forcing the layout first makes this sweep read the new rows. It is safe here: the collection view already holds
            /// the current films, and any relayout would happen before the next frame regardless.
            collectionView.layoutSubtreeIfNeeded()
            for case let band as SectionDividerDecorationView in collectionView.subviews {
                band.refreshFromLayout()
            }
        }

        /// Computes the up/down arrow-key target index when section dividers are present. It uses the layout's row and column
        /// model, so a divider band is stepped over to the next content row in the same column. Partial rows clamp to their nearest
        /// item, as in standard macOS grid navigation. `step` is -1 for up and +1 for down. It returns nil if the layout cannot
        /// resolve the current index, and the caller then uses plain arithmetic.
        private func dividerAwareVerticalTarget(from currentIndex: Int, step: Int,
                                                layout: SmoothResizingGridLayout) -> Int? {
            guard let (row, col) = layout.rowColumn(forItemIndex: currentIndex) else { return nil }
            var candidateRow = row + step
            /// Rows holding only empty "Up Next" slots are skipped, as divider bands are.
            while layout.isSlotOnlyRow(candidateRow) { candidateRow += step }
            if let idx = layout.itemIndex(atRow: candidateRow, col: col) {
                /// The adjacent row has an item in this column, which is the usual case.
                return idx
            } else if layout.isDividerRow(candidateRow) {
                /// The adjacent row is a divider band, always one row deep, so a further step lands on the next content row.
                var afterDivider = candidateRow + step
                while layout.isSlotOnlyRow(afterDivider) { afterDivider += step }
                if let idx = layout.itemIndex(atRow: afterDivider, col: col) {
                    return idx
                } else if let idx = layout.lastItemIndex(inRow: afterDivider) {
                    return idx
                } else {
                    return currentIndex
                }
            } else if let idx = layout.lastItemIndex(inRow: candidateRow) {
                /// A content row with fewer than columnsPerRow items, such as a partial row before a divider or the trailing row, lands on its last item.
                return idx
            } else {
                /// No row exists there, so this is the vertical edge.
                return currentIndex
            }
        }

        // MARK: - Keyboard Navigation

        /// Seeds `cursorIndexPath` and `anchorIndexPath` at item 0 and selects it. It is called by GalleryCollectionView.becomeFirstResponder
        /// through onKeyboardFocusWithNoSelection, when the view gains focus with no selection, such as after Tab.
        ///
        /// AppKit's own Tab focus selects the first item. This subclass routes arrow keys through handleArrowKey and bypasses
        /// super.keyDown, so that side effect never fires. seedInitialCursor restores it explicitly.
        ///
        /// It does nothing when films is empty, when isUpdatingSelection is already true, or when a selection has appeared since focus.
        func seedInitialCursor() {
            guard !films.isEmpty, !isUpdatingSelection, let collectionView else { return }
            /// An empty selection here is a deliberate result of the selected films leaving the view, such as a FilmSheet removing one.
            /// Returning focus honors that clear. The flag is consumed so it cannot suppress a later genuine focus event.
            if selectionClearedByPrune {
                selectionClearedByPrune = false
                return
            }
            /// The seed runs one turn after focus arrives. A selection made in that turn may not be synced to this view yet, so both
            /// the model and this view are checked before seeding over it.
            guard selectionState.selectedFilmIDs.isEmpty, !selectionState.hasPendingSelection,
                  collectionView.selectionIndexPaths.isEmpty else { return }
            let indexPath = IndexPath(item: 0, section: 0)
            isUpdatingSelection = true
            anchorIndexPath = indexPath
            cursorIndexPath = indexPath
            collectionView.selectionIndexPaths = [indexPath]
            let ids = Set([indexPath].compactMap { filmID(at: $0) })
            selectionState.selectImmediate(ids)
            DispatchQueue.main.async { [weak self] in self?.isUpdatingSelection = false }
        }

        func handleArrowKey(_ direction: ArrowDirection, withShift: Bool, isRepeat: Bool) {
            guard let collectionView, !films.isEmpty else { return }
            isUpdatingSelection = true
            /// The entry guard does not test isUpdatingSelection. That flag is held across a run-loop turn to suppress the echo of
            /// selectImmediate() through the observation loop. Gating entry on it would swallow a second arrow press that arrives quickly.
            /// handleArrowKey runs synchronously from keyDown, so every press is honored. Setting the flag on each entry keeps the echo
            /// suppressed, and the single pending reset clears it once the burst settles.

            let layout = collectionView.collectionViewLayout as? SmoothResizingGridLayout
            let itemsPerRow = max(1, layout?.columnsPerRow ?? 1)
            let totalItems = films.count

            let currentIndex: Int
            if let cursor = cursorIndexPath {
                currentIndex = cursor.item
            } else if let first = collectionView.selectionIndexPaths.min() {
                currentIndex = first.item
            } else {
                isUpdatingSelection = false
                return
            }

            var targetIndex = currentIndex

            switch direction {
            case .up:
                if let layout, layout.hasSectionDividers,
                   let idx = dividerAwareVerticalTarget(from: currentIndex, step: -1, layout: layout) {
                    /// Film Queue with dividers: navigate through the layout's row and column model, so a divider is transparent and
                    /// partial rows clamp. See dividerAwareVerticalTarget.
                    targetIndex = idx
                } else {
                    /// Uniform grid, which is every other view and the queue without dividers. The row above is always full, except the grid's
                    /// last row, so same-column arithmetic is valid here. This path is unchanged.
                    targetIndex = currentIndex - itemsPerRow
                    if targetIndex < 0 { targetIndex = currentIndex }
                }
            case .down:
                if let layout, layout.hasSectionDividers,
                   let idx = dividerAwareVerticalTarget(from: currentIndex, step: 1, layout: layout) {
                    /// Film Queue with dividers: see dividerAwareVerticalTarget.
                    targetIndex = idx
                } else {
                    /// Uniform grid. The row below can be the trailing partial row, and plain arithmetic can overshoot its end. Instead, the
                    /// move lands on the last item of that row, as standard macOS grid navigation does.
                    let candidateIndex = currentIndex + itemsPerRow
                    if candidateIndex < totalItems {
                        /// The row below exists and has an item at this exact column — the
                        /// common case, a same-column step across a uniform stretch of rows.
                        targetIndex = candidateIndex
                    } else {
                        let nextRowStart = ((currentIndex / itemsPerRow) + 1) * itemsPerRow
                        if nextRowStart < totalItems {
                            /// The next row exists — it's the trailing partial row — but has
                            /// no item at this column. Land on its last available item.
                            targetIndex = totalItems - 1
                        } else {
                            /// No further row exists at all — genuinely at the vertical edge.
                            targetIndex = currentIndex
                        }
                    }
                }
            case .left:
                targetIndex = currentIndex - 1
                if targetIndex < 0 { targetIndex = totalItems - 1 }
            case .right:
                targetIndex = currentIndex + 1
                if targetIndex >= totalItems { targetIndex = 0 }
            }

            targetIndex = max(0, min(targetIndex, totalItems - 1))
            let targetPath = IndexPath(item: targetIndex, section: 0)

            if withShift {
                if anchorIndexPath == nil { anchorIndexPath = IndexPath(item: currentIndex, section: 0) }
                cursorIndexPath = targetPath
                if let anchor = anchorIndexPath {
                    let range = min(anchor.item, targetIndex)...max(anchor.item, targetIndex)
                    let paths = Set(range.map { IndexPath(item: $0, section: 0) })
                    collectionView.selectionIndexPaths = paths
                    /// Compute IDs directly from the known range — avoids an AppKit
                    /// bridge round-trip to read selectionIndexPaths back from NSCollectionView.
                    let ids = Set(range.compactMap { filmID(at: IndexPath(item: $0, section: 0)) })
                    selectionState.selectImmediate(ids, inputKind: isRepeat ? .keyRepeat : .discrete)
                }
            } else {
                anchorIndexPath = targetPath
                cursorIndexPath = targetPath
                collectionView.selectionIndexPaths = [targetPath]
                /// Single-item selection: compute the ID directly from the target path
                /// rather than reading selectionIndexPaths back from NSCollectionView.
                if let id = filmID(at: targetPath) {
                    selectionState.selectImmediate([id], inputKind: isRepeat ? .keyRepeat : .discrete)
                }
            }

            /// Reveal the scroller only when the step actually moved the viewport, as
            /// NSTableView does. Revealing it on every step made it blink on each
            /// selection change whose target was already on screen.
            if scrollToItemIfNeeded(at: targetPath) {
                showScrollersInstantly()
            }

            /// Schedules a single reset, so rapid key presses do not queue several resets and redundant syncs.
            if !hasScheduledSelectionReset {
                hasScheduledSelectionReset = true
                DispatchQueue.main.async { [weak self] in
                    self?.isUpdatingSelection = false
                    self?.hasScheduledSelectionReset = false
                }
            }
        }

        func selectAll() {
            guard let collectionView, !films.isEmpty else { return }

            /// The visual selection and the model update together. Setting selectionIndexPaths first makes focus rings appear at once.
            /// The model is updated unconditionally, so it stays in sync during rapid arrow navigation. NSCollectionView does not call
            /// delegate methods for programmatic selection, so this cannot loop.
            guard !isUpdatingSelection else {
                /// Another selection operation is in flight. Its reset will run later, and the model would not yet reflect Select All, so this
                /// schedules its own update after that reset.
                DispatchQueue.main.async { [weak self] in
                    self?.selectAll()
                }
                return
            }
            isUpdatingSelection = true

            collectionView.selectionIndexPaths = Set((0..<films.count).map { IndexPath(item: $0, section: 0) })

            /// Uses filmIndexMap.keys, which already holds exactly the IDs in the current view. No read-back of selectionIndexPaths is needed.
            let ids = Set(filmIndexMap.keys)
            selectionState.selectImmediate(ids)

            if !hasScheduledSelectionReset {
                hasScheduledSelectionReset = true
                DispatchQueue.main.async { [weak self] in
                    self?.isUpdatingSelection = false
                    self?.hasScheduledSelectionReset = false
                }
            }
        }

        /// Returns whether the viewport moved.
        private func scrollToItemIfNeeded(at indexPath: IndexPath) -> Bool {
            guard let collectionView, let scrollView,
                  let layout = collectionView.collectionViewLayout as? SmoothResizingGridLayout,
                  let attrs = layout.layoutAttributesForItem(at: indexPath) else { return false }

            let visibleRect = scrollView.documentVisibleRect
            let itemFrame = attrs.frame

            /// Checks whether the item is fully visible. If not, computes the scroll target that makes it fully visible.
            if visibleRect.contains(itemFrame) { return false }

            /// Calculate the target scroll position to make item fully visible
            var targetPoint = scrollView.documentView?.bounds.origin ?? .zero

            /// Padding depends on scroll direction. It uses the layout's inter-row gap, and adds the StatusBar height when the bar is visible.
            let gridPadding = layout.lineSpacing
            let topPadding = gridPadding
            let bottomPadding = isStatusBarVisible ? gridPadding + kStatusBarHeight : gridPadding

            if itemFrame.minY < visibleRect.minY {
                /// Item is above visible area — scroll up
                targetPoint.y = max(0, itemFrame.minY - topPadding)
            } else if itemFrame.maxY > visibleRect.maxY {
                /// Item is below visible area — scroll down
                targetPoint.y = itemFrame.maxY + bottomPadding - visibleRect.height
            }

            /// Clamps to the valid scroll range.
            let contentHeight = layout.collectionViewContentSize.height
            let maxScrollY = max(0, contentHeight - visibleRect.height)
            targetPoint.y = max(0, min(targetPoint.y, maxScrollY))
            /// A partly hidden item can still clamp to the current origin, such as the last row.
            guard targetPoint.y != visibleRect.minY else { return false }

            /// Scrolls instantly, without animation, by setting the document's visible rect directly.
            appViewportMove {
                scrollView.contentView.setBoundsOrigin(targetPoint)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            return true
        }

        /// Returns whether the item at an index path is fully or partly visible in the viewport. updateNSView uses it to decide
        /// whether scrollToTopRow is needed after a film edit. A partial intersection counts as visible.
        fileprivate func isFilmVisible(at indexPath: IndexPath) -> Bool {
            guard let collectionView, let scrollView,
                  let layout = collectionView.collectionViewLayout as? SmoothResizingGridLayout,
                  let attrs = layout.layoutAttributesForItem(at: indexPath) else {
                /// If visibility cannot be determined, the item counts as not visible, so a scroll is attempted and the film is not left off screen.
                return false
            }
            let visibleRect = scrollView.documentVisibleRect
            return visibleRect.intersects(attrs.frame)
        }

        /// Returns the film that is topmost, and within a partly visible top row leftmost, in the viewport. It captures the target for a
        /// grid-to-list handoff, and serves the reverse direction too. It uses the layout's attributes-in-rect query, not fixed
        /// arithmetic, so it stays correct with divider views. Those are excluded by the .item category filter, as in
        /// prefetchAroundVisibleRect and updateLiveSelection.
        func topmostVisibleFilmID() -> UUID? {
            topmostVisibleItemIndex().map { films[$0].id }
        }

        /// The index of the topmost-leftmost film in the viewport. See topmostVisibleFilmID.
        private func topmostVisibleItemIndex() -> Int? {
            guard let collectionView, let scrollView,
                  let layout = collectionView.collectionViewLayout as? SmoothResizingGridLayout,
                  !films.isEmpty else { return nil }

            let visible = scrollView.documentVisibleRect
            guard visible.height > 0 else { return nil }

            let itemIndexPaths = layout.layoutAttributesForElements(in: visible)
                .filter { $0.representedElementCategory == .item }
                .compactMap { $0.indexPath }

            guard let topIndexPath = itemIndexPaths.min(),
                  topIndexPath.item >= 0, topIndexPath.item < films.count else { return nil }

            return topIndexPath.item
        }

        /// Scrolls so the item sits in the top row of the visible area. It scrolls instantly, as arrow navigation does. Returns whether
        /// the viewport moved.
        @discardableResult
        fileprivate func scrollToTopRow(at indexPath: IndexPath) -> Bool {
            guard let collectionView, let scrollView,
                  let layout = collectionView.collectionViewLayout as? SmoothResizingGridLayout,
                  let attrs = layout.layoutAttributesForItem(at: indexPath) else { return false }

            return scrollContentTop(to: attrs.frame.minY, layout: layout, scrollView: scrollView)
        }

        /// Places the section band that starts with `firstFilmID` at the top of the viewport. It targets the band's own Y, not the
        /// film's. Scrolling to the film would push its section label off the top, and that label is what the user clicked. If no band
        /// precedes the film, because bands were switched off after the menu was built, the film itself goes to the top.
        func scrollToSectionBand(firstFilmID: UUID) {
            guard let index = filmIndexMap[firstFilmID],
                  let collectionView, let scrollView,
                  let layout = collectionView.collectionViewLayout as? SmoothResizingGridLayout
            else { return }

            let moved: Bool
            if let bandY = layout.dividerY(forItemIndex: index) {
                moved = scrollContentTop(to: bandY, layout: layout, scrollView: scrollView)
            } else {
                moved = scrollToTopRow(at: IndexPath(item: index, section: 0))
            }
            if moved { showScrollersInstantly() }
            /// A menu-driven jump is a choice by the user, like a scroll gesture. It moves the viewport programmatically, so no
            /// didEndLiveScroll banks the pre-jump origin. Claiming it here stops that origin from being restored later.
            claimViewportForUser()
        }

        /// Scrolls so `contentY` sits at the top of the viewport, inset by the line spacing and clamped to the scrollable range.
        /// Both row placement and the section jump use it, so they land at the same offset for the same target. Returns whether the
        /// viewport moved.
        @discardableResult
        private func scrollContentTop(to contentY: CGFloat,
                                      layout: SmoothResizingGridLayout,
                                      scrollView: NSScrollView) -> Bool {
            var targetPoint = scrollView.documentView?.bounds.origin ?? .zero
            targetPoint.y = max(0, contentY - layout.lineSpacing)

            /// If the target would scroll past the end of the content, this shows as much as possible instead.
            let contentHeight = layout.collectionViewContentSize.height
            let visibleHeight = scrollView.documentVisibleRect.height
            if targetPoint.y + visibleHeight > contentHeight {
                targetPoint.y = max(0, contentHeight - visibleHeight)
            }

            guard targetPoint.y != scrollView.documentVisibleRect.minY else { return false }

            /// Instant, non-animated scroll, matching arrow-key navigation.
            appViewportMove {
                scrollView.contentView.setBoundsOrigin(targetPoint)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            return true
        }

        /// Shows scroll indicators instantly without fade-in animation
        /// Allows natural fade-out to occur, matching native macOS arrow key behavior
        private func showScrollersInstantly() {
            guard let scrollView = scrollView else { return }

            /// Make scrollers visible instantly by setting alpha to 1.0
            /// This bypasses the fade-in animation of flashScrollers()
            if let verticalScroller = scrollView.verticalScroller {
                verticalScroller.alphaValue = 1.0

                /// Trigger the normal auto-hide fade-out behavior
                /// This schedules the scroller to fade out after the standard delay
                scrollView.flashScrollers()
            }
        }
    }
}

// MARK: - App-Initiated Viewport Moves

/// Runs a viewport move the app makes on purpose. In release it only runs `move`. In DEBUG, the viewport-jump tracer skips
/// it, since the call stack would only name a caller that already explains itself. Every programmatic origin change in both
/// galleries goes through here.
@MainActor
func appViewportMove(_ move: () -> Void) {
    #if DEBUG
    ViewportJumpTracer.appMoveDepth += 1
    defer { ViewportJumpTracer.appMoveDepth -= 1 }
    #endif
    move()
}

// MARK: - Coasting-Scroll Stopper

/// Stops a coasting trackpad scroll so a programmatic jump lands and stays put. The grid and the list both use it for Cmd+L.
///
/// With responsive scrolling, AppKit runs the coast on its own background thread. A setBoundsOrigin during the coast counts as
/// an unexpected scroll, and the coast carries on from the new origin. The private `_stopGestureScrollTracking` is the only
/// call found to end the coast, after testing public and private alternatives. Stopping makes AppKit write its last origin
/// and post didEndLiveScroll, sometimes a few milliseconds later. So the jump waits for that notification. Jumping immediately
/// lost to the final write, and the viewport snapped back.
///
/// Every failure falls back to an immediate jump. The fallbacks cover: no live scroll, a mouse
/// button held (a scroller-knob drag is not ours to stop), a changed method signature in a later macOS, or no didEndLiveScroll
/// within `endTimeout`.
@MainActor
final class CoastingScrollStopper: NSObject, Loggable {
    nonisolated static let logTag = "[CoastingScrollStopper]"

    private static let stopSelector = NSSelectorFromString("_stopGestureScrollTracking")
    /// Objective-C type encoding of `- (void)_stopGestureScrollTracking` on 64-bit macOS. Any other encoding means the method
    /// changed shape, and it must not be called.
    private static let stopEncoding = "v16@0:8"
    /// How long to wait for didEndLiveScroll after stopping, before jumping anyway.
    private static let endTimeout: TimeInterval = 0.25

    private weak var scrollView: NSScrollView?
    /// Whether a live scroll is in progress for `scrollView`, between willStartLiveScroll and didEndLiveScroll.
    private var isLiveScrolling = false
    /// A jump waiting for didEndLiveScroll. Only the newest is kept.
    private var pendingJump: (@MainActor () -> Void)?
    /// Identifies the current pendingJump, so a superseded timeout does nothing.
    private var pendingGeneration = 0

    func install(on scrollView: NSScrollView) {
        self.scrollView = scrollView
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleLiveScrollStarted(_:)),
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleLiveScrollEnded(_:)),
            name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    /// Idempotent. Drops any pending jump.
    func remove() {
        NotificationCenter.default.removeObserver(
            self, name: NSScrollView.willStartLiveScrollNotification, object: nil)
        NotificationCenter.default.removeObserver(
            self, name: NSScrollView.didEndLiveScrollNotification, object: nil)
        scrollView = nil
        isLiveScrolling = false
        pendingJump = nil
    }

    /// Runs `jump`, first stopping a coast in progress if possible.
    ///
    /// `jump` receives true when a coast was stopped. AppKit's didEndLiveScroll then reached the scroll-origin recorder with the
    /// pre-jump position, so the caller must bank its new position itself. With false, the jump is a plain one.
    func jump(_ jump: @escaping @MainActor (_ stoppedCoast: Bool) -> Void) {
        guard isLiveScrolling, NSEvent.pressedMouseButtons == 0,
              let scrollView, let behavior = Self.stoppableBehavior(of: scrollView) else {
            jump(false)
            return
        }

        _ = unsafe behavior.perform(Self.stopSelector)

        guard isLiveScrolling else {
            /// didEndLiveScroll arrived inside the stop, so AppKit's final write is done.
            log("Stopped coast; ended synchronously")
            jump(true)
            return
        }

        pendingGeneration += 1
        let generation = pendingGeneration
        pendingJump = { jump(true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.endTimeout) { [weak self] in
            guard let self, generation == self.pendingGeneration,
                  let pending = self.pendingJump else { return }
            self.pendingJump = nil
            self.log("No didEndLiveScroll \(Int(Self.endTimeout * 1000)) ms after stopping; jumping anyway",
                     level: .warning)
            pending()
        }
    }

    /// The scroll view's scrolling behavior, if it can be stopped safely. Otherwise nil.
    private static func stoppableBehavior(of scrollView: NSScrollView) -> NSObject? {
        guard let ivar = unsafe class_getInstanceVariable(NSScrollView.self, "_scrollingBehavior"),
              let ivarEncoding = unsafe ivar_getTypeEncoding(ivar),
              unsafe String(cString: ivarEncoding).hasPrefix("@"),
              let behavior = unsafe object_getIvar(scrollView, ivar) as? NSObject,
              let method = unsafe class_getInstanceMethod(type(of: behavior), stopSelector),
              let methodEncoding = unsafe method_getTypeEncoding(method),
              unsafe String(cString: methodEncoding) == stopEncoding else { return nil }
        return behavior
    }

    @objc private func handleLiveScrollStarted(_ notification: Notification) {
        isLiveScrolling = true
    }

    @objc private func handleLiveScrollEnded(_ notification: Notification) {
        isLiveScrolling = false
        guard let pending = pendingJump else { return }
        pendingJump = nil
        log("Stopped coast; ended asynchronously")
        /// Waits one more turn, so every other didEndLiveScroll observer, including the scroll-origin recorder, runs before the jump.
        DispatchQueue.main.async { pending() }
    }
}

#if DEBUG
// MARK: - Viewport-Jump Tracer (DEBUG only)

/// Reports viewport moves the app did not request. The grid and the list share it.
/// It logs a clip-view bounds change whose vertical delta exceeds three viewport heights, with the call stack that moved it.
///
/// Two kinds of move are already explained and skipped: the app's own moves inside `appViewportMove`, and anything during a
/// live scroll. The second is the user's, such as a scroller-knob drag or a fast flick. What remains is a move nobody claimed.
///
/// The handler stays an `@objc` notification selector, so `dropFirst(2)` trims exactly the handler and its thunk from the stack.
@MainActor
final class ViewportJumpTracer: NSObject, Loggable {
    nonisolated static let logTag = "[ViewportJumpTracer]"

    /// Which gallery owns this tracer. Each log line names it, so grid and list jumps stay distinct.
    private let owner: String
    private weak var clipView: NSClipView?
    private var lastY: CGFloat = 0
    /// Whether a live scroll is in progress, between willStartLiveScroll and didEndLiveScroll.
    private var isLiveScrolling = false
    /// Nesting depth of `appViewportMove`. It is shared by every tracer, since a move is the app's whichever gallery made it.
    static var appMoveDepth = 0
    /// Jumps this tracer has flagged, whether or not logging is on. Read by `coast-stop`.
    static var jumpsFlagged = 0
    /// The owning coordinator's current view, read at log time.
    private var describeView: () -> String = { "?" }

    init(owner: String) {
        self.owner = owner
    }

    func install(on scrollView: NSScrollView, describeView: @escaping () -> String) {
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clipView = clip
        lastY = clip.bounds.origin.y
        self.describeView = describeView
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTick(_:)),
            name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleLiveScrollStarted(_:)),
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleLiveScrollEnded(_:)),
            name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    func remove() {
        if let clip = clipView {
            NotificationCenter.default.removeObserver(
                self, name: NSView.boundsDidChangeNotification, object: clip)
        }
        NotificationCenter.default.removeObserver(
            self, name: NSScrollView.willStartLiveScrollNotification, object: nil)
        NotificationCenter.default.removeObserver(
            self, name: NSScrollView.didEndLiveScrollNotification, object: nil)
        clipView = nil
        isLiveScrolling = false
    }

    @objc private func handleLiveScrollStarted(_ notification: Notification) {
        isLiveScrolling = true
    }

    @objc private func handleLiveScrollEnded(_ notification: Notification) {
        isLiveScrolling = false
    }

    @objc private func handleTick(_ notification: Notification) {
        guard let clip = clipView else { return }
        let y = clip.bounds.origin.y
        let delta = y - lastY
        lastY = y
        let viewport = clip.bounds.height
        guard viewport > 0, abs(delta) > viewport * 3,
              Self.appMoveDepth == 0, !isLiveScrolling else { return }
        Self.jumpsFlagged += 1
        /// Checked here, not in `log()`, because the stack must be captured in this frame for `dropFirst(2)` to trim the right frames.
        /// Capturing the stack is the expensive part, so it happens only when logging is on.
        guard Logger.isLoggingEnabled else { return }
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(28)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n    ")
        Self.log("VIEWPORT JUMP (\(owner)) \(Fmt.fixed(y - delta, 1)) -> \(Fmt.fixed(y, 1)) " +
                 "(viewport \(Int(viewport)), content \(Int(clip.documentView?.frame.height ?? -1)), " +
                 "view \(describeView()))\n    \(stack)")
    }
}
#endif
