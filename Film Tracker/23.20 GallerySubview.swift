// MARK: - GallerySubview.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Grid-based gallery with smooth item resizing, configurable column maximum (6 or 7),
// and centered fixed-width at 1500 units.

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

// NOTE: The search-exit scroll to the preserved film is gated by the user preference
// Preferences.maintainSelectionOnSearchExit alone, at its one producer
// (MainView.handleSearchContentChange): no film is preserved, so no intent is armed, when
// it is off. Neither gallery style applies a gate of its own.
//
// The addressed scroll intent consumed below — GalleryScrollIntent, together with
// its PendingScrollBehavior enum — is declared in ViewState.swift (kept AppKit-free),
// serving both the search-exit handoff and the grid⟷list view-style toggle handoff for
// both gallery styles. See GalleryScrollIntent's doc comment for the full rationale.

// MARK: - Width Observing Scroll View

final class WidthObservingScrollView: NSScrollView, Loggable {
    nonisolated static let logTag = "[GallerySubview]"

    /// Pending post-layout scroll target, transferred here from GalleryScrollIntent by
    /// GallerySubview.makeNSView when the grid is the destination style
    /// (DraggableListView.makeNSView in GalleryListView.swift is the equivalent
    /// consumer when the list is the destination). Resolved — and cleared —
    /// in viewWillDraw() below.
    var pendingScrollFilmID: UUID?
    /// Pending post-layout scroll ORIGIN restore for the maintainScrollPositionOnViewSwitch
    /// feature, armed by GallerySubview.updateNSView's view-switch reload branch and
    /// resolved — and cleared — in viewWillDraw() below, exactly like pendingScrollFilmID.
    /// Mutually exclusive with pendingScrollFilmID by construction (updateNSView only arms
    /// this when no film target is pending); should both ever be set, the film target wins
    /// and the superseded origin is discarded when it resolves.
    var pendingScrollPosition: GalleryScrollPosition?
    /// Pending keyboard-focus claim, transferred here from GalleryFocusIntent by
    /// GallerySubview.makeNSView (DraggableListView.makeNSView is the list-style
    /// consumer). Honored — and cleared — in viewWillDraw() below, the first hook that
    /// runs with the view in a window, which is what makeFirstResponder needs.
    var pendingKeyboardFocus = false
    /// Weak back-reference to the Coordinator so viewWillDraw() can reach filmIndexMap,
    /// isFilmVisible(at:), and scrollToTopRow(at:). Wired in makeNSView.
    weak var galleryCoordinator: GallerySubview.Coordinator?

    override func layout() {
        // Sampling point for the live-resize profiler (99.25). Inert unless the app was
        // launched with -FTDebugLiveResize; compiled out entirely in release.
        #if DEBUG
        DebugLiveResizeProfiler.shared.beginPass(width: bounds.width)
        #endif
        // Disable implicit Core Animation transitions for this layout pass.
        // Without this, CA interpolates between old and new item frames during
        // resize, creating visible pulsation when resizing slowly.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        super.layout()
        CATransaction.commit()

        // After the layout pass completes, apply any pending scroll correction
        // computed by the layout's viewport anchoring. This must happen after
        // super.layout() so that prepare() has already run and calculated the
        // correction from the new layout state.
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

    /// Resolves any pending scroll — a film-target handoff or a saved-origin restore —
    /// immediately before the view is drawn.
    ///
    /// viewWillDraw is the correct hook for this: AppKit invokes it during the display
    /// phase of the cycle, AFTER layout of the entire view hierarchy has completed
    /// (so the grid layout has real geometry) and BEFORE any drawing — so the bounds
    /// origin set here is what reaches the compositor in this very frame. The first
    /// frame ever painted for this view is already scrolled to the target: no
    /// interstitial y=0 frame, no flicker, and no need to hide the collection view.
    ///
    /// (Resolving in layout() does not work: the scroll view's layout() runs before its
    /// descendants lay out, so item attributes are still nil there, and no further
    /// scroll-view layout pass is guaranteed. Deferring via DispatchQueue.main.async
    /// works but paints one-or-more pre-scroll frames first, producing visible flicker.
    /// viewWillDraw avoids both failure modes, and because it runs before every draw,
    /// resolution is retried automatically until geometry is available.)
    override func viewWillDraw() {
        super.viewWillDraw()

        // Film-target resolution takes precedence. When a film handoff is pending, any
        // armed origin restore is stale by definition — updateNSView never arms one
        // while a film target is pending, so both being set can only mean the origin
        // came from an earlier, superseded pass — and it is discarded when the film
        // target resolves (see resolvePendingFilmTarget).
        if pendingScrollFilmID != nil {
            resolvePendingFilmTarget()
        } else if pendingScrollPosition != nil {
            resolvePendingOriginRestore()
        }

        resolvePendingKeyboardFocus()
    }

    /// Keyboard-focus claim for the search-exit handoff (see GalleryFocusIntent in
    /// ViewState.swift). Independent of the scroll resolution above: it needs no
    /// geometry, only a window, and must land whether or not a scroll was armed.
    ///
    /// The makeFirstResponder call is deferred one turn rather than made inside the
    /// display pass: becoming first responder reconfigures the selected items' highlight,
    /// and that belongs in an ordinary update, not mid-draw. One frame is invisible.
    /// The collection view already carries the preserved selection by now (the mount's
    /// syncSelectionToView ran against it), so its becomeFirstResponder sees a selection
    /// and does not seed item 0.
    private func resolvePendingKeyboardFocus() {
        guard pendingKeyboardFocus, let window = unsafe window, let target = documentView else { return }
        pendingKeyboardFocus = false
        DispatchQueue.main.async { [weak window, weak target] in
            guard let window, let target, unsafe target.window === window else { return }
            window.makeFirstResponder(target)
        }
    }

    /// Film-target resolution for every scroll handoff (see GalleryScrollIntent in
    /// ViewState.swift for the producers). The film's row goes to the top of the viewport,
    /// as far as the content allows — the same placement as Cmd+L — whether or not the
    /// film was already visible: a film left where it happened to land could be cut off at
    /// the viewport's bottom edge.
    private func resolvePendingFilmTarget() {
        guard let filmID = pendingScrollFilmID else { return }
        guard bounds.width > 0, documentVisibleRect.height > 0,
              let coordinator = galleryCoordinator else { return }

        guard let index = coordinator.filmIndexMap[filmID] else {
            // Film no longer present in this view's data — drop the stale target.
            pendingScrollFilmID = nil
            return
        }

        let indexPath = IndexPath(item: index, section: 0)
        guard let cv = documentView as? NSCollectionView,
              let layout = cv.collectionViewLayout as? SmoothResizingGridLayout,
              layout.layoutAttributesForItem(at: indexPath) != nil else {
            // Geometry not ready yet — viewWillDraw fires again on the next display
            // pass, so the target is retained and retried automatically.
            return
        }

        pendingScrollFilmID = nil
        // Discard any superseded origin restore (see viewWillDraw's precedence note),
        // both the copy armed here and the intent it was armed from — otherwise the
        // intent would simply be re-armed on the next update pass and fight this scroll.
        pendingScrollPosition = nil
        ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)

        coordinator.scrollToTopRow(at: indexPath)
        Self.log("Scroll handoff resolved pre-draw: film \(filmID) → index \(index)")
    }

    /// Applies an armed origin restore immediately, if geometry already allows it.
    ///
    /// Called synchronously from updateNSView right after arming, because viewWillDraw
    /// CANNOT be relied upon here. In a layer-backed hierarchy AppKit only sends
    /// viewWillDraw to views whose own layer needs display. On a fresh mount the whole
    /// hierarchy is dirty, so this scroll view gets one and the pre-draw resolution works
    /// — which is why the cross-view restore and the film handoffs have always behaved.
    /// On a REUSED gallery, a sub-tab switch dirties the collection view and its items but
    /// never the scroll view itself, so no viewWillDraw arrives, and an origin armed there
    /// sat untouched forever. That is the whole of the sub-tab bug.
    ///
    /// If geometry is not ready yet this is a no-op and the origin stays armed, so the
    /// viewWillDraw path still serves as the retry for the fresh-mount case.
    func applyPendingOriginRestoreIfPossible() {
        resolvePendingOriginRestore()
    }

    /// Applies an armed film target immediately, if geometry already allows it.
    ///
    /// The film-target counterpart of applyPendingOriginRestoreIfPossible(), and it exists
    /// for exactly the same reason: on a REUSED gallery — a smart-list sub-variant switch,
    /// where the enclosing GalleryView keeps its `.id` — the reload dirties the collection
    /// view and its items but never this scroll view's own layer, so AppKit sends no
    /// viewWillDraw and a target armed there would sit untouched forever. The fresh-mount
    /// producers are unaffected and continue to resolve pre-draw as before.
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
            // Geometry not ready yet — viewWillDraw fires again on the next display
            // pass, so the origin is retained and retried automatically (matching
            // resolvePendingFilmTarget's guard-and-retry pattern).
            return
        }

        pendingScrollPosition = nil
        // Retire the intent now that it has genuinely been applied against real geometry.
        // Until this point it stays live in ViewStateManager on purpose, so a reload that
        // lands between arming and resolution re-arms it rather than losing it.
        ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)

        let target = applyClampedOrigin(CGPoint(x: 0, y: coordinator.restoreY(for: position)),
                                        layout: layout)
        Self.log("Saved scroll origin restored pre-draw: \(target)")
    }

    /// Moves the viewport to `origin`, clamped to the current valid scroll range: the
    /// view's content may have shrunk since the origin was saved (films deleted, filters
    /// changed before returning), and an out-of-range origin would leave the viewport in
    /// over-scrolled blank space. Same clamping arithmetic as scrollToTopRow.
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

/// StatusBar overlay height, used for bottom inset calculations.
/// Hoisted to file scope so it isn't re-declared on every updateNSView pass.
private let kStatusBarHeight: CGFloat = 29

// NOTE: no local grid-padding constant here. One existed (`kGridPadding = 16`),
// documented as "matches SmoothResizingGridLayout.edgeInset / lineSpacing" — a
// hand-maintained restatement of a value the layout already owns, which would have
// silently desynchronized the scroll math from the actual grid geometry the moment
// either was changed. Both scroll helpers below already hold the live layout, so they
// read `layout.lineSpacing` from it directly instead.

/// Reusable cell identifier for GalleryItem, allocated once rather than on every register/dequeue call.
private let kGalleryItemID = NSUserInterfaceItemIdentifier("GalleryItem")

struct GallerySubview: NSViewRepresentable, Loggable {
    nonisolated static let logTag = "[GallerySubview]"

    // NOTE: no `forceReloadID` any more. GalleryView bumped one on every film event, but
    // nothing here decided anything from it: reloads are decided from the films alone (see
    // needsReload in updateNSView), so its only effect was an update pass, and the pass was
    // needed only when the films had changed too — which schedules one by itself.
    /// A post-edit "keep this film in view" request from GalleryView. One-shot: the
    /// Coordinator acts on a given request once and ignores it on every later pass, so
    /// GalleryView never has to clear it (which cost a second full update pass per edit).
    let scrollRequest: FilmScrollRequest?
    /// The active ViewIdentifier from ViewStateManager, passed at each update so the
    /// Coordinator can authoritatively detect view switches without probabilistic sampling.
    let activeViewID: ViewIdentifier
    /// Built once per active view by GalleryView and passed down directly (rather than through
    /// the SwiftUI environment) -- GalleryItem's tile content is now pure AppKit, with no
    /// SwiftUI environment to inherit it from. The Coordinator stores this and forwards it to
    /// GalleryItem.configure(with:subtitleProvider:) on every cell (re)configuration.
    let subtitleProvider: GallerySubtitleProvider?
    /// This view's section-dividers setting, read by GalleryView from the state of the
    /// films on screen (ViewStateManager.displayedGalleryState) and passed down. Was an
    /// @AppStorage read of a single global preference here; it is now per-view state, taken
    /// from the same state GalleryView chooses the grid/list style from, so the two cannot
    /// describe different Film Queue tabs (see the note at its read in GalleryView). A
    /// change arrives as a genuine value change on the representable, which schedules the
    /// updateNSView pass that pushes it onto the Coordinator and adds or removes the bands in
    /// place.
    let showSectionDividers: Bool

    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(SelectionState.self) private var selectionState
    // Observe StatusBar preference to calculate bottom padding.
    @AppStorage(preference: Preferences.showStatusBarKey) private var showStatusBar: Bool
    // Observe large gallery grid preference to set the column maximum.
    // false → 7 columns max; true → 6 columns max.
    @AppStorage(preference: Preferences.largeGalleryGridKey) private var largeGalleryGrid: Bool
    // NOTE: maintainScrollPositionOnViewSwitch is deliberately NOT read here any more.
    // ViewStateManager.prepareScrollHandoff is now the single gate for the feature: it
    // consults the preference at the moment of each switch and simply arms nothing when
    // the preference is off, so this layer has no decision left to make. Keeping a second
    // reader here could only ever let the two disagree.

