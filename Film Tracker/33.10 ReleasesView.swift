// MARK: - ReleasesView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// SwiftUI view layer for the "Releases" tab of FilmSheet.
// The view model and data models live in FSTabReleases.swift (33_00).

import SwiftUI

// MARK: - Carousel Navigation Commit
//
// Every navigation entry point (swipe, arrow key, arrow button) routes through this so all
// three behave identically.
//
// The commit and the step MUST land in the same run-loop turn. Deferring the index mutation
// with DispatchQueue.main.async does not buy a turn — main-queue blocks are drained within the
// same run-loop iteration, ahead of the Core Animation commit observer that fires on
// beforeWaiting — so both halves landed in one CATransaction anyway, but as two separate
// invalidation passes inside it. The spring was then established against a partially committed
// transaction, which is the truncated slide.
@MainActor
private func navigateCarousel(_ step: () -> Void) {
    commitPendingFieldEdit()
    step()
}

// MARK: - Variant Selection Commit
//
// The other in-place model swap, and the reason it needs the same treatment as a navigation
// step.
//
// Switching a merged combo pack's segment does not change the card's SwiftUI IDENTITY: the
// ForEach element, the CarouselCard and the ReleaseCardView it builds all stay put, and only
// the ReleaseCardModel handed to them changes. So every control on the card — roughly fifty of
// them — is UPDATED IN PLACE rather than rebuilt, including the TextFields, which are real
// NSTextFields.
//
// Rebinding an NSTextField that is currently being edited is the problem. During editing the
// field does not draw its own text; the window's SHARED FIELD EDITOR is installed into the
// cell inside a clip view sized from the cell's drawing rect at install time. Replacing the
// field's string out from under a live editor leaves that clip view holding the geometry it
// was installed with, so text longer than the field renders straight through the bezel and is
// cut off by whatever clips next — in practice the sheet's own edge. Nothing re-installs the
// editor afterwards, so the spill persists for as long as the field keeps focus; forcing an
// unrelated relayout (a swipe) is what appeared to "fix" it.
//
// Resigning first responder BEFORE the swap is the fix, and it is a fix for the whole card
// rather than for one field: AppKit tears the field editor out of the old field on resign, and
// the next click installs a fresh one against current geometry. It also commits the in-flight
// edit to the model that was actually being edited, which is the correct destination for it.
//
// Every OTHER path that swaps a card's model already commits first — navigateCarousel for the
// three navigation entry points, the delete confirmations, and the independence picker. This
// closes the one that did not.
@MainActor
private func selectVariant(_ variant: Int, forCard id: UUID, in viewModel: FSTabReleases) {
    commitPendingFieldEdit()
    viewModel.selectedVariantByCard[id] = variant
}

// MARK: - Field Edit Commit
//
// Resigns first responder ONLY when something with an uncommitted value holds it.
//
// `makeFirstResponder(nil)` walks the responder chain and churns SwiftUI focus state across
// every mounted card, so its cost scales with the release count. Paid unconditionally before
// an alert, that fallout lands in the alert's opening frames and drags them out one by one.
// It is needed only to force an in-progress edit into the model before something reads it, so
// it is paid only then. NSText covers the window's shared field editor, which is what
// actually holds first responder during text entry; NSTextField covers a control that took it
// directly.
@MainActor
func commitPendingFieldEdit() {
    guard let window = NSApp.keyWindow else { return }
    let responder = window.firstResponder
    guard responder is NSText || responder is NSTextField else { return }
    window.makeFirstResponder(nil)
}

// MARK: - ReleaseCardFocusRegion
// An invisible AppKit view sized to the card it sits behind, registered with
// FilmSheetKeyLoop (30_01) so Tab traversal on the Releases tab can be confined to the
// current card's own frame. The same shape as CarouselHitRegion: `hitTest` returns nil so
// it never intercepts a click, and it refuses first responder so it is never itself a stop
// in the loop it defines.
struct ReleaseCardFocusRegion: NSViewRepresentable {
    let cardID: UUID

    func makeNSView(context: Context) -> NSView {
        let view = FilmSheetKeyLoop.RegionView()
        FilmSheetKeyLoop.shared.register(view, forCard: cardID)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-registered on update for the same reason CarouselHitRegion is: the backing
        // view can be recreated across structural changes, and the registry holds it
        // weakly, so a stale entry would silently confine Tab to nothing.
        FilmSheetKeyLoop.shared.register(nsView, forCard: cardID)
    }
}

// MARK: - Carousel Dimming
//
// A card's opacity is a pure function of its resting distance from the center, in card steps
// — the ramp in FSTabReleases.cardOpacity: 1.0 at distance 0, 0.5 at 1, 0 at 2. Applied as a
// plain `.opacity(...)` where `hOffset` is already computed.
//
// Two cases are not about position and are handled at the call site: a card being deleted or
// added sits at 0, and the departing card of an add sequence stays at full opacity.

// MARK: - FSTabReleasesView
struct FSTabReleasesView: View {
    @Bindable var viewModel: FSTabReleases

    /// Width of BOTH header controls — the card-selection ("jump") menu and the "Add New
    /// Release" menu — as one constant so they cannot disagree.
    ///
    /// Sized from the jump menu, the wider demand: its rows are a column layout (format,
    /// label, glyph, each at a fixed tab stop — see ReleaseJumpMenu), so the width needed is
    /// the last tab stop plus the glyph plus the popup's bezel and chevron, not the width of
    /// the longest sentence.
    static let headerMenuWidth: CGFloat = 170

    /// Height reserved for the header's control row, so the row does not resize when the
    /// cap help button appears. See the frame in `carouselHeader`.
    static let headerControlHeight: CGFloat = 22
    /// Center-to-center distance between two adjacent cards in the stack. `cardWidth` plus
    /// the gutter that keeps the neighboring cards visibly separate as they slide past.
    private static let cardStep: CGFloat = 556
    /// Width of a card, and of the inert spacer that stands in for an unmounted one.
    ///
    /// ONE constant because the two must agree: a spacer of a different width would shift
    /// the ZStack's geometry as cards mount and unmount, so the offsets computed from
    /// `cardStep` would land differently depending on which cards happened to be inside the
    /// mount window. It was written as the same literal in both places.
    private static let cardWidth: CGFloat = 536

    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?

    // MARK: - Swipe Gesture State
    //
    // Per-gesture bookkeeping, reset at every `.began`. A reference type because the NSEvent
    // monitor's closure captures it and mutates it in place; main-actor isolated because that
    // closure runs on the main thread only.
    //
    // A swipe is a DISCRETE navigation — one gesture advances one card under the same spring
    // the arrows use — so this only decides the gesture's axis and whether it traveled far
    // enough, then ignores the rest of it.
    @MainActor
    private final class SwipeState {
        /// Running totals for the gesture, used for axis lock and for the commit threshold.
        var accumulatedX: CGFloat = 0
        var accumulatedY: CGFloat = 0
        /// nil until the gesture's movement clearly favors an axis. Latched to false once
        /// the gesture has been resolved — either as vertical/ambiguous, or as a horizontal
        /// swipe that has already fired its one navigation — so every further event in the
        /// gesture is ignored outright. That latch is what limits a swipe to a single card.
        var isHorizontal: Bool?

        /// Whether this gesture started inside the carousel. Evaluated once, on the first
        /// event seen, and reused for the rest of the gesture — so a swipe that begins in
        /// the carousel and drifts out still completes, and one that begins outside never
        /// starts driving partway through.
        var inRegion: Bool?

        func reset() {
            accumulatedX = 0
            accumulatedY = 0
            isHorizontal = nil
            inRegion = nil
        }
    }
    @State private var swipeState = SwipeState()

