// MARK: - RightSidebar.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Omnipresent right sidebar showing film information and contextual tabs
// for the selected gallery item. Maintains stable film snapshot across tab
// switches to prevent unnecessary reloads. Also contains SidebarScrollView
// and SidebarEnvironmentModifier, the AppKitScrollView facade and environment
// re-injection modifier used by all three sidebar tab views.

import SwiftUI
import AppKit
import QuartzCore

// Locally-scoped environment key for selected film snapshot.
// Child views use sidebarFilm.id instead of a separate UUID environment value.
private struct SidebarFilmKey: EnvironmentKey {
    static let defaultValue: FilmSnapshot? = nil
}

extension EnvironmentValues {
    var sidebarFilm: FilmSnapshot? {
        get { self[SidebarFilmKey.self] }
        set { self[SidebarFilmKey.self] = newValue }
    }
}

// Locally-scoped environment key carrying the tab slot's `AppKitScrollActivation`. The
// object is created once per slot (see `tabActivations` on RightSidebar) and never replaced,
// so this environment value never changes; only the flag inside it does, which SwiftUI does
// not see. That is the point: a flag placed in the environment directly would be bridged
// into each tab's hosted NSHostingView and re-resolve its whole tree on every tab switch.
private struct SidebarTabActivationKey: EnvironmentKey {
    static let defaultValue: AppKitScrollActivation? = nil
}

extension EnvironmentValues {
    var sidebarTabActivation: AppKitScrollActivation? {
        get { self[SidebarTabActivationKey.self] }
        set { self[SidebarTabActivationKey.self] = newValue }
    }
}

// MARK: - HorizontalScrollZoneRegistrar

/// Tracks whether the cursor is currently hovering over any actively
/// horizontal-scrolling table hosted inside the sidebar — that is, any table reached
/// via `CustomTable`'s `allowHorizontalScroll` path, which is the only path that
/// registers a zone. RightSidebar's swipe monitor (see `installSwipeMonitor()`)
/// consults this so a horizontal-dominant scroll gesture that begins over one of these
/// tables scrolls the table instead of being captured as a tab swipe — without it, any
/// table content past the initial viewport becomes permanently unreachable.
///
/// In this build exactly one table qualifies: the detailed `CalendarTable`, when
/// `Preferences.additionalCalTableDetails` is enabled. The releases summary table does
/// NOT — `DiscReleasesTable`'s only live layout, `.releaseCard`, passes
/// `allowHorizontalScroll: false` and fits the sidebar's width without scrolling. Its
/// `.standard` layout does pass `true`, but that layout currently has no call site (see
/// the maintenance note atop `24_21_ReleasesTable.swift`); restoring it would restore a
/// second zone here automatically, with no change needed on this side.
///
/// Driven by SwiftUI's own `.onHover`, rather than manual `NSView` frame math.
/// These tables live deep inside a horizontally-panning, vertically-scrolling
/// hierarchy (the swipe tab plane, itself hosted inside an
/// `AppKitScrollView`-managed `NSScrollView`), and converting a raw window
/// point through all of that geometry via `NSView.convert(_:from:)` proved
/// unreliable. SwiftUI's own hit-testing already resolves "is the cursor over
/// this view" correctly through every layer of that nesting, since it's the
/// same hit-testing macOS itself would use to route the event — so leaning on
/// it directly sidesteps re-deriving that geometry by hand.
@MainActor
final class HorizontalScrollZoneRegistrar {
    private var activeZones: Set<UUID> = []

    /// True while the cursor is hovering over at least one registered zone.
    var isMouseOverActiveZone: Bool { !activeZones.isEmpty }

    /// Marks the zone identified by `id` as hovered or not. Safe to call
    /// repeatedly with the same value; backed by a Set so redundant calls are
    /// no-ops.
    func setActive(_ id: UUID, active: Bool) {
        if active {
            activeZones.insert(id)
        } else {
            activeZones.remove(id)
        }
    }
}

private struct HorizontalScrollZoneRegistrarKey: EnvironmentKey {
    static let defaultValue: HorizontalScrollZoneRegistrar? = nil
}

extension EnvironmentValues {
    var horizontalScrollZoneRegistrar: HorizontalScrollZoneRegistrar? {
        get { self[HorizontalScrollZoneRegistrarKey.self] }
        set { self[HorizontalScrollZoneRegistrarKey.self] = newValue }
    }
}

// MARK: - SidebarEnvironmentModifier

/// Re-injects sidebarFilm, DataCoordinator, and the horizontal-scroll-zone
/// registrar into the NSHostingView subtree. NSHostingView does not inherit the
/// enclosing SwiftUI environment; this modifier ensures child views can read all
/// three values via @Environment in the usual way.
struct SidebarEnvironmentModifier: ViewModifier {
    let sidebarFilm: FilmSnapshot?
    let dataCoordinator: DataCoordinator
    let horizontalScrollZoneRegistrar: HorizontalScrollZoneRegistrar?

    func body(content: Content) -> some View {
        content
            .environment(\.sidebarFilm, sidebarFilm)
            .environment(dataCoordinator)
            .environment(\.horizontalScrollZoneRegistrar, horizontalScrollZoneRegistrar)
    }
}

// MARK: - SidebarScrollView

/// SwiftUI wrapper for the right sidebar's three scrollable tabs.
/// Reads sidebarFilm and DataCoordinator from the enclosing environment,
/// re-injects both into the hosted content via SidebarEnvironmentModifier, and
/// fires AppEventBus.shared.rightSidebarDidStartLiveScroll() at the start of
/// each live-scroll phase so sidebar-local subscribers (e.g. WatchDetails'
/// viewing popover) can dismiss themselves before the content re-lays out.
struct SidebarScrollView<Content: View>: View {

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @Environment(\.sidebarFilm) private var sidebarFilm: FilmSnapshot?
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(\.horizontalScrollZoneRegistrar) private var horizontalScrollZoneRegistrar
    // Whether this tab slot is the active one arrives as the slot's stable activation
    // object, not as a Bool. A Bool here — as a parameter or as an environment value —
    // changes on every tab switch, and either way re-measured the tab's whole hosted tree.
    // See SidebarTabActivationKey above and "isActive / hit-test isolation" in
    // `98.20 UtilityKit.swift`.
    @Environment(\.sidebarTabActivation) private var tabActivation

    var body: some View {
        AppKitScrollView(
            modifier: SidebarEnvironmentModifier(
                sidebarFilm: sidebarFilm,
                dataCoordinator: dataCoordinator,
                horizontalScrollZoneRegistrar: horizontalScrollZoneRegistrar
            ),
            activation: tabActivation,
            onScrollWillStart: {
                AppEventBus.shared.rightSidebarDidStartLiveScroll()
            },
            // Selecting a different film is a new subject, so the tab returns to the
            // top — the one user-visible job the per-film `.id()` on the tab content
            // used to do as a side effect of destroying and rebuilding the whole
            // scroll view. Stating it explicitly is what makes dropping that `.id`
            // safe; see the note on `tabPlane`.
            contentResetKey: sidebarFilm?.id
        ) {
            content
        }
    }
}

// MARK: - SidebarSwipeZoneAnchor

/// Zero-footprint `NSViewRepresentable` used only to obtain a stable `NSView`
/// reference for the tab plane's fixed (non-panning) viewport frame. RightSidebar's
/// horizontal-swipe `NSEvent` monitor (see `installSwipeMonitor()`) uses this
/// reference to test whether a given scroll-wheel event's location falls within
/// the sidebar's content area — the same "cursor is over this view" gate that
/// `scrollWheel(with:)` would have provided for free, without requiring an
/// `NSScrollView` subclass (and the responsive-scrolling cost that came with one;
/// see `98.20 UtilityKit.swift` for the full history).
private struct SidebarSwipeZoneAnchor: NSViewRepresentable {
    @Binding var anchor: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Defer the binding write one run-loop turn so the view is fully
        // inserted into its window hierarchy before anything reads its
        // `.window` or `.bounds`. Mirrors WindowAccessor's own pattern.
        Task { @MainActor in
            anchor = view
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Only update when the reference actually changes; updateNSView runs
        // on every SwiftUI render pass, and unconditionally writing the
        // binding would trigger unnecessary view updates.
        if anchor !== nsView {
            Task { @MainActor in
                anchor = nsView
            }
        }
    }
}

// MARK: - RightSidebar Controller
struct RightSidebar: View, Loggable {
    nonisolated static let logTag = "[RightSidebar]"

    @Environment(SelectionState.self) private var selectionState
    @Environment(DataCoordinator.self) private var dataCoordinator
    private let viewStateManager = ViewStateManager.shared

    // Registry of horizontal-scroll zones (ReleasesTable, and the detailed
    // CalendarTable when enabled) that the swipe monitor must let scroll natively
    // rather than intercepting as a tab swipe. Must be @State, not a plain `let`:
    // RightSidebar is a struct whose body is re-evaluated (and therefore whose
    // plain stored properties are re-initialized from scratch) on every render,
    // while installSwipeMonitor's NSEvent closure is installed exactly once (in
    // .onAppear) and captures whatever instance existed at that moment. A plain
    // `let` here would mean every subsequent render hands CustomTable's .onHover
    // a fresh, different registrar than the one the frozen monitor closure is
    // still checking — the two would never agree, and the check would silently
    // always read false. @State gives this one persistent instance for the
    // sidebar's entire lifetime, exactly like swipeZoneAnchor/swipeMonitor/
    // swipeGestureState immediately below.
    @State private var horizontalScrollZoneRegistrar = HorizontalScrollZoneRegistrar()