    func makeNSView(context: Context) -> NSScrollView {
        #if DEBUG
        ViewSwitchProbe.record("grid.make \(activeViewID) films=\(dataCoordinator.films.count)")
        #endif
        let scrollView = WidthObservingScrollView()
        configureScrollView(scrollView)

        let collectionView = GalleryCollectionView()
        configureCollectionView(collectionView)

        let layout = SmoothResizingGridLayout()
        // edgeInset / itemSpacing / lineSpacing are `let` constants on the layout and are
        // no longer assigned here: the three assignments this line replaces set them to
        // exactly the values they already defaulted to, which implied a configurability
        // that never existed. Only the genuinely variable properties are set below.
        // Reserve space for StatusBar when visible
        layout.bottomInset = showStatusBar ? kStatusBarHeight : 0
        layout.hasSubtitles = subtitleProvider != nil
        // Apply column maximum from preference: false → 7 (default), true → 6 (large grid).
        layout.maxColumns = largeGalleryGrid ? Preferences.galleryMaxColumnsLargeGrid
                                             : Preferences.galleryMaxColumns
        collectionView.collectionViewLayout = layout

        collectionView.register(GalleryItem.self,
            forItemWithIdentifier: kGalleryItemID)

        // Register the section-divider decoration view. AppKit creates and
        // recycles instances of this class itself, positioned per the frames the layout returns
        // from layoutAttributesForDecorationView(ofKind:at:). Registering it here is inert for
        // every other gallery view: those views never publish section breaks, so the layout
        // produces zero divider rows and this decoration is never instantiated or positioned.
        layout.register(SectionDividerDecorationView.self,
            forDecorationViewOfKind: sectionDividerDecorationKind)
        // The "Up Next" placeholder slots — instantiated only on the Film Queue's "All" tab,
        // the one place the layout is given a slot run (see updateSectionDividers).
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

        // Arm the warming-scoped scroll prefetch (no-op if the startup population
        // pipeline has already finished — see the Coordinator's "Warming-Scoped
        // Scroll Prefetch" section).
        coordinator.installWarmingScrollPrefetch(on: scrollView)
        #if DEBUG
        coordinator.installViewportJumpTracer(on: scrollView)
        #endif

        // Keep this view's saved scroll origin current as the user scrolls (see the
        // method's doc comment for why the teardown-time save alone is not sufficient).
        collectionView.onUserViewportInteraction = { [weak coordinator] in
            coordinator?.claimViewportForUser()
        }
        coordinator.installScrollOriginRecorder(on: scrollView)

        // Wire up callbacks (layout is self-computing — no onWidthChange needed).
        collectionView.onMarqueeSelectionChanged = { [weak coordinator] in coordinator?.handleMarqueeSelection($0) }
        collectionView.onArrowNavigation = { [weak coordinator] in coordinator?.handleArrowKey($0, withShift: $1, isRepeat: $2) }
        // Gated on the same capability KeyboardManager and the MenuBar's Select All apply.
        // In a view that supports it, KeyboardManager consumes Cmd+A before it gets here;
        // in one that does not, it passes the key through and the menu item is disabled,
        // so this is the only gate left — without it, Cmd+A selected every film in Recents,
        // Unwatched and the Film Queue.
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
        // Seed cursor at item 0 when focus arrives via Tab or programmatic transfer with
        // no existing selection. This replicates the native NSCollectionView behavior
        // that applies during Tab-chain-initiated focus, enabling immediate arrow-key
        // navigation without requiring a prior mouse-click selection.
        collectionView.onKeyboardFocusWithNoSelection = { [weak coordinator] in coordinator?.seedInitialCursor() }
        // Secondary-click contextual menu. GalleryCollectionView.menu(for:) has already
        // established that the click landed on a real item before this runs.
        collectionView.getContextMenu = { [weak coordinator] in coordinator?.contextMenu(forItemAt: $0) }

        // MARK: Scroll-Position Handoff (Search Exit / Grid⟷List Toggle)
        //
        // If a scroll intent is pending AND addressed to this view's activeViewID
        // (the targeting prevents a stale, still-mounted search-view instance from
        // consuming it — see GalleryScrollIntent in ViewState.swift):
        //
        // 1. Preload the destination view's films into the coordinator and reloadData().
        //    The first updateNSView pass then computes needsReload = false (identical
        //    films, matching view identity), so no second reloadData() — which
        //    unconditionally resets scroll to y=0 — fires after the scroll is performed.
        //    dataCoordinator.films already holds the destination view's films here:
        //    MainView calls switchToViewSync(destination) before flipping
        //    selectedSidebarItem, and GalleryView only instantiates GallerySubview
        //    after the `!dataCoordinator.films.isEmpty` guard passes.
        //
        // 2. Transfer the film ID onto the scroll view. The scroll itself runs in
        //    WidthObservingScrollView.viewWillDraw() — after the full hierarchy has
        //    laid out with real geometry, immediately before the first frame is
        //    painted — so the gallery's first visible frame is already positioned at
        //    the selected film. No hiding, no deferral, no interstitial frames.
        scrollView.galleryCoordinator = coordinator
        // A request already standing when this gallery mounts belongs to an edit some
        // earlier instance handled; seeding it keeps this one from acting on it again.
        coordinator.lastScrollRequest = scrollRequest

        // Register this coordinator as the source of "what's on top" for the active
        // view — read by ViewStateManager.updateListViewStyle when the grid⟷list toggle
        // is about to switch AWAY from the grid. See registerScrollPositionProvider's
        // doc comment; unregistered in dismantleNSView below.
        ViewStateManager.shared.registerScrollPositionProvider(coordinator)

        // Consume a pending scroll intent addressed to this view — the search-exit handoff
        // or the grid⟷list view-style toggle handoff; both share the identical preload
        // sequence below. Each producer has already applied its own gating (see the note at
        // the top of this file).
        if let filmID = GalleryScrollIntent.shared.consume(ifTargeting: activeViewID) {
            coordinator.films = dataCoordinator.films
            // This preload path bypasses the normal updateNSView reload branch entirely
            // (it seeds coordinator.films and the view identities directly so the very next
            // updateNSView pass sees no change and skips its own reload — which would
            // reset scroll to y=0 a second time, after this arming has already taken
            // effect), which means it must also perform the section-divider recomputation
            // that branch would otherwise have done. Without this, a fresh Film Queue
            // instance created via search-exit scroll handoff would reload with the
            // layout's default empty sectionBreaks and show no dividers until some
            // unrelated later reload happened to fire. The call is correct on this path
            // without any further seeding: it derives everything it needs from
            // dataCoordinator, whose view identity and Film Queue filter are already those
            // of the destination (switchToViewSync ran before this mount — see the
            // dataCoordinator.films note above). (This path CAN now reach the Film
            // Queue, whose view-style toggle is no longer disabled, so this call genuinely
            // does the divider work on that path too rather than being a guarded no-op.)
            //
            // currentViewID is nonetheless set from activeViewID here (it is normally only
            // assigned in updateNSView) so that it and prevViewID, seeded together just
            // below, agree with the data this preload installed.
            //
            // prevViewID is also seeded to activeViewID here (not just currentViewID).
            // Without this it stays nil — its "nothing rendered yet" default — so the very
            // next updateNSView pass finds isLikelyViewSwitch() == true even though this
            // preload just loaded the correct, current data, triggering a second, fully
            // redundant reloadData() + selection clear/resync on top of the one just
            // performed above. It would also let that pass arm an origin restore on top of
            // the film handoff this path exists to serve. Seeding both fields here keeps
            // the two in sync, exactly as updateNSView's own reload branch does when it
            // advances prevViewID.
            coordinator.currentViewID = activeViewID
            coordinator.prevViewID = activeViewID
            // The preloaded films were built with dataCoordinator's loaded Queue filter;
            // seeding it keeps displayedScrollKey describing them from the start (and the
            // first pass's filter-change test reads it as unchanged, which it is).
            coordinator.lastFilmQueueFilter = dataCoordinator.loadedFilmQueueFilter
            coordinator.updateSectionDividers()
            coordinator.withSuppressedCallbacks {
                collectionView.reloadData()
            }
            scrollView.pendingScrollFilmID = filmID
            // This path deliberately bypasses updateNSView's reload branch, which is where
            // an origin restore would otherwise be picked up. The film handoff outranks it,
            // so retire the intent here rather than leaving it to be armed by a later pass
            // and fight the scroll this path exists to perform.
            ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)
            Self.log("Scroll handoff armed in makeNSView for film \(filmID) (view: \(activeViewID))")
        } else {
            // No film handoff claims this mount, so a saved origin may. Preserves the
            // coverage the old fresh-mount-reads-as-a-transition behavior provided for
            // arrivals that switchToViewSync does not see as a change — see
            // armScrollOriginRestoreOnMount. Subordinate to any in-flight switch intent,
            // and the restore itself is still performed by updateNSView's reload branch
            // once the destination's films are actually in place.
            ViewStateManager.shared.armScrollOriginRestoreOnMount(
                for: GalleryScrollKey(viewID: activeViewID,
                                      subTab: dataCoordinator.loadedFilmQueueFilter?.rawValue))
        }

        // Outside the scroll-handoff branch on purpose: the two intents are independent.
        // See GalleryFocusIntent.
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
        // Pinned to overlay scrollers, matching DraggableListView.makeNSView. Not cosmetic:
        // SmoothResizingGridLayout.prepare() derives the whole grid's width from
        // `cv.enclosingScrollView?.bounds.width` and publishes it as
        // collectionViewContentSize.width. Under overlay scrollers the clip view spans the
        // scroll view's full width, so the two agree. Under LEGACY scrollers (System
        // Settings ▸ Appearance ▸ Show scroll bars: Always) AppKit reserves the scroller's
        // width from the clip view, so the layout would lay a grid out ~15pt wider than the
        // visible area — and with hasHorizontalScroller off, that surplus is simply clipped
        // off the trailing column, with no way to scroll to it. Forcing overlay keeps the
        // layout's single width source correct in both system settings.
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
        // Must precede every updateSectionDividers() call in this pass — the bands it
        // computes are gated on it.
        coordinator.showSortingSections = showSectionDividers
        // Pass the current view identity so the Coordinator can detect genuine view switches.
        coordinator.currentViewID = activeViewID

        // Calculate StatusBar inset once and reuse
        let bottomInset: CGFloat = showStatusBar ? kStatusBarHeight : 0
        
        coordinator.isStatusBarVisible = showStatusBar

        // Update scroll view's scroller insets to prevent scrollbar from hiding behind StatusBar
        if scrollView.scrollerInsets.bottom != bottomInset {
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }

        // Batch all layout mutations into a single cast.
        // Calling invalidateLayout() once after all changes prevents multiple redundant
        // layout passes when more than one property changes simultaneously (e.g. on first
        // updateNSView after a view switch where subtitle provider and grid size both differ).
        let previousKind = coordinator.subtitleProvider?.kind
        let hadProvider = previousKind != nil
        let hasProvider = subtitleProvider != nil
        // Presence change — the only thing the LAYOUT cares about, since it only
        // needs to know whether to reserve a subtitle line's height.
        let providerChanged = hadProvider != hasProvider
        // Kind change — what the CELLS care about. A Recents sub-tab switch swaps
        // one non-nil provider for another, so `providerChanged` above is false
        // for it while every cell's text is nonetheless now wrong. Compared on
        // `GallerySubtitleProvider.kind` because a closure has no identity of its
        // own; see that property's doc comment.
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

        // First update - clear any stale selection from previous view
        if !coordinator.hasCompletedFirstUpdate {
            coordinator.hasCompletedFirstUpdate = true
            Self.log("First update - clearing NSCollectionView selection")
            coordinator.withSuppressedCallbacks { collectionView.selectionIndexPaths = [] }
        }

        // Stale-pass guard. This method reads dataCoordinator.films, so SwiftUI also runs
        // it when the films change on their own — carrying the stored properties of the
        // LAST body pass, activeViewID included. After a view switch that is a pass in
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

        // Style guard, for a Film Queue tab switch between tabs of different styles. The
        // incoming tab's films and its style land in the same update, but SwiftUI can run
        // this outgoing gallery's pass first, and reloading here put the incoming films on
        // screen in the outgoing style for a committed frame. A gallery whose style is not
        // the one GalleryView presents for the loaded films is about to be removed, so the
        // pass is skipped. Same function GalleryView decides with, so the two cannot differ.
        if case .filmQueue = activeViewID,
           ViewStateManager.shared.displayedGalleryState(
               loadedQueueFilter: dataCoordinator.loadedFilmQueueFilter).isListView {
            return
        }

        let newFilms = dataCoordinator.films

        // MARK: Launch Pre-Paint Warm Registration
        // One-shot per session (needsLaunchWarm gates the O(N) map so this is a single
        // Bool read on every later pass): hands PosterCache the launch view's display
        // order BEFORE the first reloadData below, triggering the synchronous parallel
        // pre-paint warm of the leading posters and registering the full ordering as
        // the background restore's priority hint. This is what guarantees the very
        // first cells configured find their images already resident — with no serial
        // per-cell main-thread disk decode — and that background population proceeds
        // top-of-grid first. See PosterCache.registerLaunchDisplayOrder.
        if PosterCache.shared.needsLaunchWarm, !newFilms.isEmpty {
            PosterCache.shared.registerLaunchDisplayOrder(newFilms.map(\.posterUID))
        }
        if !newFilms.isEmpty { LaunchReveal.shared.galleryWillAppear(scrollView) }

        // Early exit if both empty
        guard !newFilms.isEmpty || !coordinator.films.isEmpty else {
            coordinator.syncSelectionToView()
            return
        }

        // Check if reload is needed:
        // 1. View identity changed since the last reload (see viewIdentityChanged below)
        // 2. Count changed (view switch or filter change)
        // 3. First/last film changed (different view or major sort change)
        // 4. Interior reorder with stable endpoints (ambiguous-case fallback, below)

        // Identity-based signal, independent of film-content heuristics: currentViewID was
        // just set to activeViewID above, and prevViewID is only ever advanced inside the
        // reload branch below, so a mismatch here means the active view has changed since
        // the last time this Coordinator actually reloaded — even in the (rare, but possible)
        // case where the new view's film count and first/last IDs coincidentally match the
        // old one's, which the content-based heuristics below cannot detect on their own.
        let viewIdentityChanged = coordinator.isLikelyViewSwitch()

        // The Film Queue's segmented filter narrows/widens the SAME view (currentViewID
        // stays .filmQueue throughout), so viewIdentityChanged above can never detect a
        // switch between "All" and a single section. Left undetected, such a switch would
        // fall through to the same-view reload path below, which preserves scroll position
        // instead of zeroing it first — and, because "All" is the literal union of every
        // section, the previously-visible cells belonging to the now-excluded sections would
        // still be on screen (at the preserved scroll position) for the one frame between
        // reloadData() being called and the new, narrower layout actually committing.
        //
        // Compared against dataCoordinator.loadedFilmQueueFilter — the filter the films
        // handed to this pass were actually produced with — and NOT against
        // FilmQueueFilterState.shared.selectedFilter, which is the live intent. The
        // distinction is the whole fix for the All → single-section flicker: the live filter
        // flips synchronously inside selectFilter while the narrowed film set only arrives
        // with the deferred reload that follows, so any update pass landing in that window
        // used to see "filter changed" while `dataCoordinator.films` still held the full
        // union. It then took the reload branch below with STALE films — zeroing the scroll,
        // clearing the dividers, and calling reloadData() — which is precisely the one frame
        // of un-dividered "All" content the user sees, and it also consumed the signal so
        // the genuine, narrowed pass that followed no longer received view-switch treatment.
        // Keying on the loaded filter makes this fire exactly once, on the pass that actually
        // installs the new film set, so the stale pass in between becomes a true no-op.
        //
        // A nil last-seen value means "no Film Queue film set has been observed by this
        // Coordinator yet" and never counts as a change: a fresh mount's transition is
        // already covered by viewIdentityChanged above, and reporting a filter change there
        // would additionally discard a scroll handoff armed by makeNSView. The value is reset
        // to nil whenever a non-Queue film set is displayed so that returning to the Queue is
        // treated as that same first observation rather than compared against a stale section.
        // The key of what was on screen before this pass, captured before the filter below
        // is advanced. Only the outgoing-origin save reads it.
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

