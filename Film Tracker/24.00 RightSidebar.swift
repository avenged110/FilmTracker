// MARK: - RightSidebar.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The omnipresent right sidebar: film information and contextual tabs for the selected gallery
// item. It keeps a stable film snapshot across tab switches to avoid reloads. Also contains
// SidebarScrollView and SidebarEnvironmentModifier, the AppKitScrollView facade and environment
// modifier used by the three sidebar tab views.

import SwiftUI
import AppKit
import QuartzCore

// Environment key for the selected film snapshot. Child views use sidebarFilm.id instead of a
// separate UUID.
private struct SidebarFilmKey: EnvironmentKey {
    static let defaultValue: FilmSnapshot? = nil
}

extension EnvironmentValues {
    var sidebarFilm: FilmSnapshot? {
        get { self[SidebarFilmKey.self] }
        set { self[SidebarFilmKey.self] = newValue }
    }
}

// Environment key carrying the tab slot's `AppKitScrollActivation`. The object is created once
// per slot (see `tabActivations` on RightSidebar) and never replaced, so the value never changes.
// Only the flag inside it does, and SwiftUI does not observe that. A flag placed in the
// environment directly would be bridged into each tab's NSHostingView and re-resolve the whole
// tree on every tab switch.
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

/// Tracks whether the cursor is over an actively horizontal-scrolling table in the sidebar. Such
/// a table is reached through `CustomTable`'s `allowHorizontalScroll` path, the only path that
/// registers a zone. RightSidebar's swipe monitor (see `installSwipeMonitor()`) checks this, so
/// a horizontal scroll that starts over such a table scrolls the table instead of turning the
/// tab. Without it, table content past the first viewport would be unreachable.
///
/// In this build only the detailed `CalendarTable` qualifies, when
/// `Preferences.additionalCalTableDetails` is on. `DiscReleasesTable`'s live `.releaseCard`
/// layout passes `allowHorizontalScroll: false`, since it fits the sidebar width. Its `.standard`
/// layout passes `true` but has no call site (see the maintenance note atop
/// `24.21 ReleasesTable.swift`). Restoring it would add a second zone here with no change on
/// this side.
///
/// Driven by SwiftUI's `.onHover`, not manual `NSView` frame math. These tables sit inside a
/// horizontally panning, vertically scrolling hierarchy, and converting a window point through
/// it with `NSView.convert(_:from:)` is unreliable. SwiftUI's hit-testing already resolves
/// the cursor's view through every layer, so relying on it avoids re-deriving that geometry.
@MainActor
final class HorizontalScrollZoneRegistrar {
    private var activeZones: Set<UUID> = []

    /// True while the cursor is hovering over at least one registered zone.
    var isMouseOverActiveZone: Bool { !activeZones.isEmpty }

    /// Marks zone `id` as hovered or not. Safe to repeat with the same value.
    func setActive(_ id: UUID, active: Bool) {
        if active {
            activeZones.insert(id)
        } else {
            activeZones.remove(id)
        }
    }