    // Axis-lock tuning, carried over from the reference implementation.
    /// Movement below this is too noisy to call a direction on.
    private static let axisLockDeadZone: CGFloat = 6
    /// How decisively horizontal must beat vertical to lock in as a swipe.
    private static let axisLockRatio: CGFloat = 1.4
    /// Horizontal travel a gesture must cover before it commits to a card.
    ///
    /// Larger than the axis-lock dead zone on purpose: the dead zone only has to be big
    /// enough to call a direction, while this decides a navigation the user cannot take
    /// back partway through.
    ///
    /// MARK: Why this is the carousel's largest source of INCONSISTENT latency
    ///
    /// This is a distance, but trackpad events arrive at a fixed RATE — roughly one `.changed`
    /// per display frame — not at a fixed distance. So the number of events needed to clear it,
    /// and therefore the wall-clock delay before the carousel is even asked to move, scales
    /// inversely with how fast the user swiped:
    ///
    ///     flick        ~20-40 pt per event   ->  clears on event 1        ~8 ms
    ///     ordinary     ~8-12 pt per event    ->  clears on event 2        ~16 ms
    ///     deliberate   ~2-4  pt per event    ->  clears on event 4-7   35-115 ms
    ///
    /// That spread is paid entirely BEFORE the navigation spring exists, so no amount of tuning
    /// on `navigationSpring.response` can touch it — which is why the same gesture reads as
    /// instant one time and as visibly delayed the next, while the arrow keys (which have no
    /// accumulation phase at all) stay consistent.
    ///
    /// 8 rather than the 14 it was, and the 20 before that. Lowering it compresses the slow end
    /// of that table toward the fast end — a deliberate swipe now clears in 2-3 events rather
    /// than 4-7 — which is what makes the gesture's latency repeatable rather than merely
    /// faster on average. It is deliberately NOT replaced with a velocity projection: projecting
    /// would fire a flick even sooner and WIDEN the spread, which is the opposite of the goal.
    ///
    /// Still above the 6 pt axis-lock dead zone, so the lock (6 pt plus a 1.4x horizontal
    /// margin) always resolves first and this only ever decides whether an already-horizontal
    /// gesture was deliberate. The margin over the dead zone is thinner than it was, which is
    /// acceptable here specifically because the Releases tab scrolls vertically nowhere: there
    /// is no vertical gesture on this tab for a swipe to be confused with.
    private static let discreteSwipeThreshold: CGFloat = 8

    // MARK: - Carousel Hit Region
    // Backing store for the carousel area's live AppKit view, used to decide whether a swipe
    // landed inside the carousel.
    //
    // An AppKit probe rather than a SwiftUI frame in .global coordinates because the test
    // compares against an NSEvent's locationInWindow, and AppKit and SwiftUI disagree on
    // origin and on what "global" means inside a sheet. Holding the real view lets
    // NSView.convert do the conversion, which is exact by construction.
    @MainActor
    fileprivate final class HitRegionProbe {
        weak var view: NSView?

        /// True when `point`, expressed in `window`'s coordinates, falls inside the
        /// probed view. False whenever the probe is not installed in that same window,
        /// which is what keeps swipes in other windows — or in the sheet's own gutter
        /// and header — from reaching the carousel.
        func contains(_ point: CGPoint, in window: NSWindow?) -> Bool {
            guard let view, let probeWindow = unsafe view.window, probeWindow === window else { return false }
            return view.bounds.contains(view.convert(point, from: nil))
        }
    }
    @State private var hitRegionProbe = HitRegionProbe()

    @AppStorage(preference: Preferences.confirmReleaseDeleteKey) private var confirmReleaseDelete: Bool

    // MARK: - Card Mount Window
    //
    // The set of card indices mounted as real ReleaseCardViews. Every other index renders as
    // an inert fixed-size spacer.
    //
    // WHY IT IS BOUNDED. This was a set that only ever grew, so a few hundred milliseconds
    // after the tab opened every card was mounted for the life of the sheet. Profiling at 3
    // cards versus 30 (Time Profiler, Release, main thread) showed card BODIES never
    // re-evaluating — the observation isolation works — while AttributeGraph scaled with the
    // mounted count:
    //
    //     AG::Graph::propagate_dirty      20 ms  →  207 ms   (10.4x, for 10x the cards)
    //     AG::Subgraph::update            36 ms  →  282 ms
    //     AG::Graph::UpdateStack::update  55 ms  →  420 ms
    //
    // and main-thread busy time over one alert presentation went 528 ms → 3.13 s. The
    // mechanism is layout, not body evaluation: `.equatable()` gates bodies but not layout, so
    // the spring dirtied every mounted card's offset attribute every frame and propagate_dirty
    // walked into each card's entire layout tree. Bounding the mounted set makes the per-frame
    // cost O(1) in release count by construction.
    //
    // WHY THE WINDOW IS DERIVED, NEVER STORED. It is a pure function of (current index, card
    // count, hydration radius), computed in `body`, with nothing to reconcile — when the index
    // moves, the window moves in the same body evaluation that read it.
    //
    // The first version stored it as @State and re-centered it on a deferred schedule, on the
    // theory that mounting must be kept out of animation frames. That put a mount and an
    // unmount inside the spring's settle phase, which is plainly visible as a jerk in exactly
    // the part of the motion that makes a spring read as a spring. Deferring was the error —
    // see navigateCarousel at the top of this file, where deferring the index mutation
    // produced a truncated slide for the same reason. Deriving makes both unrepresentable:
    // there is no second pass to land anywhere, no schedule to tune, and no state that can
    // disagree with the index.
    @State private var hydrationRadius: Int = 0

    /// Guards a stale hydration phase from landing after a newer hydration superseded it.
    @State private var hydrationGeneration: Int = 0

    /// One value rather than a per-format dictionary: the carousel hydrates once, when the tab
    /// first appears (or when it gains its first card after being empty), and never ramps
    /// again for the life of the sheet.
    private static let visibleRadius: Int = 1
    /// How far beyond the visible neighbors the window mounts. 1 — the same as
    /// `visibleRadius`, so nothing is mounted that cannot be seen.
    ///
    /// It was 2, keeping five cards live rather than three. Measured against the alert
    /// presentation spike (a view-tree census and main-thread sampler around each
    /// presentation, since removed), that spike cost ~0.78 ms per first-responder-capable
    /// view in the window across 14 alerts and four runs, and this constant is the only thing
    /// that sets how many such views there are: each card carries 22. The two cards radius 2
    /// added sat at distance 2, where cardOpacity is exactly 0 — mounted, focusable, walked by
    /// AppKit on every responder change, and drawing nothing.
    ///
    /// The mount-ahead cost is unchanged either way: Phase A centers the window on the
    /// destination a full run-loop turn before the index moves, so a step mounts exactly one
    /// new card at radius 1 just as it did at radius 2. What radius 1 gives up is a margin
    /// against pop-in — a newly mounted card is immediately visible at 50% opacity, so its
    /// controls have to finish assembling within Phase A's turn. They do: a card mounts in
    /// ~55 ms on the main thread (see the `card-perf` harness scenario), well inside the turn
    /// that precedes the index change.
    private static let prefetchRadius: Int = 1

        // MARK: Two ranges, not a Set
        //
        // This was a Set<Int> built by unioning two more — three heap allocations and a hash
        // of every member on every body pass, to describe at most two contiguous runs of five
        // indices. A window is a RANGE by construction (a center and a radius), so membership
        // is two integer comparisons and the whole value fits in registers.
        //
        // Deliberately not Equatable and not stored: derived in `body` and passed down.
    private struct MountWindow {
        private let primary: ClosedRange<Int>?
        private let secondary: ClosedRange<Int>?

        init(primary: Int, secondary: Int?, radius: Int, total: Int) {
            self.primary = Self.window(around: primary, radius: radius, total: total)
            self.secondary = secondary.flatMap {
                Self.window(around: $0, radius: radius, total: total)
            }
        }

        /// The contiguous index window of `radius` around `idx`, clamped to `0..<total`.
        /// `nil` where that window is empty — no cards, or a center outside the stack.
        private static func window(around idx: Int, radius: Int,
                                   total: Int) -> ClosedRange<Int>? {
            guard total > 0 else { return nil }
            let lo = max(0, idx - radius)
            let hi = min(total - 1, idx + radius)
            guard lo <= hi else { return nil }
            return lo...hi
        }