        // When the count and both endpoints match, the cheap heuristics above cannot tell
        // whether the interior order changed — e.g. switching between two sort options that
        // share the same first and last film (Date Added ⇄ Date Modified when the newest and
        // oldest films coincide under both orderings). A sort change routes through
        // loadFilms() (which reassigns dataCoordinator.films but emits no event), so without
        // this check the reordered interior would never be
        // drawn and the gallery would keep displaying the prior order.
        //
        // The O(N) ordered-ID scan is only reached in this ambiguous branch and is negligible
        // next to the reloadData() it gates. On a genuine no-op re-render (identical order —
        // e.g. a status-bar toggle) it returns false, preserving the existing skip-reload
        // behavior. Identity comparison on FilmSnapshot value types only; no managed-object access.
        //
        // `==` first: Array equality is O(1) when the buffers are identical, which is every
        // pass where dataCoordinator.films was not reassigned (selection, status-bar toggle,
        // dividers setting), so the O(N) ID walk is only reached after a real reload.
        //
        // A film edit or a smart-list recalculation is held to the same test rather than
        // reloading unconditionally: when the ID sequence survived, the edit changed only
        // what the tiles show, and the in-place branch below reconfigures
        // them without the reloadData() that rebuilt every visible tile and reset the scroll.
        let structuralChange = viewIdentityChanged || countChanged || firstOrLastChanged ||
                               filmQueueFilterChanged
        let interiorReordered =
            !structuralChange && !newFilms.isEmpty && coordinator.films != newFilms &&
            !coordinator.films.elementsEqual(newFilms) { $0.id == $1.id }

        let needsReload = structuralChange || interiorReordered

        // The request is acted on by whichever branch below runs on this pass, and only on
        // this pass — see `scrollRequest`.
        let scrollToFilmID: UUID?
        if let scrollRequest, scrollRequest != coordinator.lastScrollRequest {
            scrollToFilmID = scrollRequest.filmID
        } else {
            scrollToFilmID = nil
        }
        coordinator.lastScrollRequest = scrollRequest

        if needsReload {
            // isViewSwitch reuses the identity signal computed above, OR'd with the
            // Film-Queue-filter signal — prevViewID has not been advanced since, so the
            // comparison still reflects the transition. Treating a Film Queue filter change
            // as a view switch here means it gets the same scroll-to-zero-before-reload
            // treatment below, preventing the now-excluded sections' cells from remaining
            // visible for a frame at the old scroll position (see filmQueueFilterChanged's
            // doc comment above for the full rationale).
            let isViewSwitch = viewIdentityChanged || filmQueueFilterChanged

            // Record the OUTGOING view's scroll position before the scroll-to-zero and
            // reloadData() below destroy it.
            //
            // dismantleNSView only covers transitions that tear this gallery down. A large
            // family of view changes does not: every Recents sub-tab, every Unwatched tab,
            // and every smart-list variant (rotation, purchased/unpurchased format,
            // alternate versions, filtered-library sorting) keeps the enclosing
            // GalleryView's .id unchanged, so the SAME GallerySubview is reused and only
            // its activeViewID changes. For all of those, the outgoing view's position was
            // never saved at all — the preference silently did nothing — while the
            // incoming view's stale origin was still restored, which is the asymmetry this
            // closes.
            //
            // The save is unconditional in value, y == 0 included. Recording a return to
            // the top is exactly as important as recording a deep offset: leaving the
            // previous (deeper) entry in place is what made a view the user had
            // deliberately scrolled back to the top reopen far down the grid.
            //
            // Gated on viewIdentityChanged rather than isViewSwitch: a Film Queue filter
            // change reports isViewSwitch to get the same flicker-free zero-then-reload
            // treatment, but currentViewID is still .filmQueue, so saving there would file
            // one section's position under the key shared by all of them. Gated on a
            // non-nil prevViewID so a first pass — which has no previously displayed view
            // — cannot file this mount's synthetic zero against an unrelated view.
            if viewIdentityChanged, let outgoingViewID = coordinator.prevViewID {
                ViewStateManager.shared.saveScrollPosition(
                    coordinator.scrollPosition(of: scrollView),
                    under: GalleryScrollKey(viewID: outgoingViewID, subTab: outgoingQueueFilter?.rawValue))
            }

            // A same-view reload that empties the grid is about to take it off screen:
            // GalleryView shows a placeholder instead, dismantling this gallery, and the
            // next film to arrive mounts a fresh one that restores this view's banked
            // origin. Bank the position the user is leaving now, while this pass can vouch
            // for its key. dismantleNSView cannot record the top (see its y > 0 note), and
            // a scroll back to the top by wheel or keyboard posts no live-scroll end, so
            // the remount used to restore whatever deeper position was banked before.
            if !isViewSwitch && newFilms.isEmpty {
                ViewStateManager.shared.saveScrollPosition(coordinator.scrollPosition(of: scrollView),
                                                           under: coordinator.displayedScrollKey)
            }

            // Advance prevViewID now that we've consumed the transition.
            coordinator.prevViewID = coordinator.currentViewID

            // For view switches, zero the scroll position before reloading to prevent flicker.
            // For same-view reloads (e.g. film edits), capture the current origin so it can be
            // restored after reloadData() — NSCollectionView.reloadData() resets the scroll
            // position to zero unconditionally, which would otherwise throw the user to the top
            // of the gallery whenever a film is saved, even if its sorted position did not change.
            let savedScrollOrigin: CGPoint?

            // NOTE: No scroll-intent consumption here — deliberately.
            //
            // Every destination in MainContentSwitcher carries a distinct stable .id,
            // so a search exit ALWAYS instantiates a fresh GalleryView → fresh
            // GallerySubview → makeNSView, which is the sole legitimate consumer of
            // GalleryScrollIntent. A "reuse path" consumption here is not only
            // unnecessary, it is actively harmful: during the exit transition the
            // still-mounted SEARCH instance re-renders one final time (the destination
            // pre-load changes dataCoordinator.films), and that render passes the
            // ALREADY-PROMOTED activeViewID into this updateNSView — so the doomed
            // instance's currentViewID matches the intent's target, it consumes the
            // intent, arms the scroll on a scroll view about to be dismantled, and
            // the real destination's makeNSView finds nothing. This was confirmed in
            // live logs ("armed in updateNSView (reuse path)" emitted by the search
            // instance on every non-All-Films exit; All Films escaped only because
            // its film set coincidentally matches the post-clear search set, keeping
            // needsReload false on the stale instance). Leaving the intent untouched
            // here lets it survive to the destination's makeNSView in all views.

            if isViewSwitch {
                // Discard any origin restore armed by an earlier pass that this transition
                // supersedes. Without this, rapidly switching sub-tabs (A → B → C) before
                // the pending restore for B has had a chance to resolve would leave B's
                // origin armed on this same, reused scroll view, where it would then
                // resolve against C's content. The restore branch below re-arms this for
                // the incoming view when one is genuinely available.
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
            // Recompute the section-divider breaks from the new films and push them to the
            // layout BEFORE reloadData(), so the relayout reloadData() triggers already sees
            // current, correct breaks rather than stale ones. Where no bands apply this is a
            // guarded no-op (it only ever clears already-empty breaks).
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

            // Decide how to handle scroll position after the reload.
            // Priority order:
            //   0. Reuse-path film handoff — "Show in List" redirect to a sub-variant.
            //   1. scrollToFilmID   — intentional post-edit reposition.
            //   2. Saved origin     — view-switch restore (maintainScrollPositionOnViewSwitch).
            //   3. Same-view origin — restore pre-reload viewport for in-place edits.
            //
            // Search-exit scroll is handled in makeNSView and does not appear here.
            if let handoffFilmID = GalleryScrollIntent.shared.consumeOnReuse(ifTargeting: coordinator.currentViewID) {
                // Priority 0 — a reuse-path film handoff, which by construction can only be
                // a ShowInListNavigation redirection to a smart-list sub-variant of the
                // parent already on screen (see GalleryScrollIntent.consumableOnReuse for
                // why no other producer may take this branch, and why the doomed-instance
                // hazard documented above cannot arise here: the one mounted gallery IS the
                // destination, and no fresh makeNSView will ever run to claim the intent).
                //
                // Outranks both the saved-origin restore and any same-view origin, so the
                // intent for this view is retired and the armed origin discarded before the
                // target is placed.
                ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)
                coordinator.scrollView?.pendingScrollPosition = nil
                coordinator.scrollView?.pendingScrollFilmID = handoffFilmID
                // Force the collection view to lay out against the films just installed, so
                // layoutAttributesForItem is available and the target resolves within this
                // very update pass — before the first post-reload frame is painted, leaving
                // no interstitial y=0 frame. If layout still isn't ready the target simply
                // stays armed and viewWillDraw retries it.
                collectionView.layoutSubtreeIfNeeded()
                coordinator.scrollView?.applyPendingFilmTargetIfPossible()
                Self.log("Scroll handoff armed on reuse path for film \(handoffFilmID) (view: \(coordinator.currentViewID))")

            } else if let filmID = scrollToFilmID,
               let index = coordinator.filmIndexMap[filmID] {

                Self.log("Checking scroll for film \(filmID): newIndex=\(index)")

                // An explicit post-edit reposition outranks a saved-origin restore, so
                // retire any intent addressed to this view rather than leaving it live to
                // be armed by a later pass and undo the placement performed just below.
                ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)

                // Step 1 — Restore the pre-reload scroll origin (or leave at zero for view
                // switches where savedScrollOrigin is nil). This undoes the unconditional
                // scroll-to-zero that NSCollectionView.reloadData() applies internally.
                if let origin = savedScrollOrigin {
                    appViewportMove {
                        scrollView.contentView.setBoundsOrigin(origin)
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                    }
                }

                // Step 2 — Check whether the film is visible in the now-restored viewport.
                // If it is, the user can already see it and no further scrolling is needed.
                // If it is not visible (it moved out of view due to a sort-key change), scroll
                // to place it in the top row so it remains in focus.
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
                // Priority 2 — Restore this view's saved scroll origin
                // (maintainScrollPositionOnViewSwitch).
                //
                // Note what this branch no longer tests: `isViewSwitch`. It used to, and
                // that is precisely what broke the preference for a view's own sub-tabs.
                // `isViewSwitch` is true only on the pass that CONSUMES the prevViewID →
                // currentViewID transition, but on a sub-tab switch the enclosing
                // GalleryView keeps its .id, so this same Coordinator is reused and the
                // pass that consumes the transition need not be the pass that finally
                // reloads with the destination's films. Whenever those separated, the
                // restore was armed on a pass with nothing to restore against, or not
                // armed at all, and the grid stayed where the pre-reload zeroing left it.
                //
                // The addressed intent removes the guesswork entirely: it is armed once,
                // authoritatively, by ViewStateManager at the moment of the switch, and it
                // stays live until a gallery displaying that exact view actually applies
                // it. So this branch fires on whichever pass performs the destination's
                // reload — first, third, or otherwise — and is inert on every other pass
                // because the intent is keyed to a view and retired on application.
                // The preference itself is checked at arming time, so no check is needed
                // here: nothing is ever armed while it is off.
                //
                // Armed on the scroll view, then applied by the explicit call below.
                // NOT left to WidthObservingScrollView.viewWillDraw() alone: AppKit only
                // sends viewWillDraw to a layer-backed view whose own layer needs display,
                // and a reused gallery's scroll view is never dirtied by a sub-tab reload
                // (the collection view and its items are). viewWillDraw remains the retry
                // path for a fresh mount, where geometry may not be ready during this pass.
                // Either way the origin lands before the first post-reload frame is
                // painted, so there is no interstitial y=0 frame.
                //
                // The pendingScrollFilmID == nil condition keeps the film-target
                // handoff authoritative: if makeNSView armed a scroll-to-film for this
                // same mount, the origin restore must not fight it.
                coordinator.scrollView?.pendingScrollPosition = restoredPosition
                Self.log("Scroll-origin restore armed for \(coordinator.currentViewID): \(restoredPosition.origin)")
                // Force the collection view to lay out against the films just installed,
                // then apply the origin now rather than waiting for a viewWillDraw that
                // will never arrive on a reused gallery (see
                // applyPendingOriginRestoreIfPossible). Done before this update pass
                // returns, so the first painted frame is already at the restored offset.
                collectionView.layoutSubtreeIfNeeded()
                coordinator.scrollView?.applyPendingOriginRestoreIfPossible()
            } else {
                // No scroll-to-film was requested (add/delete path, or filmID not in map).
                // Restore the pre-reload scroll origin to prevent an unintended jump to the top.
                // On a view switch this is a no-op because savedScrollOrigin is nil.
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
            // Same films in the same order, possibly with new content (an edited film's
            // poster, or a Recents date). Install them and reconfigure the cells that exist:
            // GalleryItem.configure diffs the film, poster, and subtitle, so only a tile
            // whose display actually changed is rebuilt. Cells created later read the
            // installed films through the data source.
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
                // Prepared cells just outside the viewport are kept by NSCollectionView and
                // are not re-requested when they scroll in, so any of them showing a film
                // that changed is reconfigured too.
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

            // A reuse-path film handoff is claimed here too, not only by the reload branch.
            // A Film Queue section move that leaves the film at the same index (the last Up
            // Next film moved to the head of Soon, say) changes no film order, so no reload
            // runs; the intent used to stay pending and was claimed by the next reload
            // instead — a later tab switch — which then threw away that tab's restore.
            if let handoffFilmID = GalleryScrollIntent.shared.consumeOnReuse(ifTargeting: coordinator.currentViewID) {
                ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)
                coordinator.scrollView?.pendingScrollPosition = nil
                coordinator.scrollView?.pendingScrollFilmID = handoffFilmID
                coordinator.scrollView?.applyPendingFilmTargetIfPossible()
                Self.log("Scroll handoff applied in place for film \(handoffFilmID) (view: \(coordinator.currentViewID))")
            }