    /// Clears every zone. RightSidebar calls this on a tab switch, which moves a hovered table
    /// away from a stationary pointer without sending a hover exit.
    func removeAll() {
        activeZones.removeAll()
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

// MARK: - Profile Flags

/// DEBUG launch flags that switch off one piece of the sidebar's load work, for A/B runs of
/// the `rsb-load` harness scenario (99.20). Release builds read none of them.
enum RSBProfileFlags {
    #if DEBUG
    /// `-FTNeighborArmingAllAtOnce`: arm both neighbor tabs in one commit, without staging.
    static let neighborsAllAtOnce = ProcessInfo.processInfo.arguments.contains("-FTNeighborArmingAllAtOnce")
    /// `-FTRSBNoTopPinnedLayout`: RSBTopPinnedLayout passes its proposal straight through.
    static let noTopPinnedLayout = ProcessInfo.processInfo.arguments.contains("-FTRSBNoTopPinnedLayout")
    /// `-FTRSBNoViewport`: SidebarScrollView tracks no viewport height.
    static let noViewport = ProcessInfo.processInfo.arguments.contains("-FTRSBNoViewport")
    /// `-FTRSBNoSidebar`: MainView puts an empty view where the sidebar goes, so a run
    /// measures what a selection costs everything else.
    static let noSidebar = ProcessInfo.processInfo.arguments.contains("-FTRSBNoSidebar")
    /// `-FTRSBSwiftUICrewRows`: Metadata's crew sections draw their rows as a ForEach of
    /// SearchableItemRow rather than as CrewRowList.
    static let swiftUICrewRows = ProcessInfo.processInfo.arguments.contains("-FTRSBSwiftUICrewRows")
    /// `-FTRSBNoCrewBlock`: Metadata leaves out its cast-and-crew block (measurement only).
    static let noCrewBlock = ProcessInfo.processInfo.arguments.contains("-FTRSBNoCrewBlock")
    /// `-FTRSBNoReleaseCards`: the Releases tab leaves out its card stack (measurement only).
    static let noReleaseCards = ProcessInfo.processInfo.arguments.contains("-FTRSBNoReleaseCards")
    /// `-FTRSBNoNotesFrames`: the Notes tab leaves out its two frames tables (measurement only).
    static let noNotesFrames = ProcessInfo.processInfo.arguments.contains("-FTRSBNoNotesFrames")
    /// `-FTRSBSwiftUIFramesRows`: the Notes tab's frames tables draw their rows as a ForEach of
    /// FrameEntryRow rather than as FramesRowList.
    static let swiftUIFramesRows = ProcessInfo.processInfo.arguments.contains("-FTRSBSwiftUIFramesRows")
    /// `-FTRSBNoTabBar`: a same-height empty strip replaces the tab bar (measurement only).
    static let noTabBar = ProcessInfo.processInfo.arguments.contains("-FTRSBNoTabBar")
    /// `-FTRSBNoHeader`: a fixed-height empty block replaces the Header (measurement only).
    static let noHeader = ProcessInfo.processInfo.arguments.contains("-FTRSBNoHeader")
    /// `-FTRSBFlatPlane`: only the selected tab, placed directly, with no panning strip,
    /// neighbor slots, or swipe animation (measurement only).
    static let flatPlane = ProcessInfo.processInfo.arguments.contains("-FTRSBFlatPlane")
    /// `-FTTabBarNoEquatable`: CustomTabHeader re-diffs on every parent update.
    static let tabBarNoEquatable = ProcessInfo.processInfo.arguments.contains("-FTTabBarNoEquatable")
    #else
    static let neighborsAllAtOnce = false
    static let noTopPinnedLayout = false
    static let noViewport = false
    static let noSidebar = false
    static let swiftUICrewRows = false
    static let noCrewBlock = false
    static let noReleaseCards = false
    static let noNotesFrames = false
    static let swiftUIFramesRows = false
    static let noTabBar = false
    static let noHeader = false
    static let flatPlane = false
    static let tabBarNoEquatable = false
    #endif
}

// MARK: - SidebarViewport

/// The visible height of one sidebar tab's scroll view, for hosted content that sizes itself to
/// the viewport (the Releases tab's empty states). It is a reference with a stable identity, so
/// a resize invalidates only the views that read `height`. Passing the height through
/// SidebarEnvironmentModifier would change the modifier on every resize step and re-render every
/// tab's hosted tree.
@Observable @MainActor
final class SidebarViewport {
    var height: CGFloat = 0
}

private struct SidebarViewportKey: EnvironmentKey {
    static let defaultValue: SidebarViewport? = nil
}

extension EnvironmentValues {
    /// Nil outside a SidebarScrollView.
    var sidebarViewport: SidebarViewport? {
        get { self[SidebarViewportKey.self] }
        set { self[SidebarViewportKey.self] = newValue }
    }
}

// MARK: - SidebarEnvironmentModifier

/// Re-injects sidebarFilm, DataCoordinator, the zone registrar, and the viewport into the
/// NSHostingView subtree. NSHostingView does not inherit the SwiftUI environment, so this lets
/// child views read all four with @Environment.
private struct SidebarEnvironmentModifier: ViewModifier {
    let sidebarFilm: FilmSnapshot?
    let dataCoordinator: DataCoordinator
    let horizontalScrollZoneRegistrar: HorizontalScrollZoneRegistrar?
    let viewport: SidebarViewport

    func body(content: Content) -> some View {
        content
            .environment(\.sidebarFilm, sidebarFilm)
            .environment(dataCoordinator)
            .environment(\.horizontalScrollZoneRegistrar, horizontalScrollZoneRegistrar)
            .environment(\.sidebarViewport, viewport)
    }
}

// MARK: - SidebarScrollView

/// SwiftUI wrapper for the right sidebar's three scrollable tabs. It reads sidebarFilm and
/// DataCoordinator from the environment and re-injects them into the hosted content. At the start
/// of each live scroll it calls AppEventBus.shared.rightSidebarDidStartLiveScroll(), so sidebar
/// subscribers (for example WatchDetails' viewing popover) can dismiss before content re-lays out.
struct SidebarScrollView<Content: View>: View {

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @Environment(\.sidebarFilm) private var sidebarFilm: FilmSnapshot?
    @Environment(DataCoordinator.self) private var dataCoordinator
    @Environment(\.horizontalScrollZoneRegistrar) private var horizontalScrollZoneRegistrar
    // Whether this slot is active comes from its stable activation object, not a Bool. A Bool,
    // as a parameter or environment value, changes on every tab switch and re-measures the tab's
    // whole hosted tree. See SidebarTabActivationKey above and "isActive / hit-test isolation"
    // in `98.20 UtilityKit.swift`.
    @Environment(\.sidebarTabActivation) private var tabActivation

    /// This scroll view's visible height, handed to the hosted content (see SidebarViewport).
    @State private var viewport = SidebarViewport()

    var body: some View {
        AppKitScrollView(
            modifier: SidebarEnvironmentModifier(
                sidebarFilm: sidebarFilm,
                dataCoordinator: dataCoordinator,
                horizontalScrollZoneRegistrar: horizontalScrollZoneRegistrar,
                viewport: viewport
            ),
            activation: tabActivation,
            onScrollWillStart: {
                AppEventBus.shared.rightSidebarDidStartLiveScroll()
            },
            // A different film is a new subject, so the tab returns to the top here. A per-film `.id()` on the tab
            // content would do it by rebuilding the whole scroll view (see the note on `tabPlane`).
            contentResetKey: sidebarFilm?.id
        ) {
            content
        }
        .modifier(SidebarViewportTracking(viewport: viewport))
    }
}

/// Keeps a SidebarViewport's height current. Off under `RSBProfileFlags.noViewport`.
private struct SidebarViewportTracking: ViewModifier {
    let viewport: SidebarViewport

    @ViewBuilder
    func body(content: Content) -> some View {
        if RSBProfileFlags.noViewport {
            content
        } else {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if viewport.height != height { viewport.height = height }
            }
        }
    }
}

// MARK: - SidebarSwipeZoneAnchor

/// A zero-footprint `NSViewRepresentable` that supplies a stable `NSView` for the tab plane's
/// fixed viewport frame. RightSidebar's horizontal-swipe `NSEvent` monitor (see
/// `installSwipeMonitor()`) uses it to test whether a scroll event falls in the sidebar's content
/// area. That is the "cursor is over this view" check `scrollWheel(with:)` would provide, without
/// an `NSScrollView` subclass and its scrolling cost (see `98.20 UtilityKit.swift`).
private struct SidebarSwipeZoneAnchor: NSViewRepresentable {
    @Binding var anchor: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Defer the write one run-loop turn, so the view is in its window before anything reads
        // `.window` or `.bounds`. Mirrors WindowAccessor.
        Task { @MainActor in
            anchor = view
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Writes only when the reference changes. updateNSView runs on every render pass, so an
        // unconditional write would trigger needless updates.
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

    // Registry of horizontal-scroll zones (in this build only the detailed CalendarTable, when enabled; see
    // HorizontalScrollZoneRegistrar) that the swipe monitor must let scroll natively rather than intercepting as a
    // tab swipe. Must be @State, not a plain `let`. The body re-initializes plain stored properties on every render,
    // but installSwipeMonitor's NSEvent closure is installed once (in .onAppear) and captures the instance that
    // existed then. A plain `let` would give CustomTable's .onHover a different registrar from the one the closure
    // checks, so the check would always read false. @State keeps one instance for the sidebar's lifetime, like
    // swipeZoneAnchor, swipeMonitor, and swipeGestureState below.
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
    // Expansion state for the Releases tab's summary table, the only releases-table expansion state the sidebar owns.
    @State private var releasesSummaryExpanded: Bool = false

    /// The Releases tab's purchase filter. It lives here, not in the tab, because the tab's view
    /// does not survive a selection change: an off-screen slot is a placeholder until the new
    /// film's neighbors are armed, and a deselect removes the plane. A filter kept in the tab
    /// would be lost, so the remember preference could not hold it. Reset to `.all` on a
    /// selection change unless that preference is on (see the `.onChange` in `body`).
    @State private var releasesPurchaseFilter: RSBPurchaseFilter = .all
    
    // Adaptive debounce state for film resolution during rapid scrolling.
    @State private var resolutionTask: Task<Void, Never>?

    /// The debounce decision's timing inputs (see `SelectionTiming`). Held in one persistent
    /// reference, not as `@State` values. Both are written on every selection step and read
    /// only by `handleSelectionChange`, never by `body`, so as state they would only schedule
    /// renders with nothing to show.
    @State private var selectionTiming = SelectionTiming()

    /// Ceiling on the self-tuning coalescing window derived from
    /// `selectionTiming.lastResolutionCost`. The clamp stops one slow resolution, such as a stall
    /// from unrelated main-thread work, from making the next press feel sluggish.
    private static let maxCoalescingWindow: TimeInterval = 0.12


    // True when a selection change arrived during the composite drag-deferral window (an
    // item-hit click still ambiguous, or a drag session in flight; see
    // DragSessionMonitor.isDeferralWindowActive). Its content resolution was deferred to the
    // window's end. flushDragDeferredResolution() resolves from selectionState's live selection,
    // never a stashed snapshot, so a stale value cannot be shown. See handleSelectionChange.
    @State private var hasDragDeferredResolution: Bool = false

    // True once the sidebar is cleared for a live drag of a film other than the one shown (see
    // `clearForDragInterim()` and `handleDragSessionWillBegin()`). The body then shows
    // `dragInProgressPlaceholder`. This flag is always reset with `hasDragDeferredResolution`.
    @State private var sidebarClearedForDrag: Bool = false
    
    // MARK: - Swipe Navigation State
    
    // True only while a swipe-initiated tab change animates. It gates the scoped `.transaction`
    // that re-injects the spring (see the tab plane below), so swipes animate while every other
    // tab change (button, menu, keyboard) pans instantly. This is a plain flag, not a direction.
    // The slide direction is implicit in the pan offset, so no direction state can fall out of sync.
    @State private var isSwipeAnimating: Bool = false
    
    // Clears `isSwipeAnimating` once a swipe settles. Stored so a rapid second swipe can cancel
    // the pending reset. Canceled on dismount.
    @State private var swipeResetTask: Task<Void, Never>? = nil
    
    // The tab a swipe animates away from: `selectedTab` just before `handleSwipe` changes it.
    // `nil` when no swipe is animating. `isTabActiveForHitTesting(_:)` uses it, so the departing
    // tab, still visible mid-slide, stays click-active. Every other resident but not visible slot,
    // including a third tab pre-armed for the next swipe, does not. Cleared with `isSwipeAnimating`.
    @State private var departingTab: RightSidebarTab? = nil
    
    /// How long the selection must stay put before the off-screen neighbor tabs are built (see
    /// `isTabRendered` and the `.task` in `body`).
    ///
    /// The neighbors exist so a swipe can slide the incoming tab in rather than insert it. They
    /// are never visible at rest, but each costs as much to build as the visible tab: a fresh
    /// `NSScrollView` and `NSHostingView` hosting a full module stack. `isTabRendered` drops every
    /// neighbor slot when the film changes. Keeping them mounted would not avoid the cost, because
    /// an inactive slot buffers its root view hand-off, so the re-measure would land at the start
    /// of the swipe instead. Arming them after every film change would also run during rapid arrow
    /// navigation, where the next keypress tears each build down before a swipe could use it.
    ///
    /// Debouncing here, rather than in `handleSelectionChange`, is the point. The visible tab still
    /// resolves and paints synchronously on every discrete press. Only the invisible pre-arming
    /// waits for the user to settle. 180 ms is shorter than the gap between the last arrow press
    /// and any possible two-finger swipe, so the swipe window is armed by the time a gesture could
    /// begin.
    private static let neighborArmingQuietWindow: Duration = .milliseconds(180)

    /// Resumes on the next main-queue turn, after the current run-loop pass and its screen
    /// flush. See the neighbor-arming `.task` in `body` for why not `Task.yield()`.
    private static func nextMainQueueTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    /// The film whose neighbor tabs are resident behind the selected tab. When it does not match
    /// the current film (right after a selection change), only the selected tab renders, keeping
    /// the initial paint instant. A deferred task then sets it to the current film, making the rest
    /// of the swipe window resident. See `isTabRendered` and the `.task` in `body`.
    @State private var neighborsReadyFilmID: UUID? = nil

    /// How much of the swipe window is armed for `neighborsReadyFilmID`. With the middle tab
    /// selected there are two neighbors. Building both in one commit would be one long main-thread
    /// stretch, so they are armed one run-loop turn apart, the priority neighbor first (see
    /// `priorityNeighbor`). With one neighbor there is nothing to split, so arming goes straight
    /// to `.all`.
    @State private var neighborArmingStage: NeighborArmingStage = .all

    private enum NeighborArmingStage { case priority, all }

    // The spring for swipe-driven tab changes only. It is re-applied locally (see the tab plane's
    // `.transaction` below), because MainView nils the ambient transaction to suppress sidebar
    // 'jiggle', and that would strip this animation before it reaches the pan. It mirrors the
    // ReleaseCard carousel. `swipeAnimationDuration` is the conservative settle time after which
    // `isSwipeAnimating` is cleared.
    private static let swipeAnimation: Animation = .spring(response: 0.35,
                                                           dampingFraction: 0.85)
    private static let swipeAnimationDuration: Double = 0.6
    
    // The sidebar's fixed width, which sets each tab panel's width and the pan distance per swipe
    // step. The sidebar frame is pinned to it, so the plane reads the constant directly. Measuring
    // the laid-out panels to size them is a layout feedback loop that runs away to a non-finite
    // width and hangs. A GeometryReader around the active AppKit scroll view also degrades scrolling.
    static let sidebarWidth: CGFloat = 300

    // MARK: - Swipe Recognition State
    //
    // Swipe recognition runs in a standalone NSEvent local monitor, the same pattern as the ReleaseCard carousel
    // (FSTabReleasesView). A subclass of NSScrollView that overrode scrollWheel(with:) was ruled out, since it hurt
    // scrolling smoothness (see HorizontalSwipeScrollView in `98.20 UtilityKit.swift`). The monitor either passes an
    // event through unchanged, so AppKit dispatches it normally, or consumes it. The NSScrollView behind each tab is
    // never subclassed, so its scrolling matches a plain NSScrollView.

    /// The tab plane's fixed viewport, used to test whether a scroll-wheel event falls in the
    /// sidebar's content area. See `SidebarSwipeZoneAnchor`.
    @State private var swipeZoneAnchor: NSView? = nil

    /// The local event monitor, removed on dismount. `Any?` matches the token type
    /// `NSEvent.addLocalMonitorForEvents` returns.
    @State private var swipeMonitor: Any? = nil

    /// Covers one physical gesture. Once true, the rest of that gesture (trailing `.changed`
    /// frames and momentum) is absorbed, so it cannot cause a stray overscroll or extra scroll on
    /// the newly selected tab. It is re-armed on the next gesture's `.began` phase. One monitor
    /// exists for the sidebar's lifetime, so a plain instance property is enough.
    @State private var swipeGestureState = SwipeGestureState()

    /// Minimum absolute horizontal delta for a deliberate swipe. Matches the ReleaseCard carousel
    /// (FSTabReleasesView).
    private static let swipeRecognitionThreshold: CGFloat = 20

    // Preference to control automatic table expansion.
    @AppStorage(preference: Preferences.autoExpandRightSidebarTablesKey)
        private var autoExpandRightSidebarTables: Bool
    
    // Preference to control tab memory behavior.
    @AppStorage(preference: Preferences.rememberRightSidebarTabKey)
        private var rememberRightSidebarTab: Bool

    // Preference to keep the Releases tab's purchase filter across selection changes.
    @AppStorage(preference: Preferences.rememberRightSidebarReleasesFilterKey)
        private var rememberReleasesFilter: Bool
    
    // Computed property for accessing the current tab from ViewStateManager
    private var selectedTab: RightSidebarTab {
        viewStateManager.selectedRightSidebarTab
    }
    
    /// Wraps one of the three table-expansion states in the auto-expand preference:
    /// pinned open when the preference is on, otherwise the live binding the table
    /// drives itself.
    ///
    /// One function for all three table-expansion states, so the shared rule lives in one place. The three `@State`
    /// flags stay separate, because the tables expand independently.
    ///
    /// The pinned-open case returns one shared binding rather than a fresh `.constant(true)`. SwiftUI compares a
    /// binding by its storage identity, so a new constant on every body pass would look like a changed input to the
    /// Details and Releases tabs, which would then get a new rootView (a full re-measure) on every tab switch, swipe,
    /// and neighbor arming.
    private func expansionBinding(_ state: Binding<Bool>) -> Binding<Bool> {
        autoExpandRightSidebarTables ? Self.alwaysExpanded : state
    }

    /// The single pinned-open binding `expansionBinding` hands out. See there.
    private static let alwaysExpanded: Binding<Bool> = .constant(true)

    /// Shared header shown once above the tab plane so it persists across all three
    /// tabs without rebuilding. Extracted from `body` to keep that expression within
    /// the type-checker's budget.
    @ViewBuilder
    private var sidebarHeader: some View {
        if let film = selectedFilm {
            VStack(spacing: 0) {
                Group {
                    if RSBProfileFlags.noHeader {
                        Color.clear.frame(height: 150)
                    } else {
                        Header(filmID: film.id)
                    }
                }
                    .padding(.horizontal, RSBCardChrome.sidebarInset)
                    .padding(.top, 8)
                Divider()
                    .padding(.horizontal, RSBCardChrome.sidebarInset)
            }
        }
    }

    /// The per-tab content, laid out as one horizontal plane. Each tab occupies a fixed,
    /// index-ordered, sidebar-width slot, and the strip is panned so the selected tab fills the
    /// viewport. A tab change moves only the pan offset, so the outgoing and incoming tabs always
    /// travel together in the correct direction (Details, Releases, Notes, as in the tab header).
    /// There are no per-tab insert or remove transitions, so no direction can go stale. The strip
    /// stays mounted, so the pan always has a prior value to animate from. That is why the first
    /// swipe and rapid consecutive swipes both slide rather than snap.
    ///
    /// `isTabRendered` decides which slots hold real content. A new selection builds only the
    /// selected tab. The neighbors a swipe can reach are armed behind it once the selection has
    /// stayed put for `neighborArmingQuietWindow`. Every other slot is a placeholder that keeps
    /// the geometry, so the pan never reindexes. The pan animates only for swipes. MainView applies
    /// `.transaction { animation = nil }` to its layout container to stop sidebar jiggling, and
    /// that propagates down. A descendant `.transaction` applies after its ancestor's, so
    /// re-setting the animation here, and only while a swipe animates, restores the slide and
    /// leaves the jiggle fix and instant tab switches alone.
    ///
    /// Resident but unselected slots are also removed from AppKit hit-testing through their
    /// `AppKitScrollActivation` (see `tabActivations`). `.clipped()` stops painting only, not
    /// hit-testing, which walks real `NSView` frames. An inactive slot can sit over the gallery,
    /// and its still-live `NSScrollView` would intercept clicks meant for the gallery. The same constraint applies to
    /// `FilmSheetScrollView`.`isTabActiveForHitTesting(_:)` keeps hit-testing
    /// on the selected tab and, only during a swipe animation, on the departing tab. Every other
    /// resident slot, including a pre-armed third tab, is excluded. See `AppKitScrollActivation`
    /// and `HitTestGatedScrollView` in `98.20 UtilityKit.swift`. The gate is a pure `hitTest(_:)`
    /// check rather than `isHidden`, so reactivating a tab never triggers AppKit's
    /// scroll-indicator flash. The swipe gesture itself is untouched. Its local `NSEvent` monitor
    /// (`installSwipeMonitor()`) inspects scroll-wheel events directly and never depends on
    /// hit-testing.
    @ViewBuilder
    private var tabPlane: some View {
        if RSBProfileFlags.flatPlane {
            tabContent(for: selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.sidebarTabActivation, tabActivations[selectedTab])
                .appKitScrollActivation(tabActivations[selectedTab]!, isActive: true)
                .background(SidebarSwipeZoneAnchor(anchor: $swipeZoneAnchor))
        } else {
            swipingTabPlane
        }
    }

    private var swipingTabPlane: some View {
        // A `sidebarWidth`-wide, full-height viewport that clips the panning strip. The base is
        // `Color.clear`, which is flexible and collapses to the sidebar's width. The strip is an
        // overlay, so it does not enlarge the base, and `.clipped()` clips to the viewport rather
        // than to the 3-panel strip. A plain `.frame(maxWidth: .infinity)` around the strip would
        // not work: it cannot shrink below the strip's rigid minimum, so it would clip nothing.
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
            // Supplies an NSView matching this fixed viewport's frame, so the swipe monitor (see
            // installSwipeMonitor()) can test whether a scroll event falls in the sidebar's content area.
            .background(SidebarSwipeZoneAnchor(anchor: $swipeZoneAnchor))
            // Animate the pan for swipes only. MainView nils the ambient transaction to stop sidebar
            // jiggling. Re-injecting the spring here, as a descendant and only while a swipe animates,
            // restores the slide and leaves instant tab switches alone. Nothing is inserted during a
            // swipe, since the incoming tab is already resident, so the pan is the only visible change.
            // Any off-screen bookkeeping is clipped away.
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
                        
                        // The per-tab plane (see `tabPlane`). It is a separate property to keep the
                        // body within the type-checker's budget.
                        tabPlane
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sidebarClearedForDrag {
                // A live drag of a different film. Show a dedicated message rather than stale
                // content or the default placeholder (see clearForDragInterim()).
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
        // Passes the zone registrar to SidebarScrollView (see HorizontalScrollZoneRegistrar and
        // installSwipeMonitor()).
        .environment(\.horizontalScrollZoneRegistrar, horizontalScrollZoneRegistrar)
        // Defers the swipe window's neighbor tabs until just after the selected tab has painted.
        // Restarts on every film change. The selected tab's instant paint commits before
        // `neighborsReadyFilmID` advances, which pulls in the heavier neighbor tabs. They sit
        // off-screen, so their later arrival is invisible, and the swipe is armed well before any
        // gesture could occur.
        //
        // Not `Task.yield()`: a yield re-enqueues behind other MainActor work and has no defined
        // relationship to AppKit's screen-update commit. The neighbors could then build into the
        // same CA commit as the selected tab, which defeats the staging. `DispatchQueue.main.async`
        // runs only after the current run-loop pass and its screen flush, the same guarantee the
        // alert-presentation deferral relies on. It is bridged into the task with a checked
        // continuation, so the modifier chain stays structured-concurrency-based.
        .task(id: selectedFilm?.id) {
            // Quiet-window gate. `.task(id:)` cancels and restarts on every film change, so this
            // sleep is the debounce. A burst of arrow presses never passes this line until the user
            // stops. See `Self.neighborArmingQuietWindow`.
            try? await Task.sleep(for: Self.neighborArmingQuietWindow)
            guard !Task.isCancelled else { return }

            await Self.nextMainQueueTurn()
            // Canceled if a new film is selected while this is suspended. The staleness check stops it
            // advancing `neighborsReadyFilmID` for a selection that is already out of date.
            guard !Task.isCancelled else { return }
            // Two neighbors (the middle tab is selected). The priority one is armed now and the other a
            // turn later, so the builds do not share a commit. The stage is written first, so this
            // turn's render sees both values.
            let staged = swipeWindowTabs.count > 2 && !RSBProfileFlags.neighborsAllAtOnce
            neighborArmingStage = staged ? .priority : .all
            neighborsReadyFilmID = selectedFilm?.id
            guard staged else { return }

            await Self.nextMainQueueTurn()
            guard !Task.isCancelled else { return }
            neighborArmingStage = .all
        }
        // Adaptive debouncing: combines view switching delay with scrolling performance.
        .onChange(of: selectionState.selectedFilmIDs) { oldIDs, newIDs in
            handleSelectionChange(oldIDs: oldIDs, newIDs: newIDs)
        }
        // A new displayed film resets the Releases filter to All unless the preference keeps it.
        // This keys on the resolved film, not the raw selection, so a deferred resolution resets it
        // when the new film lands.
        .onChange(of: selectedFilm?.id) { _, _ in
            guard !rememberReleasesFilter, releasesPurchaseFilter != .all else { return }
            RSBHelpers.withoutAnimation { releasesPurchaseFilter = .all }
        }
        // A tab switch clears horizontal-scroll zones. A table's hover exit or onDisappear would
        // normally clear them, but a switch fires neither. The Details tab often stays resident, and
        // a stationary pointer sends no exit, so the swipe monitor would pass every swipe through
        // until the mouse moved. Only the selected tab can hold the pointer, so a switch clears all.
        .onChange(of: selectedTab) { _, _ in
            horizontalScrollZoneRegistrar.removeAll()
        }
        // The single listener for film updates. It replaces listeners in child components.
        .onReceive(AppEventBus.shared.filmEvents) { event in
            handleFilmEvent(event)
        }
        // Swipe-driven tab navigation. installSwipeMonitor() posts `.rightSidebarSwipe` for a
        // horizontal trackpad swipe over the content area. This is the only path that animates a tab
        // change. Other view events are ignored.
        .onReceive(AppEventBus.shared.viewEvents) { event in
            if case .rightSidebarSwipe(let direction) = event {
                handleSwipe(direction)
            }
        }
        // MARK: Drag Deferral Flush
        // The deferred content resolution flushes at the boundary that resolves its gesture:
        //  - .dragDeferralWindowDidEnd: the item-hit click resolved as a plain click. Posted
        //    synchronously from the gallery's mouseUp handling.
        //  - .dragSessionDidEnd: the click became a drag. GalleryDragEngine posts this from its
        //    session-end callbacks, which AppKit defers until after drag-completion rendering,
        //    including any native cancel fly-back. AlertHostView uses the same anchor for the Film
        //    Queue drop alert.
        // flushDragDeferredResolution() hops one turn with DispatchQueue.main.async. That moves the
        // heavy rebuild off the notification's AppKit callback stack into its own run-loop pass, so it
        // never shares a CA commit with the gesture's final frame. It resolves from selectionState's
        // live selection, so churn during the deferral settles correctly. The pending-flag guard makes
        // a boundary with nothing pending a no-op.
        .onReceive(NotificationCenter.default.publisher(for: .dragDeferralWindowDidEnd)) { _ in
            flushDragDeferredResolution()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dragSessionDidEnd)) { _ in
            flushDragDeferredResolution()
        }
        // MARK: Drag-Start Interim Clear
        // Posted when a drag session is committed to begin (see DragSessionMonitor.sessionWillBegin()).
        // If a selection change landed during the click-ambiguity window, the sidebar shows content
        // that is stale for the dragged film. Clear it now rather than when the drag ends.
        .onReceive(NotificationCenter.default.publisher(for: .dragSessionWillBegin)) { _ in
            handleDragSessionWillBegin()
        }
        // Installs the swipe NSEvent monitor for this omnipresent view's lifetime. installSwipeMonitor()
        // is idempotent, so repeat calls are safe.
        .onAppear {
            installSwipeMonitor()
        }
        // Cancels the in-flight resolution task on dismount, so it cannot run against a deallocated
        // view hierarchy. Replacing it on a new selection is handled in handleSelectionChange.
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
    /// Keeps the bottom row's position fixed whether the top text is one or two lines, so switching
    /// placeholder strings never shifts the text. Callers center the block as a whole with `Spacer()`s.
    @ViewBuilder
    private func placeholderTextBlock(_ lines: [String]) -> some View {
        let hasTopLine = lines.count > 1
        // Renders a single space when there is no second line. An empty `Text` measures shorter
        // than one with content. A space has the same font metrics, so
        // the row height never changes.
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
    
    /// Point size of the placeholder glyph. Matches `StandardPlaceholder` (90.00 GlobalUtilities.swift)
    /// so the sidebar's empty states read at the gallery's scale.
    private static let placeholderGlyphSize: CGFloat = 64

    /// Fixed height of the glyph container, matching `StandardPlaceholder`. Symbols differ in
    /// intrinsic height at the same point size, so pinning the container keeps the text from moving
    /// when the glyph changes.
    private static let placeholderGlyphContainerHeight: CGFloat = 100

    /// Vertical gap between the glyph container and the text block.
    private static let placeholderGlyphToTextSpacing: CGFloat = 2

    /// Visual nudge for the drag-session glyph. `cursorarrow.and.square.on.square.dashed` adds a
    /// cursor arrow left of its stacked squares, which pushes the squares right of the symbol's
    /// center. The nudge lines them up with the plain `square.on.square` used for multi-selection.
    /// Negative `width` moves the glyph left, and negative `height` moves it up. The offset is applied
    /// inside the fixed-height container, so it never changes the block's footprint.
    private static let dragGlyphOffsetX: CGFloat = 0
    private static let dragGlyphOffsetY: CGFloat = 7

    /// The glyph above a placeholder's text, sized and colored to match `StandardPlaceholder`. It sits
    /// in a fixed-height container, so every glyph gives the same block height.
    ///
    /// `offset` nudges the symbol within the container (see `dragGlyphOffsetX` and
    /// `dragGlyphOffsetY`). It never changes the container's geometry.
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

    /// Vertically centers a glyph and its text block in the sidebar. `topInset` reserves the height of
    /// the floating tab bar for the placeholders in the outer ZStack. The multi-selection placeholder
    /// passes `0`, since it sits in the content VStack, which opens with a 30 pt spacer under the tab
    /// bar.
    ///
    /// The glyph and text containers are fixed-height, so the block takes the same space in every
    /// state. Switching states changes only what is drawn.
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
            RTabReleases(releasesSummaryExpanded: expansionBinding($releasesSummaryExpanded),
                         purchaseFilter: $releasesPurchaseFilter)
        case .notes:
            RTabNotes()
        }
    }
    
    @ViewBuilder
    private var tabsHeader: some View {
        if RSBProfileFlags.noTabBar {
            Color.clear.frame(height: 28)
        } else {
            realTabsHeader
        }
    }

    private var realTabsHeader: some View {
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
    
    /// The tabs that render real content: the selected tab and its immediate neighbors, which are
    /// the only tabs a single-step swipe can show, minus any disabled tab. Other slots render a
    /// lightweight placeholder, so heavy tabs (such as Details' tables) are not built off screen.
    /// Slot geometry stays fixed, so the pan never reindexes.
    private var swipeWindowTabs: Set<RightSidebarTab> {
        let tabs = Self.tabOrder
        guard let idx = tabs.firstIndex(of: selectedTab) else { return [selectedTab] }
        let lower = max(0, idx - 1)
        let upper = min(tabs.count - 1, idx + 1)
        return Set(tabs[lower...upper]).subtracting(notesDisabledTabs)
    }

    /// The neighbor armed first when two are due: the one before the selected tab, so
    /// from Releases, Details is built ahead of Notes. From an end tab it is the only one.
    private var priorityNeighbor: RightSidebarTab? {
        let tabs = Self.tabOrder
        guard let idx = tabs.firstIndex(of: selectedTab) else { return nil }
        let window = swipeWindowTabs
        return [idx - 1, idx + 1]
            .filter { tabs.indices.contains($0) }
            .map { tabs[$0] }
            .first { window.contains($0) }
    }

    /// Whether a plane slot holds real content rather than a placeholder.
    ///
    /// The selected tab always renders at once, so a new selection paints instantly. Its neighbors
    /// (the rest of the swipe window) are brought in a beat later, once `neighborsReadyFilmID` catches
    /// up to the current film (see the `.task` in `body`). They are needed only so a swipe can slide
    /// the incoming tab in rather than fade it in. Gating on the film id means each new selection is
    /// instant again: the stale id no longer matches, so only the selected tab paints until the
    /// neighbors are rescheduled. Tabs outside the window are always placeholders.
    ///
    /// `AppKitScrollView` keeps its `GeometryReader`. Scrolling stays smooth because each tab's
    /// `NSScrollView` is never subclassed. Swipe recognition lives in the `NSEvent` monitor
    /// (`installSwipeMonitor()`), which passes ordinary vertical scroll events through unchanged. A few
    /// small sidebar scroll views are cheap next to the gallery's own scroll view.
    private func isTabRendered(_ tab: RightSidebarTab) -> Bool {
        if tab == selectedTab { return true }
        guard neighborsReadyFilmID == selectedFilm?.id, swipeWindowTabs.contains(tab) else { return false }
        return neighborArmingStage == .all || tab == priorityNeighbor
    }
    
    // MARK: - Event Handling
    
    /// Flushes a resolution deferred by the drag-deferral gate in handleSelectionChange. It runs from
    /// the `.dragDeferralWindowDidEnd` and `.dragSessionDidEnd` handlers in `body` (see the rationale
    /// there). The re-check keeps it consistent if two boundary notifications race their async hops:
    /// the first clears the flag, and the second does nothing.
    private func flushDragDeferredResolution() {
        guard hasDragDeferredResolution else { return }
        DispatchQueue.main.async {
            guard hasDragDeferredResolution,
                  !DragSessionMonitor.shared.isDeferralWindowActive else { return }
            hasDragDeferredResolution = false
            sidebarClearedForDrag = false
            applySelection(selectionState.selectedFilmIDs)
        }
    }

    /// Resolves `ids` into the displayed film and syncs the sidebar's per-selection state. Every resolution site
    /// (empty, synchronous, debounced, and drag-deferred flush) must run these steps together, so they are one call.
    private func applySelection(_ ids: Set<UUID>) {
        // Times this resolution's own CoreAnimation commit, so the reading reflects this change alone.
        // A transaction completion block fires once this change commits. A main-queue hop would instead
        // measure the whole queue draining, which reads far too high during a burst and pins the window
        // to its cap.
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

    /// Marks the pending resolution as drag-deferred while the drag-deferral window is open, and reports
    /// whether the caller should stop.
    ///
    /// Returns `false` when the window is closed, which is the usual case, and the caller resolves
    /// normally. Returns `true` only after setting `hasDragDeferredResolution`, which
    /// `flushDragDeferredResolution()` consumes at the gesture's boundary.
    ///
    /// If a drag session is already in flight, the displayed content is stale, because the
    /// `.dragSessionWillBegin` notification fired before this change landed. The sidebar is
    /// interim-cleared here. This is not done while the click is merely ambiguous, since a click that
    /// resolves as a plain click never needs it.
    ///
    /// Shared by the synchronous entry check and the re-check inside the debounced task.
    private func deferResolutionIfWindowActive() -> Bool {
        guard DragSessionMonitor.shared.isDeferralWindowActive else { return false }
        hasDragDeferredResolution = true
        if DragSessionMonitor.shared.isDragSessionActive {
            clearForDragInterim()
        }
        return true
    }

    /// Handles `.dragSessionWillBegin`. If a selection change landed during the click-ambiguity window
    /// (`hasDragDeferredResolution` is set), the displayed content is stale for the film being dragged.
    /// Such a change is the only thing that sets that flag (see `handleSelectionChange`). Clear it now.
    /// This is a no-op when no mismatch is pending, such as when the dragged film was already displayed.
    private func handleDragSessionWillBegin() {
        guard hasDragDeferredResolution else { return }
        clearForDragInterim()
    }

    /// Clears the sidebar to `dragInProgressPlaceholder`, replacing whatever was shown, including the
    /// default "no selection" text. During an active drag that text is as stale as a loaded film, because
    /// the gallery's focus ring has already moved to the dragged item. Idempotent via
    /// `sidebarClearedForDrag`. Table expansion state is also reset here, as on every other path that
    /// clears `selectedFilm`, so a later flush's reset is redundant.
    private func clearForDragInterim() {
        guard !sidebarClearedForDrag else { return }
        sidebarClearedForDrag = true
        setSelectionFlags(hasSelection: false, isMultiSelection: false)
        selectedFilm = nil
        resetTableExpansionStates()
    }

    /// Handles selection changes with adaptive debouncing.
    ///
    /// Discrete navigation, including fast arrow taps through search results or a list, resolves the
    /// film synchronously in the same run-loop turn. A debounce applies only when the change comes from
    /// a held arrow key, so the sidebar never queues dozens of rebuilds while the user is still scrolling.
    ///
    /// The decision uses `SelectionState.lastSelectionInputKind`:
    ///
    /// - `.keyRepeat`: `NSEvent.isARepeat` is true (a held arrow key). Debounce. This is AppKit's
    ///   authoritative signal and is true on the first repeat event, so a timestamp heuristic's lag
    ///   does not apply.
    /// - `.discrete`: one deliberate input (an arrow-key tap), known at the call site. Resolve instantly,
    ///   however fast successive taps arrive, so deliberate switching never feels debounced.
    /// - `.unspecified`: no authoritative signal (native NSTableView arrow navigation, programmatic batch
    ///   selection, marquee or drag, report-driven selection). Fall back to the inter-event timing
    ///   heuristic, so debounce protection degrades gracefully.
    ///
    /// `selectionTiming.lastChangeTime` is stamped on every call that reaches the debounce decision, so the
    /// `.unspecified` fallback stays accurate even when an authoritative kind settles the turn. The two
    /// short-circuited paths (the drag-deferral gate and the empty selection) do not stamp it. Neither is
    /// a navigation step the heuristic should measure. The resulting staleness can only widen the next
    /// measured gap, which errs toward instant resolution rather than wrongly debouncing.
    private func handleSelectionChange(oldIDs: Set<UUID>, newIDs: Set<UUID>) {
        // Cancel any in-flight debounced resolution before processing the new event.
        resolutionTask?.cancel()

        // MARK: Drag-Session / Click-Window Deferral
        // While the drag-deferral window is active (an item-hit click is still ambiguous, or a drag session
        // is in flight), do not resolve now. Selection commits at mouseDown, so its deferred write lands
        // inside that window. Resolving here would rebuild the sidebar's content tree in the frames a fast
        // drag needs to start its session, which is the source of the drag-start hitch. Instead, mark the
        // resolution pending and return. The flush runs at the gesture's boundary: `.dragDeferralWindowDidEnd`
        // (a plain click, with content landing at mouseUp) or `.dragSessionDidEnd` (a drag, with content
        // landing at session end). Both are lifecycle anchors from DragSessionMonitor and GalleryDragEngine,
        // not timers, so keyboard, marquee, and programmatic changes are unaffected.
        //
        // A clear is gated too. A programmatic clear that tears down the content tree inside the window would
        // contend the same way, and the flush handles it.
        if deferResolutionIfWindowActive() { return }

        // Past the deferral gate, any drag-related interim state is stale. Clearing here stops
        // `sidebarClearedForDrag` from outliving its gesture on paths that skip flushDragDeferredResolution().
        // Otherwise a selection clear after an interim clear, outside the window, would leave the "Drag
        // session in progress" placeholder up for good, since no later flush could reset it. Both flags
        // are cleared together, since they share one lifecycle (see `clearForDragInterim`). Leaving
        // `hasDragDeferredResolution` set would let a stale pending resolution fire on an unrelated later
        // gesture. That would run `applySelection`, collapse an expanded table, and reset the tab, even
        // when `rememberRightSidebarTab` is on. In the common case both assignments are no-ops.
        sidebarClearedForDrag = false
        hasDragDeferredResolution = false

        // Clearing selection is always synchronous — no debounce needed.
        if newIDs.isEmpty {
            applySelection(newIDs)
            return
        }

        // Stamp the fallback timestamp for every change that reaches this point, so the `.unspecified` path
        // stays accurate whichever branch decides this turn. Short-circuited changes do not stamp it (see
        // the note on this function).
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
            // Deliberate tap or click. The rule is not a fixed delay: never start a new resolution faster than
            // the last one took to finish.
            //
            // A press resolves instantly whenever the sidebar keeps up, which is the usual case. Only when
            // presses arrive faster than the sidebar can render does this coalesce them. Resolving each one
            // would be harmful: every intermediate rebuild is torn down unseen by the next press and occupies
            // the main thread AppKit needs to dispatch the next key event. That backlog is why the selection
            // can fall behind the presses. The highlight is set synchronously in `handleArrowKey`, so
            // it lags only if the events queue behind render work.
            //
            // The window is the measured cost, not a constant, so it self-tunes. A light film gives a
            // short window, effectively instant. A heavy one gives just enough to stop the queue
            // growing. It never exceeds `maxCoalescingWindow`.
            isRapidNavigation = timeSinceLastChange < min(lastResolutionCost, Self.maxCoalescingWindow)
        case .unspecified:
            // No authoritative signal for this source: fall back to inter-event timing.
            isRapidNavigation = isFallbackRapidNavigation
        }
        
        if isRapidNavigation {
            // Debounce during rapid navigation to avoid render congestion.
            //
            // A held key (`.keyRepeat`) uses the fixed 75 ms settle window. A coalesced discrete burst instead
            // waits only as long as the last resolution actually took: that is by construction the shortest delay that
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
                // began, but the settle window is long enough for the user to have pressed the
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
            // Normal navigation resolves synchronously, so the content appears in the same frame as the
            // gallery's selection highlight. The lookup reads MemoryStore and touches no store.
            applySelection(newIDs)
        }
    }
    
    /// Handles film events. `.updated` and `.releaseChanged` both re-read the snapshot when the displayed
    /// film changed. DataCoordinator keeps FilmSnapshot.releases in sync after any release mutation, so
    /// both need the same response. Children that react to release changes (for example RSBReleasesSection)
    /// observe the film value and use onChange(of: film).
    private func handleFilmEvent(_ event: FilmEvent) {
        guard let currentFilmID = selectedFilm?.id else { return }

        switch event {
        case .updated(let updatedFilmID),
             .releaseChanged(let updatedFilmID):
            if updatedFilmID == currentFilmID {
                refreshCurrentFilm()
            }
        case .deleted(let deletedIDs):
            // Several delete paths leave the selection standing (DuplicateSheet, Delete List Contents, the
            // menu's delete). Clear the copied snapshot and re-resolve, so a deleted film is not shown,
            // edited, or given a viewing. resolveSelectedFilm's "already loaded" check is why the copy is
            // cleared first. A selection still naming the film then resolves to nothing.
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
        // An event can arrive for an edit that leaves the snapshot unchanged. Replacing it anyway would
        // change the environment every rendered tab re-injects, re-measuring each.
        guard updatedFilm != selectedFilm else { return }
        selectedFilm = updatedFilm
        fallBackFromNotesTabIfNeeded(for: updatedFilm)
        Self.log("Refreshed film snapshot: \(updatedFilm.name)")
    }

    // MARK: - Film Resolution
    
    /// Resolves a UUID Set to a FilmSnapshot (for single or multi-selection states).
    private func resolveSelectedFilm(from ids: Set<UUID>) {
        // No selection.
        guard !ids.isEmpty else {
            selectedFilm = nil
            setSelectionFlags(hasSelection: false, isMultiSelection: false)
            return
        }
        
        // Multi-selection.
        if ids.count > 1 {
            selectedFilm = nil
            setSelectionFlags(hasSelection: true, isMultiSelection: true)
            Self.log("Multi-selection: \(ids.count) films")
            return
        }
        
        // Single selection. `ids.first` is non-nil here, since the guards above rejected empty and
        // multi-selection sets.
        let id = ids.first!

        // If the same film is already loaded, don't re-fetch.
        if selectedFilm?.id == id {
            Self.log("Film already loaded: \(selectedFilm?.name ?? "Unknown")")
            setSelectionFlags(hasSelection: true, isMultiSelection: false)
            return
        }

        // Fetch snapshot from DataCoordinator (reads from MemoryStore — no store touch).
        if let snapshot = dataCoordinator.getFilm(id) {
            selectedFilm = snapshot
            setSelectionFlags(hasSelection: true, isMultiSelection: false)
            fallBackFromNotesTabIfNeeded(for: snapshot)
            Self.log("Loaded film snapshot: \(snapshot.name)")
        } else {
            selectedFilm = nil
            setSelectionFlags(hasSelection: false, isMultiSelection: false)
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
    
    /// Writes the two selection flags, skipping any that already hold the value. SwiftUI
    /// does not dedupe a `@State` write against its current value (see
    /// `resetTableExpansionStates`), and the resolution paths write these on every step.
    private func setSelectionFlags(hasSelection has: Bool, isMultiSelection multi: Bool) {
        if hasSelection != has { hasSelection = has }
        if isMultiSelection != multi { isMultiSelection = multi }
    }

    /// Resets all table expansion states.
    private func resetTableExpansionStates() {
        // Guarded: SwiftUI does not dedupe a `@State` write, so assigning `false` to a flag already `false`
        // still invalidates the view. Most selections start with these flags false, so unguarded writes
        // would cost three needless invalidations per step.
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
    
    /// Moves the selected tab one step in response to a swipe. Swipes past either end, and swipes into a
    /// disabled tab (Notes when the film has no notes), are ignored. Changing `selectedIndex` drives the pan
    /// offset. Setting `isSwipeAnimating` first makes that change animate, since the scoped `.transaction`
    /// re-injects the spring past MainView's ambient nil. The pan direction comes from the fixed,
    /// index-ordered slot positions, so it is always spatially correct.
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
        
        // Capture the departing tab before the change. It stays click-active for the slide (see
        // `isTabActiveForHitTesting(_:)`). This is a UX choice, not a rendering need, since the hitTest gate
        // never affects rendering. Reading `selectedTab` before `setRightSidebarTab` also keeps this right
        // for a rapid second swipe while the first reset is pending.
        departingTab = selectedTab
        
        // Mark the swipe as animating before the change, so the pan animates with the spring. Button, menu,
        // and keyboard switches leave this false and pan instantly.
        isSwipeAnimating = true
        viewStateManager.setRightSidebarTab(target)
        
        // Stop animating once the slide settles, so later non-swipe switches are instant again. A new swipe
        // cancels this reset.
        swipeResetTask?.cancel()
        swipeResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.swipeAnimationDuration))
            guard !Task.isCancelled else { return }
            isSwipeAnimating = false
            departingTab = nil
        }
    }
    
    /// Whether a plane slot stays in AppKit's hit-test chain (its `NSScrollView` clickable) rather than
    /// excluded. True for the selected tab, and, only during a swipe animation, for `departingTab`. Those
    /// are the only slots visible in the clipped viewport at any moment. Every other resident slot,
    /// including a third tab pre-armed for the next swipe (see `isTabRendered`), is off screen and stays
    /// excluded at all times. Its `NSScrollView` would otherwise intercept clicks on the content that
    /// occupies that screen position. See `tabPlane` and `tabActivations` for how this feeds
    /// `AppKitScrollView`'s hit-test gate.
    private func isTabActiveForHitTesting(_ tab: RightSidebarTab) -> Bool {
        if tab == selectedTab { return true }
        return isSwipeAnimating && tab == departingTab
    }

    /// Installs the NSEvent local monitor that recognizes a horizontal two-finger trackpad swipe over the
    /// sidebar's content area and broadcasts `.rightSidebarSwipe` view events. No-op if a monitor is
    /// already installed.
    ///
    /// The recognition logic matches `HorizontalSwipeScrollView.scrollWheel(with:)` (same threshold, phase and
    /// momentum handling, and per-gesture de-duplication). Only where it runs differs. The monitor sees each
    /// scroll-wheel event before AppKit dispatches it. It returns the event
    /// unchanged, so ordinary vertical scrolling reaches the plain NSScrollView untouched, or returns `nil`
    /// to consume it. See `SidebarSwipeZoneAnchor` for how "cursor is over the sidebar" is determined
    private func installSwipeMonitor() {
        guard swipeMonitor == nil else { return }

        let gestureState = swipeGestureState

        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Only recognize while a single film is displayed — mirrors handleSwipe's
            // own guard, so no work happens for an empty or multi-selection sidebar.
            guard hasSelection, !isMultiSelection else { return event }

            // The cursor must be over the sidebar's tab content. swipeZoneAnchor is the fixed viewport, so the
            // test is stable across swipes and across the mounted tab scroll views. Scoping to one scroll
            // view's bounds would be ambiguous mid-pan.
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

            // Let any actively horizontal-scrolling table (in this build only the
            // detailed CalendarTable, when Preferences.additionalCalTableDetails is
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

            // Once this gesture has switched a tab, absorb the rest of the same gesture (trailing `.changed`
            // frames and momentum). Otherwise that residual could cause an overscroll or an extra scroll on
            // the new tab.
            if gestureState.consumed,
               momentumPhase != [] || phase.contains(.changed) {
                return nil
            }

            // Trackpad gestures carry precise deltas during an active phase. Wheels, momentum frames, and
            // `.ended` events pass through untouched.
            guard phase.contains(.began) || phase.contains(.changed) else {
                return event
            }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY

            // Horizontal-dominant motion is consumed, so no horizontal delta reaches a scroll view, even when no
            // swipe is recognized (a nudge below the threshold, or a swipe past the first or last tab).
            // Vertical-dominant motion passes through unchanged.
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

    /// Removes the monitor from `installSwipeMonitor()`. Safe to call when none is installed.
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
    /// When the last selection change reached the debounce decision. Used only by the timing fallback for
    /// sources with no key-repeat signal (see `handleSelectionChange`).
    var lastChangeTime: Date = .distantPast

    /// Wall time the latest resolution took, through its run-loop turn, layout, and CoreAnimation commit.
    /// The cost depends on the film. A film with no releases, viewings, or notes resolves quickly, while one
    /// with a long viewing history and a full release table costs far more.
    /// `handleSelectionChange` uses this to decide whether a discrete press needs coalescing. It starts at
    /// zero, so the first resolution of a session is always instant.
    var lastResolutionCost: TimeInterval = 0
}

// MARK: - SwipeGestureState

/// Whether the current trackpad gesture has already switched a tab. One instance per `RightSidebar`
/// (see `swipeGestureState`), captured by its single, long-lived NSEvent monitor. It is an instance
/// property, not `static`, since the sidebar has exactly one monitor.
@MainActor
private final class SwipeGestureState {
    var consumed = false
}

// MARK: - Right Sidebar Tab CustomTab Conformance
extension RightSidebarTab: CustomTab {
    var iconName: String {
        switch self {
        case .details: return "square.text.square"
        case .releases: return ContentGlyphs.disc
        case .notes: return "square.and.pencil"
        }
    }
}

// MARK: - SidebarPrewarm

/// Builds the Header and Details tab once for a real film, in an offscreen transparent window, lays
/// them out and draws them, then discards them. This pays SwiftUI's first-use costs (type metadata,
/// first sizing of hosted AppKit controls, font resolution) before the user's first selection.
/// EventKitManager.prewarm covers the calendar daemon's share.
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
                .padding(.horizontal, RSBCardChrome.sidebarInset)
                .padding(.top, 8)
            Divider()
                .padding(.horizontal, RSBCardChrome.sidebarInset)
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