        func contains(_ index: Int) -> Bool {
            if let primary, primary.contains(index) { return true }
            if let secondary, secondary.contains(index) { return true }
            return false
        }
    }

    // Explicit placeholder visibility flag, so the placeholder fades without a ghost.
    // Branching directly on carouselEntries.isEmpty gives SwiftUI an animation context for the
    // branch swap on the same pass as the model mutation, which lets the departing card appear
    // as a ghost frame. Decoupling the branch condition from the live collection read means
    // hydrationRadius is zeroed first, then this flips inside withAnimation — the card is out
    // of the tree before the swap fires.
    //
    // Seeded in init from carouselEntries.isEmpty so the very first render — which may occur
    // mid-sheet-open, before .onAppear — already reflects the correct state.
    @State private var showPlaceholder: Bool

    // MARK: - Init
    // Custom init seeds showPlaceholder from the view model's current filtered-release
    // state. All other @State properties use their property-declaration defaults.
    init(viewModel: FSTabReleases) {
        self._viewModel = Bindable(viewModel)
        self._showPlaceholder = State(initialValue: viewModel.carouselEntries.isEmpty)
    }

    // MARK: - Body
    // Reads only structural properties from the view model: carouselEntries, currentCardIndex,
    // isTransitioning. Field-level mutations hit ReleaseCardModel properties directly, and
    // @Observable tracks those reads inside ReleaseCardView — so typing or changing a Picker
    // never invalidates this view.
    var body: some View {
        let _ = FilmSheetBodyProbe.hit("releases")
        let entries = viewModel.carouselEntries
        let idx = viewModel.currentCardIndex
        let canAddRelease = viewModel.canAddRelease()

        // The mounted window, derived here and nowhere else. `radius` is prefetchRadius in
        // steady state; it is smaller only during the carousel's cold-start hydration ramp,
        // which is the sole reason any window state exists at all.
        let radius = hydrationRadius

        // Centered on the navigation override when one is set, and on the current card
        // otherwise. That distinction keeps mounting out of the animation: during a move the
        // pipeline points this at the destination one full run-loop turn BEFORE touching the
        // index, so the pass that starts the spring finds every card already mounted. See
        // FSTabReleases.beginNavigationMove.
        //
        // The override governs which cards are MOUNTED and nothing else — appearance and
        // interactivity key to `idx` directly. A jump adds a second center so the card being
        // left stays mounted until the destination has replaced it (mountWindowSecondary);
        // the union is at most two windows, so the O(1) bound is unaffected.
        let mountedCards = MountWindow(primary: viewModel.mountWindowTarget ?? idx,
                                       secondary: viewModel.mountWindowSecondary,
                                       radius: radius,
                                       total: entries.count)

        // Readiness gate for structural mutation: asks whether every card the user can see is
        // mounted. False only during the first turns after the carousel gains cards, which is
        // exactly when an add or delete should not land.
        //
        // The isEmpty term is load-bearing. An empty carousel never hydrates, so without it
        // this reads as permanently un-ready — which disabled the add control forever and
        // stranded a user who deleted their last release.
        let carouselReady = entries.isEmpty || radius >= Self.visibleRadius

        VStack(alignment: .leading, spacing: 0) {
            carouselHeader(entries: entries, idx: idx,
                           canAddRelease: canAddRelease, carouselReady: carouselReady)

            carouselArea(entries: entries, idx: idx,
                         mountedCards: mountedCards, carouselReady: carouselReady)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            let vm = viewModel

            // Synchronize showPlaceholder to the carousel's state immediately on first
            // appearance (no animation — the sheet open handles the visual).
            showPlaceholder = vm.carouselEntries.isEmpty

            // NOTE: the deep-link position ("edit this film's 4K releases") is NOT applied
            // here. SheetHostView applies it to the view model before the sheet is
            // presented, so the very first body pass already renders the right card and the
            // hydration ramp below centers on it. See openOnFirstCard(ofFormat:).
            hydrateWindow()

            // MARK: Menu tracking guard
            // Shared with FilmSheetKeyLoop's tab monitor — see
            // FilmSheetKeyLoop.MenuTrackingState's doc comment. Guards the NSEvent local
            // monitors below, which would otherwise see scrollWheel/keyDown events ahead of
            // an open menu's own tracking loop and reassign carouselEntries/currentIndex out
            // from under it, orphaning it on screen.
            let tracking = FilmSheetKeyLoop.MenuTrackingState.shared

            // MARK: Trackpad horizontal swipe
            //
            // Structured as the reference implementation's scrollWheel handler: reset on
            // .began, accumulate and axis-lock on .changed, decide on .ended. Momentum is
            // deliberately not handled — `event.phase` alone drives this, so the gesture ends
            // when the fingers lift, not when inertia decays.
            let swipe = swipeState
            let probe = hitRegionProbe
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                guard vm.owner?.selectedTab == .releases else { return event }
                guard !vm.isConfirmationPresented else { return event }
                guard !tracking.isActive else { return event }
                guard event.hasPreciseScrollingDeltas else { return event }

                switch event.phase {
                case .began:
                    swipe.reset()
                    swipe.inRegion = probe.contains(event.locationInWindow, in: event.window)
                    return event

                case .changed:
                    // Evaluated here too, not only on .began, so a gesture whose .began was
                    // missed (another monitor consumed it, the window activated mid-swipe)
                    // still gets a region decision rather than silently never tracking.
                    if swipe.inRegion == nil {
                        swipe.inRegion = probe.contains(event.locationInWindow, in: event.window)
                    }
                    guard swipe.inRegion == true else { return event }

                    swipe.accumulatedX += event.scrollingDeltaX
                    swipe.accumulatedY += event.scrollingDeltaY

                    // The gesture is resolved exactly once, on the event that first clears
                    // the axis-lock dead zone. After that `isHorizontal` is latched false
                    // and every further event falls straight through the guard below, which
                    // is what limits one gesture to one card.
                    guard swipe.isHorizontal == nil else { return event }

                    let magnitude = max(abs(swipe.accumulatedX), abs(swipe.accumulatedY))
                    guard magnitude > Self.axisLockDeadZone else { return event }
                    let horizontal = abs(swipe.accumulatedX)
                        > abs(swipe.accumulatedY) * Self.axisLockRatio

                    // Vertical or ambiguous: latch and ignore the rest of the gesture
                    // rather than re-asking on every event.
                    guard horizontal else {
                        swipe.isHorizontal = false
                        return event
                    }

                    // Horizontal, but not far enough yet. Deliberately does NOT latch — the
                    // gesture may still travel further. The dead zone above decides a
                    // DIRECTION; this decides a navigation the user cannot take back, so it
                    // is larger.
                    guard abs(swipe.accumulatedX) >= Self.discreteSwipeThreshold else {
                        return event
                    }

                    // Committed. One step through the same navigateCarousel path the arrow
                    // key and button use, so a swipe is indistinguishable from them once
                    // fired. Negative accumulated X means the NEXT card is drawn in from the
                    // right.
                    swipe.isHorizontal = false
                    let toNext = swipe.accumulatedX < 0
                    navigateCarousel { toNext ? vm.nextCard() : vm.previousCard() }
                    return nil

                case .ended, .cancelled:
                    swipe.reset()
                    return event

                default:
                    return event
                }
            }

            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard vm.owner?.selectedTab == .releases else { return event }
                guard !vm.isConfirmationPresented else { return event }
                guard !tracking.isActive else { return event }

                // Tab is not handled here: the sheet-level monitor in FilmSheetView takes
                // it for every tab, and on this one confines it to the current card — see
                // FilmSheetKeyLoop (30_01).

                let firstResponder = NSApp.keyWindow?.firstResponder
                let isTextInputActive = firstResponder is NSTextView
                    || firstResponder is NSTextField
                    || firstResponder is NSSegmentedControl

                // Option+arrow used to cycle the format tabs. There are no format tabs any
                // more — every format shares one stack — so the modifier is left to the
                // responder chain rather than being given a second, redundant meaning
                // alongside the plain arrows.
                guard !event.modifierFlags.contains(.option) else { return event }

                guard event.keyCode == 123 || event.keyCode == 124 else { return event }
                if isTextInputActive { return event }
                // A key that reaches here has no edit to commit — isTextInputActive above
                // already returned the event for any focused text control — so
                // navigateCarousel's responder check is a no-op and the step runs
                // synchronously.
                if event.keyCode == 123 {
                    navigateCarousel { vm.previousCard() }
                } else {
                    navigateCarousel { vm.nextCard() }
                }
                return nil
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
        }
        .onReceive(AppEventBus.shared.uiCommands) { command in
            guard !viewModel.isConfirmationPresented else { return }
            switch command {
            case .addReleaseToActiveSheet(let format):
                guard carouselReady && !viewModel.isTransitioning else { return }
                guard viewModel.canAddRelease() else { return }
                viewModel.addRelease(format: format)
            case .deleteReleaseFromActiveSheet:
                guard carouselReady && !viewModel.isTransitioning else { return }
                let currentIdx = viewModel.currentCardIndex
                let entries = viewModel.carouselEntries
                guard currentIdx < entries.count else { return }
                // Always the entry's PARENT: a merged card is deleted as one unit, and its
                // bundled children go with it (deleteRelease already cascades). A child is
                // never an entry of its own, so it can never be the target here.
                let release = entries[currentIdx].parent
                requestDelete(id: release.id)
            default:
                break
            }
        }
    }

    // MARK: - Carousel Header
    //
    // The card-selection ("jump") menu and the "Add New Release" menu. The segmented format
    // picker is gone — with one stack there is nothing to select between — and "+" became a
    // menu because with no selected format the format has to be part of the ask.
    @ViewBuilder
    private func carouselHeader(
        entries: [ReleaseCarouselEntry],
        idx: Int,
        canAddRelease: Bool,
        carouselReady: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if !entries.isEmpty {
                    jumpMenu(entries: entries, idx: idx)
                        .transition(.opacity)
                }

                Spacer()

                // Appears exactly when the Add menu is unreachable BECAUSE THE FILM IS FULL —
                // keyed to `canAddRelease`, not the menu's `isEnabled`, which also goes false
                // during hydration and mid-add. Placed BEFORE the menu so the menu keeps its
                // position and the button fades in beside it.
                if !canAddRelease {
                    HelpPopoverButton(helpText: ReleasesFormatting.releaseCapHelpText,
                                      autoDismissDuration: 7.5)
                        .transition(.opacity)
                }

                addReleaseMenu(canAddRelease: canAddRelease, carouselReady: carouselReady)
            }
            // Fixed height, so the row does not resize under the help button: the button is
            // 22 pt and a bordered menu is 21, so a row sized to its tallest child grew by a
            // point the moment the button faded in — pushing every card down mid-fade.
            .frame(height: Self.headerControlHeight)
            .animation(.easeInOut(duration: 0.25), value: entries.isEmpty)
            // The cap button's fade. Keyed separately from the placeholder transition
            // above: the two conditions are unrelated, and sharing a key would animate
            // whichever one had not changed.
            .animation(.easeInOut(duration: 0.25), value: canAddRelease)

            Divider()
        }
        .padding(.horizontal, 33)
        .padding(.top, 13)
        .padding(.bottom, 0)
    }

    /// Lists every card so the user can switch to one directly.
    ///
    /// The selection is reported back as the LIVE index rather than what was clicked:
    /// `jumpToCard` declines while the carousel is busy, and a control that displayed the
    /// declined choice would show a card the carousel never traveled to.
    ///
    /// UNCONDITIONALLY ENABLED. This control used to gate on
    /// `carouselReady && !viewModel.isTransitioning && entries.count >= 2`, which was sound
    /// on its own terms and still produced bad behavior. `carouselReady` is false for the
    /// first moments after the tab appears, so opening the sheet flickered the control from
    /// disabled to enabled; and the whole expression is recomputed continuously, so a
    /// single-release film could see the control re-enable mid-session whenever one of the
    /// other two terms changed — a disabled state that did not stay disabled, which reads as
    /// a glitch rather than as a rule.
    ///
    /// Nothing downstream depends on the gate. `onSelect` ignores a no-op selection, and
    /// `viewModel.jumpToCard` declines outright while the carousel is busy — with
    /// ReleaseJumpMenu.Coordinator.selectionChanged restoring the button's own selection
    /// before it asks, so a declined jump leaves no trace on screen. A one-item menu simply
    /// opens and shows its one item, which is a fair answer to the click. The control is not
    /// rendered at all when `entries` is empty (see carouselHeader), so it can never be an
    /// enabled popup with nothing in it.
    @ViewBuilder
    private func jumpMenu(entries: [ReleaseCarouselEntry], idx: Int) -> some View {
        JumpMenuControl(
            entries: entries,
            idx: idx,
            isEnabled: true,
            viewModel: viewModel,
            onSelect: { target in
                guard target != idx else { return }
                // Commits an in-progress field edit first, exactly as an arrow press does.
                navigateCarousel { viewModel.jumpToCard(target) }
            }
        )
    }

    /// The drop-down that replaced the "+" button: one item per format, since a unified
    /// carousel cannot infer which format a new release should be.
    @ViewBuilder
    private func addReleaseMenu(canAddRelease: Bool, carouselReady: Bool) -> some View {
        let isEnabled = canAddRelease && carouselReady && !viewModel.isTransitioning
        Menu("Add New Release") {
            ForEach(ReleaseFormat.allCases, id: \.rawValue) { format in
                Button(format.rawValue) {
                    viewModel.addRelease(format: format.rawValue)
                }
            }
        }
        // Bordered rather than borderless: this replaced a button, and borderless renders as
        // bare text plus a chevron, which does not announce itself as clickable. A frame
        // rather than .fixedSize() because the shared width is larger than its intrinsic one.
        .frame(width: Self.headerMenuWidth)
        .focusable(false)
        .disabled(!isEnabled)
    }

    // MARK: - Carousel Area
    // The card stack, arrow buttons, placeholder text, and all carousel-state observers.
    // The two .onChange modifiers must live here on the always-present outer container —
    // not inside the if/else branches — so they fire regardless of placeholder state.
    @ViewBuilder
    private func carouselArea(
        entries: [ReleaseCarouselEntry],
        idx: Int,
        mountedCards: MountWindow,
        carouselReady: Bool
    ) -> some View {
        ZStack {
            if showPlaceholder {
                Text("No releases. Add one to get started.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 26)
                    .transition(.opacity)
            } else {
                cardStack(entries: entries, idx: idx, mountedCards: mountedCards)
            }

            // Arrow buttons live outside the if/else so they can animate opacity
            // independently of the branch swap.
            HStack {
                CarouselArrowButton(
                    systemImage: "arrow.left",
                    isDisabled: idx <= 0 || !carouselReady
                ) {
                    // Clicking an arrow while a text field holds focus has to commit
                    // that edit first; navigateCarousel does so only in that case.
                    navigateCarousel { viewModel.previousCard() }
                }

                Spacer()

                CarouselArrowButton(
                    systemImage: "arrow.right",
                    isDisabled: idx >= entries.count - 1 || !carouselReady
                ) {
                    // See the left arrow above — identical rationale.
                    navigateCarousel { viewModel.nextCard() }
                }
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .zIndex(10)
            // Fade the arrow buttons in/out when the format gains or loses all its cards.
            // Keyed on showPlaceholder (not carouselEntries.isEmpty) so it stays in sync
            // with the branch condition — both flip together in the same animation context.
            .opacity(showPlaceholder ? 0 : 1)
            .animation(.easeInOut(duration: 0.25), value: showPlaceholder)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        // Publishes this container's live bounds to the scroll monitor, which uses them to
        // ignore swipes landing outside the carousel. Attached here so the region is the
        // carousel area itself and stays correct across the placeholder swap and any resize.
        .background(CarouselHitRegion(probe: hitRegionProbe))
        // IMPORTANT: This onChange must live on the always-present outer container,
        // NOT inside the carousel's else branch.
        .onChange(of: viewModel.carouselEntries.count) { oldCount, newCount in
            // A queued step was aimed at the index layout that existed before this add or
            // delete renumbered the cards. Dropping it also releases the lock.
            //
            // NOT while an add sequence owns the carousel: cancelNavigation clears the mount
            // overrides that addRelease sets, and this handler fires BETWEEN that sequence's
            // Phase A and Phase B — so clearing them here unmounts the destination and Phase B
            // remounts it on the very pass that starts the spring. Safe to skip, because
            // addRelease already calls cancelNavigation() itself before arming the sequence.
            if viewModel.addingCardID == nil {
                viewModel.cancelNavigation()
            }

            if newCount == 0 {
                // Last card deleted. The ForEach is already empty, so the placeholder's
                // transition has nothing left to ghost.
                //
                // hydrationRadius is deliberately NOT zeroed: the window is derived from the
                // release count, so zeroing it only marked the carousel un-hydrated — which
                // disabled the add control and stranded the user with no way back.
                withAnimation(.easeIn(duration: 0.25)) {
                    showPlaceholder = true
                }
                return
            }

            if oldCount == 0 {
                // First card added. Yield once so SwiftUI mounts the else branch, then
                // hide the placeholder inside withAnimation so the branch swap and the new
                // card fade in together.
                Task { @MainActor in
                    await Task.yield()
                    withAnimation(.easeIn(duration: 0.25)) {
                        showPlaceholder = false
                    }
                    // Only if the carousel has never ramped up. One already at full radius
                    // is correct for any index, so a carousel the user emptied and refilled
                    // shows its card immediately instead of paying the ramp again.
                    if hydrationRadius < Self.prefetchRadius {
                        hydrateWindow()
                    }
                }
            }
            // No else branch. Any other add or delete changes the index and the count, and the
            // window is derived from exactly those — so it is already correct on the pass that
            // observes them.
        }
        // No .onChange watching the current index: the mounted window follows the index by
        // derivation in `body`, and a handler that reconciled it would reintroduce the second
        // invalidation pass that caused the jerk in the spring's tail. No format-switch
        // handler either — with one stack there is no switch.
    }

    // MARK: - Card Stack
    // The ZStack of positioned, animated ReleaseCardView instances for the active format.
    @ViewBuilder
    private func cardStack(
        entries: [ReleaseCarouselEntry],
        idx: Int,
        mountedCards: MountWindow
    ) -> some View {
        // An ordinary ForEach, evaluated on each structural change. It used to be built
        // once and stored inside a CarouselDragLayer so that a ~120 Hz live-drag gesture
        // re-ran only that wrapper rather than re-iterating this ForEach; with swipes now
        // discrete there is no per-frame gesture input to isolate it from.
        ZStack {
            // Each card is a ReleaseCardView backed by a ReleaseCardModel (@Observable).
            // Field mutations go directly to model properties — @Observable invalidates
            // only the card whose field changed, never this view.
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                // The slot's place in the STRIP, in absolute card steps from card 0. It does
                // not mention `idx` and so never changes for the life of the entry — see the
                // strip note below. Navigation moves the strip, not the slots.
                let hOffset = CGFloat(index) * Self.cardStep
                let isMounted     = mountedCards.contains(index)
                let isDismissing  = viewModel.dismissingCardID == entry.id
                let isAdding      = viewModel.addingCardID     == entry.id
                let isAddInFlight = viewModel.addingCardID     != nil
                // The two cases where a card's opacity is NOT a function of its
                // distance from the center. Everything else falls through to the
                // distance ramp applied below.
                let fixedOpacity: Double? = (isDismissing || isAdding) ? 0.0
                    // During an add sequence the departing card slides out at full
                    // opacity. Distance-based dimming only applies during navigation.
                    : isAddInFlight ? 1.0
                    : nil
                let vOffset: CGFloat = isDismissing ? -700 : 0

                // MARK: The slot is placed, never animated
                //
                // `hOffset` above is a constant per entry, so this `.offset` is a STATIC
                // layout fact: it lays the cards out as a fixed strip, card 0 at 0, card 1 one
                // step to its right, and so on. Nothing here interpolates during navigation.
                // The only animating position attribute in the carousel is the strip's own
                // offset, applied once to the ZStack below.
                //
                // Position modifiers still sit out here, above the mounted/unmounted branch,
                // so they belong to the ForEach element's identity and survive the branch
                // swap — a mount must not be able to create or destroy a position attribute.
                Group {
                    // Cards outside the window are inert spacers holding the ZStack's
                    // geometry. ONE width constant with the card, so the swap is invisible.
                    //
                    // .allowsHitTesting(false) below is what makes the shared offset safe —
                    // Color.clear IS hit-testable, and the offset carries these off the card.
                    if !isMounted {
                        Color.clear
                    } else {
                        CarouselCard(
                            entry: entry,
                            viewModel: viewModel,
                            onDelete: {
                                requestDelete(id: entry.parent.id)
                            }
                        )
                        // No .focusable(index == idx) here. It never excluded descendants from
                        // the focus ring the way its old comment claimed, but it did cost:
                        // toggling focusability invalidates the window's key view loop, which
                        // AppKit rebuilds by walking every focusable view in the WINDOW, on two
                        // cards per navigation. .focusEffectDisabled() stays — it is
                        // environment-propagated and never depended on this.
                        .focusEffectDisabled()
                    }
                }
                // `.equatable()` is applied INSIDE CarouselCard, to the ReleaseCardView
                // it builds. The slide/fade below is applied OUTSIDE it and updates
                // freely; @Observable still drives all content updates.
                .frame(width: Self.cardWidth)
                // MARK: Geometry isolation
                //
                // Stops the strip spring's per-frame position change at the card boundary.
                //
                // A descendant's resolved position is an attribute DERIVED from its
                // ancestor's, so dirtying the .offset below marks every position inside the
                // card dirty and propagate_dirty walks the whole subtree — ~50 controls, of
                // which the Steppers, TextFields, Pickers and Toggles terminate in a real
                // NSView whose frame is then re-set. That walk is the cost the mount window
                // above bounds but does not remove; this is what removes it. Children resolve
                // against the GROUP, and the group's own position is the one attribute the
                // spring moves.
                //
                // ORDER IS LOAD-BEARING: it must sit below .offset, so the offset is applied
                // to the group. Above it, the offset would be inside the isolation and
                // isolate nothing. Still true even though this slot's own offset is now
                // static: the attribute the strip dirties is this group's position.
                //
                // Safe here specifically because a card's INTERNAL geometry is static —
                // nothing inside ReleaseCardView animates its own frame — so there is no
                // in-card animation whose semantics the grouping could change. It neither
                // rasterizes nor flattens the render tree, so unlike .compositingGroup it
                // does not touch the hosted NSViews (see the note in FSTextHelpers 30_10 on
                // what flattening a layer tree containing one does).
                .geometryGroup()
                // NO per-card .animation modifiers here — every curve lives on the ZStack
                // container below. A per-card .animation overrides the inherited ambient
                // transaction for whatever it scopes, which is what prevented the container's
                // spring from reaching .offset(x:) and eliminated the bounce.
                //
                // x is the static strip placement. y is genuinely per-card: it is the
                // deletion fly-up, which is one card leaving on its own and is driven by the
                // .easeOut keyed to dismissingCardID, never by the navigation spring.
                .offset(x: hOffset, y: vOffset)
                // Distance-based dimming: full opacity at the center, half at an
                // immediate neighbor, nothing beyond. `fixedOpacity` overrides it for
                // the two cases that are not about position — see its declaration above.
                // Unmounted slots take the same value; at distance >= 2 the ramp is already
                // 0, and Color.clear draws nothing at any opacity.
                .opacity(fixedOpacity
                         ?? FSTabReleases.cardOpacity(distanceInSteps: CGFloat(index - idx)))
                .zIndex(index == idx ? 1 : 0)
                // MARK: .allowsHitTesting and NOT .disabled
                //
                // `.disabled` renders every control in its disabled style, so a card
                // grayed out while off-center and un-grayed on arrival — a visible change
                // caused purely by position. It also writes the ENVIRONMENT, re-evaluating
                // ~40 controls per card on two cards per step, which was felt as
                // resistance at the start of a gesture.
                //
                // CONSEQUENCE, HANDLED ELSEWHERE: unlike `.disabled` this does not remove
                // the card's controls from AppKit's key view loop, so a native Tab could walk
                // into an off-screen card. It cannot here: the sheet's key monitor takes Tab
                // away from AppKit and FilmSheetKeyLoop (30_01) confines it to the current
                // card by geometry.
                .allowsHitTesting(isMounted && index == idx)
            }
        }
        // MARK: The strip — ONE animating position attribute for the whole carousel
        //
        // The cards are laid out as a fixed strip by their static per-slot offsets above, and
        // NAVIGATION MOVES THE STRIP. Centering card `idx` is a single translation of
        // -idx * cardStep, and that one number is the only position the navigation spring
        // interpolates.
        //
        // This is what makes lock-step structural rather than coincidental. Before this, each
        // slot carried its own `(index - idx) * cardStep` offset: N separate animatable
        // attributes that all had to be picked up by the same transaction, given the same
        // start time, and ticked on the same frames to stay glued. That is not a guarantee
        // SwiftUI makes. When one attribute was established a beat late — most likely under
        // back-to-back navigation, where a step begins against a graph still busy with the
        // last one — that card sat still while its neighbors set off, then caught up and
        // overlapped them on the way to its resting place. Cards cannot drift apart now
        // because there is no longer any per-card quantity for them to drift in: their
        // relative spacing is layout, fixed at `cardStep`, and a single spring carries all of
        // them at once.
        //
        // geometryGroup below it for the same reason each card has one: children resolve
        // against the strip as a unit, so the spring dirties the strip's position rather than
        // walking into ten slots. ORDER IS LOAD-BEARING in the same way — the group must sit
        // below the offset.
        .geometryGroup()
        .offset(x: -CGFloat(idx) * Self.cardStep)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Keyed animation modifiers, on the CONTAINER rather than per card.
        //
        // .spring keyed on keyboardNavigationToken drives the strip's slide and bounce;
        // .easeOut keyed on dismissingCardID drives a deletion's fade and fly-up. The two
        // tokens never change together, because navigation is blocked while isTransitioning.
        //
        // Keying the spring to the token rather than to `idx` is what lets a path opt out:
        // every navigation route bumps it — the jump menu included, since jumps travel — while
        // the index writes that are not moves (addRelease's correction across an insertion,
        // openOnFirstCard's pre-render seed) deliberately do not.
        .animation(.spring(FSTabReleases.navigationSpring),
                   value: viewModel.keyboardNavigationToken)
        .animation(.easeOut(duration: 0.3), value: viewModel.dismissingCardID)
    }

    // MARK: - Delete Routing
    // Routes a delete request through confirmation or fires immediately.
    // When the release has combo-pack children, the confirmation is always shown
    // regardless of the confirmReleaseDelete preference (point 4).
    private func requestDelete(id: UUID) {
        // MARK: Wording is keyed to the TYPE, not the child count
        //
        // The message says "this release" or "this combo-pack release", and which one is a
        // property of the card's independence value — so a combo pack whose children have gone
        // missing is still described as the combo pack it is. The child count below decides
        // something different (whether the preference may skip the prompt) and the two must not
        // be conflated.
        //
        // Neither form names the card. "Blu-ray Release 2" was written into the sentence back
        // when the alert could be raised for a card the user was not looking at; every route in
        // now targets the CENTERED card — the card's own delete button, the menu command, both
        // of which act on the current entry — so the name restated what was on screen behind
        // the alert. The demonstrative is what the user is actually looking at.
        let isComboPack = viewModel.model(id)
            .map { ReleaseIndependence.isComboPack($0.independence) } ?? false

        // How many bundled discs go with this card. Only the "always confirm" rule below reads
        // it; the message no longer counts them, because "combo-pack release" already says a
        // pack is going and the discs in a pack are not separable from it.
        //
        // Asked of the view model rather than computed here. Stale child UUIDs whose models are
        // not in the session are pruned off the parent as part of answering, so the
        // confirmation neither warns about a child that doesn't exist nor leaves the parent
        // inconsistent — but the pruning is hierarchy state, which this view is no longer a
        // writer of. See FSTabReleases.liveChildCount(of:).
        let childCount = viewModel.model(id).map { viewModel.liveChildCount(of: $0) } ?? 0

        // Always confirm if there are combo-pack children, regardless of preference.
        if confirmReleaseDelete || childCount > 0 {
            // The commit must stay on THIS tick — the field-editor teardown writes any
            // in-progress edit into the model, which deletion then reads. It is conditional
            // (see commitPendingFieldEdit), so the common case costs nothing.
            commitPendingFieldEdit()

            // Quiescence window over the alert's presentation: a committed field edit arms a
            // 150 ms debounced change check that can cascade into a FilmSheet footer
            // re-render, squarely inside the alert's pop.
            viewModel.markAnimationWindow(.milliseconds(500))

            // One sentence pair either way — the two forms differ by the noun alone, so they
            // are written as one string with the qualifier interpolated rather than as two
            // near-identical sentences that can drift apart.
            let noun = isComboPack ? "this combo-pack release" : "this release"
            let message = "Are you sure you want to delete \(noun) from your library? This action cannot be undone unless all changes to the sheet are discarded."

            let vm = viewModel
            // Raised on the next turn so the resignation's fallout commits first. The
            // one-tick window is not user-observable: no input can arrive between ticks,
            // and requestConfirmation rejects a duplicate presentation.
            DispatchQueue.main.async {
                vm.requestConfirmation(
                    title: "Delete Release",
                    message: message,
                    confirmTitle: "Delete",
                    isDestructive: true,
                    onConfirm: {
                        // Deferred one tick so the alert's dismissal owns the current turn:
                        // deleteRelease starts the fly-up and a full carousel re-render, and
                        // running both in one turn gave Core Animation two competing
                        // transactions on a congested tick.
                        DispatchQueue.main.async { vm.deleteRelease(id: id) }
                    }
                )
            }
        } else {
            // No confirmation alert on this path — the commit must stay synchronous
            // here so any in-progress field edit is written into the model before
            // deleteRelease() reads release state.
            commitPendingFieldEdit()
            // Deferred one tick for the same transaction-isolation reason as above:
            // deleteRelease() sets dismissingCardID, which starts the fly-up and a full
            // carousel re-render. Its own isTransitioning guard and in-task ID re-validation
            // make the deferred call exactly as safe as a synchronous one.
            DispatchQueue.main.async {
                viewModel.deleteRelease(id: id)
            }
        }
    }

    // MARK: - Window Hydration
    // Ramps the mount radius up from cold — on first appearance, and when the carousel gains
    // its first card after being empty. The ONLY window state that exists; steady state needs
    // none, since the window is derived from the index.
    //
    // What derivation cannot avoid is mounting the full radius in one pass when the carousel
    // first appears, on the pass that also runs the sheet open. So the RADIUS is staggered
    // across turns, one radius step per turn, up to rampTarget — at today's visibleRadius and
    // prefetchRadius (both 1) that is a single turn, mounting the current card and its visible
    // neighbors together and flipping carouselReady true; a wider prefetchRadius would ramp
    // through the invisible prefetch ring in further turns after that.
    //
    // Each phase yields a real run-loop turn via DispatchQueue.main.async — Task.yield() is
    // cooperative only and would not let SwiftUI finish a render pass between batches. A
    // radius is independent of index and count, so the ramp cannot go stale mid-flight.
    private func hydrateWindow() {
        let newGeneration = hydrationGeneration &+ 1
        hydrationGeneration = newGeneration

        hydrationRadius = 0

        // The radius the ramp climbs to.
        //
        // Floored at `visibleRadius` because the two constants are tuned independently (see
        // the EXPERIMENT note on prefetchRadius) and a prefetchRadius below it breaks this
        // method twice over. `1...prefetchRadius` is a ClosedRange, which TRAPS when its
        // upper bound falls below its lower — so a prefetchRadius of 0 is a crash on tab
        // open, not a degraded window. And `carouselReady` gates every structural mutation on
        // `radius >= visibleRadius`, so a ramp that stops short of it leaves the carousel
        // permanently un-ready: the add control disabled with no way back, which is the exact
        // stranding the isEmpty term in `carouselReady` exists to prevent.
        //
        // A no-op at today's values (max(1, 1) == 1).
        let rampTarget = max(Self.prefetchRadius, Self.visibleRadius)

        Task { @MainActor in
            for radius in 1...rampTarget {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.async { continuation.resume() }
                }
                guard hydrationGeneration == newGeneration else { return }
                hydrationRadius = radius
            }
        }
    }
}