    /// One activation object per tab slot, for the sidebar's lifetime: the channel through
    /// which a slot's scroll view learns it is (or is no longer) the click-active tab without
    /// any SwiftUI value changing. See SidebarTabActivationKey.
    @State private var tabActivations: [RightSidebarTab: AppKitScrollActivation] =
        Dictionary(uniqueKeysWithValues: tabOrder.map { ($0, AppKitScrollActivation()) })
    
    // Selection state (derived from selectionState for cleaner logic)
    @State private var hasSelection: Bool = false
    @State private var isMultiSelection: Bool = false
    @State private var selectedFilm: FilmSnapshot? = nil
    
    // Individual table expansion states.
    @State private var calendarTableExpanded: Bool = false
    @State private var listTableExpanded: Bool = false
    // Expansion state for the Releases tab's summary table. The Details tab no longer
    // renders a copy of that table, so this is now the only releases-table expansion
    // state the sidebar owns.
    @State private var releasesSummaryExpanded: Bool = false
    
    // Adaptive debounce state for film resolution during rapid scrolling.
    @State private var resolutionTask: Task<Void, Never>?

    /// The debounce decision's timing inputs (see `SelectionTiming`). Held in one
    /// persistent reference rather than as `@State` values: both are written on every
    /// selection step and read only by `handleSelectionChange`, never by `body`, so as
    /// state they could only ever schedule a render that has nothing to show.
    @State private var selectionTiming = SelectionTiming()

    /// Ceiling on the self-tuning coalescing window derived from
    /// `selectionTiming.lastResolutionCost`.
    /// One pathological resolution (a stall from unrelated main-thread work that
    /// happened to land in the same turn) must not be able to make the *next* press
    /// feel sluggish, so the measurement is clamped before it is ever used as a delay.
    private static let maxCoalescingWindow: TimeInterval = 0.12


    // True when a selection change arrived while the composite drag-deferral window
    // (item-hit click still ambiguous, or a drag session in flight — see
    // DragSessionMonitor.isDeferralWindowActive) was active and its (expensive)
    // content resolution was structurally deferred to the window's resolving
    // boundary. Flushed by flushDragDeferredResolution(), which resolves from
    // selectionState's LIVE selection — never a stashed snapshot — so a stale value
    // can never be displayed no matter how many selection changes occur while the
    // flag is pending. See handleSelectionChange for the full rationale.
    @State private var hasDragDeferredResolution: Bool = false

    // True once the sidebar has been interim-cleared because a live drag session
    // is dragging a film that differs from whatever is currently displayed (or
    // was about to be displayed) — see `clearForDragInterim()` and
    // `handleDragSessionWillBegin()`. While true, the body shows
    // `dragInProgressPlaceholder` instead of either the normal content or the
    // default "no selection" placeholder. Always reset alongside
    // `hasDragDeferredResolution` — the two flags share the same lifecycle.
    @State private var sidebarClearedForDrag: Bool = false
    
    // MARK: - Swipe Navigation State
    
    // True only while a swipe-initiated tab change is animating. Gates the scoped
    // `.transaction` that re-injects the spring (see the tab plane below), so the
    // plane's pan animates for swipes but every other tab-change source (tab button,
    // menu, keyboard) pans instantly. This is a plain flag, not a direction: the
    // slide direction is implicit in the pan offset, so it is always spatially
    // correct and there is no direction state that can fall out of sync.
    @State private var isSwipeAnimating: Bool = false
    
    // Clears `isSwipeAnimating` once a swipe slide has settled. Stored so a rapid
    // second swipe can cancel the pending reset from the first. Canceled on dismount.
    @State private var swipeResetTask: Task<Void, Never>? = nil
    
    // The tab a swipe is animating away from — i.e. whatever `selectedTab` was the
    // instant `handleSwipe` fired, captured before it flips to the target. `nil`
    // whenever no swipe is currently animating. Used by `isTabActiveForHitTesting(_:)`
    // so the departing tab (still genuinely visible mid-slide) stays click-active
    // for the swipe's duration, while every other resident-but-not-visible slot
    // (including any third tab kept merely pre-armed for the next swipe) does not.
    // Cleared alongside `isSwipeAnimating` when the slide settles.
    @State private var departingTab: RightSidebarTab? = nil
    
    // The film whose neighbor tabs have been brought in behind the selected tab. When
    // it doesn't match the current film (i.e. right after a new selection), only the
    // selected tab renders, keeping the initial paint instant; a deferred task then
    // sets this to the current film so the rest of the swipe window becomes resident.
    // See `isTabRendered` and the `.task` in `body`.
    /// How long the selection must stay put before the off-screen neighbor tabs are
    /// built (see `isTabRendered` and the `.task` in `body`).
    ///
    /// The neighbors exist only so a swipe can *slide* the incoming tab in rather than
    /// insert it. They are never visible at rest, yet building them is as expensive as
    /// building the visible tab: each one is a fresh `NSScrollView` + `NSHostingView`
    /// hosting a full module stack, created from scratch because the tab plane keys its
    /// slots on `selectedFilm?.id`. Arming them immediately after every film change
    /// therefore paid 2-3x the cost of a selection step, and during rapid discrete arrow
    /// navigation every one of those neighbor builds was torn down by the next keypress
    /// before it could ever be swiped to — pure waste, on the main thread, in exactly the
    /// frames the next key event needed to be dispatched. That backlog is what made the
    /// selection itself visibly lag behind the user's presses.
    ///
    /// Debouncing here rather than in `handleSelectionChange` is the point: the *visible*
    /// tab still resolves and paints synchronously on every discrete press (a single
    /// arrow tap is as instant as it ever was), and only the invisible pre-arming waits
    /// for the user to settle. 180 ms is comfortably shorter than the gap between the
    /// last arrow press and any physically possible two-finger trackpad swipe, so the
    /// swipe window is always armed by the time a gesture could begin.
    private static let neighborArmingQuietWindow: Duration = .milliseconds(180)

    @State private var neighborsReadyFilmID: UUID? = nil
    
    // The spring used exclusively for swipe-driven tab changes. It is re-applied
    // locally (see the tab plane's `.transaction` below) because MainView nils the
    // ambient transaction for its whole layout container to suppress sidebar
    // 'jiggle'; that nil would otherwise strip this animation before it reaches the
    // pan. Mirrors the ReleaseCard carousel's feel. `duration` is the conservative
    // settle time after which `isSwipeAnimating` is cleared.
    private static let swipeAnimation: Animation = .spring(response: 0.35,
                                                           dampingFraction: 0.85)
    private static let swipeAnimationDuration: Double = 0.6
    
    // The sidebar's fixed width, and therefore each tab panel's width and the pan
    // distance for one swipe step. This is a compile-time constant (the sidebar frame
    // below is pinned to it), so the plane reads it directly rather than measuring the
    // laid-out panels — measuring the panels to size the panels is a layout feedback
    // loop that runs away to a non-finite width and hangs, and a GeometryReader around
    // the active AppKit scroll view also measurably degrades its scrolling.
    static let sidebarWidth: CGFloat = 300

    // MARK: - Swipe Recognition State
    //
    // Horizontal-swipe recognition previously lived inside a custom NSScrollView
    // subclass (HorizontalSwipeScrollView, in `98.20 UtilityKit.swift`) that
    // overrode scrollWheel(with:). That override — even once made as cheap as
    // possible — measurably cost this sidebar's scrolling smoothness relative to a
    // plain NSScrollView, and no fix to the override itself closed that gap. The
    // recognition logic below is functionally identical (same threshold, same
    // phase/momentum handling, same per-gesture de-duplication) but runs inside a
    // standalone NSEvent local monitor instead — the same pattern already used by
    // the ReleaseCard carousel (FSTabReleasesView) for its own trackpad swipe. A
    // local monitor inspects events *before* AppKit's normal dispatch and can
    // return the event unchanged to let it proceed exactly as if the monitor did
    // not exist, or return nil to consume it. Because the NSScrollView backing
    // each tab is never subclassed or touched, its scrolling is guaranteed
    // identical to a plain, undecorated NSScrollView.

    /// Reference to the tab plane's fixed (non-panning) viewport, used to test
    /// whether a scroll-wheel event's location falls within the sidebar's content
    /// area. See `SidebarSwipeZoneAnchor`.
    @State private var swipeZoneAnchor: NSView? = nil

    /// The installed local event monitor, removed on dismount. `Any?` matches the
    /// opaque token type `NSEvent.addLocalMonitorForEvents` returns.
    @State private var swipeMonitor: Any? = nil

    /// Shared across every scroll-wheel event of a single physical gesture: once
    /// true, the remainder of that gesture (trailing `.changed` frames and
    /// momentum) is absorbed so it can't also drive a stray overscroll or an
    /// unwanted extra scroll on the newly-selected tab. Re-armed on the next
    /// gesture's `.began` phase. Unlike the previous subclass's `static var`
    /// (which had to be shared across every concurrently-mounted tab's scroll
    /// view instance), this only needs to be a plain instance property: exactly
    /// one monitor exists for the sidebar's entire lifetime, installed once in
    /// `.onAppear`.
    @State private var swipeGestureState = SwipeGestureState()

    /// Minimum absolute horizontal delta required to register a deliberate swipe.
    /// Matches the threshold used by the ReleaseCard carousel (FSTabReleasesView)
    /// and the value the previous NSScrollView-subclass implementation used.
    private static let swipeRecognitionThreshold: CGFloat = 20