            // The post-edit reposition, minus the origin restore the reload branch needs:
            // nothing reloaded, so the viewport is still where the user left it. A film
            // still on screen is left alone; one that is not is brought to the top row.
            if let filmID = scrollToFilmID, let index = coordinator.filmIndexMap[filmID] {
                ViewStateManager.shared.finishScrollOriginRestore(for: coordinator.displayedScrollKey)
                let indexPath = IndexPath(item: index, section: 0)
                if !coordinator.isFilmVisible(at: indexPath) {
                    coordinator.scrollToTopRow(at: indexPath)
                    Self.log("Film not visible after in-place update — scrolled to index \(index)")
                }
            }

            // No reload was judged necessary by the heuristics above, but the section-divider
            // breaks must still be reconciled against the CURRENT view, filter, and sort state
            // on every pass — not just when a reload happens to fire. This is also the only
            // path by which a change to this view's section-dividers setting reaches the
            // grid: ViewStateManager.updateShowSectionDividers deliberately passes
            // `reload: false`, because the setting changes nothing about the film set
            // itself, so no reload will fire for it and this pass is the whole mechanism. Without
            // this, a transient render pass with stale data (e.g. the brief window between a
            // fresh GalleryView's first body evaluation and its onAppear-triggered view-switch
            // completing) could compute breaks against the wrong view, and — if a later
            // genuine reload's content heuristics happened not to detect a change — those
            // stale breaks (or no breaks at all) would persist indefinitely. This call is a
            // guarded no-op in the common case: it only invalidates the layout when the
            // freshly computed breaks actually differ from what's already set, and it is a
            // trivial no-op entirely wherever no bands apply.
            coordinator.updateSectionDividers()

            // The subtitle KIND changed but the film-content heuristics found no
            // reason to reload — so every already-configured cell is still
            // displaying text resolved through the previous provider, and nothing
            // else in this pass will replace it.
            //
            // This is reachable whenever two views share a film set the heuristics
            // above cannot tell apart: same count, same first and last film, same
            // interior order. Two Recents categories can satisfy all three (a
            // small library where the same films, in the same order, are both the
            // most recently added and the most recently updated is the obvious
            // case, but any coincidence of ordering will do), and when they do,
            // the switch between them changes nothing except which date each tile
            // should be showing. Left unhandled, the previous category's dates
            // simply stayed on screen until something unrelated forced a reload.
            //
            // Reconfiguring rather than reloading is deliberate: the films, their
            // order, the scroll position, and the selection are all unchanged and
            // must stay that way, and `reloadData()` would reset the scroll origin
            // and force every cell to be rebuilt to change one label.
            // `GalleryItem.configure` compares the RESOLVED subtitle string, so a
            // cell whose text happens to be identical under both providers does no
            // work at all, and `visibleItems()` bounds the cost to what is on
            // screen — cells scrolled into view afterward are configured fresh from
            // the Coordinator's now-current provider through the normal data-source
            // path.
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

        // Re-prime the look-ahead band after any data change while the startup
        // population pipeline is still running (a Bool-guarded no-op afterwards) —
        // mirrors the reference design's updateNSView-side prefetch call. Strictly
        // additive: reads layout/cache state and dispatches background work only.
        coordinator.prefetchAroundVisibleRectIfPopulating()