// The view model is the tab's only input, and it is the same object for the sheet's life;
// see FilmSheetTabContent's Releases case for why the comparison exists. `@Bindable` is
// main-actor state that the nonisolated == Equatable requires cannot read directly; SwiftUI
// performs view comparisons on the main actor, so MainActor.assumeIsolated asserts that, as
// ReleaseCardView's conformance does.
extension FSTabReleasesView: Equatable {
    nonisolated static func == (lhs: FSTabReleasesView, rhs: FSTabReleasesView) -> Bool {
        MainActor.assumeIsolated { lhs.viewModel === rhs.viewModel }
    }
}

// MARK: - Alert Text Formatting
//
// There is deliberately no `comboChildClause` any more. It built "the 2 associated combo-pack
// releases" for both destructive alerts, from the era when the alerts described the bundled
// discs as separate releases. Neither alert counts them now: the delete alert says
// "this combo-pack release" and treats the pack as the single thing it is on screen, and the
// type-change alert names the discs as Blu-rays directly, since only a combo pack can raise it.
// Both strings live at their call sites, which is where the sentence around them lives.
enum ReleasesFormatting {
    /// The text behind the header's cap help button.
    ///
    /// The number is spelled out from `maxReleases` so the prose cannot contradict the rule.
    /// A `static let` because NumberFormatter is expensive to build and this is a constant;
    /// the locale is pinned because the sentence around it is fixed American English.
    static let releaseCapHelpText: String = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        let cap = FSTabReleases.maxReleases
        let spelled = formatter.string(from: NSNumber(value: cap)) ?? "\(cap)"
        return "You may add up to \(spelled) releases per film, regardless of format. "
             + "A combo pack counts as one, including its bundled discs."
    }()
}