    // Preference to control automatic table expansion.
    @AppStorage(preference: Preferences.autoExpandRightSidebarTablesKey)
        private var autoExpandRightSidebarTables: Bool
    
    // Preference to control tab memory behavior.
    @AppStorage(preference: Preferences.rememberRightSidebarTabKey)
        private var rememberRightSidebarTab: Bool
    
    // Computed property for accessing the current tab from ViewStateManager
    private var selectedTab: RightSidebarTab {
        viewStateManager.selectedRightSidebarTab
    }
    
    /// Wraps one of the three table-expansion states in the auto-expand preference:
    /// pinned open when the preference is on, otherwise the live binding the table
    /// drives itself.
    ///
    /// One function rather than the three near-identical computed properties this
    /// replaces — `calendarTableExpandedBinding`, `listTableExpandedBinding`, and
    /// `releasesSummaryExpandedBinding` — each of which restated the same conditional
    /// against a different state variable and had to be kept in step with the other two
    /// by hand. The three `@State` flags stay separate, because the tables genuinely
    /// expand independently; only the shared rule is consolidated.
    private func expansionBinding(_ state: Binding<Bool>) -> Binding<Bool> {
        autoExpandRightSidebarTables ? .constant(true) : state
    }

    /// Shared header shown once above the tab plane so it persists across all three
    /// tabs without rebuilding. Extracted from `body` to keep that expression within
    /// the type-checker's budget.
    @ViewBuilder
    private var sidebarHeader: some View {
        if let film = selectedFilm {
            VStack(spacing: 0) {
                Header(filmID: film.id)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                Divider()
                    .padding(.horizontal, 16)
            }
        }
    }