        // Final reconciliation of the divider bands' TEXT against the layout
        // that this pass just produced. Deliberately last: by here the collection view holds
        // the current film set and the layout has been invalidated with the current breaks,
        // so every band resolves exactly. See refreshVisibleSectionDividers for why an
        // explicit sweep is needed on top of the attributes AppKit already carries.
        coordinator.refreshVisibleSectionDividers()
    }

    /// Explicit teardown — cancels the Coordinator's Combine subscriptions when the
    /// NSViewRepresentable is removed from the hierarchy, which is the Apple-recommended
    /// lifecycle hook for NSViewRepresentable cleanup (preferred over relying on deinit).
    /// Also saves the current scroll origin so it can be restored if the user returns
    /// to this view and maintainScrollPositionOnViewSwitch is enabled. dismantleNSView
    /// fires while nsView is still live, making it the only reliable point to read a
    /// valid scroll position — by the time the new view's updateNSView runs, the old
    /// scroll view has already been destroyed and its geometry is gone.
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        // Backstop save. Two earlier, better-attributed save points normally beat this
        // one to it — the end of each user scroll gesture, and updateNSView's
        // outgoing-view save when the transition is detected in place — so this exists
        // only for teardowns that produce neither.
        //
        // The y > 0 condition is deliberate and must NOT be relaxed to an unconditional
        // save here. Unlike the other two, this call site cannot vouch for its own key:
        // during a navigation the outgoing gallery can receive one final render carrying
        // the DESTINATION's activeViewID (the search-exit sequence documented in
        // updateNSView is the clearest example), which promotes currentViewID before
        // teardown. That render also zeroes the scroll position, so an unconditional save
        // would overwrite the destination's genuine saved origin with a synthetic zero
        // moments before the destination's own fresh mount tries to restore it. Requiring
        // a non-zero origin makes that specific mis-attribution unrepresentable, and the
        // "user scrolled back to the top" case it declines to record is already covered
        // correctly by the live-scroll and outgoing-view saves.
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
    final class Coordinator: NSObject, NSCollectionViewDelegate, NSCollectionViewDataSource,
                              GalleryScrollPositionProviding, Loggable {
        nonisolated static let logTag = "[GallerySubview]"

        weak var collectionView: NSCollectionView?
        weak var scrollView: WidthObservingScrollView?
        weak var dataCoordinator: DataCoordinator?
        /// Mirror of the active view's ViewState.showSectionDividers, pushed here by
        /// makeNSView/updateNSView on every pass. Gates the sort-derived divider bands in
        /// updateSectionDividers below; the Film Queue's own fixed bands ignore it.
        var showSortingSections: Bool = false
        // The active subtitle provider, pushed here by makeNSView/updateNSView on every pass
        // and forwarded to every cell via GalleryItem.configure(with:subtitleProvider:) in
        // itemForRepresentedObjectAt below. GalleryItem's tile content is pure AppKit, with no
        // SwiftUI environment to inherit this from -- unlike the prior SwiftUI-hosted
        // GalleryItemView, which read `\.gallerySubtitleProvider` directly from the environment
        // inherited through the NSHostingView bridge. updateNSView also compares this against
        // nil to detect the nil↔non-nil transition that requires a layout invalidation
        // (reserving/releasing the subtitle row's extra height).
        var subtitleProvider: GallerySubtitleProvider?

        // Track StatusBar visibility for layout calculations
        var isStatusBarVisible: Bool = false

        // Current and previous view identifiers for authoritative view-switch detection.
        // Updated by updateNSView on every pass; prevViewID is set to currentViewID
        // just before films are replaced so isLikelyViewSwitch can compare them.
        //
        // prevViewID is OPTIONAL, and nil means "this Coordinator has not yet rendered
        // any view." It must not default to a concrete case: when it defaulted to
        // .allFilms, a freshly mounted grid whose activeViewID was also .allFilms
        // compared equal on its very first pass, so isLikelyViewSwitch() returned false
        // and the whole view-switch branch below — including the
        // maintainScrollPositionOnViewSwitch origin restore — was skipped. The net effect
        // was that the preference worked for every view EXCEPT All Films, which always
        // reopened at the top. nil compares unequal to every case, so the first pass is
        // now correctly treated as a transition regardless of which view is being entered.
        //
        // The nil state carries a second meaning the outgoing-origin save below relies
        // on: there is no previously displayed view whose scroll position could be worth
        // recording, so that save is skipped on a first pass rather than filing this
        // mount's synthetic zero under an unrelated view's key.
        var currentViewID: ViewIdentifier = .allFilms
        fileprivate var prevViewID: ViewIdentifier?

        // The Film Queue segmented filter ("All" / "Up Next" / "Soon" / "Later") that the
        // film set displayed as of the last updateNSView pass was built from — nil when the
        // last pass was not showing a Film Queue film set at all. currentViewID never changes
        // when this filter is switched (the Film Queue stays a single view), so
        // isLikelyViewSwitch() alone cannot detect the transition. updateNSView compares this
        // against dataCoordinator.loadedFilmQueueFilter on every pass to synthesize an
        // equivalent "treat this like a view switch" signal — see the flicker-prevention
        // comment at its use site for why the comparison is against the loaded filter and not
        // the live one in FilmQueueFilterState.
        fileprivate var lastFilmQueueFilter: FilmQueueFilter?

        // Property observer auto-rebuilds index map.
        // Films are stored as FilmSnapshot value types — no live model-object references.
        var films: [FilmSnapshot] = [] { didSet { rebuildFilmIndexMap() } }
        let selectionState: SelectionState

        var hasCompletedFirstUpdate = false
        /// The last scroll request this Coordinator has seen, acted on or not.
        fileprivate var lastScrollRequest: FilmScrollRequest?
        private var isSuppressingCallbacks = false
        private var isUpdatingSelection = false
        // Prevents race conditions during rapid arrow key navigation.
        private var hasScheduledSelectionReset = false
        // Set by syncSelectionToView() whenever it prunes a genuinely non-empty
        // selection down to nothing because every previously-selected film left the
        // current view (e.g. removed from the list/queue being viewed while a
        // FilmSheet was open on it). Consumed by seedInitialCursor() to distinguish
        // that deliberate, data-driven clear from an organic "no selection yet" state.
        //
        // WHY THIS IS NEEDED: closing a FilmSheet returns first responder to this
        // collection view, which — per GalleryCollectionView.becomeFirstResponder —
        // auto-seeds item 0 as the selection if it finds no selection at focus time.
        // That convenience exists for genuine keyboard-Tab focus into an empty
        // selection, but without this flag it also fires immediately after we've
        // just intentionally cleared the selection because the selected film left
        // the view, silently reselecting whatever film now occupies index 0 instead
        // of leaving the selection empty as intended.
        private var selectionClearedByPrune = false
        private var anchorIndexPath: IndexPath?
        // Tracks the moving end of the selection during shift+arrow navigation.
        // Unlike anchorIndexPath (the fixed end), this advances with each key press.
        // Necessary because Set<IndexPath>.first is non-deterministic and cannot
        // reliably indicate which end of the selection the user is extending.
        private var cursorIndexPath: IndexPath?
        private var cancellables = Set<AnyCancellable>()
        /// Task handle for the withObservationTracking loop that watches
        /// selectionState.selectedFilmIDs. Stored so cancelSubscriptions() can
        /// cancel it cleanly when the NSViewRepresentable is dismantled.
        private var observationTask: Task<Void, Never>?

        // Cached film index map for O(1) selection lookups
        // Rebuilt immediately whenever films array changes (proactive caching)
        fileprivate var filmIndexMap: [UUID: Int] = [:]

        init(selectionState: SelectionState) {
            self.selectionState = selectionState
            super.init()
            setupSubscriptions()
        }

        /// Cancels all Combine subscriptions and the observation task. Called from
        /// dismantleNSView for explicit cleanup when the NSViewRepresentable is removed
        /// from the hierarchy.
        func cancelSubscriptions() {
            // removeAll() triggers AnyCancellable.deinit on each element, which calls cancel().
            // An explicit forEach loop before removeAll() is redundant.
            cancellables.removeAll()
            // Cancel the @Observable observation task for SelectionState.
            observationTask?.cancel()
            observationTask = nil
            // Remove the warming-scoped scroll-prefetch observer, if still installed
            // (it normally self-uninstalls the first time it fires after the startup
            // population pipeline finishes — see handleWarmingScrollPrefetchTick).
            removeWarmingScrollPrefetch()
            #if DEBUG
            removeViewportJumpTracer()
            #endif
            // Remove the live-scroll origin recorder installed by makeNSView.
            removeScrollOriginRecorder()
        }

        /// Starts a recursive withObservationTracking loop on selectionState.selectedFilmIDs.
        /// Each iteration registers a one-shot observation: when selectedFilmIDs changes,
        /// the onChange handler fires on MainActor, syncs the collection view, then calls
        /// observeSelectionState() again to re-register for the next change. The task is
        /// canceled in cancelSubscriptions() when the NSViewRepresentable is dismantled.
        private func observeSelectionState() {
            // .userInitiated priority matches the QoS at which AppKit delivers mouse and
            // keyboard events (user-interactive). Without an explicit priority the Task
            // defaults to .default, which is lower than user-interactive. When
            // super.mouseDown enters its event-tracking run loop and that loop services
            // the continuation resume triggered by a selection change, the runtime detects
            // that a user-interactive thread is waiting on a default-QoS Task and warns:
            // "[Internal] Thread running at User-interactive quality-of-service class
            // waiting on a lower QoS thread running at Default quality-of-service class."
            // Elevating to .userInitiated eliminates the inversion. .userInitiated is the
            // correct Swift 6–compatible spelling: Swift concurrency has no .userInteractive
            // priority; .userInitiated maps to DISPATCH_QUEUE_PRIORITY_HIGH at the GCD layer,
            // which is equivalent to the user-interactive tier for tasks of this kind.
            observationTask = Task(priority: .userInitiated) { @MainActor [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    // withObservationTracking registers a one-shot observation on the
                    // properties accessed inside the apply closure. When any of those
                    // properties change, onChange is called once, then tracking stops.
                    // We loop to re-register after each delivery.
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        withObservationTracking {
                            // Access the property to register this loop iteration as an observer.
                            _ = self.selectionState.selectedFilmIDs
                        } onChange: {
                            continuation.resume()
                        }
                    }
                    // Cancellation cannot interrupt the wait above — only the next change
                    // resumes it — so a dismantled gallery's loop wakes here once more. It
                    // must stop without acting: its films are the outgoing view's, and a sync
                    // would prune a selection made in the view that replaced it.
                    guard !Task.isCancelled else { break }
                    // onChange fired — selectedFilmIDs changed. Sync the collection view
                    // unless we are mid-update (which means this change was self-initiated).
                    guard !self.isUpdatingSelection else { continue }
                    self.syncSelectionToView()
                }
            }
        }

        // MARK: - Subscriptions
        private func setupSubscriptions() {
            // Sync external selection changes to the collection view.
            //
            // SelectionState is now @Observable, so it no longer exposes a @Published
            // projected-value publisher ($selectedFilmIDs). The correct replacement for
            // imperative observation of @Observable properties outside a SwiftUI view body
            // is withObservationTracking(_:onChange:). The pattern below schedules a
            // recursive @MainActor task: each iteration reads the property (registering
            // a one-shot observation), then re-schedules itself inside the onChange
            // handler. This delivers exactly one callback per change — the same contract
            // as the former Combine sink — and the task handle on `observationTask` lets
            // dismantleNSView cancel it cleanly.
            observeSelectionState()

            // Handle select all and clear focus rings
            // selectAllFilms must be handled here for menu bar Select All to work
            // The onSelectAll callback only fires for Cmd+A typed directly in the collection view
            //
            // Switched over exhaustively, with no `default` clause: SelectionEvent has
            // exactly these two cases, so a `default` was unreachable (and warned as
            // such). Leaving it off is also the safer shape — a third event added later
            // becomes a compile error here rather than a silently ignored no-op.
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

            // Cmd+L - Scroll gallery so the topmost selected film appears in the top
            // visible row. Works for both single and multi-selection: when multiple
            // films are selected, "topmost" is the one with the smallest indexPath,
            // which — for this single-section, row-major flow layout — corresponds
            // to the item nearest the top of the scroll view (leftmost within that
            // row when multiple selected items share the same row).
            AppEventBus.shared.uiCommands
                .receive(on: RunLoop.main)
                .sink { [weak self] command in
                    guard let self, command == .scrollToSelection else { return }
                    guard let collectionView = self.collectionView else { return }
                    let selected = collectionView.selectionIndexPaths
                    guard let indexPath = selected.min() else { return }
                    // Through the stopper, so a trackpad coast in flight ends at the jump
                    // instead of carrying on from it. See CoastingScrollStopper.
                    self.coastStopper.jump { [weak self] stoppedCoast in
                        guard let self else { return }
                        self.scrollToTopRow(at: indexPath)
                        // The stop's didEndLiveScroll banked the pre-jump position.
                        if stoppedCoast { self.claimViewportForUser() }
                    }
                }
                .store(in: &cancellables)

            // NOTE: No filmEvents subscription here. Every film change reaches this view as a
            // change of dataCoordinator.films (GalleryView reloads for any change its sender
            // did not load), and updateNSView answers that pass with either a
            // reloadData() (the film set or its order changed) or an in-place reconfigure of
            // the existing cells (only their content did). A refresh here would duplicate it.
        }

        // MARK: - Scroll-Origin Persistence

        /// Begins recording this view's scroll origin each time a user-driven scroll
        /// gesture ends, so `ViewStateManager`'s per-view store always reflects where the
        /// user actually last was.
        ///
        /// The two other save points are both transition-triggered — updateNSView's
        /// outgoing-view save and dismantleNSView — and each depends on the outgoing
        /// gallery receiving one final render (or teardown) while it still owns a
        /// meaningful position. That holds for the paths this app actually takes today,
        /// but it is timing-dependent in a way this is not: `didEndLiveScrollNotification`
        /// fires only for genuine user scrolling, never for the programmatic
        /// `setBoundsOrigin`/`scroll(to:)` calls used by the zero-before-reload step, the
        /// origin restore, or scrollToTopRow. A doomed instance being re-rendered with the
        /// destination's identity therefore cannot emit one, and so cannot mis-attribute a
        /// synthetic zero to the destination's key.
        ///
        /// Uses the target/selector NotificationCenter API rather than a Combine sink, for
        /// the same reason installWarmingScrollPrefetch does: AppKit posts this
        /// synchronously on the main thread, and observing it directly keeps delivery
        /// synchronous. A `.receive(on: RunLoop.main)` hop would defer the save by a
        /// run-loop cycle, where a view transition occurring in between could advance
        /// currentViewID first and file the origin under the wrong view — reintroducing
        /// exactly the mis-attribution this mechanism exists to avoid.
        ///
        /// Called once per Coordinator, from makeNSView. Overscroll bounce can leave a
        /// slightly negative y at gesture end; the restore path clamps to the valid range,
        /// so no guard is needed here.
        func installScrollOriginRecorder(on scrollView: NSScrollView) {
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleLiveScrollEnded(_:)),
                name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            coastStopper.install(on: scrollView)
        }

        /// Lets Cmd+L stop a trackpad coast in flight. Installed and removed with the
        /// scroll-origin recorder, whose live-scroll notifications it also follows.
        private let coastStopper = CoastingScrollStopper()

        /// Removes the live-scroll observer. Idempotent — a passing `object: nil` removes
        /// this observation regardless of which scroll view it was registered against, so
        /// no separate bookkeeping is needed. Called from cancelSubscriptions().
        private func removeScrollOriginRecorder() {
            NotificationCenter.default.removeObserver(
                self, name: NSScrollView.didEndLiveScrollNotification, object: nil)
            coastStopper.remove()
        }

        @objc private func handleLiveScrollEnded(_ notification: Notification) {
            guard let scrollView else { return }
            // The user has taken the viewport over by hand. Retire any restore still
            // pending for this view BEFORE saving: bankScrollOrigin refuses to overwrite a
            // key with an outstanding restore, so retiring second would silently discard
            // the position the user just scrolled to. Retiring first also prevents a later
            // reload from re-arming that stale restore and yanking them back.
            // Addressed, so it can never cancel another view's intent.
            ViewStateManager.shared.finishScrollOriginRestore(for: displayedScrollKey)
            ViewStateManager.shared.saveScrollPosition(scrollPosition(of: scrollView),
                                                       under: displayedScrollKey)
        }

        /// The scroll-bank key of the films this gallery is showing. For the Film Queue the
        /// sub-tab comes from the filter those films were LOADED with, not the live filter:
        /// selectFilter flips the live one two turns before the films arrive, and every
        /// save, restore and retire made in between used to address the incoming tab while
        /// the outgoing tab was still on screen.
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

        /// The scroll position of `scrollView` (this gallery's): its origin, anchored on the
        /// topmost visible film. See GalleryScrollPosition.
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

        /// The content y a banked position resolves to in this grid's current films and
        /// geometry. See GalleryScrollPosition.restoreY.
        func restoreY(for position: GalleryScrollPosition) -> CGFloat {
            let layout = collectionView?.collectionViewLayout as? SmoothResizingGridLayout
            return position.restoreY(
                filmCount: films.count,
                indexOf: { filmIndexMap[$0] },
                frameOfFilm: { layout?.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame })
        }

        // MARK: - Helper Methods
        /// Executes a block with selection callbacks suppressed.
        /// Uses defer to guarantee isSuppressingCallbacks is always reset, even if
        /// block() throws or a future caller changes the closure's throwing nature.
        func withSuppressedCallbacks(_ block: () -> Void) {
            isSuppressingCallbacks = true
            defer { isSuppressingCallbacks = false }
            block()
        }

        /// Detects if the new films array represents a different view (vs same-view sort/filter change).
        ///
        /// Uses the authoritative `prevViewID` → `currentViewID` transition recorded by
        /// updateNSView rather than probabilistic content sampling. This eliminates false
        /// positives (e.g. a large sort change whose first N items share low overlap) that
        /// previously caused unwanted scroll-to-top resets within the same view.
        /// (`prevViewID` is Optional; Swift promotes the non-optional right-hand side, so
        /// a nil `prevViewID` — a Coordinator that has not yet rendered anything — always
        /// compares unequal and correctly reports the first pass as a transition.)
        func isLikelyViewSwitch() -> Bool {
            return prevViewID != currentViewID
        }

        /// Returns film snapshot at index path, or nil if out of bounds.
        ///
        /// `fileprivate` rather than `private` so `updateNSView`'s subtitle-kind
        /// reconfigure path can resolve a visible cell's film through the same
        /// bounds-checked accessor the data source uses, rather than indexing
        /// `films` a second way that could drift from it.
        fileprivate func film(at indexPath: IndexPath) -> FilmSnapshot? {
            guard indexPath.item < films.count else { return nil }
            return films[indexPath.item]
        }

        /// Returns film ID at index path
        func filmID(at indexPath: IndexPath) -> UUID? {
            film(at: indexPath)?.id
        }

        /// Rebuilds the film index map immediately for O(1) selection lookups.
        /// Called proactively whenever films array changes.
        /// Uses a lazy sequence to avoid allocating an intermediate [(UUID, Int)] array.
        ///
        /// uniquingKeysWith (last-wins) is used instead of Dictionary(uniqueKeysWithValues:)
        /// for defensive reliability: the latter traps on a duplicate key, and this runs
        /// synchronously inside films.didSet on every reload. Should an upstream ordering
        /// (e.g. a recents fast-path order from MetadataCache) ever contain a repeated film
        /// ID, the grid degrades gracefully — mapping the ID to its last index — rather than
        /// crashing the app. For the normal case of unique IDs the result is identical.
        fileprivate func rebuildFilmIndexMap() {
            filmIndexMap = Dictionary(
                films.enumerated().lazy.map { ($1.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
        }

        // Returns poster image for film ID, for use as the flyback drag-preview
        // thumbnail. Called from within the manual drag-detection tracking loop
        // (see DragDropSupport.canStartDrag/startManualDrag), which runs on the
        // main thread at User-Interactive QoS — dragPreviewImage is cache-only
        // and never falls back to disk. See PosterCache.dragPreviewImage for
        // the full rationale (mirrors the equivalent GalleryListView fix).
        //
        // O(1) lookup using filmIndexMap. Any index returned by filmIndexMap is
        // guaranteed in range for films[], because the map is rebuilt synchronously
        // via films.didSet → rebuildFilmIndexMap() whenever films changes, and the
        // Coordinator is @MainActor-isolated so no concurrent mutation can occur.
        func posterImage(for filmID: UUID) -> NSImage? {
            guard let index = filmIndexMap[filmID] else { return nil }
            let film = films[index]
            return PosterCache.shared.dragPreviewImage(for: film.posterUID)
        }

        // MARK: - Warming-Scoped Scroll Prefetch
        //
        // Ported from the reference design's GallerySubview "Scroll Monitoring" section,
        // whose history is instructive: an UNCONDITIONAL scroll-tied prefetch running for
        // the lifetime of every grid caused its own persistent micro-stutter with no
        // offsetting benefit once images had settled into memory, while REMOVING it
        // entirely made scrolling during the transient background-restore window
        // dramatically worse. The reconciliation — proven there and adopted here — is the
        // identical mechanism scoped strictly to the population window:
        //
        //  • AppKit's NSCollectionView exposes no first-party scroll callback; the
        //    Apple-recommended substitute is NSView.boundsDidChangeNotification on the
        //    scroll view's NSClipView (already used by GalleryCollectionView for live
        //    marquee tracking — multiple observers on the same clip view coexist without
        //    conflict, so this is strictly additive).
        //  • While PosterCache.isPopulating is true (launch → completeCache finished),
        //    each bounds change — throttled to at most once per 180 ms — warms the band
        //    one viewport ahead (plus 25% behind, for reversals) via a background
        //    PosterCache.prefetchPosters load, so a fast fling ahead of the restore's own
        //    progress finds its posters already resident instead of falling through to
        //    the synchronous main-thread disk-decode backstop in refreshTileContent.
        //  • The first tick observed after isPopulating goes false UNINSTALLS the
        //    observer entirely, so the mechanism has zero recurring cost — not even the
        //    throttle check — for the remainder of the session.

        /// UIDs with a prefetch load currently in flight, preventing duplicate
        /// background loads across rapid successive ticks for the same band.
        private var inFlightPrefetchUIDs: Set<String> = []
        /// The clip view the observer is registered on, retained weakly for removal.
        private weak var prefetchClipView: NSClipView?
        private var isWarmingPrefetchObserverInstalled = false
        private var lastWarmingPrefetchTick: ContinuousClock.Instant?
        /// Matches the reference design's proven throttle: frequent enough to stay
        /// ahead of any fling, sparse enough to be imperceptible on the main thread.
        private static let warmingPrefetchThrottleInterval: Duration = .milliseconds(180)

        /// Installs the warming-scoped bounds-change observer. Called once from
        /// makeNSView; a no-op when the startup population pipeline has already
        /// finished (e.g. any view switch after the first seconds of the session),
        /// so post-warmup grids never register an observer at all.
        func installWarmingScrollPrefetch(on scrollView: NSScrollView) {
            guard PosterCache.shared.isPopulating,
                  !isWarmingPrefetchObserverInstalled else { return }
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            prefetchClipView = clip
            // Selector-based observation, matching GalleryCollectionView's existing
            // clip-view observer pattern: the notification is posted synchronously on
            // the main thread, where this @MainActor Coordinator lives.
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleWarmingScrollPrefetchTick(_:)),
                name: NSView.boundsDidChangeNotification, object: clip)
            isWarmingPrefetchObserverInstalled = true
        }

        #if DEBUG
        // MARK: Viewport-Jump Tracer (DEBUG only)
        //
        // Diagnostic for viewport moves the app did not ask for. Every programmatic scroll
        // in this file goes through appViewportMove, which the tracer skips, as it does
        // live scrolls; a jump it still reports came from somewhere else, and this names
        // the caller. Logs a bounds change whose vertical delta exceeds three viewport
        // heights, together with the call stack that moved the clip view. Selector-based
        // on the clip view's bounds notification, exactly like the warming prefetch above;
        // compiled out in release.
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

        /// Removes the observer and clears all prefetch bookkeeping. Idempotent.
        /// Called from handleWarmingScrollPrefetchTick (self-uninstall once population
        /// completes) and from cancelSubscriptions (dismantle path).
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

        /// Throttled tick handler. The isPopulating guard is a single Bool read; the
        /// full prefetch pass runs at most once per throttle interval, and only while
        /// the cache is still populating.
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

        /// Population-gated wrapper for the updateNSView call site — a Bool-guarded
        /// no-op for the entire session once the startup pipeline has finished.
        func prefetchAroundVisibleRectIfPopulating() {
            guard PosterCache.shared.isPopulating else { return }
            prefetchAroundVisibleRect()
        }

        /// Warms posters for the band of rows just beyond the current visible rect in
        /// both scroll directions, so a tile is already resident and decoded by the
        /// time it scrolls into view — keeping the synchronous main-thread disk-decode
        /// backstop in GalleryItem.refreshTileContent from ever firing mid-scroll
        /// during the population window. Runs only on the main actor; all disk work is
        /// dispatched to a detached background task.
        private func prefetchAroundVisibleRect() {
            guard let collectionView, let scrollView,
                  let layout = collectionView.collectionViewLayout as? SmoothResizingGridLayout,
                  !films.isEmpty
            else { return }

            let visible = scrollView.documentVisibleRect
            guard visible.height > 0 else { return }

            // One full viewport ahead plus a 25% trailing margin behind — mirroring
            // the "roughly one screen ahead" heuristic the reference design (and
            // UIKit's own prefetching) uses.
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
                // Excludes section-divider decoration attributes, whose IndexPaths
                // live in the same numeric namespace as real items —
                // see the matching filter in GalleryCollectionView.updateLiveSelection().
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

            // Single weak self capture with a single await crossing back onto the main
            // actor via a dedicated method — the Swift 6 strict-concurrency shape the
            // reference design settled on (a second, separately captured `self` inside
            // a nested MainActor closure is flagged as a potential race).
            Task.detached(priority: .utility) { [weak self] in
                await PosterCache.shared.prefetchPosters(uidsToLoad)
                await self?.finishPrefetch(uidsToLoad)
            }
        }

        /// MainActor-isolated completion step: clears finished keys from the in-flight
        /// set so a later tick may re-request any that somehow still aren't cached.
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

            // Read the authoritative, synchronous AppKit selection directly, rather
            // than selectionState.selectedFilmIDs — the latter is written via a
            // deferred DispatchQueue.main.async in SelectionState.select(_:) and can
            // therefore still reflect the PREVIOUS selection for one run-loop turn
            // after a click has already committed a new one (e.g. a Cmd-click toggle
            // immediately followed by a drag). collectionView.selectionIndexPaths is
            // the same source mouseDown itself consults when deciding whether a click
            // landed on an already-selected item, so this keeps a single, always-
            // current source of truth for both decisions.
            let selection = Set((collectionView?.selectionIndexPaths ?? []).compactMap { filmID(at: $0) })

            // If clicked item is in selection, drag all selected
            if let id = clickedID, selection.contains(id) {
                Self.log("Drag: \(selection.count) selected film(s)")
                return selection
            }

            // Otherwise drag just the clicked item
            if let id = clickedID {
                Self.log("Drag: single unselected film")
                return [id]
            }

            return []
        }

        // MARK: - Layout
        // Grid layout is self-computing: prepare() reads current bounds and
        // calculates all parameters in integer backing pixels. No manual
        // recalculation needed — shouldInvalidateLayout drives it through AppKit.

        // MARK: - Selection
        func handleMarqueeSelection(_ indexPaths: Set<IndexPath>) {
            guard !isUpdatingSelection else { return }
            isUpdatingSelection = true
            defer { isUpdatingSelection = false }

            // Marquee establishes a new selection context; clear keyboard cursor
            // so the next arrow press starts from the selection rather than a
            // stale cursor position.
            cursorIndexPath = nil
            anchorIndexPath = nil
            // A genuine marquee-driven selection change supersedes any stale prune flag.
            selectionClearedByPrune = false

            let ids = Set(indexPaths.compactMap { filmID(at: $0) })
            selectionState.select(ids)
        }

        func syncSelectionToView() {
            guard let collectionView, !isUpdatingSelection else { return }
            isUpdatingSelection = true
            defer { isUpdatingSelection = false }

            // Untracked: this also runs inside updateNSView — see untrackedSelectedFilmIDs.
            let selectedIDs = selectionState.untrackedSelectedFilmIDs
            guard !selectedIDs.isEmpty else {
                collectionView.selectionIndexPaths = []
                cursorIndexPath = nil
                return
            }

            // Use cached index map (rebuilt proactively when films change)
            // For 1300+ films, this provides instant O(1) lookups
            let validIDs = selectedIDs.filter { filmIndexMap[$0] != nil }

            // Prune invalid selections.
            // selectImmediate is correct here: syncSelectionToView is called from
            // the @MainActor observationTask (not from an AppKit view-update callback),
            // so a synchronous write is safe. Using the deferred select() would schedule
            // a DispatchQueue.main.async that lands after isUpdatingSelection resets,
            // causing the observation loop to re-fire syncSelectionToView unnecessarily.
            if validIDs.count != selectedIDs.count {
                if validIDs.isEmpty {
                    Self.log("No selected films in current view - clearing selection")
                    selectionState.selectImmediate(Set<UUID>())
                    collectionView.selectionIndexPaths = []
                    cursorIndexPath = nil
                    // Every previously-selected film left the view (e.g. removed from
                    // the list/queue being viewed). Flag this so a subsequent
                    // becomeFirstResponder — typically from a FilmSheet closing —
                    // does not auto-seed item 0 in place of the deliberate clear.
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

            // Re-anchor the keyboard cursor to the film's current visual position.
            //
            // After a reload triggered by a sort-key change (e.g. a FilmSheet edit
            // or an import that reorders the grid), the film moves to a new index.
            // The visual selection highlight is correctly placed above via
            // collectionView.selectionIndexPaths, but cursorIndexPath and
            // anchorIndexPath still hold the pre-reload index. The next arrow key
            // press reads cursorIndexPath as the starting position and therefore
            // navigates relative to the old index rather than the film's new
            // visual position — producing the observed "jump" behavior.
            //
            // Fix: always update both cursor and anchor to match the post-reload
            // selection state so keyboard navigation remains visually consistent.
            //
            // For a single-item selection, cursor = anchor = the item's new index.
            // For a multi-item selection (rare after a reload), use the minimum
            // index as the anchor and the maximum as the cursor, preserving the
            // directional intent of any prior shift-selection.
            if newSelection.count == 1, let singlePath = newSelection.first {
                cursorIndexPath = singlePath
                anchorIndexPath = singlePath
            } else if newSelection.count > 1 {
                let sorted = newSelection.sorted { $0.item < $1.item }
                anchorIndexPath = sorted.first
                cursorIndexPath = sorted.last
            }
            // count == 0 is handled by the early-exit guard above; no else branch needed.
        }

        // MARK: - Contextual Menu

        /// Resolves the film set a secondary-click contextual menu should act on, and
        /// builds the menu for it. Called from GalleryCollectionView.menu(for:), which
        /// has already verified the click landed on an actual item.
        ///
        /// SELECTION SEMANTICS. A secondary-click on an item that is ALREADY part of the
        /// current selection leaves the selection completely untouched, so the menu acts
        /// on the whole group — this is the case the user cares about and it costs
        /// nothing to honor.
        ///
        /// A secondary-click on an item that is NOT selected must select it. This is
        /// necessary by construction rather than a stylistic choice: "Edit Metadata…"
        /// and "Edit Releases…" are dispatched as bare AppEventBus commands that
        /// SheetHostView resolves against SelectionState.selectedFilmID — there is no
        /// film ID carried in the command — so a menu built for an unselected film would
        /// silently open the sheet for whatever else happened to be selected. Promoting
        /// the click to a selection is also the standard macOS behavior (Finder, Mail,
        /// Photos all do exactly this), and it keeps the RightSidebar, StatusBar, and
        /// MenuBar in agreement with what the menu is about to operate on.
        ///
        /// The selection commit here mirrors the plain-click path in didSelectItemsAt:
        /// the AppKit selection, the keyboard anchor/cursor, and the model are all
        /// updated together. selectImmediate is used rather than the deferred select()
        /// because this runs from an AppKit event dispatch (rightMouseDown), not from a
        /// SwiftUI view update, and the menu's own tracking loop begins the instant this
        /// method returns — the model must already be correct by then.
        func contextMenu(forItemAt indexPath: IndexPath) -> NSMenu? {
            guard let collectionView, let clickedID = filmID(at: indexPath) else { return nil }

            var targetIDs = Set(collectionView.selectionIndexPaths.compactMap { filmID(at: $0) })

            if !targetIDs.contains(clickedID) {
                isUpdatingSelection = true
                collectionView.selectionIndexPaths = [indexPath]
                anchorIndexPath = indexPath
                cursorIndexPath = indexPath
                // A deliberate, user-initiated selection supersedes any stale prune flag,
                // exactly as in updateSelectionFromView below.
                selectionClearedByPrune = false
                isUpdatingSelection = false
                selectionState.selectImmediate([clickedID], inputKind: .fromCurrentAppKitEvent())
                targetIDs = [clickedID]
            }

            return GalleryContextMenu.makeMenu(for: targetIDs)
        }

        private func updateSelectionFromView() {
            guard !isSuppressingCallbacks else { return }
            // NOTE: Entry is intentionally NOT gated on isUpdatingSelection. This method
            // only ever runs from didSelectItemsAt/didDeselectItemsAt — genuine AppKit
            // selection-change notifications produced by direct user interaction (click,
            // Cmd/Shift-click, marquee drag). isUpdatingSelection is also held open by
            // handleArrowKey across a short window to suppress the observation-loop echo
            // from its own programmatic selectImmediate() calls. If a click and an arrow
            // key land close enough together that the click's delegate callback fires
            // while that hold is still active, gating entry here would silently drop the
            // click's resulting model update — leaving selectionState out of sync with
            // whatever AppKit actually displays. A real, AppKit-confirmed selection change
            // must always be allowed to update the model; it is the authoritative source
            // of truth for what is actually selected on screen.
            isUpdatingSelection = true
            defer {
                isUpdatingSelection = false
                // Also clear any pending reset flag so a stale handleArrowKey-scheduled
                // async block (from before this click was processed) does not redundantly
                // fire after this method has already settled the flag.
                hasScheduledSelectionReset = false
            }

            // A genuine, AppKit-confirmed selection change (click, Cmd/Shift-click, or
            // marquee) supersedes any stale prune flag from an earlier data-driven clear.
            selectionClearedByPrune = false

            let ids = Set((collectionView?.selectionIndexPaths ?? []).compactMap { filmID(at: $0) })
            // Classify the input authoritatively from NSApp.currentEvent: this method only
            // runs from didSelectItemsAt/didDeselectItemsAt, which fire synchronously inside
            // the dispatch of the triggering event, so a mouse press/release here is a
            // deliberate discrete click and RightSidebar resolves it instantly — matching
            // the documented `.discrete` contract that the arrow-key path already supplies.
            // Non-mouse origins (and drag-driven churn) classify `.unspecified`, keeping the
            // timing-fallback debounce exactly as before. See
            // SelectionInputKind.fromCurrentAppKitEvent for the full rationale.
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
        //
        // This method is the sole authority for resolving a click's selection
        // result. GalleryCollectionView (23_10_GalleryViewUI.swift) calls it
        // directly rather than calling super.mouseDown(with:) and letting
        // NSCollectionView's own internal tracking loop compute the result and
        // invoke this delegate at mouseUp. It is invoked from one of two places:
        //   - mouseDown, synchronously, for any click that changes the selection
        //     (a not-yet-selected item, or a Shift/Cmd-click).
        //   - mouseUp, for a plain click on an item already part of the selection
        //     that did NOT turn into a drag — see GalleryCollectionView's
        //     `pendingPlainClickCollapse` and its SELECTION TIMING comment.
        // Either way, there is no AppKit-side computation happening — this method
        // must fully resolve the result itself. In particular, the Shift-click-
        // with-no-anchor branch below can no longer trust "AppKit has already
        // computed the resulting full selection" and derives its own fallback
        // anchor instead. The Cmd-click toggle branch is unaffected: mouseDown
        // already stages the toggle against selectionIndexPaths itself before
        // calling here, exactly as AppKit's internal tracking used to.
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            let shiftHeld = NSEvent.modifierFlags.contains(.shift)
            let commandHeld = NSEvent.modifierFlags.contains(.command)

            if shiftHeld, let clicked = indexPaths.first {
                // Extend from the tracked anchor (the fixed end of the shift-range) to
                // the clicked item. If no anchor is tracked — e.g. right after a
                // marquee drag, which intentionally nils anchorIndexPath, or this is
                // the first shift-click of a session — fall back to the nearest edge
                // of whatever is currently selected (its lowest index), so the
                // extension still reads as "select everything between the existing
                // selection and the clicked item" rather than silently doing nothing.
                // If nothing is selected at all, the clicked item anchors itself.
                let anchor = anchorIndexPath
                    ?? collectionView.selectionIndexPaths.min(by: { $0.item < $1.item })
                    ?? clicked
                let range = min(anchor.item, clicked.item)...max(anchor.item, clicked.item)
                collectionView.selectionIndexPaths = Set(range.map { IndexPath(item: $0, section: 0) })
                anchorIndexPath = anchor
                cursorIndexPath = clicked
            } else if commandHeld {
                // Cmd-click toggle: already performed against selectionIndexPaths in
                // mouseDown, before this method was invoked, so trust that result
                // completely rather than forcing a single-item override, which would
                // incorrectly collapse a legitimate multi-item selection. Re-derive
                // anchor/cursor from the actual resulting selection (sorted, not from
                // the unordered `indexPaths` diff parameter) so subsequent keyboard
                // navigation starts from a deterministic, correct endpoint.
                let full = collectionView.selectionIndexPaths
                if full.count == 1, let only = full.first {
                    anchorIndexPath = only
                    cursorIndexPath = only
                } else if !full.isEmpty {
                    let sorted = full.sorted { $0.item < $1.item }
                    anchorIndexPath = sorted.first
                    cursorIndexPath = sorted.last
                } else {
                    // Cmd-click toggled the only selected item off.
                    anchorIndexPath = nil
                    cursorIndexPath = nil
                }
            } else if let first = indexPaths.first {
                // Force the collection view's selection to exactly this single item.
                //
                // mouseDown now resolves plain clicks itself (see
                // GalleryCollectionView.mouseDown in 23_10_GalleryViewUI.swift) rather
                // than deferring to AppKit's own internal tracking, so a stale
                // AppKit-side selection snapshot is no longer a factor here. This
                // explicit assignment is kept as a cheap, defensive invariant: it
                // guarantees a plain click can never leave more than one focus ring
                // drawn, regardless of whatever collectionView.selectionIndexPaths
                // held going in (e.g. a still-settling arrow-key-driven change). It
                // does not re-invoke this delegate method — NSCollectionView does not
                // call back for programmatic selectionIndexPaths assignments (see
                // selectAll/handleArrowKey above for the same pattern). This branch is
                // only reachable when neither Shift nor Command is held, so genuine
                // multi-select gestures are never affected by this override.
                collectionView.selectionIndexPaths = [first]
                anchorIndexPath = first
                cursorIndexPath = first
            }
            updateSelectionFromView()
        }

        // Kept for NSCollectionViewDelegate completeness / defensiveness, but no
        // longer reachable via ordinary mouse clicks: GalleryCollectionView.mouseDown
        // now resolves every click (including a Cmd-click toggle that removes an
        // item) via programmatic selectionIndexPaths assignment followed by a direct
        // call to didSelectItemsAt(_:), and programmatic assignment never invokes
        // this method. It would only fire if some future AppKit-driven path (e.g. a
        // native deselectAll(_:) action) is added to this collection view.
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            updateSelectionFromView()
        }

        // MARK: - Section Dividers

        /// Recomputes the section-divider breaks from the current `films` array and pushes
        /// them to the layout. Which bands apply — the Film Queue's three fixed sections, or
        /// bands derived from the sort option the films were ordered by, or none at all — is
        /// decided entirely by GallerySectioning.displayedSectionBreaks; see that function
        /// for the priority rules. When it yields nothing this clears the breaks (a guarded
        /// no-op once already empty), leaving the divider machinery as inert as it was before
        /// the feature existed.
        ///
        /// Called from updateNSView on every reload, before reloadData(), so the layout
        /// always relayouts with breaks that match the films actually on screen. Note that
        /// this settles the layout's GEOMETRY only; the bands' text is reconciled separately,
        /// at the end of the same pass — see refreshVisibleSectionDividers.
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

        /// True when the bands' labels may lag the layout: the breaks or slot run changed,
        /// or the collection view reloaded, since the last refreshVisibleSectionDividers.
        /// That sweep is skipped on every other pass, where nothing it reconciles moved.
        fileprivate var dividerBandsNeedRefresh = true

        func updateSectionDividers() {
            guard let layout = collectionView?.collectionViewLayout as? SmoothResizingGridLayout else { return }
            // This runs on every update pass, and the breaks are an O(films) scan whenever
            // bands apply. Skip it when nothing they derive from has changed: `films`
            // compares in O(1) when it is the same buffer, and the other inputs are the
            // gates inside displayedSectionBreaks — the same skip GalleryListView makes
            // for its row model. The Film Queue's "All" tab takes its bands from queue
            // membership, which no FilmSnapshot field reflects, so that membership is an
            // input of its own.
            let inputs = SectionBreakInputs(films: films,
                                            showSortingSections: showSortingSections,
                                            queueFilter: dataCoordinator?.loadedFilmQueueFilter,
                                            sortOption: dataCoordinator?.loadedSortOption,
                                            recentsCategory: dataCoordinator?.loadedRecentsCategory,
                                            queueMembership: dataCoordinator.flatMap(GallerySectioning.filmQueueMembership))
            if inputs == lastSectionBreakInputs { return }
            lastSectionBreakInputs = inputs
            // Every gate lives in GallerySectioning.displayedSectionBreaks, which the list
            // style and the Sort menu's "Jump to Section" submenu also call — so all three
            // read one answer rather than three agreeing implementations. Both of the
            // DataCoordinator properties it consults (loadedFilmQueueFilter,
            // loadedSortOption) are written in the same synchronous pass as `films` itself,
            // which is what makes the divider state a pure function of the films being
            // displayed and therefore impossible to desync from them. Reading the LIVE
            // filter or sort intent instead was the original flicker: those report the new
            // selection the instant a control is tapped, so a pass arriving before the
            // deferred reload would draw the incoming selection's bands over the outgoing
            // selection's still-displayed films.
            let rawBreaks = dataCoordinator.map { dc in
                GallerySectioning.displayedSectionBreaks(
                    films: films, coordinator: dc,
                    showSortingSections: showSortingSections)
            } ?? []
            let breaks: [SmoothResizingGridLayout.SectionBreak] =
                rawBreaks.map { .init(index: $0.index, section: $0.section) }
            // The Queue's "All" tab alone also gets its empty "Up Next" slots.
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

        /// Declares that the user has taken this viewport over by hand, so nothing the app
        /// armed earlier may still move it.
        ///
        /// Three mechanisms can reposition a gallery after the fact — a saved-origin restore
        /// pending in ViewStateManager, an origin armed on the scroll view itself, and an
        /// armed scroll-to-film target — and each resolves on a later layout or draw pass,
        /// not at the moment it is armed. That is fine while the app owns the viewport. It
        /// stops being fine the instant the user does, because the next thing to trigger a
        /// draw is then their own click, and the gallery jumps out from under it.
        ///
        /// That was the "selected a film and the gallery leapt from the top to the bottom"
        /// report. Jumping to a section moves the viewport with a programmatic
        /// setBoundsOrigin, which — deliberately — emits no didEndLiveScroll notification,
        /// so the scroll-origin recorder never banked the new position and ViewStateManager
        /// still held the origin from wherever the user had last scrolled by hand. Clicking
        /// a film then drove a pass that resolved that stale restore.
        ///
        /// The fix is to make "the user acted on the gallery" and "no scroll machinery is
        /// armed against it" the same event. This is the exact body of handleLiveScrollEnded
        /// — retire first, then bank, so bankScrollOrigin's refusal to overwrite a key with
        /// an outstanding restore cannot discard the position being saved — plus the two
        /// scroll-view-local arms that a live scroll cannot leave behind but a programmatic
        /// jump can.
        func claimViewportForUser() {
            ViewStateManager.shared.finishScrollOriginRestore(for: displayedScrollKey)
            scrollView?.pendingScrollPosition = nil
            scrollView?.pendingScrollFilmID = nil
            guard let scrollView else { return }
            ViewStateManager.shared.saveScrollPosition(scrollPosition(of: scrollView),
                                                       under: displayedScrollKey)
        }

        /// Pushes the current layout's section identities into every live divider decoration
        /// view, so a band's label can never lag the breaks the layout is actually using.
        ///
        /// This closes the last gap in the chain. `sectionBreaks` is a pure function of the
        /// displayed films and the sort option they were loaded with; the layout's
        /// `dividerRows` are a pure function of `sectionBreaks`; the attributes are a pure
        /// function of `dividerRows`. What was NOT guaranteed is that AppKit re-applies those
        /// attributes to an existing decoration view when only the label changed — a sort
        /// change frequently leaves band ordinals and Y positions untouched while replacing
        /// every label, and a decoration view AppKit elects not to touch keeps showing the
        /// previous sort's sections. Sweeping them here makes the refresh the gallery's own
        /// responsibility rather than a behavior it has to hope for.
        ///
        /// Runs only on a pass where the breaks changed or the collection view reloaded (see
        /// dividerBandsNeedRefresh). Then only bands currently in the view hierarchy are
        /// visited (a handful, regardless of library size), and each one short-circuits on
        /// unchanged text without touching the view.
        func refreshVisibleSectionDividers() {
            guard let collectionView,
                  let layout = collectionView.collectionViewLayout as? SmoothResizingGridLayout
            else { return }
            // Nothing the sweep reconciles has moved since it last ran: the breaks are the
            // ones the bands were last labeled from, and no reload has rebuilt them. Forcing
            // the layout here on such a pass (a selection change, a status-bar toggle) was a
            // layout of its own for no change.
            guard dividerBandsNeedRefresh else {
                #if DEBUG
                GalleryRefreshProbe.skippedDividerLayouts += 1
                #endif
                return
            }
            dividerBandsNeedRefresh = false
            // No bands to label: no breaks means no divider rows, and the slot run is the
            // only other thing that places a band (its leading "Up Next" one). That is every
            // view without section dividers, and there the forced layout below was a pass of
            // its own on every update — at the old width, when the same update also resizes
            // the gallery (the right sidebar mounting with a view switch), and so repeated by
            // AppKit's own layout moments later. Breaks that have just been cleared need no
            // sweep either: the bands they leave behind are removed, not relabeled.
            guard !layout.sectionBreaks.isEmpty || layout.slotRun != nil else {
                #if DEBUG
                GalleryRefreshProbe.skippedDividerLayouts += 1
                #endif
                return
            }
            #if DEBUG
            GalleryRefreshProbe.forcedDividerLayouts += 1
            #endif
            // The breaks were pushed to the layout earlier in this pass, but prepare() —
            // which turns them into the dividerRows every band resolves against — runs
            // lazily. Forcing the layout first is what makes this sweep read the NEW rows
            // rather than the ones it is trying to replace. Safe at this point in the pass:
            // the collection view is already holding the current film set, so there is no
            // stale-data-source hazard, and any relayout it triggers is one AppKit was going
            // to perform before the next frame regardless.
            collectionView.layoutSubtreeIfNeeded()
            for case let band as SectionDividerDecorationView in collectionView.subviews {
                band.refreshFromLayout()
            }
        }

        /// Computes the up/down arrow-key target index when section dividers are present, going
        /// through the layout's own row/column model so a divider band is treated as transparent
        /// to navigation — stepped directly over to the next content row at the same column
        /// rather than landed on — and partial rows (fewer than columnsPerRow items, which occur
        /// immediately before a divider or at the grid's trailing edge) clamp to their nearest
        /// available item, matching standard macOS grid navigation. `step` is -1 for up, +1 for
        /// down. Returns nil only if the layout can't resolve the current index (the caller then
        /// falls back to the plain arithmetic path).
        private func dividerAwareVerticalTarget(from currentIndex: Int, step: Int,
                                                layout: SmoothResizingGridLayout) -> Int? {
            guard let (row, col) = layout.rowColumn(forItemIndex: currentIndex) else { return nil }
            var candidateRow = row + step
            // Rows holding only empty "Up Next" slots are as transparent as divider bands.
            while layout.isSlotOnlyRow(candidateRow) { candidateRow += step }
            if let idx = layout.itemIndex(atRow: candidateRow, col: col) {
                // The adjacent row exists and has an item at this exact column — the common case.
                return idx
            } else if layout.isDividerRow(candidateRow) {
                // The adjacent row is a divider band (always exactly one row deep), so a single
                // further step lands on the next content row on the other side of it.
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
                // A genuine content row that simply has fewer than columnsPerRow items (a partial
                // row before a divider, or the trailing partial row) — land on its last item.
                return idx
            } else {
                // No row exists there at all — genuinely at the vertical edge.
                return currentIndex
            }
        }

        // MARK: - Keyboard Navigation

        /// Seeds `cursorIndexPath` and `anchorIndexPath` at item 0 and visually
        /// selects it in the collection view.
        ///
        /// Called by `GalleryCollectionView.becomeFirstResponder` (via the
        /// `onKeyboardFocusWithNoSelection` callback) when the collection view gains
        /// keyboard focus while no item is selected — typically after a Tab key press
        /// or direct programmatic `makeFirstResponder` call from `KeyboardManager`.
        ///
        /// This replicates the native `NSCollectionView` behavior that applies during
        /// AppKit's own Tab-chain-initiated focus: on becoming key, a collection view
        /// with no selection highlights item 0 so that the user can immediately navigate
        /// with the arrow keys. Because we override `keyDown` to route all arrow events
        /// through `handleArrowKey` (bypassing `super.keyDown`), the built-in
        /// "select-first-on-focus" side-effect of native Tab traversal never fires in
        /// this subclass. `seedInitialCursor` restores that behavior explicitly.
        ///
        /// The method is a no-op when `films` is empty (nothing to select), when
        /// `isUpdatingSelection` is already true (prevents re-entrancy), or when a
        /// selection has appeared since focus arrived.
        func seedInitialCursor() {
            guard !films.isEmpty, !isUpdatingSelection, let collectionView else { return }
            // The current empty selection is the direct, deliberate result of the
            // selected film(s) leaving the view (see syncSelectionToView) — most
            // commonly because a FilmSheet just removed the film from the list/queue
            // being viewed and closing the sheet returned first responder here. Honor
            // that clear instead of auto-seeding item 0; consume the flag so it can't
            // suppress a later, genuinely organic focus-with-no-selection event.
            if selectionClearedByPrune {
                selectionClearedByPrune = false
                return
            }
            // The seed runs one turn after focus arrived, so a selection made in that same
            // turn has landed in the model by now even though this view may not have synced
            // it yet (the observation loop's own sync is queued behind this call). Seeding
            // would replace it with item 0, so both are checked.
            guard selectionState.selectedFilmIDs.isEmpty,
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
            // NOTE: The entry guard intentionally does NOT test isUpdatingSelection.
            // That flag is held across the run-loop boundary (reset asynchronously via the
            // DispatchQueue.main.async block below) purely to suppress the redundant
            // syncSelectionToView() echo that the observation loop on
            // selectionState.selectedFilmIDs would otherwise fire after selectImmediate()
            // publishes the change. Gating entry on it would let that cross-turn hold
            // swallow a genuinely distinct, rapidly-delivered second arrow keyDown — making
            // the selection move once when the user pressed twice. handleArrowKey only ever
            // runs synchronously from keyDown (serialized by the run loop), so it has no
            // real re-entrancy to guard against; every press must be honored. Setting the
            // flag true (idempotently) on each entry keeps echo suppression intact, and the
            // single pending reset (gated by hasScheduledSelectionReset) still clears it once
            // the burst settles.

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
                    // Film Queue with section dividers: step through the layout's row/column
                    // model so a divider band is treated as transparent to navigation and partial
                    // rows clamp correctly. See dividerAwareVerticalTarget.
                    targetIndex = idx
                } else {
                    // Uniform grid (every other view, and the queue when it has no dividers): the
                    // row above the current one is always a full row — only the grid's very last
                    // row can ever have fewer than itemsPerRow items — so plain same-column
                    // arithmetic is always valid here. This path is byte-for-byte unchanged.
                    targetIndex = currentIndex - itemsPerRow
                    if targetIndex < 0 { targetIndex = currentIndex }
                }
            case .down:
                if let layout, layout.hasSectionDividers,
                   let idx = dividerAwareVerticalTarget(from: currentIndex, step: 1, layout: layout) {
                    // Film Queue with section dividers: see dividerAwareVerticalTarget.
                    targetIndex = idx
                } else {
                    // Uniform grid (unchanged): the row below can be the grid's trailing partial
                    // row (fewer than itemsPerRow items). Plain `currentIndex + itemsPerRow`
                    // arithmetic can overshoot past the end of that shorter row even though the
                    // row itself exists, which previously refused to move at all rather than
                    // landing on the row's last item. Standard macOS grid navigation instead
                    // lands on the nearest item in that row — its last one — matching a full-width
                    // row seamlessly into the start of a shorter one below it.
                    let candidateIndex = currentIndex + itemsPerRow
                    if candidateIndex < totalItems {
                        // The row below exists and has an item at this exact column — the
                        // common case, a same-column step across a uniform stretch of rows.
                        targetIndex = candidateIndex
                    } else {
                        let nextRowStart = ((currentIndex / itemsPerRow) + 1) * itemsPerRow
                        if nextRowStart < totalItems {
                            // The next row exists — it's the trailing partial row — but has
                            // no item at this column. Land on its last available item.
                            targetIndex = totalItems - 1
                        } else {
                            // No further row exists at all — genuinely at the vertical edge.
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
                    // Compute IDs directly from the known range — avoids an AppKit
                    // bridge round-trip to read selectionIndexPaths back from NSCollectionView.
                    let ids = Set(range.compactMap { filmID(at: IndexPath(item: $0, section: 0)) })
                    selectionState.selectImmediate(ids, inputKind: isRepeat ? .keyRepeat : .discrete)
                }
            } else {
                anchorIndexPath = targetPath
                cursorIndexPath = targetPath
                collectionView.selectionIndexPaths = [targetPath]
                // Single-item selection: compute the ID directly from the target path
                // rather than reading selectionIndexPaths back from NSCollectionView.
                if let id = filmID(at: targetPath) {
                    selectionState.selectImmediate([id], inputKind: isRepeat ? .keyRepeat : .discrete)
                }
            }

            // Reveal the scroller only when the step actually moved the viewport, as
            // NSTableView does. Revealing it on every step made it blink on each
            // selection change whose target was already on screen.
            if scrollToItemIfNeeded(at: targetPath) {
                showScrollersInstantly()
            }

            // Schedule single reset to prevent redundant sync from Combine subscription
            // Use flag to prevent multiple resets from queuing during rapid key presses
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

            // Visual selection and model update must happen together.
            // Setting selectionIndexPaths first ensures focus rings appear immediately;
            // updating selectedFilmIDs unconditionally (not guarded by isUpdatingSelection)
            // ensures the model stays in sync even when called during rapid arrow-key navigation.
            // NSCollectionView does not invoke delegate callbacks when selectionIndexPaths is
            // set programmatically, so this cannot create a feedback loop.
            guard !isUpdatingSelection else {
                // Another selection operation is mid-flight. Merge its reset: once it clears
                // isUpdatingSelection the pending async dispatch will fire, but the model won't
                // reflect the Select All. Schedule our own update to run after that reset.
                DispatchQueue.main.async { [weak self] in
                    self?.selectAll()
                }
                return
            }
            isUpdatingSelection = true

            collectionView.selectionIndexPaths = Set((0..<films.count).map { IndexPath(item: $0, section: 0) })

            // Use filmIndexMap.keys directly — already contains exactly the IDs in the current
            // view, so there is no need to read selectionIndexPaths back and map through filmID(at:).
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

            // Check if item is fully visible
            if visibleRect.contains(itemFrame) { return false }

            // Calculate the target scroll position to make item fully visible
            var targetPoint = scrollView.documentView?.bounds.origin ?? .zero

            // Calculate padding based on scroll direction and StatusBar visibility.
            // Standard padding is the layout's own inter-row gap, read from the live
            // layout rather than restated locally.
            // When StatusBar is visible: add kStatusBarHeight to bottom padding to clear the overlay
            let gridPadding = layout.lineSpacing
            let topPadding = gridPadding
            let bottomPadding = isStatusBarVisible ? gridPadding + kStatusBarHeight : gridPadding

            if itemFrame.minY < visibleRect.minY {
                // Item is above visible area — scroll up
                targetPoint.y = max(0, itemFrame.minY - topPadding)
            } else if itemFrame.maxY > visibleRect.maxY {
                // Item is below visible area — scroll down
                targetPoint.y = itemFrame.maxY + bottomPadding - visibleRect.height
            }

            // Clamp to valid scroll range
            let contentHeight = layout.collectionViewContentSize.height
            let maxScrollY = max(0, contentHeight - visibleRect.height)
            targetPoint.y = max(0, min(targetPoint.y, maxScrollY))
            // A partly-hidden item can still clamp to the current origin (e.g. the last row).
            guard targetPoint.y != visibleRect.minY else { return false }

            // Perform instant, non-animated scroll by directly setting the document visible rect
            // This bypasses NSScrollView's animation and makes scrolling appear instantaneous
            appViewportMove {
                scrollView.contentView.setBoundsOrigin(targetPoint)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            return true
        }

        /// Returns whether the item at the given index path is fully or partially visible
        /// in the current scroll viewport.
        ///
        /// Used by updateNSView to decide whether scrollToTopRow is needed after a film
        /// edit. "Visible" is defined as the item frame intersecting the visible rect — a
        /// partial intersection is sufficient, since even a partially visible item confirms
        /// the film has not moved off-screen. A fully-out-of-viewport item requires a scroll.
        fileprivate func isFilmVisible(at indexPath: IndexPath) -> Bool {
            guard let collectionView, let scrollView,
                  let layout = collectionView.collectionViewLayout as? SmoothResizingGridLayout,
                  let attrs = layout.layoutAttributesForItem(at: indexPath) else {
                // Cannot determine visibility — treat as not visible to be safe, so a
                // scroll is attempted rather than silently leaving the film off-screen.
                return false
            }
            let visibleRect = scrollView.documentVisibleRect
            return visibleRect.intersects(attrs.frame)
        }

        /// Returns the film that is topmost — and, within a partially-visible top row,
        /// leftmost — in the current viewport. Used both to capture a grid→list handoff
        /// target and, in reverse, to serve as the film a list→grid handoff restores.
        ///
        /// Uses the layout's own attributes-in-rect query (the same one
        /// prefetchAroundVisibleRect uses) rather than assuming a fixed
        /// items-per-row arithmetic, so this stays correct for the Film Queue's
        /// section-divider decoration views (excluded via the .item category filter,
        /// matching prefetchAroundVisibleRect and updateLiveSelection) and for any
        /// partially-visible top row.
        func topmostVisibleFilmID() -> UUID? {
            topmostVisibleItemIndex().map { films[$0].id }
        }

        /// The index of the film topmost-leftmost in the viewport; see topmostVisibleFilmID.
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

        /// Scrolls to position the item in the top row of the visible area
        /// Uses instant, non-animated scrolling like arrow key navigation.
        /// Returns whether the viewport moved.
        @discardableResult
        fileprivate func scrollToTopRow(at indexPath: IndexPath) -> Bool {
            guard let collectionView, let scrollView,
                  let layout = collectionView.collectionViewLayout as? SmoothResizingGridLayout,
                  let attrs = layout.layoutAttributesForItem(at: indexPath) else { return false }

            return scrollContentTop(to: attrs.frame.minY, layout: layout, scrollView: scrollView)
        }

        /// Places the section band beginning with `firstFilmID` at the top of the viewport.
        ///
        /// Targets the BAND's own Y, not the film's: scrolling to the first film in a
        /// section would push that section's own label just off the top edge, which is
        /// precisely the label the user clicked. When no band precedes the film — the bands
        /// were switched off between the menu being built and the item being chosen — this
        /// falls back to placing the film itself at the top, which is still the right
        /// answer for where the user asked to go.
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
            // A menu-driven jump is as much "the user chose where to be" as a scroll
            // gesture is, but it moves the viewport programmatically and so emits no
            // didEndLiveScroll for the recorder to bank. Claiming it here is what stops the
            // pre-jump origin from surviving in ViewStateManager and being restored later.
            claimViewportForUser()
        }

        /// Scrolls so `contentY` sits at the top of the viewport, inset by the standard line
        /// spacing and clamped to the scrollable range. Shared by the arrow-key/post-edit
        /// row placement and the section-band jump so the two cannot land at different
        /// offsets for the same target. Returns whether the viewport moved.
        @discardableResult
        private func scrollContentTop(to contentY: CGFloat,
                                      layout: SmoothResizingGridLayout,
                                      scrollView: NSScrollView) -> Bool {
            var targetPoint = scrollView.documentView?.bounds.origin ?? .zero
            targetPoint.y = max(0, contentY - layout.lineSpacing)

            // If the target would scroll past the end of content, scroll to show as much as
            // possible instead.
            let contentHeight = layout.collectionViewContentSize.height
            let visibleHeight = scrollView.documentVisibleRect.height
            if targetPoint.y + visibleHeight > contentHeight {
                targetPoint.y = max(0, contentHeight - visibleHeight)
            }

            guard targetPoint.y != scrollView.documentVisibleRect.minY else { return false }

            // Instant, non-animated scroll, matching arrow-key navigation.
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

            // Make scrollers visible instantly by setting alpha to 1.0
            // This bypasses the fade-in animation of flashScrollers()
            if let verticalScroller = scrollView.verticalScroller {
                verticalScroller.alphaValue = 1.0

                // Trigger the normal auto-hide fade-out behavior
                // This schedules the scroller to fade out after the standard delay
                scrollView.flashScrollers()
            }
        }
    }
}