// MARK: - CarouselCard
//
// Chooses WHICH release a card displays, and nothing else.
//
// It is a view rather than four lines in the ForEach so the read of
// `viewModel.selectedVariantByCard` stays out of FSTabReleasesView.body, which would make the
// whole tab an observer of it — clicking one combo pack's segment would then invalidate the
// header, the jump menu, and every card wrapper, possibly mid-settle. Held here, the write
// reaches only the mounted CarouselCards; `.equatable()` on ReleaseCardView stops every card
// but the changed one from re-evaluating its ~50 controls.
//
// The wrapper is deliberately NOT itself Equatable: it must re-evaluate when the variant map
// changes, which a conformance over (entry, viewModel) would suppress.
//
// Exactly one variant is built — building all of them and hiding the inactive ones behind
// `.opacity` would multiply this tab's cost by the combo-pack rate, since `.equatable()`
// gates body evaluation but not layout.
private struct CarouselCard: View {
    let entry: ReleaseCarouselEntry
    let viewModel: FSTabReleases
    let onDelete: () -> Void

    var body: some View {
        let selection = viewModel.variantIndex(for: entry.id,
                                               variantCount: entry.variantCount)
        let model     = entry.variant(at: selection)

        ReleaseCardView(
            model: model,
            // The header names the CARD, so both come from the parent whichever variant is
            // displayed: a merged pack is one release to the user, and bundled discs have no
            // release number of their own.
            badgeFormat: entry.parent.format,
            displayIndex: viewModel.displayNumbers[entry.parent.id] ?? 1,
            // Empty unless this card merges a combo pack, in which case the header shows
            // one segment per disc in the box.
            variantLabels: ReleaseCardView.variantLabels(for: entry),
            variantSelection: selection,
            // Routed through selectVariant rather than writing the dictionary directly: the
            // swap replaces the model under a card that keeps its identity, so a field being
            // edited has to give up the field editor first. See selectVariant.
            onSelectVariant: { selectVariant($0, forCard: entry.id, in: viewModel) },
            // A merged card deletes as one unit, so this always targets the PARENT —
            // deleteRelease cascades to the bundled children, and a child is never a card of
            // its own.
            onDelete: onDelete,
            viewModel: viewModel
        )
        .equatable()
        // Sized to the card, so the key loop can tell this card's controls from a
        // neighbor's by geometry alone. Outside `.equatable()` — it is not part of what the
        // card draws — and keyed to the entry, so a merged pack's variant swap keeps it.
        .background(ReleaseCardFocusRegion(cardID: entry.id))
    }
}