    /// Per-tab content laid out as a single horizontal plane: all tabs occupy fixed,
    /// index-ordered slots (each one sidebar-width wide), and the whole strip is panned
    /// so the selected tab fills the viewport. Switching tabs changes only the pan
    /// offset, so the outgoing and incoming tabs always travel together in the
    /// spatially correct direction (Details is left of Metadata is left of Notes,
    /// exactly as in the tab header) with no overlap — there are no per-tab
    /// insertion/removal transitions whose direction could be captured stale. The strip
    /// is always mounted so the pan offset always has a prior value to animate from,
    /// which is what makes both the first swipe and rapid consecutive swipes slide
    /// instead of snap.
    ///
    /// Which slots hold *real* content is gated by `isTabRendered`: at rest only the
    /// selected tab is real (a single live AppKit scroll view — so scrolling keeps its
    /// native-smooth frame rate and selecting a film from an empty selection builds
    /// just one tab), and only during a swipe do the neighbors that can scroll into
    /// view become real. Every other slot is a lightweight placeholder that holds the
    /// slot geometry so the pan never reindexes. The pan animates for swipes only:
    /// MainView applies `.transaction { animation = nil }` to its whole layout
    /// container (to stop the sidebar 'jiggling' on left-sidebar state changes), which
    /// propagates down; because a descendant `.transaction` is applied after an
    /// ancestor's, re-setting the animation here — and only while a swipe is animating
    /// — restores the slide for swipes while leaving that jiggle fix and every
    /// non-swipe (instant) tab switch untouched.
    ///
    /// Every rendered-but-not-selected slot (the neighbor(s) kept resident so the swipe
    /// window is armed — see `isTabRendered`) is additionally excluded from AppKit's
    /// hit-test chain via the slot's `AppKitScrollActivation` (see `tabActivations`). `.clipped()`
    /// only stops those slots from being *painted*; it does nothing to stop AppKit
    /// hit-testing from reaching the real `NSScrollView` (and every native control
    /// inside it) that each tab's content hosts via `SidebarScrollView`/
    /// `AppKitScrollView`, because that hit-testing walks actual `NSView` frames in
    /// the window's real coordinate space, not the SwiftUI clip mask. A non-selected
    /// slot's `HStack` position can sit outside the clipped viewport — directly over
    /// the gallery for the slot one step before the selected tab — and without this,
    /// its still-live (merely invisible) `NSScrollView` silently intercepts clicks
    /// meant for the gallery there, exactly as FilmSheet's `FilmSheetScrollView`
    /// found for its own inactive tabs. `isTabActiveForHitTesting(_:)` computes which
    /// slots stay hit-testable: the selected tab, plus — only while a swipe's slide
    /// is actually animating — the tab it is animating away from, so the two tabs
    /// genuinely visible mid-slide both remain interactive for the duration; every
    /// other resident slot (including a third tab kept merely pre-armed for the next
    /// possible swipe) is excluded throughout, at rest and during swipes alike. See
    /// `AppKitScrollActivation` and `HitTestGatedScrollView` in
    /// `98.20 UtilityKit.swift` for the actual mechanism — a pure `hitTest(_:)`
    /// gate, not `isHidden`, so reactivating a tab never triggers AppKit's automatic
    /// scroll-indicator reveal flash. None of this touches the swipe gesture itself:
    /// recognition runs entirely through the local `NSEvent` monitor installed in
    /// `installSwipeMonitor()`, which inspects scroll-wheel events
    /// directly and never depends on any tab's hit-testing.
    private var tabPlane: some View {
        // A hard `sidebarWidth`-wide, full-height viewport that clips the panning
        // strip. The base is `Color.clear`, which — unlike the rigid strip — is
        // flexible and so collapses to exactly the width the sidebar offers (the
        // sidebar is pinned to `sidebarWidth`). The strip is an overlay, which does
        // NOT enlarge the base, so `.clipped()` clips to the viewport rather than to
        // the strip's full 3-panel width. (A plain `.frame(maxWidth: .infinity)`
        // around the strip cannot do this: a flexible max-width frame can't shrink
        // below its child's rigid minimum, so it would grow to the full strip width
        // and clip nothing — the bug this replaces.)
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Self.tabOrder, id: \.self) { tab in
                        Group {
                            if isTabRendered(tab) {
                                let isActiveSlot = isTabActiveForHitTesting(tab)
                                tabContent(for: tab)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .allowsHitTesting(isActiveSlot)
                                    .environment(\.sidebarTabActivation, tabActivations[tab])
                                    .appKitScrollActivation(tabActivations[tab]!, isActive: isActiveSlot)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(minWidth: Self.sidebarWidth,
                               maxWidth: Self.sidebarWidth,
                               maxHeight: .infinity)
                    }
                }
                .offset(x: -CGFloat(selectedIndex) * Self.sidebarWidth)
            }
            .clipped()
            // Exposes a stable NSView reference matching this fixed (non-panning)
            // viewport's frame, so the swipe-recognizing NSEvent monitor installed
            // in .onAppear can test whether a scroll-wheel event falls within the
            // sidebar's content area. See SidebarSwipeZoneAnchor and
            // installSwipeMonitor().
            .background(SidebarSwipeZoneAnchor(anchor: $swipeZoneAnchor))
            // Animate the pan for swipes only. MainView nils the ambient transaction
            // for the whole sidebar (its 'jiggle' fix); re-injecting the spring here —
            // as a descendant, and only while a swipe is animating — restores the slide
            // for swipe-driven tab changes while leaving that fix and every non-swipe
            // (instant) switch untouched. Nothing is inserted in the viewport during a
            // swipe (the incoming tab is already resident via the swipe window), so the
            // pan is the only visible change and it simply slides; the off-screen
            // window bookkeeping that does occur is clipped away and never seen.
            .transaction { txn in
                if isSwipeAnimating {
                    txn.animation = Self.swipeAnimation
                }
            }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if hasSelection {
                // Content area with scrolling handled independently inside each tab.
                VStack(spacing: 0) {
                    // Spacer under the tab bar.
                    Color.clear.frame(height: 30)
                    
                    if isMultiSelection {
                        // Show multi-selection placeholder.
                        multiSelectionPlaceholder
                    } else {
                        // Shared header — rendered once above the tab content so it
                        // persists visually across all three tabs without rebuilding.
                        sidebarHeader
                        
                        // Per-tab content laid out as a single horizontal plane. See
                        // `tabPlane` for the full rationale; extracted into its own
                        // property so the body stays within the type-checker's budget.
                        tabPlane
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sidebarClearedForDrag {
                // A live drag is dragging a film that differs from whatever was
                // displayed (or about to be displayed); show a dedicated interim
                // message rather than either stale content or the default
                // "no selection" placeholder. See clearForDragInterim().
                dragInProgressPlaceholder
            } else {
                // Fixed, vertically centered placeholder (non-scrollable).
                noSelectionPlaceholder
            }
            
            // Tab bar (fixed, floats above content).
            tabsHeader
                .padding(.horizontal, 4)
                .padding(.top, 1)
                .padding(.bottom, 1)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(Divider(), alignment: .bottom)
                .zIndex(1)
        }
        .frame(minWidth: Self.sidebarWidth, maxWidth: Self.sidebarWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        // Inject the selected film snapshot into the local environment for all sidebar children.
        .environment(\.sidebarFilm, selectedFilm)
        // Inject the horizontal-scroll-zone registrar so SidebarScrollView can pass
        // it along into each tab's NSHostingView subtree. See
        // HorizontalScrollZoneRegistrar and installSwipeMonitor().
        .environment(\.horizontalScrollZoneRegistrar, horizontalScrollZoneRegistrar)
        // Defer the swipe window's neighbor tabs until just after the selected tab has
        // painted. Restarts whenever the film changes; the deferral below lets the
        // selected tab's (instant) paint commit before `neighborsReadyFilmID` is
        // advanced, which is what pulls the heavier neighbor tabs into the view tree.
        // The neighbors sit off-screen, so their slightly later arrival is invisible
        // and leaves the swipe fully armed well before any gesture could occur.
        //
        // This intentionally does NOT use `Task.yield()`. A yield only re-enqueues
        // this task behind whatever other work is already queued on the MainActor
        // executor — it has no defined relationship to AppKit's screen-update commit
        // for the current run-loop pass. Under light MainActor load a yield can
        // resume before that commit, in which case the neighbor tabs would be built
        // into the *same* CA commit as the selected tab, defeating the point of
        // staging them at all. `DispatchQueue.main.async` is the guarantee actually
        // needed here: a block enqueued on the main queue runs only after the
        // current run-loop pass (and its screen flush) has completed — the same
        // reasoning already relied on for the alert-presentation deferral pattern
        // elsewhere in this app. Bridged into the task via a checked continuation so
        // the rest of this modifier chain stays structured-concurrency-based.
        .task(id: selectedFilm?.id) {
            // Quiet-window gate. `.task(id:)` is canceled and restarted on every film
            // change, so this sleep IS the debounce — no extra state, no timer to cancel
            // by hand: a burst of rapid arrow presses simply never gets past this line
            // until the user stops. See `Self.neighborArmingQuietWindow` for why the
            // neighbors (and only the neighbors) are the right thing to debounce.
            try? await Task.sleep(for: Self.neighborArmingQuietWindow)
            guard !Task.isCancelled else { return }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
            // The id-scoped task is canceled and replaced the instant a new film is
            // selected while this is still suspended; guard against advancing
            // `neighborsReadyFilmID` for a selection that's already stale by the
            // time the main-queue hop completes.
            guard !Task.isCancelled else { return }
            neighborsReadyFilmID = selectedFilm?.id
        }
        // Adaptive debouncing: combines view switching delay with scrolling performance.
        .onChange(of: selectionState.selectedFilmIDs) { oldIDs, newIDs in
            handleSelectionChange(oldIDs: oldIDs, newIDs: newIDs)
        }
        // Single consolidated listener for film updates.
        // This replaces scattered listeners in child components.
        .onReceive(AppEventBus.shared.filmEvents) { event in
            handleFilmEvent(event)
        }
        // Swipe-driven tab navigation. installSwipeMonitor() (see below) recognizes
        // a horizontal two-finger trackpad swipe over the sidebar's content area
        // and broadcasts a .rightSidebarSwipe view event; this is the only path
        // that animates a tab change. Only .rightSidebarSwipe is handled here —
        // every other ViewEvent is ignored, so this subscription does no work for
        // unrelated view activity.
        .onReceive(AppEventBus.shared.viewEvents) { event in
            if case .rightSidebarSwipe(let direction) = event {
                handleSwipe(direction)
            }
        }
        // MARK: Drag Deferral Flush
        // The deferred content resolution flushes at whichever structural boundary
        // resolves the gesture that gated it:
        //  - .dragDeferralWindowDidEnd — the item-hit click resolved as a plain click
        //    (posted synchronously from the gallery view's mouseUp handling).
        //  - .dragSessionDidEnd — the click became a drag; GalleryDragEngine posts
        //    this from its session-end callbacks, which AppKit defers until after its
        //    drag-completion rendering pass (including the native cancel fly-back
        //    animation, when one runs) — the same anchor AlertHostView uses for the
        //    Film Queue drop alert.
        // In both cases flushDragDeferredResolution()'s one-turn
        // DispatchQueue.main.async hop moves the heavy content rebuild off the
        // notification's delivery stack (an AppKit mouse/delegate callback) into its
        // own run-loop pass, so it never shares a CA commit with the gesture's final
        // frame. Resolution reads selectionState's LIVE selection, so any churn that
        // occurred while deferred settles correctly, and the pending-flag guard makes
        // every boundary with nothing pending a strict no-op.
        .onReceive(NotificationCenter.default.publisher(for: .dragDeferralWindowDidEnd)) { _ in
            flushDragDeferredResolution()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dragSessionDidEnd)) { _ in
            flushDragDeferredResolution()
        }
        // MARK: Drag-Start Interim Clear
        // Posted the instant a drag session is structurally committed to begin —
        // see DragSessionMonitor.sessionWillBegin(). If a selection change already
        // landed during the preceding click-ambiguity window (hasDragDeferredResolution
        // is already true), the sidebar is showing content that is now known to be
        // stale for the film actually being dragged; clear it immediately rather than
        // waiting for the drag to end. See handleDragSessionWillBegin().
        .onReceive(NotificationCenter.default.publisher(for: .dragSessionWillBegin)) { _ in
            handleDragSessionWillBegin()
        }
        // Installs the horizontal-swipe NSEvent monitor once, for the lifetime of
        // this (omnipresent) view. Idempotent — installSwipeMonitor() no-ops if a
        // monitor is already installed, so this is safe even if .onAppear were
        // ever invoked more than once.
        .onAppear {
            installSwipeMonitor()
        }
        // Cancel any in-flight adaptive-debounce resolution task on dismount.
        // The replace-on-new-selection case is already handled by the cancel() call
        // at the top of handleSelectionChange; this covers the dismount case, ensuring
        // the task does not run against a deallocated view hierarchy.
        .onDisappear {
            resolutionTask?.cancel()
            resolutionTask = nil
            hasDragDeferredResolution = false
            sidebarClearedForDrag = false
            swipeResetTask?.cancel()
            swipeResetTask = nil
            removeSwipeMonitor()
        }
    }
    
    // MARK: - View Components
    
    /// A fixed two-row text block for sidebar placeholder messages. Always
    /// reserves space for two lines: the last line passed in is rendered in the
    /// bottom row, and — if a second line is supplied — the preceding line is
    /// rendered in the top row. When only one line is supplied, the top row is
    /// still present (holding an invisible placeholder character at zero
    /// opacity) so the block's overall height never changes.
    ///
    /// This keeps the bottom row's vertical position fixed regardless of whether
    /// the surrounding placeholder text is one line or two, so switching between
    /// placeholder strings (e.g. "no selection" vs. "drag in progress") never
    /// shifts the text up or down. Callers vertically center this block as a
    /// whole (typically via `Spacer()`s above and below) the same way as before.
    @ViewBuilder
    private func placeholderTextBlock(_ lines: [String]) -> some View {
        let hasTopLine = lines.count > 1
        // When there's no second line, the row still renders a single space rather
        // than an empty string. An empty `Text` can report a slightly smaller
        // intrinsic height than one with real content (there's no glyph to
        // establish the full font ascent/descent box in some layout passes), which
        // is what caused the bottom row to shift by a hair. A space character has
        // the same font metrics as any other character, so the row's height is
        // always identical whether or not it's actually showing text.
        let topLine = hasTopLine ? lines[0] : " "
        let bottomLine = lines.last ?? ""
        VStack(spacing: 4) {
            Text(topLine)
                .opacity(hasTopLine ? 1 : 0)
                .fontWeight(.semibold)
            Text(bottomLine)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
    
    /// Point size of the placeholder glyph. Matches `StandardPlaceholder`'s glyph
    /// size (see 90_00_GlobalUtilities.swift) so the sidebar's empty states read
    /// at the same scale as the gallery's.
    private static let placeholderGlyphSize: CGFloat = 64

    /// Fixed height of the glyph's container. Mirrors `StandardPlaceholder`'s own
    /// fixed container: different SF Symbols report different intrinsic heights at
    /// the same point size, so pinning the container guarantees the text below it
    /// never moves when the glyph swaps between placeholder states.
    private static let placeholderGlyphContainerHeight: CGFloat = 100

    /// Vertical gap between the glyph container and the text block.
    private static let placeholderGlyphToTextSpacing: CGFloat = 2

    /// Purely visual nudge applied to the drag-session glyph.
    ///
    /// `cursorarrow.and.square.on.square.dashed` carries an extra cursor arrow to
    /// the left of its stacked squares, which pushes those squares to the right of
    /// the symbol's own center. Centering the symbol therefore does *not* center
    /// the squares, so they land in a different spot than the plain
    /// `square.on.square` used for the multi-selection placeholder. Shifting the
    /// whole symbol left by roughly the width the arrow adds puts the squares back
    /// in the same apparent position as that glyph's.
    ///
    /// Tweak these two values to taste — negative `width` moves the glyph left,
    /// negative `height` moves it up. The offset is cosmetic only: it is applied
    /// *inside* the fixed-height glyph container, so it can never change the
    /// placeholder block's footprint or move the text below it.
    private static let dragGlyphOffsetX: CGFloat = 0
    private static let dragGlyphOffsetY: CGFloat = 7

    /// The glyph shown above a placeholder's text, sized and colored to match the
    /// gallery's `StandardPlaceholder`. Rendered inside a fixed-height container so
    /// the composed block's overall height is identical for every glyph.
    ///
    /// `offset` applies an optional per-glyph visual nudge (see
    /// `dragGlyphOffsetX` / `dragGlyphOffsetY`). It affects only where the symbol
    /// is drawn within the container, never the container's own geometry.
    @ViewBuilder
    private func placeholderGlyph(_ glyph: String, offset: CGSize = .zero) -> some View {
        VStack {
            Image(systemName: glyph)
                .font(.system(size: Self.placeholderGlyphSize))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
                .offset(x: offset.width, y: offset.height)
        }
        .frame(height: Self.placeholderGlyphContainerHeight)
    }

    /// Vertically centers a glyph plus its `placeholderTextBlock` in the full
    /// sidebar area.
    ///
    /// `topInset` reserves the height of the floating tab bar for the two
    /// placeholders that sit directly in the outer ZStack (`dragInProgress…` and
    /// `noSelection…`), so their content centers within the area *below* that bar.
    /// The multi-selection placeholder passes `0`: it is nested inside the content
    /// VStack, which already opens with a 30pt spacer under the tab bar.
    ///
    /// Both the glyph container and the text block are fixed-height, so the
    /// composed block occupies exactly the same space in every placeholder state —
    /// switching between them changes only what is drawn, never where it sits.
    @ViewBuilder
    private func centeredPlaceholder(
        glyph: String,
        glyphOffset: CGSize = .zero,
        topInset: CGFloat,
        _ lines: [String]
    ) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 0) {
                placeholderGlyph(glyph, offset: glyphOffset)
                placeholderTextBlock(lines)
                    .padding(.top, Self.placeholderGlyphToTextSpacing)
            }
            Spacer()
        }
        .padding(.top, topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var multiSelectionPlaceholder: some View {
        centeredPlaceholder(glyph: "square.on.square", topInset: 0, [
            "Multiple Films Selected",
            "Select a film from the gallery to view details."
        ])
    }
    
    private var dragInProgressPlaceholder: some View {
        centeredPlaceholder(
            glyph: "cursorarrow.and.square.on.square.dashed",
            glyphOffset: CGSize(width: Self.dragGlyphOffsetX, height: Self.dragGlyphOffsetY),
            topInset: 30, [
            "Drag Session In-Progress",
            "Details will appear after it concludes."
        ])
    }
    
    private var noSelectionPlaceholder: some View {
        centeredPlaceholder(glyph: "square.text.square", topInset: 30, [
            "Nothing Selected",
            "Select a film from the gallery to view details."
        ])
    }
    
    @ViewBuilder
    private func tabContent(for tab: RightSidebarTab) -> some View {
        switch tab {
        case .details:
            RTabDetails(
                calendarTableExpanded: expansionBinding($calendarTableExpanded),
                listTableExpanded: expansionBinding($listTableExpanded)
            )
        case .releases:
            RTabReleases(releasesSummaryExpanded: expansionBinding($releasesSummaryExpanded))
        case .notes:
            RTabNotes()
        }
    }
    
    @ViewBuilder
    private var tabsHeader: some View {
        CustomTabHeader(
            selectedTab: selectedTab,
            enabled: hasSelection && !isMultiSelection,
            showIcons: Preferences.showRightSidebarTabIcons,
            disabledTabs: notesDisabledTabs,
            onTabSelect: { viewStateManager.setRightSidebarTab($0) }
        )
    }
    
    /// The set of tabs that should be individually disabled.
    /// Notes is disabled when the selected film has no notes content.
    private var notesDisabledTabs: Set<RightSidebarTab> {
        guard let film = selectedFilm, !film.hasNotesContent else { return [] }
        return [.notes]
    }
    
    /// Index of the currently selected tab within `tabOrder`; drives the plane's pan.
    private var selectedIndex: Int {
        Self.tabOrder.firstIndex(of: selectedTab) ?? 0
    }
    
    /// The tabs that render real content on the plane: the selected tab and its
    /// immediate neighbors (the only tabs that can become visible during a single-
    /// step swipe), minus any disabled tab. Every other slot renders a lightweight
    /// placeholder, so heavy tabs (e.g. Details' tables) aren't built while off in
    /// the wings, yet the slot geometry stays fixed so the pan never reindexes.
    private var swipeWindowTabs: Set<RightSidebarTab> {
        let tabs = Self.tabOrder
        guard let idx = tabs.firstIndex(of: selectedTab) else { return [selectedTab] }
        let lower = max(0, idx - 1)
        let upper = min(tabs.count - 1, idx + 1)
        return Set(tabs[lower...upper]).subtracting(notesDisabledTabs)
    }
    
    /// Whether a given plane slot holds real content rather than a placeholder.
    ///
    /// The selected tab always renders immediately, so a new selection paints its
    /// visible content instantly. Its neighbors — the rest of the swipe window, needed
    /// only so a swipe can slide the incoming tab in rather than insert (fade) it — are
    /// brought in a beat later, once `neighborsReadyFilmID` catches up to the current
    /// film (scheduled just after the selected tab paints; see the `.task` in `body`).
    /// Gating on the film id rather than a bare flag means every new selection is
    /// instant again: the stale id no longer matches, so only the selected tab paints
    /// until the neighbors are rescheduled. Tabs outside the window are always
    /// placeholders. (`AppKitScrollView` keeps its `GeometryReader` — removing it was
    /// evaluated separately and rejected as not worth the risk. Scrolling smoothness
    /// here instead comes from the fact that each tab's `NSScrollView` is never
    /// subclassed and never overrides `scrollWheel(with:)` at all: swipe recognition
    /// lives entirely in the standalone `NSEvent` local monitor installed by
    /// `installSwipeMonitor()`, which returns ordinary vertical-scroll events
    /// unchanged. It is therefore not affected by the live scroll-view count — a few
    /// small sidebar scroll views are cheap next to the gallery's own AppKit scroll
    /// view.)
    private func isTabRendered(_ tab: RightSidebarTab) -> Bool {
        if tab == selectedTab { return true }
        guard neighborsReadyFilmID == selectedFilm?.id else { return false }
        return swipeWindowTabs.contains(tab)
    }
    
    // MARK: - Event Handling
    
    /// Flushes a resolution that was deferred by the drag-deferral gate in
    /// handleSelectionChange. Invoked from the `.dragDeferralWindowDidEnd` and
    /// `.dragSessionDidEnd` onReceive handlers in `body`; see the comment there for
    /// the notification semantics and the rationale for the one-turn hop. The inner
    /// re-check keeps the flush provably consistent even if two boundary
    /// notifications race their async hops (the first to run clears the flag; the
    /// second no-ops).
    private func flushDragDeferredResolution() {
        guard hasDragDeferredResolution else { return }
        DispatchQueue.main.async {
            guard hasDragDeferredResolution else { return }
            hasDragDeferredResolution = false
            sidebarClearedForDrag = false
            applySelection(selectionState.selectedFilmIDs)
        }
    }

    /// Resolves `ids` into the displayed film and brings the sidebar's per-selection
    /// state in line with it. These three steps were previously written out together
    /// at all four resolution sites (empty-selection, synchronous, debounced, and
    /// drag-deferred flush); they must always run as a unit, so they are one call.
    private func applySelection(_ ids: Set<UUID>) {
        // Time this resolution's own CoreAnimation commit. A transaction completion
        // block fires when *this* state change has been committed, so the reading is
        // attributable to this resolution alone.
        //
        // A main-queue hop was used here originally and was wrong: once several
        // resolutions are queued, such a block measures the time for the whole queue to
        // drain, not the cost of one step. That made every sample during a burst — the
        // only samples that matter for this decision — read far too high, so the window
        // pinned to its cap instead of tracking the real cost.
        let start = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            let cost = CACurrentMediaTime() - start
            Task { @MainActor [selectionTiming] in selectionTiming.lastResolutionCost = cost }
        }
        CATransaction.commit()

        resolveSelectedFilm(from: ids)
        resetTableExpansionStates()
        resetTabIfNeeded()
    }

    /// Marks the pending resolution as drag-deferred when the composite drag-deferral
    /// window is open, and reports whether the caller should therefore stop.
    ///
    /// Returns `false` (window closed) in the overwhelmingly common case, leaving all
    /// state untouched so the caller resolves normally. Returns `true` only after
    /// setting `hasDragDeferredResolution`, which
    /// `flushDragDeferredResolution()` later consumes at the gesture's structural
    /// boundary.
    ///
    /// When a genuine drag session is already in flight (as opposed to just an
    /// ambiguous, not-yet-a-drag click), the displayed content is known stale right
    /// now — the `.dragSessionWillBegin` notification that would otherwise catch this
    /// already fired before this change landed — so the sidebar is interim-cleared
    /// here. That is deliberately *not* done when the click window is merely open and
    /// the drag is unconfirmed: a click that resolves as a plain click by mouseUp
    /// never needed it.
    ///
    /// Identical logic previously appeared verbatim at both gate sites in
    /// `handleSelectionChange` — the synchronous entry check and the re-check inside
    /// the 75 ms debounced task — where the two copies had to be kept in step by hand.
    private func deferResolutionIfWindowActive() -> Bool {
        guard DragSessionMonitor.shared.isDeferralWindowActive else { return false }
        hasDragDeferredResolution = true
        if DragSessionMonitor.shared.isDragSessionActive {
            clearForDragInterim()
        }
        return true
    }

    /// Reacts to `.dragSessionWillBegin`. If a selection change already landed
    /// during the preceding click-ambiguity window — `hasDragDeferredResolution` is
    /// already true — the sidebar's currently-displayed content (if any) is now
    /// known to be stale relative to the film actually being dragged, since a
    /// mismatched selection change is the only thing that sets that flag (see
    /// `handleSelectionChange`). Clear it immediately rather than leaving it
    /// visible until the drag ends. A no-op whenever no such mismatch is pending
    /// (e.g. the user is dragging the film that was already displayed).
    private func handleDragSessionWillBegin() {
        guard hasDragDeferredResolution else { return }
        clearForDragInterim()
    }

    /// Interim-clears the sidebar to `dragInProgressPlaceholder`, in place of
    /// whatever was previously displayed — including the default "no selection"
    /// placeholder. That default text is just as much a stale mismatch during an
    /// active drag as a loaded film would be: the gallery's focus ring has already
    /// moved onto the dragged item, so leaving "Select a film from the gallery..."
    /// in place is misleading in exactly the same way stale film details would be.
    /// Idempotent via `sidebarClearedForDrag`. Table expansion state is reset here
    /// too, matching every other path that clears `selectedFilm`, so a later
    /// flush's own reset is simply redundant rather than load-bearing.
    private func clearForDragInterim() {
        guard !sidebarClearedForDrag else { return }
        sidebarClearedForDrag = true
        hasSelection = false
        isMultiSelection = false
        selectedFilm = nil
        resetTableExpansionStates()
    }

    /// Handles selection changes with adaptive debouncing.
    ///
    /// Normal navigation — including fast *discrete* switching between films (e.g. arrow-
    /// tapping through search results or a user-generated list) — resolves the film
    /// **synchronously** in the same run-loop turn for zero-delay display, regardless of
    /// how quickly successive selections arrive. A debounce is applied only when the
    /// selection change is confirmed to originate from a held arrow key, so dozens of
    /// expensive view rebuilds are never queued while the user is still scrolling.
    ///
    /// The decision is driven by `SelectionState.lastSelectionInputKind`:
    ///
    /// - `.keyRepeat`  — the change came from `NSEvent.isARepeat == true` (the user is
    ///   holding an arrow key). Debounce. This is AppKit's own authoritative signal, true on
    ///   the very first repeat event of a held key, so there is no one-event lag that a
    ///   purely timestamp-based heuristic could not avoid.
    /// - `.discrete`   — the change came from a single deliberate input whose non-repeat
    ///   status is known at the call site (a discrete arrow-key tap). Resolve **instantly**,
    ///   with no debounce, no matter how quickly successive discrete changes arrive. This is
    ///   what keeps deliberate fast switching feeling real-time: it is never debounced on a
    ///   timing technicality.
    /// - `.unspecified` — the source could not supply an authoritative signal (native
    ///   NSTableView list-view arrow navigation, programmatic batch selection, marquee/drag,
    ///   report-driven selection). For these, fall back to the inter-event timing heuristic
    ///   so debounce protection degrades gracefully rather than disappearing entirely.
    ///
    /// `selectionTiming.lastChangeTime` is updated on every call that actually reaches the debounce
    /// decision — i.e. every call not already short-circuited by the drag-deferral gate or the
    /// empty-selection branch above it — so the fallback stays accurate for `.unspecified`
    /// sources even on turns where the decision is settled by an authoritative kind. The two
    /// short-circuited paths leave the stamp alone deliberately: neither represents a
    /// navigation step whose spacing the heuristic is trying to measure, and the resulting
    /// staleness can only widen the next measured gap, which errs toward resolving
    /// synchronously rather than toward debouncing something that should have been instant.
    private func handleSelectionChange(oldIDs: Set<UUID>, newIDs: Set<UUID>) {
        // Cancel any in-flight debounced resolution before processing the new event.
        resolutionTask?.cancel()

        // MARK: Drag-Session / Click-Window Deferral
        // If the composite drag-deferral window is active — an item-hit click gesture
        // is still ambiguous (mouseDown seen, not yet resolved as click or drag) OR a
        // drag session is in flight — do NOT resolve now. Selection commits at
        // mouseDown, so its one-turn-deferred SelectionState write lands squarely
        // inside that window; resolving here would rebuild the sidebar's full content
        // tree (header + tab plane) in exactly the frames a fast drag needs for its
        // session start (or, once a session is live, inside the session's run loop) —
        // the source of the drag-start hitch. Instead, mark the resolution pending
        // and return; the flush runs at whichever structural boundary resolves the
        // gesture: `.dragDeferralWindowDidEnd` (plain click — content lands at
        // mouseUp, with the focus ring having appeared at mouseDown) or
        // `.dragSessionDidEnd` (drag — content lands at session end). Both are
        // lifecycle anchors from DragSessionMonitor / GalleryDragEngine, never
        // wall-clock timers, so this is a strict no-op for keyboard, marquee, and
        // programmatic selection changes.
        //
        // The empty (clear) case is gated too: a mid-gesture clear cannot originate
        // from the gallery views themselves, but a programmatic clear tearing down
        // the whole content tree inside the window would contend identically, and
        // the flush handles it correctly.
        if deferResolutionIfWindowActive() { return }

        // Past the deferral gate, no drag-related interim state can still be
        // correct: this change is being resolved normally, in this run-loop turn or
        // shortly after. Clearing here keeps `sidebarClearedForDrag` from outliving
        // the gesture that set it on any path that does not run through
        // flushDragDeferredResolution(). Without this, a selection *clear* arriving
        // after an interim clear but outside the deferral window would leave the
        // "Drag session in progress" placeholder on screen permanently, since
        // `hasDragDeferredResolution` would already be false and no later flush
        // could ever reset it. A strict no-op in the overwhelmingly common case
        // where the flag is already false.
        //
        // `hasDragDeferredResolution` is cleared alongside it, because the two genuinely
        // do share one lifecycle (see `clearForDragInterim`) and this was the one site
        // that reset only half of the pair. Reaching here means this change is being
        // resolved normally *now*, so any resolution still marked pending from an earlier
        // gesture has been superseded and there is nothing left for a later flush to do.
        // Left set, it would survive to the next unrelated `.dragDeferralWindowDidEnd` /
        // `.dragSessionDidEnd` and drive a spurious `applySelection` — not merely wasted
        // work, since that call also runs `resetTableExpansionStates()` and
        // `resetTabIfNeeded()`, so it would silently collapse a table the user had
        // expanded (and reset the tab when `rememberRightSidebarTab` is off). Both
        // assignments are strict no-ops on the overwhelmingly common path.
        sidebarClearedForDrag = false
        hasDragDeferredResolution = false

        // Clearing selection is always synchronous — no debounce needed.
        if newIDs.isEmpty {
            applySelection(newIDs)
            return
        }

        // Update the fallback timestamp for every change that reaches this point, so the
        // `.unspecified` path below stays accurate regardless of which branch ultimately
        // decides this turn. Changes short-circuited above (deferred, or a clear) do not
        // stamp it — see the note on this function.
        let now = Date()
        let timeSinceLastChange = now.timeIntervalSince(selectionTiming.lastChangeTime)
        selectionTiming.lastChangeTime = now
        let lastResolutionCost = selectionTiming.lastResolutionCost
        let isFallbackRapidNavigation = timeSinceLastChange < 0.15

        // Decide whether to debounce, preferring the authoritative input kind and using the
        // timing heuristic only when no authoritative signal is available.
        let isRapidNavigation: Bool
        switch selectionState.lastSelectionInputKind {
        case .keyRepeat:
            // Held arrow key: debounce so we don't queue a rebuild per intermediate film.
            isRapidNavigation = true
        case .discrete:
            // Deliberate single tap/click. The rule is *not* a fixed delay — it is
            // "never start a new resolution faster than the last one took to finish".
            //
            // A discrete press resolves instantly whenever the sidebar can keep up,
            // which is the overwhelmingly common case and the behavior this branch was
            // introduced to guarantee: any press arriving after a gap longer than the
            // previous resolution's measured cost is synchronous, exactly as before.
            // Only when presses arrive *faster than the sidebar can render* does this
            // coalesce them — and at that point resolving each one is not merely
            // wasted, it is actively harmful: every intermediate rebuild is torn down
            // unseen by the next press while occupying the main thread that AppKit
            // needs to dispatch the next key event. That backlog is what makes the
            // selection itself fall seconds behind the user's presses; the highlight is
            // set synchronously in `handleArrowKey`, so it can only lag if the events
            // themselves are queued behind render work.
            //
            // Because the window is the measured cost rather than a constant, it
            // self-tunes: on a light film it is a millisecond or two (effectively
            // always instant), on a heavy one it is just wide enough to stop the queue
            // from growing. It can never exceed `maxCoalescingWindow`.
            isRapidNavigation = timeSinceLastChange < min(lastResolutionCost, Self.maxCoalescingWindow)
        case .unspecified:
            // No authoritative signal for this source: fall back to inter-event timing.
            isRapidNavigation = isFallbackRapidNavigation
        }
        
        if isRapidNavigation {
            // Debounce during rapid navigation to avoid render congestion.
            //
            // A held key (`.keyRepeat`) uses the fixed 75 ms settle window it always
            // has. A coalesced discrete burst instead waits only as long as the last
            // resolution actually took: that is by construction the shortest delay that
            // stops the render queue from outrunning the key queue, and it keeps the
            // content arriving as close to the user's final press as the machine
            // allows. Both are capped by `maxCoalescingWindow`.
            let settleWindow: Duration = selectionState.lastSelectionInputKind == .keyRepeat
                ? .milliseconds(75)
                : .seconds(min(lastResolutionCost, Self.maxCoalescingWindow))

            resolutionTask = Task { @MainActor in
                try? await Task.sleep(for: settleWindow)
                guard !Task.isCancelled else { return }

                // Re-check the drag-deferral gate. The gate was open when this turn
                // began, but 75 ms is long enough for the user to have pressed the
                // mouse on a gallery item in the interim (e.g. key-repeat navigation
                // immediately followed by a click-drag). Resolving here would rebuild
                // the full content tree inside exactly the frames the drag needs —
                // the hitch the gate exists to prevent. Defer to the same structural
                // boundary instead; the flush resolves from the LIVE selection, so
                // `newIDs` going unused on this path cannot produce a stale display.
                if deferResolutionIfWindowActive() { return }

                applySelection(newIDs)
            }
        } else {
            // Normal (non-rapid) navigation: resolve synchronously with zero delay.
            // MemoryStore.getFilm is an O(1) dictionary lookup; no async work is
            // required. Resolving here ensures the sidebar content appears in the
            // same frame as the gallery selection highlight, eliminating the
            // previously visible ~5 ms delay on fresh-launch first-click.
            applySelection(newIDs)
        }
    }
    
    /// Consolidated film event handler.
    /// Both .updated and .releaseChanged refresh the environment snapshot when the
    /// affected film is the one currently displayed. DataCoordinator keeps
    /// FilmSnapshot.releases in sync after any release mutation, so the two events
    /// require the same response: re-read the snapshot from MemoryStore and push it
    /// through the environment. Children that care about release-specific changes
    /// (e.g. RSBReleasesSection) observe the film value itself and react via
    /// onChange(of: film).
    private func handleFilmEvent(_ event: FilmEvent) {
        guard let currentFilmID = selectedFilm?.id else { return }

        switch event {
        case .updated(let updatedFilmID),
             .releaseChanged(let updatedFilmID):
            if updatedFilmID == currentFilmID {
                refreshCurrentFilm()
            }
        case .deleted(let deletedIDs):
            // Several delete paths leave the selection standing (DuplicateSheet, Delete
            // List Contents, the menu's delete). Drop the copied snapshot and re-resolve,
            // so a deleted film is not shown — or edited, or given a viewing — from here.
            // resolveSelectedFilm's "already loaded" short-circuit is why the copy is
            // cleared first; a selection still naming the film then resolves to nothing.
            if deletedIDs.contains(currentFilmID) {
                selectedFilm = nil
                resolveSelectedFilm(from: selectionState.selectedFilmIDs)
            }
        default:
            break
        }
    }
    
    /// Refreshes the currently selected film snapshot from DataCoordinator.
    private func refreshCurrentFilm() {
        guard let filmID = selectedFilm?.id,
              let updatedFilm = dataCoordinator.getFilm(filmID) else { return }
        selectedFilm = updatedFilm
        fallBackFromNotesTabIfNeeded(for: updatedFilm)
        Self.log("Refreshed film snapshot: \(updatedFilm.name)")
    }

    // MARK: - Film Resolution
    
    /// Resolves a UUID Set to a FilmSnapshot (for single or multi-selection states).
    @MainActor
    private func resolveSelectedFilm(from ids: Set<UUID>) {
        // No selection.
        guard !ids.isEmpty else {
            selectedFilm = nil
            hasSelection = false
            isMultiSelection = false
            return
        }
        
        // Multi-selection.
        if ids.count > 1 {
            selectedFilm = nil
            hasSelection = true
            isMultiSelection = true
            Self.log("Multi-selection: \(ids.count) films")
            return
        }
        
        // Single selection. `ids.first` is guaranteed non-nil here because the
        // prior guards rejected empty sets and multi-selection.
        let id = ids.first!

        // If the same film is already loaded, don't re-fetch.
        if selectedFilm?.id == id {
            Self.log("Film already loaded: \(selectedFilm?.name ?? "Unknown")")
            hasSelection = true
            isMultiSelection = false
            return
        }

        // Fetch snapshot from DataCoordinator (reads from MemoryStore — no SwiftData touch).
        if let snapshot = dataCoordinator.getFilm(id) {
            selectedFilm = snapshot
            hasSelection = true
            isMultiSelection = false
            fallBackFromNotesTabIfNeeded(for: snapshot)
            Self.log("Loaded film snapshot: \(snapshot.name)")
        } else {
            selectedFilm = nil
            hasSelection = false
            isMultiSelection = false
            Self.log("Film not found: \(id)")
        }
    }
    
    /// Falls back to the Details tab when the currently selected tab is Notes but
    /// the given film has no notes content. This prevents the sidebar from showing
    /// an empty Notes tab after navigating to a film that has none.
    private func fallBackFromNotesTabIfNeeded(for film: FilmSnapshot) {
        if selectedTab == .notes && !film.hasNotesContent {
            viewStateManager.setRightSidebarTab(.details)
        }
    }
    
    /// Resets all table expansion states.
    private func resetTableExpansionStates() {
        // Guarded rather than assigned unconditionally: SwiftUI does not dedupe a
        // `@State` write against its current value, so assigning `false` to a flag that
        // is already `false` still invalidates the view. These are false for the great
        // majority of selections, which made this three needless invalidations per
        // selection step.
        if calendarTableExpanded { calendarTableExpanded = false }
        if listTableExpanded { listTableExpanded = false }
        if releasesSummaryExpanded { releasesSummaryExpanded = false }
    }
    
    /// Resets tab to Details if preference is disabled.
    private func resetTabIfNeeded() {
        if !rememberRightSidebarTab {
            viewStateManager.resetRightSidebarTab()
        }
    }
    
    // MARK: - Swipe Navigation
    
    /// The canonical left-to-right ordering of the sidebar tabs used for swipe navigation.
    private static let tabOrder: [RightSidebarTab] = [.details, .releases, .notes]
    
    /// Advances or retreats the selected tab by one step in response to a sidebar
    /// swipe event. Swipes past either end of the tab strip, and swipes into a
    /// disabled tab (Notes when the film has no notes content), are silently ignored
    /// — reproducing the "nothing to its left/right" no-op the design calls for.
    ///
    /// The tab switch changes `selectedIndex`, which drives the plane's pan offset;
    /// setting `isSwipeAnimating` first makes that offset change animate (the scoped
    /// `.transaction` re-injects the spring past MainView's ambient nil). The pan
    /// direction is inherent in the offset math — the plane's tabs sit at fixed,
    /// index-ordered positions — so it is always spatially correct, with no direction
    /// state that could be captured stale or fall out of sync.
    private func handleSwipe(_ direction: RightSidebarSwipeDirection) {
        // Only navigate when a single film is selected and displayed.
        guard hasSelection, !isMultiSelection else { return }
        
        let tabs = Self.tabOrder
        guard let currentIndex = tabs.firstIndex(of: selectedTab) else { return }
        
        let targetIndex = (direction == .forward) ? currentIndex + 1 : currentIndex - 1
        guard tabs.indices.contains(targetIndex) else { return }
        
        let target = tabs[targetIndex]
        
        // Skip disabled tabs (e.g. Notes when the selected film has no notes content).
        guard !notesDisabledTabs.contains(target) else { return }
        
        // Capture the tab being animated away from before it flips, so
        // isTabActiveForHitTesting(_:) can keep it click-active for the duration of
        // the slide — it is the one still genuinely visible sliding out, and it reads
        // as more correct for a tab the user can still see to remain clickable while
        // it's on screen. (Unlike an isHidden-based gate, HitTestGatedScrollView's
        // pure hitTest(_:) override never affects rendering, so this is purely a UX
        // nicety, not something required to prevent the tab from visually vanishing.)
        // Reading `selectedTab` here — before setRightSidebarTab below changes it —
        // is what makes this correct even for a rapid second swipe fired while the
        // first's reset task is still pending.
        departingTab = selectedTab
        
        // Mark the swipe as animating before the tab change so the pan offset change
        // it triggers animates with the spring; button, menu, and keyboard switches
        // leave this false and pan instantly.
        isSwipeAnimating = true
        viewStateManager.setRightSidebarTab(target)
        
        // Stop animating once the slide settles, so later non-swipe switches are
        // instant again. A new swipe cancels this pending reset.
        swipeResetTask?.cancel()
        swipeResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.swipeAnimationDuration))
            guard !Task.isCancelled else { return }
            isSwipeAnimating = false
            departingTab = nil
        }
    }
    
    /// Whether a given tab-plane slot should remain part of AppKit's hit-test chain
    /// (its `NSScrollView` un-hidden and clickable) rather than being excluded from it.
    ///
    /// True for the currently selected tab always, and — only while a swipe's slide
    /// is actually animating — for `departingTab`, the tab it is animating away from.
    /// Those are the only two slots ever genuinely visible inside the clipped
    /// viewport at any given moment (at rest, only the selected tab is; mid-swipe,
    /// the departing and arriving tabs trade places as the pan interpolates between
    /// them). Every other resident slot — most notably a third tab kept merely
    /// pre-armed for the *next* possible swipe (see `isTabRendered`) — sits entirely
    /// outside the viewport at all times and must stay excluded, whether at rest or
    /// mid-swipe, since its off-plane `NSScrollView` would otherwise silently
    /// intercept clicks over whatever real content (the gallery) actually occupies
    /// that screen position. See `tabPlane` and `tabActivations` for how this
    /// feeds into `AppKitScrollView`'s hit-test gate.
    private func isTabActiveForHitTesting(_ tab: RightSidebarTab) -> Bool {
        if tab == selectedTab { return true }
        return isSwipeAnimating && tab == departingTab
    }

    /// Installs the NSEvent local monitor that recognizes a horizontal two-finger
    /// trackpad swipe over the sidebar's content area and broadcasts
    /// `.rightSidebarSwipe` view events. No-ops if a monitor is already installed.
    ///
    /// This recognition logic is functionally identical to the previous
    /// `HorizontalSwipeScrollView.scrollWheel(with:)` override (same threshold,
    /// same phase/momentum handling, same per-gesture de-duplication) — only
    /// *where* it runs has changed. A local monitor inspects every scroll-wheel
    /// event in this app before AppKit's normal dispatch: returning the event
    /// unchanged lets it proceed exactly as if no monitor existed at all (the
    /// vast majority of events — ordinary vertical scrolling — take this path
    /// and reach a plain, never-subclassed NSScrollView with full responsive
    /// scrolling); returning `nil` consumes it. See `SidebarSwipeZoneAnchor` for
    /// how "cursor is over the sidebar" is determined without an NSView subclass.
    private func installSwipeMonitor() {
        guard swipeMonitor == nil else { return }

        let gestureState = swipeGestureState

        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Only recognize while a single film is displayed — mirrors handleSwipe's
            // own guard, so no work happens for an empty or multi-selection sidebar.
            guard hasSelection, !isMultiSelection else { return event }

            // "Cursor is over the sidebar's tab content" gate. swipeZoneAnchor is the
            // tab plane's fixed (non-panning) viewport, so this test is stable across
            // every swipe and every one of the (up to three) concurrently mounted tab
            // scroll views — unlike scoping to an individual scroll view's bounds,
            // there is no ambiguity about which underlying tab happens to be visually
            // present at a given point mid-pan.
            guard let anchor = swipeZoneAnchor,
                  let window = unsafe anchor.window,
                  event.window === window else { return event }

            // Nothing behind a sheet is interactive, and that includes this gesture.
            // The monitor sees scroll-wheel events app-wide *before* AppKit's normal
            // dispatch, so the window-modal blocking AppKit applies to the parent
            // window's view hierarchy never gets a chance to suppress a swipe —
            // without this gate, a two-finger swipe over the (visually blocked)
            // sidebar still switches tabs while a sheet is up. `attachedSheet` is the
            // authoritative AppKit signal here and covers every sheet the app can
            // raise over this window: SwiftUI `.sheet` presentations, NSAlert sheets,
            // and NSOpen/NSSavePanel run as sheets alike. Returning the event (rather
            // than nil) leaves dispatch exactly as if this monitor did not exist, so
            // AppKit's own modal-session handling decides what happens next.
            guard window.attachedSheet == nil else { return event }

            let localPoint = anchor.convert(event.locationInWindow, from: nil)
            guard anchor.bounds.contains(localPoint) else { return event }

            // Let any actively horizontal-scrolling table (ReleasesTable, or the
            // detailed CalendarTable when Preferences.additionalCalTableDetails is
            // enabled) handle its own horizontal scrolling untouched. Without this,
            // a horizontal-dominant gesture beginning over such a table would be
            // captured below as a tab swipe, leaving any of its content past the
            // initial viewport permanently unreachable. Returning the event here —
            // before any of the swipe-recognition or gesture-absorption logic below
            // — means the table's own NSScrollView receives it exactly as if this
            // monitor did not exist at all.
            if horizontalScrollZoneRegistrar.isMouseOverActiveZone {
                return event
            }

            guard event.hasPreciseScrollingDeltas else { return event }

            let phase = event.phase
            let momentumPhase = event.momentumPhase

            // The opening of a new physical gesture re-arms recognition.
            if phase.contains(.began) {
                gestureState.consumed = false
            }

            // Once this gesture has switched a tab, absorb the remainder of the SAME
            // physical gesture — its trailing finger-down frames (.changed) and its
            // momentum (momentumPhase) — so no residual delta reaches any tab's
            // scroll view. Without this, that residual drives a stray
            // overscroll/rubber-band, or an unwanted extra scroll on the
            // newly-selected tab immediately after the swipe.
            if gestureState.consumed,
               momentumPhase != [] || phase.contains(.changed) {
                return nil
            }

            // Only trackpad gestures carry precise deltas together with an active
            // (finger-down) gesture phase; physical scroll wheels, momentum frames,
            // and terminating .ended events fall straight through to normal,
            // untouched scrolling.
            guard phase.contains(.began) || phase.contains(.changed) else {
                return event
            }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY

            // Horizontal-dominant motion never scrolls the sidebar vertically.
            // Recognize a deliberate swipe once the threshold is crossed; either way,
            // consume the event so no horizontal delta ever reaches a scroll view —
            // matters even when no swipe is recognized (a sub-threshold nudge, or a
            // swipe past the first/last tab, must not leak through and drive a
            // horizontal overscroll/rubber-band). Vertical-dominant motion is
            // returned unchanged, preserving normal, fully responsive scrolling.
            guard abs(dx) > abs(dy) else { return event }

            if !gestureState.consumed {
                if dx < -Self.swipeRecognitionThreshold {
                    gestureState.consumed = true
                    AppEventBus.shared.rightSidebarSwipe(.forward)
                } else if dx > Self.swipeRecognitionThreshold {
                    gestureState.consumed = true
                    AppEventBus.shared.rightSidebarSwipe(.backward)
                }
            }
            return nil
        }
    }

    /// Removes the horizontal-swipe NSEvent monitor installed by
    /// `installSwipeMonitor()`. Safe to call even if no monitor is installed.
    private func removeSwipeMonitor() {
        if let monitor = swipeMonitor {
            NSEvent.removeMonitor(monitor)
            swipeMonitor = nil
        }
    }
}