// MARK: - App-Initiated Viewport Moves

/// Runs a viewport move the app makes on purpose. In release it only runs `move`; in DEBUG
/// the viewport-jump tracer below skips any jump made inside it, because its stack would
/// only name a caller that already explains itself. Every programmatic origin change in
/// both galleries goes through here.
@MainActor
func appViewportMove(_ move: () -> Void) {
    #if DEBUG
    ViewportJumpTracer.appMoveDepth += 1
    defer { ViewportJumpTracer.appMoveDepth -= 1 }
    #endif
    move()
}

// MARK: - Coasting-Scroll Stopper

/// Stops a coasting trackpad scroll so a programmatic jump lands and stays put. Shared by
/// the grid (`GallerySubview.Coordinator`) and the list (`DraggableListView.Coordinator`)
/// for Cmd+L.
///
/// With responsive scrolling, AppKit runs the coast after the fingers lift on its own
/// background thread (`NSScrollingBehaviorConcurrentVBL` and its momentum calculator). The
/// main thread sees no momentum events to drop, and a `setBoundsOrigin` mid-coast counts as
/// an "unexpected scroll": the coast carries on from the new origin. The behavior's private
/// `_stopGestureScrollTracking` is the only call found to end it (2026-10-04, tested with
/// real flicks against eight alternatives, public and private). Stopping makes AppKit write
/// its last canonical origin to the clip view and post didEndLiveScroll — sometimes inside
/// the call, sometimes a few milliseconds later — so the jump is applied only once that
/// notification has arrived. Jumping straight after the stop lost to that final write: the
/// content stopped, but the viewport snapped back to the coast position and the scroller
/// flickered.
///
/// Every failure falls back to an immediate jump, which is the behavior before this type
/// existed: no live scroll in progress, a mouse button held (a scroller-knob drag is also a
/// live scroll and is not ours to stop), the ivar or method missing or changed shape in a
/// later macOS, or no didEndLiveScroll within `endTimeout`.
@MainActor
final class CoastingScrollStopper: NSObject, Loggable {
    nonisolated static let logTag = "[CoastingScrollStopper]"