// MARK: - Jump Menu Control
//
// The SwiftUI half of the header's card-selection menu, and the reason it is a separate view:
// building the rows reads `purchased` and `displayNumbers` for every card, and doing that in
// FSTabReleasesView.body would make the whole tab an observer of every card's purchased flag
// — so ticking one checkbox would invalidate the header, the menu, and every card wrapper,
// possibly while the carousel is still settling.
private struct JumpMenuControl: View {
    let entries: [ReleaseCarouselEntry]
    let idx: Int
    let isEnabled: Bool
    let viewModel: FSTabReleases
    let onSelect: (Int) -> Void

    var body: some View {
        // A merged combo pack is described by its PARENT, matching the card header it names:
        // the pack is bought as a unit, and its bundled discs mirror the parent's purchased
        // state anyway.
        let items = entries.map { entry in
            ReleaseJumpMenu.Item(
                format: entry.parent.format,
                number: viewModel.displayNumbers[entry.parent.id] ?? 1,
                purchased: entry.parent.purchased
            )
        }
        ReleaseJumpMenu(items: items,
                        selection: idx,
                        isEnabled: isEnabled,
                        onSelect: onSelect)
            .frame(width: FSTabReleasesView.headerMenuWidth)
    }
}

// MARK: - Release Jump Menu (AppKit)
//
// An NSPopUpButton driven directly, because the rows are a small TABLE: format, "Release N",
// then a cart glyph on the ones already owned, each at a fixed tab stop. Without that the
// glyph and the number jitter sideways in the CLOSED control as the user arrows through the
// carousel. Tab stops and a per-run color are attributes of an attributed string, and a
// Picker gives no access to the one it synthesizes from `Text` — so the alternative was not
// SwiftUI but approximating columns with padding, which is wrong by a different amount on
// every row.
//
// Declined-jump semantics are preserved exactly: the coordinator restores the button's own
// selection on click and lets the index push the real value back down, so the control never
// displays a card the carousel did not travel to. See `selectionChanged`.
private struct ReleaseJumpMenu: NSViewRepresentable {
    /// Everything one row needs, as values — so the AppKit side never touches a model and
    /// the SwiftUI side owns all the observation.
    struct Item: Equatable {
        let format: String
        let number: Int
        let purchased: Bool
    }