// MARK: - SelectionTiming

/// The timing inputs to RightSidebar's selection debounce. One instance per sidebar, held
/// in `@State` for its identity only — like `SwipeGestureState` below — so writing these
/// values never invalidates the view.
@MainActor
private final class SelectionTiming {
    /// When the last selection change reached the debounce decision. Retained only as a
    /// fallback heuristic for selection sources that cannot supply an authoritative
    /// key-repeat signal (see `handleSelectionChange`).
    var lastChangeTime: Date = .distantPast

    /// Wall time the most recent sidebar resolution took to reach the end of its
    /// run-loop turn — i.e. how long that selection step actually occupied the main
    /// thread, layout and CoreAnimation commit included. Measured rather than assumed,
    /// because the cost is entirely film-dependent: a film with no releases, no
    /// viewings and no notes resolves in a couple of milliseconds, while one with a
    /// long viewing history and a full release table costs an order of magnitude more.
    ///
    /// This is what `handleSelectionChange` uses to decide whether a *discrete* press
    /// needs coalescing (see there). It starts at zero, so the very first resolution of
    /// a session is always instant.
    var lastResolutionCost: TimeInterval = 0
}

// MARK: - SwipeGestureState

/// Tracks whether the current physical trackpad gesture has already triggered a
/// tab switch. A single instance is created once per `RightSidebar` (see
/// `swipeGestureState`) and captured by that sidebar's single, long-lived NSEvent
/// monitor — unlike the previous NSScrollView-subclass design, this never needs to
/// be `static`, since there is only ever one monitor (and therefore only one
/// instance of this state) for the sidebar's entire lifetime.
@MainActor
private final class SwipeGestureState {
    var consumed = false
}