    private static let stopSelector = NSSelectorFromString("_stopGestureScrollTracking")
    /// Objective-C type encoding of `- (void)_stopGestureScrollTracking` on 64-bit macOS.
    /// Anything else means the method changed shape and must not be called.
    private static let stopEncoding = "v16@0:8"
    /// How long to wait for didEndLiveScroll after stopping before jumping anyway.
    private static let endTimeout: TimeInterval = 0.25

    private weak var scrollView: NSScrollView?
    /// Between willStartLiveScroll and didEndLiveScroll for `scrollView`.
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

    /// Runs `jump`, first stopping a coast in progress when that is possible.
    ///
    /// `jump` receives true when a coast was stopped. AppKit's didEndLiveScroll then
    /// reached the scroll-origin recorder with the pre-jump position, so the caller must
    /// bank its new position itself. With false nothing differs from a plain jump.
    func jump(_ jump: @escaping @MainActor (_ stoppedCoast: Bool) -> Void) {
        guard isLiveScrolling, NSEvent.pressedMouseButtons == 0,
              let scrollView, let behavior = Self.stoppableBehavior(of: scrollView) else {
            jump(false)
            return
        }

        _ = unsafe behavior.perform(Self.stopSelector)

        guard isLiveScrolling else {
            // didEndLiveScroll arrived inside the stop, so AppKit's final write is done.
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

    /// The scroll view's scrolling behavior if it can be stopped safely, else nil.
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
        // One more turn, so every other didEndLiveScroll observer (the scroll-origin
        // recorder among them) has run before the jump.
        DispatchQueue.main.async { pending() }
    }
}

#if DEBUG
// MARK: - Viewport-Jump Tracer (DEBUG only)

/// Diagnostic for viewport moves the app did not ask for, shared by the grid
/// (`GallerySubview.Coordinator`) and the list (`DraggableListView.Coordinator`).
/// Logs a clip-view bounds change whose vertical delta exceeds three viewport
/// heights, with the call stack that moved it. The two coordinators each carried a
/// byte-identical copy.
///
/// Two kinds of move are explained already and skipped: the app's own, made inside
/// `appViewportMove`, and anything during a live scroll. The second is the user's: a
/// scroller-knob drag, or a fast flick whose main-thread catch-up from AppKit's scrolling
/// thread lands as one large step. What remains is a move nobody claimed.
///
/// The handler stays an `@objc` notification selector, as it was in both copies, so
/// `dropFirst(2)` still trims exactly the handler and its thunk from the stack.
@MainActor
final class ViewportJumpTracer: NSObject, Loggable {
    nonisolated static let logTag = "[ViewportJumpTracer]"

    /// Which gallery owns this tracer, named in each line so grid and list jumps stay
    /// distinguishable under the one tag.
    private let owner: String
    private weak var clipView: NSClipView?
    private var lastY: CGFloat = 0
    /// Between willStartLiveScroll and didEndLiveScroll.
    private var isLiveScrolling = false
    /// Nesting depth of `appViewportMove`. Shared by every tracer: a move is the app's
    /// whichever gallery made it.
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
        // Checked here rather than left to `log()`: the stack must be captured in this
        // frame for `dropFirst(2)` to trim the right frames, and capturing it is the cost.
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