    let items: [Item]
    let selection: Int
    let isEnabled: Bool
    let onSelect: (Int) -> Void

    // Two tab stops derived from the widest content each column can hold — the widest format
    // name, and the widest label the numbering can produce at the cap — so adding a format or
    // moving the cap re-derives the columns instead of silently overflowing them.
    private static let font = NSFont.menuFont(ofSize: 0)

    private static let columnStyle: NSParagraphStyle = {
        // formatGap is the menu font's own space width, so the widest format name and
        // "Release N" read at ordinary word spacing rather than as an indented column;
        // every format inherits the same tab stop, so the column stays aligned.
        let font = NSFont.menuFont(ofSize: 0)
        let formatGap = ceil((" " as NSString).size(withAttributes: [.font: font]).width)
        // 2 pt, not more: with the glyph, the widest title plus the popup's chrome must
        // stay inside headerMenuWidth (169 of 170 pt at 2; 171 at the former 4, which grew
        // the control by a point whenever a purchased release was selected).
        let glyphGap: CGFloat = 2
        // The font is re-obtained (above) rather than read from the `font` static: this is a
        // static initializer and therefore runs nonisolated, where a main-actor-isolated
        // static is not reachable. Same call, same font.
        func width(_ string: String) -> CGFloat {
            (string as NSString).size(withAttributes: [.font: font]).width
        }
        let formatColumn = ReleaseFormat.allCases.map { width($0.rawValue) }.max() ?? 0
        let labelColumn  = width(ReleaseLabel.short(number: FSTabReleases.maxReleases))

        let style = NSMutableParagraphStyle()
        let first = ceil(formatColumn) + formatGap
        style.tabStops = [
            NSTextTab(textAlignment: .left, location: first),
            NSTextTab(textAlignment: .left, location: first + ceil(labelColumn) + glyphGap),
        ]
        // Tabs beyond the two explicit stops would otherwise fall on the default 28 pt
        // interval; there are none, but pinning it keeps the layout a function of the stops
        // alone.
        style.defaultTabInterval = 0
        return style
    }()