// MARK: - Right Sidebar Tab CustomTab Conformance
extension RightSidebarTab: CustomTab {
    var iconName: String {
        switch self {
        case .details: return "square.text.square"
        case .releases: return "opticaldisc.fill"
        case .notes: return "square.and.pencil"
        }
    }
}

// MARK: - SidebarPrewarm

/// Builds the sidebar's Header and Details tab once for a real film in an offscreen,
/// transparent window, lays it out and draws it, then throws it away. The session's first
/// selection otherwise pays SwiftUI's first-use costs in front of the user (type metadata,
/// the first sizing of every hosted AppKit control, font resolution): the `first-selection`
/// harness scenario measured ~200 ms against ~72 ms for later selections, and ~96 ms with
/// this warm-up (with EventKitManager.prewarm taking the calendar daemon's share).
@MainActor
enum SidebarPrewarm: Loggable {
    nonisolated static let logTag = "[SidebarPrewarm]"
    private static var done = false

    /// Called once at launch; skipped if a film is already selected, since the real
    /// sidebar has then paid the cost itself.
    static func runIfIdle(dataCoordinator: DataCoordinator) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["FT_NO_SIDEBAR_PREWARM"] == "1" { return }
        #endif
        guard SelectionState.shared.selectedFilmIDs.isEmpty,
              let film = dataCoordinator.films.first else { return }
        run(film: film, dataCoordinator: dataCoordinator)
    }

    static func run(film: FilmSnapshot, dataCoordinator: DataCoordinator) {
        guard !done else { return }
        done = true
        let start = CACurrentMediaTime()
        let content = VStack(spacing: 0) {
            Header(filmID: film.id)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            Divider()
                .padding(.horizontal, 16)
            RTabDetails(calendarTableExpanded: .constant(false), listTableExpanded: .constant(false))
        }
        .frame(width: RightSidebar.sidebarWidth, height: 900)
        .environment(\.sidebarFilm, film)
        .environment(dataCoordinator)
        .environment(SelectionState.shared)

        let frame = NSRect(x: -10_000, y: -10_000, width: RightSidebar.sidebarWidth, height: 900)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: frame.size)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        host.display()
        log("Built in \(Fmt.fixed((CACurrentMediaTime() - start) * 1000, 1)) ms")
        // Let onAppear work and the first commit run, then tear it down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            window.orderOut(nil)
            window.contentView = nil
        }
    }
}