    /// The purchased glyph, primary-colored to match the row text beside it.
    ///
    /// Rendered through `paletteColors` because a `.foregroundColor` text attribute colors
    /// GLYPHS and an attachment is an image. The color is therefore baked at render time,
    /// which is why the button rebuilds its menu on an appearance change.
    private static func purchasedGlyph() -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize - 1,
                                                        weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
        return NSImage(systemSymbolName: "cart.fill", accessibilityDescription: "Purchased")?
            .withSymbolConfiguration(configuration)
    }

    private static func attributedTitle(for item: Item) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: "\(item.format)\t\(ReleaseLabel.short(number: item.number))",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        if item.purchased, let glyph = purchasedGlyph() {
            title.append(NSAttributedString(string: "\t", attributes: [.font: font]))
            let attachment = NSTextAttachment()
            attachment.image = glyph
            // Dropped to the text's own descender so the glyph sits ON the baseline rather
            // than riding above it, which is where an attachment lands by default.
            attachment.bounds = CGRect(x: 0, y: font.descender,
                                       width: glyph.size.width, height: glyph.size.height)
            title.append(NSAttributedString(attachment: attachment))
        }
        // Applied last, over the whole string: paragraph attributes are read from the
        // paragraph as a unit, so every run — the appended tab and attachment included —
        // has to carry the same style.
        title.addAttribute(.paragraphStyle, value: columnStyle,
                           range: NSRange(location: 0, length: title.length))
        return title
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Takes the proposed width outright rather than the popup's intrinsic width, which
    /// tracks the SELECTED title — so a row with or without the cart glyph can never resize
    /// the control. The height stays AppKit's own.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AppearanceTrackingPopUp,
                      context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    func makeNSView(context: Context) -> AppearanceTrackingPopUp {
        let button = AppearanceTrackingPopUp(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.focusRingType = .none
        // Matches the SwiftUI controls beside it, which are all .focusable(false): the
        // carousel's own key handling owns the arrow keys, and a Tab stop here would put
        // the user in a menu they did not ask to open.
        button.refusesFirstResponder = true
        let coordinator = context.coordinator
        button.onAppearanceChange = { [weak button] in
            guard let button else { return }
            // The glyph's color is baked into an image, so a light/dark switch has to
            // re-render it. Forced, because the items themselves have not changed.
            coordinator.rebuildMenu(on: button, force: true)
        }
        return button
    }

    func updateNSView(_ button: AppearanceTrackingPopUp, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.items = items
        coordinator.selection = selection

        // Rebuilt only when a row's CONTENT changed. Every navigation pushes a new
        // selection through here, and rebuilding the menu on each one would discard and
        // re-create N NSMenuItems mid-spring for a change that moves a checkmark.
        coordinator.rebuildMenu(on: button, force: false)

        // Re-applied unconditionally rather than only on change: a rebuild resets the
        // popup to its first item, and a click that was declined left the button showing
        // its own choice.
        if items.indices.contains(selection) {
            button.selectItem(at: selection)
        }
        button.isEnabled = isEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        var onSelect: (Int) -> Void = { _ in }
        var selection: Int = 0
        var items: [Item] = []
        /// What the currently-built menu was built from, so an unchanged update is free.
        private var builtItems: [Item]?

        func rebuildMenu(on button: NSPopUpButton, force: Bool) {
            guard force || builtItems != items else { return }
            builtItems = items

            let menu = NSMenu()
            menu.autoenablesItems = false
            for (index, item) in items.enumerated() {
                let menuItem = NSMenuItem()
                menuItem.attributedTitle = ReleaseJumpMenu.attributedTitle(for: item)
                menuItem.tag = index
                menu.addItem(menuItem)
            }
            button.menu = menu
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let target = sender.indexOfSelectedItem
            // Put the control back where the carousel actually is BEFORE asking, so a
            // declined jump leaves nothing behind; an accepted one pushes the new value back
            // down through updateNSView a turn later.
            if items.indices.contains(selection) {
                sender.selectItem(at: selection)
            }
            guard items.indices.contains(target) else { return }
            onSelect(target)
        }
    }

    /// An NSPopUpButton that reports light/dark switches, so the baked glyph color can be
    /// re-rendered. Nothing else about the control is customized.
    final class AppearanceTrackingPopUp: NSPopUpButton {
        var onAppearanceChange: (() -> Void)?

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            onAppearanceChange?()
        }
    }
}

// MARK: - CarouselArrowButton
private struct CarouselArrowButton: View {
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    // Applied to the Circle alone, not the ZStack, so it traces the disc's edge and not the
    // glyph's. Scaled back rather than dropped when disabled: a full-strength shadow would
    // fight the recessive tertiaryLabelColor fill and re-assert the "raised and clickable"
    // reading that fill exists to remove.
    private var shadowColor: Color {
        Color.black.opacity(isDisabled ? 0.10 : 0.30)
    }
    private var shadowRadius: CGFloat { isDisabled ? 1.5 : 3 }
    private var shadowOffsetY: CGFloat { isDisabled ? 0.5 : 1.5 }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isDisabled ? Color(NSColor.tertiaryLabelColor) : Color.accentColor)
                    .frame(width: 32, height: 32)
                    .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowOffsetY)
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .focusable(false)
    }
}

// MARK: - CarouselHitRegion
// An invisible AppKit view whose only job is to be measurable: it hands its live NSView to a
// HitRegionProbe so the scroll monitor can ask AppKit whether a swipe landed inside the
// carousel. `hitTest` returns nil unconditionally, so it never intercepts anything from the
// cards it sits behind.
private struct CarouselHitRegion: NSViewRepresentable {
    let probe: FSTabReleasesView.HitRegionProbe

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        probe.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-established on update because SwiftUI may recreate the representable's
        // backing view across certain structural changes; the probe holds the view
        // weakly, so a stale reference would silently disable the swipe rather than
        // misreport a region.
        probe.view = nsView
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isOpaque: Bool { false }
    }
}
