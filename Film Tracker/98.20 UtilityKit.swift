// MARK: - UtilityKit.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Drop-in SwiftUI/AppKit utilities: an NSScrollView-backed scroll view, an async NSOpenPanel
/// presenter, the field-edge chrome for boxed surfaces, a path bar, and glyph badges.
///
/// STANDARDIZED SWIFTUI/APPKIT UTILITIES — one file, drop into any project.
///
/// Five pieces, with every per-app constant a defaulted parameter:
///
///   1. AppKitScrollView — an NSScrollView-backed replacement for SwiftUI's ScrollView.
///   2. SharedOpenPanel  — `OpenPanelPresenter`, an async NSOpenPanel-as-a-sheet helper.
///   3. FieldEdge        — `FieldEdgeStyle`, `.fieldEdgeChrome(...)` and `FieldEdgeLayers`: the
///                         rounded plate, fading outline and soft shadow of a boxed surface.
///   4. PathBar          — `PathBarView`, `PathBarChrome` and the `.toolTip(_:)` modifier it uses.
///   5. GlyphBadge       — `GlyphBadge`, `SymbolBadge` (animated) and `GlyphBadgeView` (AppKit):
///                         a filled, shadowed circle with a shadowed glyph centered on it.
///
/// Only the path bar depends on another piece (the field edge), and nothing here depends on
/// the other shared files.
///
/// WIRING IT UP
/// ────────────
/// Scroll view — a thin facade per context that re-injects what the hosted tree needs
/// (an NSHostingView does not inherit the enclosing SwiftUI environment):
///
///   struct PaneScrollView<Content: View>: View {
///       @Environment(AppModel.self) private var model
///       @ViewBuilder let content: Content
///       var body: some View {
///           AppKitScrollView(modifier: PaneEnvironment(model: model)) { content }
///       }
///   }
///
///   AppKitScrollView(modifier: EmptyModifier()) { page }    // nothing to re-inject
///
/// Optional, all off by default: `scrollProxy:` (scroll-to-anchor, viewport tracking,
/// animated-shrink hold), `isActive:` / `activation:` (hit-test gating for tab planes),
/// `onScrollWillStart:`, `contentResetKey:`, `alwaysOverflows:`, and `style:` (the
/// NSScrollView chrome; `.standard` by default).
///
/// Open panel:
///
///   let selection = await OpenPanelPresenter.present(
///       configuration: .init(canChooseDirectories: true, prompt: "Choose"),
///       attachedTo: window)                                // nil → key, then main window
///   guard case .urls(let urls) = selection else { return }
///
/// Project-wide panel defaults (initial folder, size, resizability, movability) live on
/// `OpenPanelPresenter.defaults`; set them once at launch if they differ from the
/// defaults (Desktop, 600 × 400, fixed, immovable):
///
///   OpenPanelPresenter.defaults.directory = .applications  // to browse for app bundles
///
/// Field edge:
///
///   content.fieldEdgeChrome()                                   // plate, outline, shadow
///   list.fieldEdgeChrome(fill: nil, clipsContent: true,         // a list painting its own rows
///                        insetsInterior: true, shadow: .content)
///   card.fieldEdgeChrome(FieldEdgeStyle(cornerRadius: 12))      // a variant of the measures
///   let edge = FieldEdgeLayers()                                // an AppKit view's layers
///
/// Path bar:
///
///   PathBarView(url: folder, isUnavailable: !exists)            // a location
///   PathBarView(pathComponents: parts, icon: Image(systemName: "doc.fill"))   // plain components
///   PathBarChrome { customContent }                             // the shell only
///
/// Glyph badge:
///
///   GlyphBadge(systemName: "checkmark", color: .green)          // 14pt, no circle shadow
///   GlyphBadge(character: "B", color: .white, ink: .black, inkShadow: nil)
///   SymbolBadge(systemName: glyph, color: color, diameter: 22)  // animated, 16pt default
///   badge.content = .symbol("checkmark"); badge.fillColor = .systemGreen   // GlyphBadgeView
///
/// ─────────────────────────────────────────────────────────────────────────────────────
/// 1. APPKITSCROLLVIEW
/// ─────────────────────────────────────────────────────────────────────────────────────
///
/// Each consumer wraps this view with a thin facade that captures its required
/// environment values and constructs the matching ViewModifier — leaving call sites
/// completely unchanged and keeping context-specific concerns (event-bus
/// broadcasting, environment re-injection) out of the utility layer.
///
/// Architecture
/// ────────────
///   AppKitScrollView<Content, Modifier: ViewModifier>  ← SwiftUI entry point
///     GeometryReader → AppKitScrollNSView               ← NSViewRepresentable
///       NSScrollView
///         AppKitFlippedContainerView (documentView)
///           NSHostingView<AppKitScrollContentWrapper<Content, Modifier>>
///
/// Structural diffing
/// ──────────────────
/// The content wrapper uses two concrete generic parameters (Content + Modifier) so
/// NSHostingView holds a fully typed, stable View value across updateNSView calls,
/// letting SwiftUI diff the hosted subtree incrementally instead of tearing it down
/// on every update. AnyView for either parameter would forfeit this.
///
/// Live-scroll suppression
/// ───────────────────────
/// rootView replacement is deferred during willStartLiveScroll…didEndLiveScroll
/// phases to prevent SwiftUI re-renders from competing with in-flight momentum
/// scroll frames — the primary source of scroll jitter in the SwiftUI ScrollView
/// model. Pending updates flush immediately when the live-scroll phase ends.
///
/// Programmatic scrolling
/// ──────────────────────
/// AppKitScrollProxy is a plain (deliberately non-@Observable) reference-type
/// bridge. Consumers that need scroll-to-anchor create one proxy per scroll view, passed to both the scroll view
/// (which wires the implementation) and the content view (which calls scroll(to:)).
/// Anchor y-offsets are reported upward via ScrollAnchorPreferenceKey, stored in
/// the coordinator, and used by scrollToAnchor(_:) to drive the NSScrollView's
/// clip view directly. That preference reader is installed only when a proxy that
/// tracks anchors was supplied (see ScrollAnchorReporter), so consumers that pass
/// none do not pay to collect a key nothing in their tree writes or reads.
/// scrollHandler is (re-)wired from syncCoordinatorState
/// whenever the proxy's identity changes, and cleared in dismantleNSView so a
/// proxy outliving its scroll view never keeps a closure aimed at a torn-down
/// coordinator.
///
/// A proxy made with `tracksViewport` also hears the visible rectangle, on every
/// scroll and resize, and when live scrolls begin and end, through the
/// `viewportHandler` and `liveScrollHandler` its consumer sets — so a long list can mount
/// only the items near the viewport, and change which only when nothing scrolls. Only such a proxy makes the scroll view observe its clip view.
///
/// Content width
/// ─────────────
/// The width proposed to the hosted SwiftUI tree is the GeometryReader's measured
/// width minus Coordinator.contentWidthInset — the gap between the NSScrollView's
/// own width and the clip view's, measured from live AppKit layout (see
/// AppKitFlippedContainerView.onWidthChange). It's 0 under the default overlay
/// scroller style, and equals the legacy scroller's width under "Show scroll bars:
/// Always," where the clip view is genuinely narrower than the GeometryReader's
/// measurement. Without the correction, content in that configuration lays out too
/// wide (clipped along the trailing edge), and text wrapping at the wrong width can
/// measure a document height short of the real one.
///
/// isActive / hit-test isolation
/// ─────────────────────────────
/// When isActive == false, the underlying NSScrollView (a HitTestGatedScrollView;
/// see below) has its hitTest(_:) short-circuited to return nil, removing it and
/// its AppKit subviews from AppKit's hit-test chain without ever setting isHidden
/// — defense in depth alongside any event-shield overlay the consumer adds.
///
/// isHidden is deliberately avoided, even though it also excludes hit testing. Toggling isHidden from true back to
/// false — which happens on every tab activation, not just once — makes AppKit
/// treat the scroll view as newly appearing, triggering its automatic "flash scroll
/// indicators" behavior regardless of whether content actually scrolled. Consumers
/// that reactivate the same scroll view repeatedly (a tab plane, on every tab
/// switch) would flash on every switch instead of only when scrolled content
/// hadn't yet faded. A pure hitTest override sidesteps this: the view is never
/// hidden or re-shown, so nothing looks "newly visible" — only its interactivity toggles.
///
/// The flag can also arrive through an `AppKitScrollActivation` (see below), and the scroll
/// view honors both: it is active only when the parameter AND the activation say so. The
/// activation route exists for cost. A parameter is part of the representable's value, so
/// flipping it rebuilds that value, stamps a new AppKitScrollRevision, and hands the
/// unchanged content to the hosting view again — a full re-measure of the hosted tree on
/// every tab activation. An environment value avoids the revision but is no cheaper: SwiftUI
/// bridges the enclosing environment into a hosted NSHostingView, so a per-tab flag there
/// dirties every environment-reading node of the hosted tree and re-measures it (profiled at
/// about half the cost of a tab switch). The activation is a reference that
/// stays the same object for the scroll view's life, so flipping it changes no SwiftUI value
/// at all: it gates hit-testing directly and flushes anything buffered while inactive.
///
/// onScrollWillStart callback
/// ──────────────────────────
/// An optional callback fired synchronously at the start of every live-scroll
/// phase — to broadcast a notification, say, letting subscribers (e.g. a popover)
/// dismiss themselves before content re-lays out. Kept as a callback, not hard-coded, so the utility
/// stays context-free.
///
/// Scroll view chrome
/// ──────────────────
/// `AppKitScrollStyle` carries the NSScrollView settings applied once, at creation:
/// vertical scroller only, autohiding, no border, no background, vertical elasticity,
/// and no automatic content insets. `.standard` is that set.
///
/// Horizontal swipe recognition (deliberately not in this utility)
/// ───────────────────────────────────────────────────────────────
/// The utility does not subclass the scroll view to override scrollWheel(with:) for horizontal
/// two-finger swipes. That override made scrolling measurably less smooth than a plain
/// NSScrollView. The responsive-scrolling compatibility method such an override would need is an
/// *instance* method on NSClipView, not a class method on NSScrollView, so a class-level
/// declaration would not take effect.
///
/// A consumer that needs swipe recognition installs a standalone NSEvent local monitor
/// instead. A local monitor intercepts events before
/// AppKit's normal dispatch and can consume (return nil) or pass them through (return the
/// event) unchanged; when passed through, AppKit dispatches to the NSScrollView exactly as
/// with no monitor installed. Every consumer of this utility receives a plain NSScrollView
/// from makeNSView, differing only in the hit-test gate.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ━━━━━━━━━━ 1. AppKitScrollView ━━━━━━━━━━

// MARK: - AppKitScrollProxy

/// Plain reference-type bridge that lets hosted SwiftUI content trigger
/// programmatic scroll-to-anchor operations on the underlying NSScrollView
/// without touching AppKit directly.
///
/// Deliberately NOT `@Observable`. Its single property is pure plumbing — written
/// once by `AppKitScrollNSView` and read only from event callbacks, never from a
/// `View.body`. `@Observable` would buy nothing while costing something real:
/// consumer views hold a proxy as a stored property of a SwiftUI `View` struct, and `@Observable`'s fine-grained tracking
/// opens a subscription for any observable object reachable that way. A plain
/// `final class` is stored and passed by reference identically, works the same
/// inside `@State`, and keeps those subtrees out of the observation graph entirely.
///
/// Usage pattern:
///   1. Create one proxy per scroll-view instance (e.g. `@State private var proxy = AppKitScrollProxy()`).
///   2. Pass it to `AppKitScrollView(scrollProxy: proxy)` — the scroll view wires the implementation.
///   3. Pass it to the content view — the content view calls `proxy.scroll(to: anchorID)`.
///   4. Content views report anchor y-offsets via `ScrollAnchorPreferenceKey`.
@MainActor
final class AppKitScrollProxy {
    /// Whether the hosted tree publishes `ScrollAnchorPreferenceKey` anchors for
    /// `scroll(to:)`. Only then is the preference reader installed (see
    /// `ScrollAnchorReporter`); a proxy used solely for `holdForAnimatedShrink`
    /// passes false and costs the hosted tree nothing.
    let tracksAnchors: Bool

    /// Whether the scroll view reports its visible rectangle to `viewportHandler`. Only then
    /// does it observe the clip view; every other consumer pays nothing for it.
    let tracksViewport: Bool

    init(tracksAnchors: Bool = true, tracksViewport: Bool = false) {
        self.tracksAnchors = tracksAnchors
        self.tracksViewport = tracksViewport
    }

    /// Set by the CONSUMER (unlike the handlers below, which the scroll view wires) when the
    /// proxy `tracksViewport`. Called with the clip view's bounds — the visible rectangle in
    /// document coordinates, top-left origin — whenever the person scrolls or the viewport is
    /// resized, synchronously, so content can respond within the same frame.
    var viewportHandler: (@MainActor (CGRect) -> Void)?

    /// Set by the consumer, alongside `viewportHandler`: true when a live scroll (a
    /// trackpad gesture, its momentum, a scroller drag) begins, false when it ends.
    var liveScrollHandler: (@MainActor (Bool) -> Void)?

    /// Wired and cleared alongside `scrollHandler`; consumers use `requestViewport`.
    var viewportRequestHandler: (@MainActor () -> Void)?

    /// Calls `viewportHandler` now with the current visible rectangle, if the scroll view is
    /// live and laid out — for a consumer that installs its handler after the first report.
    func requestViewport() {
        viewportRequestHandler?()
    }

    /// Assigned by AppKitScrollNSView once the NSScrollView is live, and cleared
    /// again in dismantleNSView so a torn-down scroll view never leaves a stale
    /// closure behind on a proxy that outlives it.
    /// Calling this directly is an internal implementation detail; consumers use scroll(to:).
    var scrollHandler: (@MainActor (String) -> Void)?

    /// Wired and cleared alongside `scrollHandler`; consumers use `holdForAnimatedShrink`.
    var shrinkHandler: (@MainActor (Double, Double) -> ShrinkAnchor)?

    /// Scrolls the NSScrollView to the named anchor, vertically centering it in
    /// the visible area without animation.
    func scroll(to anchorID: String) {
        scrollHandler?(anchorID)
    }

    /// Call immediately BEFORE a state change that makes the hosted content shorter
    /// under a SwiftUI spring with these parameters (an animated row removal). The
    /// document keeps its current height until the spring has settled.
    ///
    /// Returns where the caller must place its content, in the same update as its
    /// change, within the (held, taller) frame: `anchor.lowering(frameHeight:
    /// contentHeight:)` points below the frame's top. The rows above a removal then
    /// give up whatever the viewport could no longer show beneath the shorter content,
    /// on the caller's own spring, and when the hold is released the offset follows the
    /// content back up so that nothing moves on screen. See "Animated shrink" on the
    /// coordinator. Unwired, the anchor never lowers anything.
    func holdForAnimatedShrink(response: Double, dampingFraction: Double) -> ShrinkAnchor {
        shrinkHandler?(response, dampingFraction) ?? .top
    }

    /// Wired and cleared alongside `scrollHandler`; consumers use `shrinkDidBegin`.
    var shrinkBeganHandler: (@MainActor (CFTimeInterval) -> Void)?

    /// Call from the hosted tree's own update that applies the shrinking change (an
    /// `onChange` of the state the removal mutated). That update is when SwiftUI's
    /// spring begins, so the hold's release is timed from it.
    func shrinkDidBegin() {
        shrinkBeganHandler?(CACurrentMediaTime())
    }
}

// MARK: - ScrollAnchorPreferenceKey

/// Accumulates named scroll-anchor y-offsets reported by child views. The
/// dictionary maps anchor IDs to y-positions in the hosted content's coordinate
/// space so the Coordinator can drive the NSScrollView's clip view directly.
///
/// Child views report their position by measuring with
/// `onGeometryChange(for:of:action:)` (macOS 15) and publishing the stored result:
/// ```swift
/// @State private var anchorOffset: CGFloat?
/// ...
/// .onGeometryChange(for: CGFloat.self) { proxy in
///     proxy.frame(in: .named("filmSheetScrollContent")).minY
/// } action: { anchorOffset = $0 }
/// .preference(
///     key: ScrollAnchorPreferenceKey.self,
///     value: anchorOffset.map { [anchorID: $0] } ?? [:]
/// )
/// ```
/// A background `GeometryReader` measuring into `.preference` directly is the
/// older form and works, but it is a greedy, layout-participating view that adds
/// a node to every pass and re-evaluates its content on every geometry change,
/// including purely horizontal ones. `onGeometryChange` reduces to the single
/// value and fires only when that value moves. Publishing an empty dictionary
/// before the first measurement is deliberate: `reduce` merges it away, so an
/// unmeasured anchor is absent rather than reported at a placeholder zero, which
/// would scroll the clip view to the top of the document.
struct ScrollAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] { [:] }
    static func reduce(value: inout [String: CGFloat],
                       nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - AppKitScrollActivation

/// Out-of-band form of `AppKitScrollView`'s `isActive`, for a consumer that toggles it often
/// (see "isActive / hit-test isolation" above for why it exists). The consumer keeps one
/// instance per scroll view for that view's whole life, passes it as `activation`, and sets it
/// with `.appKitScrollActivation(_:isActive:)` placed outside the scroll view. The scroll view
/// applies a change directly, so nothing SwiftUI compares ever differs.
@MainActor
final class AppKitScrollActivation {
    private(set) var isActive: Bool
    /// The coordinator currently applying changes; a replaced scroll view's teardown must
    /// not unhook its successor's handler.
    private weak var owner: AnyObject?
    private var onChange: (() -> Void)?

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        onChange?()
    }

    fileprivate func attach(_ owner: AnyObject, onChange: @escaping () -> Void) {
        self.owner = owner
        self.onChange = onChange
    }

    fileprivate func detach(_ owner: AnyObject) {
        guard self.owner === owner else { return }
        self.owner = nil
        onChange = nil
    }
}

/// Writes a flag into an `AppKitScrollActivation` from inside a SwiftUI update. Its updateNSView
/// runs in the same update as the change that produced the flag, so a tab that becomes active
/// is unblocked, and any buffered content applied, before that update is laid out and drawn.
private struct AppKitScrollActivationRelay: NSViewRepresentable {
    let activation: AppKitScrollActivation
    let isActive: Bool

    /// Never a click target: the relay sits behind an inactive scroll view, which may lie
    /// over other interactive content.
    final class RelayView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> RelayView {
        activation.setActive(isActive)
        return RelayView()
    }

    func updateNSView(_ nsView: RelayView, context: Context) {
        activation.setActive(isActive)
    }
}

extension View {
    /// Sets `activation` to `isActive` whenever the latter changes. See `AppKitScrollActivation`.
    func appKitScrollActivation(_ activation: AppKitScrollActivation, isActive: Bool) -> some View {
        background(AppKitScrollActivationRelay(activation: activation, isActive: isActive)
            .frame(width: 0, height: 0))
    }
}

// MARK: - AppKitScrollView

/// SwiftUI entry point for the AppKit-backed scroll view.
///
/// - Parameters:
///   - modifier: A `ViewModifier` applied inside the hosted wrapper. Use this to
///     re-inject environment values that NSHostingView does not inherit from the
///     enclosing SwiftUI environment (e.g. an `@Observable` model object). Each
///     consumer context provides its own concrete modifier type, preserving SwiftUI's
///     structural diffing on the hosted content tree.
///   - scrollProxy: Optional programmatic-scroll bridge. Pass `nil` for consumers
///     that never need scroll-to-anchor; doing so also omits the
///     `ScrollAnchorPreferenceKey` reader from the hosted tree entirely.
///   - isActive: When `false`, the underlying NSScrollView's `hitTest(_:)` is
///     short-circuited to return `nil`, removing it from AppKit's hit-test chain
///     without hiding it (see the "isActive / hit-test isolation" note above for
///     why `isHidden` is deliberately not used). Defaults to `true`.
///   - activation: Combined with `isActive`, and far cheaper to toggle. See
///     `AppKitScrollActivation`.
///   - onScrollWillStart: Optional callback fired synchronously at the start of each
///     live-scroll phase. Called on the main actor.
///   - contentResetKey: Opaque token naming which subject the content shows. When it
///     changes, the scroll position returns to the top. `nil` (the default) never
///     touches the scroll position.
///   - alwaysOverflows: See the stored property.
///   - style: The NSScrollView chrome, applied once when the scroll view is made.
///     Defaults to `.standard`. See `AppKitScrollStyle`.
///   - content: The SwiftUI content to host inside the scroll view.
///
/// Concrete consumer facades (one per hosting context) wrap
/// this view, capturing their required environment values and building the appropriate
/// modifier. Direct consumers may also use `AppKitScrollView` with `EmptyModifier` when
/// no environment re-injection is needed.
struct AppKitScrollView<Content: View, Modifier: ViewModifier>: View {

    let modifier: Modifier
    let content: Content
    var scrollProxy: AppKitScrollProxy?
    var isActive: Bool
    var activation: AppKitScrollActivation?
    var onScrollWillStart: (@MainActor () -> Void)?
    var contentResetKey: AnyHashable?
    /// True for content that is always taller than the viewport, so a legacy ("always
    /// shown") vertical scroller is always tiled beside it. Lets the very first layout
    /// of a fresh scroll view use the narrower width instead of correcting to it
    /// afterward. See `AppKitScrollInitialInset`.
    var alwaysOverflows: Bool
    /// See `AppKitScrollStyle`.
    var style: AppKitScrollStyle

    init(
        modifier: Modifier,
        scrollProxy: AppKitScrollProxy? = nil,
        isActive: Bool = true,
        activation: AppKitScrollActivation? = nil,
        onScrollWillStart: (@MainActor () -> Void)? = nil,
        contentResetKey: AnyHashable? = nil,
        alwaysOverflows: Bool = false,
        style: AppKitScrollStyle = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.activation = activation
        self.style = style
        self.alwaysOverflows = alwaysOverflows
        self.modifier = modifier
        self.scrollProxy = scrollProxy
        self.isActive = isActive
        self.onScrollWillStart = onScrollWillStart
        self.contentResetKey = contentResetKey
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            AppKitScrollNSView(
                availableWidth: geometry.size.width,
                modifier: modifier,
                scrollProxy: scrollProxy,
                isActive: isActive,
                activation: activation,
                onScrollWillStart: onScrollWillStart,
                contentResetKey: contentResetKey,
                alwaysOverflows: alwaysOverflows,
                style: style,
                revision: AppKitScrollRevision.next(),
                content: content
            )
            /// The representable must fill the GeometryReader frame so that
            /// SwiftUI passes correct bounds and Auto Layout inside it receives
            /// the right clip view dimensions.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - AppKitScrollStyle

/// The NSScrollView chrome an `AppKitScrollView` is built with. Read once, when the scroll
/// view is made; changing it on a live view has no effect, as with any creation-time
/// AppKit configuration.
///
/// `.standard` is the default. The rest is fixed, because the utility depends on it: there is never a
/// horizontal scroller or horizontal elasticity (the document is pinned to the clip view's
/// width), and the scroll view and hosting view are always layer-backed with
/// `.onSetNeedsDisplay`.
struct AppKitScrollStyle: Equatable {
    /// Hides the vertical scroller while nothing scrolls. An "always show scroll bars"
    /// system setting still wins, as it does for any NSScrollView.
    var autohidesScrollers: Bool = true
    var verticalScrollElasticity: NSScrollView.Elasticity = .allowed
    var borderType: NSBorderType = .noBorder
    /// `nil` draws no background, so whatever SwiftUI puts behind the scroll view shows
    /// through. A color sets `drawsBackground` and `backgroundColor`.
    var backgroundColor: NSColor? = nil
    /// `false` (the default) turns automatic safe-area-driven content insets off and zeroes
    /// `contentInsets`: right for a scroll view that is not the window's direct content view
    /// under a titlebar, where automatic insets never apply and only their recomputation on
    /// every layout pass would be paid. Pass `true` for a scroll view that IS, so AppKit
    /// insets its content below a transparent titlebar or toolbar. (Bottom headroom for a
    /// SwiftUI overlay is a separate mechanism — `.safeAreaInset` inside the content — and
    /// works under either setting.)
    var automaticallyAdjustsContentInsets: Bool = false

    init(
        autohidesScrollers: Bool = true,
        verticalScrollElasticity: NSScrollView.Elasticity = .allowed,
        borderType: NSBorderType = .noBorder,
        backgroundColor: NSColor? = nil,
        automaticallyAdjustsContentInsets: Bool = false
    ) {
        self.autohidesScrollers = autohidesScrollers
        self.verticalScrollElasticity = verticalScrollElasticity
        self.borderType = borderType
        self.backgroundColor = backgroundColor
        self.automaticallyAdjustsContentInsets = automaticallyAdjustsContentInsets
    }

    /// The default configuration. Computed, not stored: `NSColor` is not `Sendable`.
    static var standard: AppKitScrollStyle { AppKitScrollStyle() }
}

// MARK: - AppKitScrollRevision

/// Stamps each `AppKitScrollNSView` VALUE SwiftUI builds, so `updateNSView` can tell a new
/// value (new content, width, modifier or flags — every one of which reaches the representable
/// only by SwiftUI re-running the GeometryReader closure that builds it) from an update SwiftUI
/// sends for an unchanged value because the surrounding ENVIRONMENT changed.
///
/// The second kind needs no rootView hand-off: a hosted NSHostingView does not inherit the
/// outer SwiftUI environment at all (which is why consumers re-inject what they need through
/// `Modifier`, itself part of the value), so nothing the hosted tree reads has moved. The
/// hand-off is not free — it invalidates the hosting view's intrinsic size, and the next
/// constraint pass re-measures the entire hosted tree. When a page is leaving, such an update to
/// the outgoing page would run a full re-measure (about 100 ms, as measured) in the constraint phase, before the layout phase that removes it.
@MainActor
enum AppKitScrollRevision {
    private static var counter = 0
    static func next() -> Int { counter &+= 1; return counter }
}

#if DEBUG
/// Counts content hand-offs across every AppKitScrollView, for harness measurements:
/// `newRevisions` is how many updates carried a new representable value, `applied` how many
/// actually reassigned a hosting view's rootView (each one a full re-measure of that tree).
@MainActor
enum AppKitScrollHandoffProbe {
    static var newRevisions = 0
    static var applied = 0
}
#endif

// MARK: - DampedSpring

/// SwiftUI's `.spring(response:dampingFraction:)` as a damped oscillator — unit mass,
/// stiffness (2π / response)², damping 4π · dampingFraction / response — for the one
/// thing AppKit needs to know about it: how long it runs. Underdamped fractions only
/// (0 < ζ < 1), which is every spring a shrink hold is used with.
struct DampedSpring {
    let response: Double
    let dampingFraction: Double

    /// When the remaining motion is under 0.1% of the travel for good: the envelope
    /// of the oscillation, not one zero crossing of it.
    var settlingDuration: Double {
        let naturalFrequency = 2 * .pi / response
        let decay = dampingFraction * naturalFrequency
        let dampedFrequency = naturalFrequency * (1 - dampingFraction * dampingFraction).squareRoot()
        return log((1 + decay / dampedFrequency) / 0.001) / decay
    }
}

// MARK: - ShrinkAnchor

/// Where content shorter than a held document sits within it (see
/// `AppKitScrollProxy.holdForAnimatedShrink`): as low as the viewport's eventual
/// offset requires, and no lower.
struct ShrinkAnchor: Equatable {
    /// How far the held document extends below the viewport's bottom edge.
    var slack: CGFloat
    /// The scroll offset when the hold began — as far as the offset can ever come
    /// back, so as far as the content may be lowered.
    var offset: CGFloat

    /// Never lowers anything: plain top alignment.
    static let top = ShrinkAnchor(slack: .infinity, offset: 0)

    /// Points below the frame's top. The document will end `frameHeight −
    /// contentHeight` shorter; whatever of that the slack beneath the viewport cannot
    /// absorb, the offset must give back — up to all of it, but never past zero.
    func lowering(frameHeight: CGFloat, contentHeight: CGFloat) -> CGFloat {
        min(offset, max(0, frameHeight - slack - contentHeight))
    }
}

// MARK: - AppKitScrollInitialInset

/// The content-width inset (see `Coordinator.contentWidthInset`) a fresh scroll view
/// starts with.
///
/// A fresh scroll view cannot measure its inset until AppKit has tiled its scroller,
/// which happens after the hosted content's first layout — and, with an autohiding
/// scroller, only once that content has proven taller than the viewport. When the person
/// has "Show scroll bars" set to "Always", a tall page is laid out first at the full width
/// and then corrected once the narrower width is known, which shows as a squeeze each time
/// the tab appears. Content that is
/// always taller than the viewport (`alwaysOverflows`) always has the legacy scroller
/// beside it, so it starts with that scroller's width and the first layout is the final
/// one. Everything else starts at 0, as before — its height (and so whether a scroller
/// shows at all) varies, and a wrong guess would squeeze or widen it instead; the width
/// callback corrects either way.
@MainActor
enum AppKitScrollInitialInset {
    static func initialInset(alwaysOverflows: Bool) -> CGFloat {
        guard alwaysOverflows, NSScroller.preferredScrollerStyle == .legacy else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }
}

// MARK: - WeakCoordinatorBox

/// Holds a weak reference to the Coordinator so AppKitScrollContentWrapper (a
/// struct, as required by View) can refer to it without extending its lifetime.
/// Swift does not permit `weak var` as a stored property of a struct — `weak`
/// requires a class-type storage location.
///
/// Main-actor isolated, which makes it Sendable without an unchecked promise: it is made by
/// the main-actor Coordinator and read only from the main-actor task the anchor reporter starts.
@MainActor
private final class WeakCoordinatorBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T?) { self.value = value }
}

// MARK: - AppKitScrollContentWrapper

/// Typed wrapper placed as the NSHostingView's rootView. Two concrete generic
/// parameters (Content + Modifier) give NSHostingView a fully stable type across
/// updateNSView calls, enabling incremental SwiftUI diffing of the hosted subtree.
///
/// The modifier parameter re-injects environment values that NSHostingView does not
/// inherit from the enclosing SwiftUI environment. `ScrollAnchorReporter` wires
/// ScrollAnchorPreferenceKey updates back to the coordinator via a
/// WeakCoordinatorBox (avoids retaining the coordinator from within the View
/// value type), and installs itself only when `tracksAnchors` is true.
private struct AppKitScrollContentWrapper<Content: View, Modifier: ViewModifier>: View {
    let content: Content
    let availableWidth: CGFloat
    let modifier: Modifier
    /// Whether this scroll view has a proxy, and therefore whether anything can
    /// ever act on a reported anchor. See `ScrollAnchorReporter`.
    let tracksAnchors: Bool
    /// Weak reference to the coordinator so anchor-offset preference callbacks
    /// can update the coordinator without retaining it.
    let coordinatorBox: WeakCoordinatorBox<AppKitScrollNSView<Content, Modifier>.Coordinator>

    var body: some View {
        content
            /// Explicit width lets NSHostingView resolve maxWidth: .infinity before
            /// Auto Layout runs. Height is never set here — the container/hosting-view
            /// bottom constraint chain drives it via Auto Layout.
            .frame(width: availableWidth)
            /// Re-inject caller-supplied environment values.
            .modifier(modifier)
            /// Collect anchor y-offsets from the hosted tree and forward them to
            /// the coordinator for use in scrollToAnchor(_:) — but only for the one
            /// consumer that can actually use them.
            .modifier(ScrollAnchorReporter<Content, Modifier>(
                isEnabled: tracksAnchors,
                coordinatorBox: coordinatorBox
            ))
    }

    /// Returns a copy of this wrapper laid out at a different width, reusing the
    /// existing content, modifier, and coordinator box. Used when AppKit reports
    /// a clip-view width that differs from the GeometryReader's measurement, so
    /// the width can be corrected without rebuilding anything else.
    func withAvailableWidth(_ width: CGFloat) -> AppKitScrollContentWrapper {
        AppKitScrollContentWrapper(
            content: content,
            availableWidth: width,
            modifier: modifier,
            tracksAnchors: tracksAnchors,
            coordinatorBox: coordinatorBox
        )
    }
}

// MARK: - ScrollAnchorReporter

/// Installs the `ScrollAnchorPreferenceKey` reader that feeds
/// `Coordinator.anchorOffsets` — and only when the enclosing scroll view was
/// given a proxy, because a reported anchor with no proxy to act on it is a
/// measurement nothing can consume.
///
/// `onPreferenceChange` is not free: it makes SwiftUI collect and propagate that
/// key through every node of the hosted tree on each layout pass, whether or not
/// anything in the tree writes it. Consumers that publish no anchors install no reader.
///
/// `isEnabled` is derived from the proxy's `tracksAnchors` on the representable, so
/// it is fixed for the lifetime of any given call site. The `if` therefore never
/// flips, and the branch it selects never causes a structural rebuild of
/// `content`.
///
/// The generic parameters are deliberately named `C`/`M` rather than
/// `Content`/`Modifier`: `ViewModifier` already supplies an associated type
/// named `Content` for the view being modified, and a generic parameter of that
/// name would shadow it in `body(content:)`.
private struct ScrollAnchorReporter<C: View, M: ViewModifier>: ViewModifier {
    let isEnabled: Bool
    let coordinatorBox: WeakCoordinatorBox<AppKitScrollNSView<C, M>.Coordinator>

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onPreferenceChange(ScrollAnchorPreferenceKey.self) { [coordinatorBox] offsets in
                    Task { @MainActor [coordinatorBox] in
                        coordinatorBox.value?.anchorOffsets = offsets
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - AppKitFlippedContainerView

/// NSView subclass used as the NSScrollView's documentView.
/// isFlipped = true makes y=0 the top-left origin, matching NSClipView's
/// coordinate space and ensuring Auto Layout places content from the top down.
///
/// It also reports its own laid-out width upward. This container is pinned
/// leading/trailing to the clip view, so its width is exactly the width
/// available to hosted content — which is not always the same as the width the
/// SwiftUI `GeometryReader` measures. Under the default overlay scroller style
/// the two are identical, but when the person has System Settings ▸ Appearance ▸
/// "Show scroll bars" set to "Always", NSScrollView tiles a legacy scroller
/// beside the clip view and the clip view is correspondingly narrower. See
/// `Coordinator.contentWidthInset` for how that difference is folded back into
/// the width proposed to the hosted SwiftUI tree.
private final class AppKitFlippedContainerView: NSView {
    override var isFlipped: Bool { true }

    /// Called whenever this view's laid-out width actually changes. Never called
    /// for height-only changes (which happen constantly as content grows), so
    /// this costs nothing on the common path.
    var onWidthChange: (@MainActor (CGFloat) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.size.width
        super.setFrameSize(newSize)
        if widthChanged { onWidthChange?(newSize.width) }
    }
}

// MARK: - HitTestGatedScrollView

/// `NSScrollView` subclass backing every `AppKitScrollView` instance. Implements
/// the `isActive` parameter's hit-test exclusion by overriding `hitTest(_:)`
/// rather than by toggling `isHidden` — see the "isActive / hit-test isolation"
/// note at the top of this file for why: toggling `isHidden` back to `false` on
/// every reactivation makes AppKit treat the view as newly appearing, which
/// triggers an automatic scroll-indicator flash regardless of whether the
/// content was actually scrolled. A pure `hitTest(_:)` override never hides or
/// re-shows the view, so nothing about it looks "newly visible" to AppKit and no
/// flash is triggered — only its participation in hit-testing toggles.
private final class HitTestGatedScrollView: NSScrollView {
    /// Mirrors `AppKitScrollView`'s `isActive` parameter. `true` (the default)
    /// means normal hit-testing; `false` excludes this view and every one of its
    /// subviews (document view, scrollers, and anything hosted inside) from
    /// AppKit's hit-test chain by short-circuiting to `nil` before `super` is
    /// ever consulted.
    var isHitTestActive: Bool = true

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isHitTestActive else { return nil }
        return super.hitTest(point)
    }
}

// MARK: - AppKitScrollNSView

private struct AppKitScrollNSView<Content: View, Modifier: ViewModifier>: NSViewRepresentable {

    let availableWidth: CGFloat
    let modifier: Modifier
    let scrollProxy: AppKitScrollProxy?
    let isActive: Bool
    let activation: AppKitScrollActivation?
    let onScrollWillStart: (@MainActor () -> Void)?
    /// Opaque token identifying *which* subject the content is showing. When it
    /// changes, the scroll position is returned to the top — see `updateNSView`.
    let contentResetKey: AnyHashable?
    let alwaysOverflows: Bool
    /// Applied once, in makeNSView. See `AppKitScrollStyle`.
    let style: AppKitScrollStyle
    /// See `AppKitScrollRevision`.
    let revision: Int
    let content: Content

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        var hostingView: NSHostingView<AppKitScrollContentWrapper<Content, Modifier>>?
        var scrollView: NSScrollView?

        var isLiveScrolling = false

        /// Mirrors the representable's `isActive`. Content updates that arrive while
        /// this is `false` are buffered into `pendingRootView` and applied when the
        /// view becomes active again, for the same reason they are buffered during a
        /// live scroll: assigning `NSHostingView.rootView` makes Auto Layout re-measure
        /// the entire hosted tree, and doing that for a scroll view the person cannot
        /// see is pure cost. It matters most for the tabbed consumers that actually pass
        /// this flag, where leaving a tab would otherwise re-measure the whole subtree being hidden,
        /// on the very frame it stopped being visible.
        ///
        /// Nothing is lost by deferring: the buffered tree is applied in updateNSView
        /// before the view is shown again, so a reactivated tab is never displayed
        /// with stale content.
        var isActive = true

        /// The representable's `isActive` parameter, and the activation it was given; the
        /// coordinator is active only when both are. See `AppKitScrollActivation`.
        var parameterIsActive = true
        var activation: AppKitScrollActivation?
        var effectiveIsActive: Bool { parameterIsActive && (activation?.isActive ?? true) }

        /// Applies the current activation: the hit-test gate, the hand-off gate, and anything
        /// buffered while inactive.
        func applyActivation() {
            let active = effectiveIsActive
            (scrollView as? HitTestGatedScrollView)?.isHitTestActive = active
            isActive = active
            flushPendingRootViewIfPossible()
        }

        var pendingRootView: AppKitScrollContentWrapper<Content, Modifier>?
        var willScrollToken: (any NSObjectProtocol)?
        var didScrollToken:  (any NSObjectProtocol)?
        /// Clip-view bounds and frame observers, installed only for a proxy that
        /// `tracksViewport` (see `observeViewport`).
        var viewportTokens: [any NSObjectProtocol] = []

        /// Live copy of the representable's `onScrollWillStart`. Refreshed on
        /// every updateNSView rather than captured once by the notification
        /// closure, so a consumer whose callback closes over changing state
        /// cannot end up firing a version frozen at makeNSView time.
        var onScrollWillStart: (@MainActor () -> Void)?

        /// The proxy whose `scrollHandler` this coordinator currently owns.
        /// Weak: the proxy is owned by the consumer (typically as `@State`) and
        /// routinely outlives the scroll view.
        weak var wiredProxy: AppKitScrollProxy?

        /// Difference between the NSScrollView's own width and the width actually
        /// available to hosted content, measured from the live AppKit layout.
        /// Zero under the default overlay scroller style; equal to the legacy
        /// scroller's width whenever a legacy scroller is tiled beside the clip
        /// view. Subtracted from the GeometryReader width before it is proposed
        /// to the hosted SwiftUI tree, so content is neither laid out too wide
        /// (clipped on the trailing edge) nor measured at a width that yields a
        /// too-short document height.
        var contentWidthInset: CGFloat = 0

        /// The GeometryReader width most recently passed to makeWrappedContent, before
        /// `contentWidthInset` is subtracted. The deferred width correction recomputes
        /// from this (not from the width its layout callback saw) so a representable
        /// update landing between the two cannot be overwritten with a stale width.
        var measuredWidth: CGFloat = 0

        /// The most recent wrapper built by makeWrappedContent. Kept so a
        /// width correction arriving from AppKit layout (see the container's
        /// `onWidthChange`) can re-emit the current content at the corrected
        /// width without needing to reach back into the representable — and
        /// therefore without storing a closure that would have to be
        /// reallocated on every updateNSView pass.
        var lastWrapper: AppKitScrollContentWrapper<Content, Modifier>?

        /// The `contentResetKey` most recently applied. `nil` until the first update,
        /// so the initial pass never counts as a change and a freshly created scroll
        /// view (already at the top) is not redundantly scrolled.
        var appliedResetKey: AnyHashable?

        /// Anchor name → y-offset in document coordinates.
        /// Populated via ScrollAnchorPreferenceKey updates from the hosted tree.
        var anchorOffsets: [String: CGFloat] = [:]

        /// Stable weak-reference box for this coordinator, allocated once in
        /// makeNSView and reused by every makeWrappedContent call. Avoids
        /// allocating a new heap object on every updateNSView pass.
        lazy var coordinatorBox = WeakCoordinatorBox(self)

        /// The `revision` of the representable value whose content was last handed to the
        /// hosting view (or buffered for it). See `AppKitScrollRevision`.
        var appliedRevision: Int?

        func removeObservers() {
            if let t = willScrollToken { NotificationCenter.default.removeObserver(t) }
            if let t = didScrollToken  { NotificationCenter.default.removeObserver(t) }
            willScrollToken = nil
            didScrollToken  = nil
            viewportTokens.forEach(NotificationCenter.default.removeObserver)
            viewportTokens = []
        }

        /// Reports the visible rectangle to the wired proxy's `viewportHandler` on every scroll
        /// (clip bounds) and resize (clip frame). Both notifications post synchronously on the
        /// main thread, inside the scroll or layout that caused them.
        func observeViewport(of clipView: NSClipView) {
            guard viewportTokens.isEmpty else { return }
            clipView.postsBoundsChangedNotifications = true
            clipView.postsFrameChangedNotifications = true
            viewportTokens = [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: clipView, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportViewport() }
                }
            }
        }

        func reportViewport() {
            guard let clip = scrollView?.contentView, clip.bounds.height > 0 else { return }
            wiredProxy?.viewportHandler?(clip.bounds)
        }

        /// The enclosing class is already @MainActor-isolated, so its members
        /// inherit that isolation; no per-member annotation is needed.

        /// Whether an update may be handed to the hosting view right now. Both
        /// conditions suppress the same operation — the `rootView` assignment and the
        /// Auto Layout re-measure it forces — so they share one gate.
        private var canApplyRootView: Bool { !isLiveScrolling && isActive }

        func applyRootView(_ view: AppKitScrollContentWrapper<Content, Modifier>) {
            if canApplyRootView {
                #if DEBUG
                AppKitScrollHandoffProbe.applied += 1
                #endif
                hostingView?.rootView = view
                pendingRootView = nil
            } else {
                pendingRootView = view
            }
        }

        /// Applies anything buffered while suppressed, if nothing is suppressing it
        /// any longer. Safe to call unconditionally; a no-op when there is nothing
        /// buffered or when a gate is still closed.
        func flushPendingRootViewIfPossible() {
            guard canApplyRootView, let pending = pendingRootView else { return }
            #if DEBUG
            AppKitScrollHandoffProbe.applied += 1
            #endif
            hostingView?.rootView = pending
            pendingRootView = nil
        }

        func scrollWillStart() {
            isLiveScrolling = true
            onScrollWillStart?()
            if wiredProxy?.tracksViewport == true { wiredProxy?.liveScrollHandler?(true) }
        }

        func scrollDidEnd() {
            isLiveScrolling = false
            flushPendingRootViewIfPossible()
            if wiredProxy?.tracksViewport == true { wiredProxy?.liveScrollHandler?(false) }
        }

        /// Scrolls the NSScrollView so the named anchor is vertically centered in
        /// the visible area, without animation. Matches a ScrollViewReader scroll under a
        /// disablesAnimations transaction.
        ///
        /// Centering is unconditional: a scroll-to-anchor is a deliberate navigation
        /// (often followed by a popover on the row the anchor names), so it must land on a predictable
        /// position rather than leaving the row wherever it already happened to sit.
        func scrollToAnchor(_ anchorID: String) {
            guard let sv = scrollView,
                  let yOffset = anchorOffsets[anchorID] else { return }

            let visibleHeight  = sv.contentView.bounds.height
            let documentHeight = sv.documentView?.frame.height ?? 0
            /// Center the anchor in the visible area; clamp to valid document range.
            let centered = yOffset - visibleHeight / 2
            let clamped = max(0, min(centered, max(0, documentHeight - visibleHeight)))

            sv.contentView.scroll(to: NSPoint(x: 0, y: clamped))
            sv.reflectScrolledClipView(sv.contentView)
        }

        // MARK: Animated shrink
        ///
        /// An animated removal inside the hosted tree changes the content's height in
        /// ONE step: SwiftUI reports the final (shorter) intrinsic size at once and
        /// only the drawing is interpolated, and Auto Layout applies that size to the
        /// document at the next layout pass. When the shorter document can no longer
        /// reach the current scroll offset (the person is scrolled to, or near, the
        /// bottom), NSClipView clamps the offset in that same pass: every row jumps
        /// down by the shortfall in a single frame, and a removed row at the bottom is
        /// pushed out of the viewport before its fade is ever seen. (Measured: the jump lands on the first frame after the removal.)
        ///
        /// The hold answers it with a single clock — SwiftUI's:
        ///
        ///   1. A required minimum-height constraint keeps the document at its current
        ///      height, so nothing clamps, and the caller learns the `slack`: how much
        ///      document lies below the viewport.
        ///   2. The caller lays its content out within the held frame bottom-anchored
        ///      `slack` above the frame's foot (never above its top; see
        ///      `holdForAnimatedShrink`), and makes its change. Whatever the shorter
        ///      content can no longer fill beneath the viewport, the content gives up at
        ///      its TOP instead — the rows above the removal slide down exactly as far
        ///      as the scroll offset will have to come back — and all of it moves in the
        ///      one SwiftUI spring that also fades and closes the removal.
        ///   3. Once that spring has settled, the hold is dropped and the offset shifts
        ///      up by the distance the content was lowered, in the same layout pass that
        ///      shortens the document and lifts the content back to its top. On screen,
        ///      nothing moves.
        ///
        /// The hold uses SwiftUI's own clock, so the start of the motion is known rather than
        /// estimated. A per-frame AppKit copy of the spring would have to estimate that start,
        /// and rows that should stand still could drift by several pixels.

        /// Minimum-height constraint on the document view while a shrink is held.
        private var shrinkHold: NSLayoutConstraint?
        /// The document's height and the slack below the viewport when the hold began.
        /// A second removal inside the hold reuses both: the document has not moved,
        /// so the same anchor places the content for the two changes together.
        private var heldHeight: CGFloat = 0
        private var heldAnchor = ShrinkAnchor.top
        private var shrinkSettling: Double = 0.5
        private var shrinkLink: CADisplayLink?
        private var shrinkRequestedAt: CFTimeInterval = 0
        /// When the hold is dropped: the last spring's start plus its settling time.
        /// nil until the hosted tree reports the change applied (`shrinkDidBegin`), or
        /// until the content is seen to have shrunk, whichever comes first.
        private var shrinkReleaseAt: CFTimeInterval?

        func holdForAnimatedShrink(response: Double, dampingFraction: Double) -> ShrinkAnchor {
            guard let sv = scrollView, let document = sv.documentView else { return .top }
            let clip = sv.contentView
            if shrinkHold == nil {
                heldHeight = document.frame.height
                let offset = max(0, clip.bounds.origin.y)
                heldAnchor = ShrinkAnchor(slack: max(0, heldHeight - clip.bounds.height - offset), offset: offset)
                let hold = document.heightAnchor.constraint(greaterThanOrEqualToConstant: heldHeight)
                hold.isActive = true
                shrinkHold = hold
            }
            shrinkSettling = DampedSpring(response: response, dampingFraction: dampingFraction).settlingDuration
            shrinkRequestedAt = CACurrentMediaTime()
            shrinkReleaseAt = nil
            if shrinkLink == nil {
                let link = sv.displayLink(target: self, selector: #selector(shrinkTick(_:)))
                link.add(to: .main, forMode: .common)
                shrinkLink = link
            }
            return heldAnchor
        }

        func shrinkBegan(at time: CFTimeInterval) {
            guard shrinkHold != nil else { return }
            shrinkReleaseAt = time + shrinkSettling
        }

        @objc private func shrinkTick(_ link: CADisplayLink) {
            guard scrollView != nil, let host = hostingView, shrinkHold != nil else {
                endShrinkHold()
                return
            }
            let now = link.timestamp
            if shrinkReleaseAt == nil {
                if host.intrinsicContentSize.height < heldHeight - 0.5 {
                    /// The change landed without a `shrinkDidBegin` report.
                    shrinkReleaseAt = now + shrinkSettling
                } else if now - shrinkRequestedAt > 1 {
                    /// It never shortened the content; there is nothing to bridge.
                    releaseShrinkHold()
                    return
                }
            }
            /// Released only between scroll gestures, and at the latest a little after
            /// the longest spring could have run, whatever else happens.
            guard !isLiveScrolling else { return }
            if now - shrinkRequestedAt > shrinkSettling + 2 || (shrinkReleaseAt.map { now >= $0 } ?? false) {
                releaseShrinkHold()
            }
        }

        /// Ends a hold that ran its course. The content sits `lift` below the held
        /// frame's top (see step 2 above); dropping the hold returns it to the top of
        /// a document that much shorter, so the offset moves up by the same amount in
        /// the same pass, and is brought into range if anything else left it past the
        /// end (NSClipView does not always re-clamp on a document shrink).
        private func releaseShrinkHold() {
            guard let sv = scrollView, let document = sv.documentView, let host = hostingView else {
                endShrinkHold()
                return
            }
            let lift = heldAnchor.lowering(frameHeight: heldHeight, contentHeight: host.intrinsicContentSize.height)
            let clip = sv.contentView
            /// Read before the release: the layout below may clamp the offset itself.
            let held = clip.bounds.origin.y
            endShrinkHold()
            sv.layoutSubtreeIfNeeded()
            let maxY = max(0, document.frame.height - clip.bounds.height)
            let y = min(max(0, held - lift), maxY)
            if abs(y - clip.bounds.origin.y) > 0.25 {
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                sv.reflectScrolledClipView(clip)
            }
        }

        /// Drops the hold and stops the display link. Idempotent.
        func endShrinkHold() {
            shrinkLink?.invalidate()
            shrinkLink = nil
            shrinkHold?.isActive = false
            shrinkHold = nil
            shrinkReleaseAt = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> HitTestGatedScrollView {
        /// Every consumer receives a scroll view whose configuration and scrolling
        /// behavior are identical to a plain, unmodified NSScrollView — horizontal
        /// swipe recognition, where a consumer needs it, is handled entirely outside
        /// this utility via a standalone NSEvent local monitor (see the header
        /// comment above) — so nothing here can affect scrolling responsiveness for
        /// any consumer. The only difference
        /// from a plain NSScrollView is the hitTest(_:) override described in the
        /// "isActive / hit-test isolation" note above and on HitTestGatedScrollView
        /// itself; it changes only click routing, never rendering or scrolling.
        let scrollView = HitTestGatedScrollView()
        configureScrollView(scrollView)

        let container = AppKitFlippedContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layerContentsRedrawPolicy = .onSetNeedsDisplay
        scrollView.documentView = container

        context.coordinator.contentWidthInset = AppKitScrollInitialInset.initialInset(alwaysOverflows: alwaysOverflows)
        let hostingView = NSHostingView(rootView: makeWrappedContent(coordinator: context.coordinator))
        /// Intrinsic size only. The default (.standardBounds) also installs min- and
        /// max-size constraints, and each is its own full measurement of the hosted tree
        /// at a different proposal — every time the constraints are refreshed, i.e. on
        /// every rootView hand-off and every width change. Neither constrains anything
        /// here: the width is pinned to the clip view by the container, and the height is
        /// exactly the content's (see the constraints below).
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        container.addSubview(hostingView)

        /// Hosting view fills container. Leading/trailing fix width; top/bottom
        /// let the container grow to the hosting view's intrinsic content height.
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let clipView = scrollView.contentView
        /// Container width and top are pinned to the clip view. bottomAnchor is
        /// intentionally omitted — height is content-driven via Auto Layout.
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            container.topAnchor.constraint(equalTo: clipView.topAnchor),
        ])

        wire(scrollView: scrollView, container: container, hostingView: hostingView,
             coordinator: context.coordinator)
        /// The hosting view was just built from this value's content, so the updateNSView
        /// SwiftUI sends next has nothing to hand off.
        context.coordinator.appliedRevision = revision
        return scrollView
    }

    /// Connects the new scroll view to this mount's coordinator: the coordinator's
    /// references, the width-report callback, and the live-scroll observers.
    private func wire(scrollView: HitTestGatedScrollView, container: AppKitFlippedContainerView,
                      hostingView: NSHostingView<AppKitScrollContentWrapper<Content, Modifier>>,
                      coordinator: Coordinator) {
        coordinator.hostingView = hostingView
        coordinator.scrollView  = scrollView
        syncCoordinatorState(coordinator)
        scrollView.isHitTestActive = coordinator.effectiveIsActive

        /// Fold the real, AppKit-measured content width back into the width this
        /// view proposes to its hosted SwiftUI tree. Fires only when the clip
        /// view's width actually changes relative to the scroll view's own width
        /// — i.e. when a legacy scroller is tiled in or out — so under the default
        /// overlay scroller style the inset stays 0 and this never rebuilds
        /// anything. See Coordinator.contentWidthInset.
        container.onWidthChange = { [weak coordinator] width in
            guard let coordinator, let sv = coordinator.scrollView else { return }
            /// Ignore transient zero-width passes during initial layout: at that
            /// point the scroll view may already have its final width while the
            /// container has not yet been sized, which would read as a huge bogus
            /// inset and lay the content out at (or near) zero width.
            let scrollWidth = sv.bounds.width
            guard width > 0, scrollWidth > 0 else { return }
            let inset = max(0, scrollWidth - width)
            guard abs(inset - coordinator.contentWidthInset) > 0.5 else { return }
            coordinator.contentWidthInset = inset
            /// Deferred out of the Auto Layout pass that produced this callback:
            /// assigning rootView here would mutate the hosted view tree in the
            /// middle of the layout currently sizing it. DispatchQueue.main.async
            /// (not Task) keeps this on the same run-loop turn ordering AppKit
            /// expects for deferred work originating in a layout callback.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let wrapper = coordinator.lastWrapper else { return }
                    /// Recomputed now, exactly as makeWrappedContent would, rather than
                    /// taken from `width`: an updateNSView between the layout callback
                    /// and this block (a live-resize step, say) has already handed off
                    /// content at the newer width, and re-applying the older one would
                    /// leave it laid out wrong until the next update. When that update
                    /// already carries the corrected width, there is nothing to hand off.
                    let corrected = max(0, coordinator.measuredWidth - coordinator.contentWidthInset)
                    guard corrected != wrapper.availableWidth else { return }
                    let fixed = wrapper.withAvailableWidth(corrected)
                    /// Recorded as the latest wrapper, so a second correction before the
                    /// next update compares against what was actually handed off.
                    coordinator.lastWrapper = fixed
                    coordinator.applyRootView(fixed)
                }
            }
        }

        /// queue: nil makes NotificationCenter invoke the block synchronously on
        /// the posting thread, which for NSScrollView's live-scroll notifications
        /// is always the main thread. This matters for correctness: `isLiveScrolling`
        /// becomes true immediately, so no updateNSView pass can push a fresh rootView
        /// into the hosting view at the start of a scroll, where it would compete with
        /// in-flight scroll frames. The same applies at didEndLiveScroll. MainActor.assumeIsolated
        /// is the sanctioned way to enter main-actor isolation synchronously from
        /// a callback AppKit already guarantees is on the main thread.
        let willStart = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: nil
        ) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.scrollWillStart() }
        }

        let didEnd = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: nil
        ) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.scrollDidEnd() }
        }

        coordinator.willScrollToken = willStart
        coordinator.didScrollToken  = didEnd

        if scrollProxy?.tracksViewport == true {
            coordinator.observeViewport(of: scrollView.contentView)
        }
    }

    func updateNSView(_ scrollView: HitTestGatedScrollView, context: Context) {
        let coordinator = context.coordinator
        /// Keep the live-scroll callback and the wired proxy current. Both are
        /// cheap assignments and are deliberately kept outside the isContinuous
        /// guard below so neither can go stale mid-animation.
        syncCoordinatorState(coordinator)
        /// Gate hit-testing (not visibility) when this tab is not active, removing
        /// this view and all its AppKit subviews from AppKit's hit-test traversal
        /// entirely. Deliberately not `isHidden`: see the "isActive / hit-test
        /// isolation" note above for why toggling `isHidden` back to `false` on
        /// every reactivation would trigger an unwanted scroll-indicator flash.
        scrollView.isHitTestActive = coordinator.effectiveIsActive
        /// Skip rootView replacement during continuous animation transactions.
        ///
        /// SwiftUI calls updateNSView on every interpolation frame of a running
        /// animation (spring, easeIn/Out, etc.) as well as on genuine content
        /// changes. Each call that reaches hostingView.rootView = ... forces Auto
        /// Layout to re-measure all hosted SwiftUI content from scratch, outside
        /// SwiftUI's animation transaction. For content that contains in-flight
        /// SwiftUI animations (e.g. a card collapsing), this causes
        /// sibling views to be re-laid out at each frame — producing visible size
        /// fluctuations (e.g. bottom-padding shrink/expand) on cards that are not
        /// themselves animating.
        ///
        /// context.transaction.isContinuous is true on every interpolation frame
        /// and false on the discrete update that committed the state change. We
        /// apply rootView only on non-continuous updates; the animation already
        /// running inside NSHostingView's own SwiftUI render loop is unaffected.
        ///
        /// The isHitTestActive assignment above is intentionally kept outside this
        /// guard — it is a cheap assignment that must remain current regardless of
        /// animation state.
        guard !context.transaction.isContinuous else {
            /// Taking the early return does not mean nothing needs applying. This view
            /// may have just become active again while carrying content buffered from
            /// the period it was hidden, and returning outright would leave a
            /// now-visible tab showing what it held before. Flushing costs one rootView
            /// assignment only when something is genuinely outstanding — and only when
            /// both gates are open — so at-rest continuous frames remain free.
            coordinator.flushPendingRootViewIfPossible()
            return
        }
        /// Hand off a refreshed content tree (suppressed during live scroll, and while
        /// this view is inactive — see Coordinator.isActive). The fresh tree supersedes
        /// anything buffered, so no separate flush is needed on this path.
        ///
        /// Only for a NEW value, though: an update for the value already handed off comes
        /// from an environment change the hosted tree cannot see, and re-handing it would
        /// only re-measure the whole tree for nothing (see AppKitScrollRevision). Anything
        /// still buffered from a suppressed hand-off is flushed instead.
        if coordinator.appliedRevision != revision {
            coordinator.appliedRevision = revision
            #if DEBUG
            AppKitScrollHandoffProbe.newRevisions += 1
            #endif
            coordinator.applyRootView(makeWrappedContent(coordinator: coordinator))
        } else {
            coordinator.flushPendingRootViewIfPossible()
        }

        /// Return to the top when the content's *subject* changes (a different film in
        /// the right sidebar, say) rather than merely its values. Without this, reusing
        /// one scroll view for successive subjects — which is the whole point of not
        /// giving the hosted content a new SwiftUI identity per subject — would leave
        /// the new subject scrolled to wherever the previous one happened to sit.
        ///
        /// Deliberately keyed on an explicit token rather than inferred from the content:
        /// only the consumer knows which changes are a new subject and which are an
        /// in-place edit of the current one. Consumers that pass no key (the default)
        /// keep the existing behavior — the scroll position is never touched.
        ///
        /// Ordered after the rootView hand-off so the offset applies to the new content,
        /// and skipped on the first update (`appliedResetKey` starts nil) because a
        /// freshly made scroll view is already at the top.
        if let key = contentResetKey, coordinator.appliedResetKey != key {
            let isFirstApplication = coordinator.appliedResetKey == nil
            coordinator.appliedResetKey = key
            if !isFirstApplication {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    static func dismantleNSView(_ scrollView: HitTestGatedScrollView, coordinator: Coordinator) {
        coordinator.removeObservers()
        coordinator.activation?.detach(coordinator)
        coordinator.activation = nil
        /// Drop the width-report callback before anything else: it is the one
        /// path that could still fire from an AppKit layout pass after teardown.
        (scrollView.documentView as? AppKitFlippedContainerView)?.onWidthChange = nil
        /// Unwire the proxy so a proxy that outlives this scroll view (they are
        /// typically @State on the consumer and do) is not left holding a closure
        /// pointing at a torn-down coordinator.
        coordinator.wiredProxy?.scrollHandler = nil
        coordinator.wiredProxy?.shrinkHandler = nil
        coordinator.wiredProxy?.shrinkBeganHandler = nil
        coordinator.wiredProxy?.viewportRequestHandler = nil
        coordinator.wiredProxy = nil
        coordinator.endShrinkHold()
        /// Release strong references so the hosting view's SwiftUI subtree and
        /// the scroll view's AppKit hierarchy are both eligible for deallocation.
        /// pendingRootView is cleared first in case dismantleNSView fires while an
        /// update is buffered — during a live scroll, or while this view is inactive
        /// (applyRootView defers in both cases).
        coordinator.pendingRootView    = nil
        coordinator.lastWrapper        = nil
        coordinator.onScrollWillStart  = nil
        coordinator.anchorOffsets      = [:]
        coordinator.hostingView        = nil
        coordinator.scrollView         = nil
        /// Leave the window NOW rather than when SwiftUI removes this view's host, which it
        /// does in the display cycle's LAYOUT phase — after the CONSTRAINT phase. In between,
        /// the constraint pass still reaches the hosting view, whose graph has been reset by
        /// this teardown, and asks it for its intrinsic size: a full rebuild and measurement of
        /// the entire hosted tree for a view about to be discarded, about 110–125 ms per exit
        /// from a heavy tab, as measured. Removing an already-removed view is a no-op, so
        /// SwiftUI's own removal of the host afterward is unaffected.
        scrollView.removeFromSuperview()
    }

    // MARK: - Helpers

    /// Refreshes the coordinator state that mirrors a value carried on this
    /// (value-type) representable. Called from both makeNSView and updateNSView
    /// so neither the live-scroll callback nor the wired proxy is frozen at
    /// creation time. Both are plain assignments — no allocation per pass.
    @MainActor
    private func syncCoordinatorState(_ coordinator: Coordinator) {
        coordinator.onScrollWillStart = onScrollWillStart
        coordinator.parameterIsActive = isActive
        if coordinator.activation !== activation {
            coordinator.activation?.detach(coordinator)
            coordinator.activation = activation
            activation?.attach(coordinator) { [weak coordinator] in coordinator?.applyActivation() }
        }
        /// Kept in step with the representable so applyRootView can suppress work for a
        /// scroll view that is currently hidden. See Coordinator.isActive.
        coordinator.isActive = coordinator.effectiveIsActive

        /// Re-wire only when the proxy identity actually changes. In practice each
        /// consumer passes a stable @State proxy, so this is a single reference
        /// comparison per update; handling the change case keeps a swapped proxy
        /// from silently pointing at nothing.
        if coordinator.wiredProxy !== scrollProxy {
            coordinator.wiredProxy?.scrollHandler = nil
            coordinator.wiredProxy?.shrinkHandler = nil
            coordinator.wiredProxy?.shrinkBeganHandler = nil
            coordinator.wiredProxy?.viewportRequestHandler = nil
            coordinator.wiredProxy = scrollProxy
            scrollProxy?.scrollHandler = { [weak coordinator] anchorID in
                coordinator?.scrollToAnchor(anchorID)
            }
            scrollProxy?.shrinkHandler = { [weak coordinator] response, dampingFraction in
                coordinator?.holdForAnimatedShrink(response: response, dampingFraction: dampingFraction) ?? .top
            }
            scrollProxy?.shrinkBeganHandler = { [weak coordinator] time in
                coordinator?.shrinkBegan(at: time)
            }
            scrollProxy?.viewportRequestHandler = { [weak coordinator] in
                coordinator?.reportViewport()
            }
        }
    }

    @MainActor
    private func makeWrappedContent(
        coordinator: Coordinator
    ) -> AppKitScrollContentWrapper<Content, Modifier> {
        let wrapper = AppKitScrollContentWrapper(
            content: content,
            /// GeometryReader measures the NSScrollView; the hosted tree is laid
            /// out inside the clip view. Subtracting the measured inset makes the
            /// two agree even when a legacy scroller is tiled beside the clip
            /// view. The inset is 0 under the default overlay scroller style, so
            /// this is the identity operation in the common case.
            availableWidth: max(0, availableWidth - coordinator.contentWidthInset),
            modifier: modifier,
            /// Only a consumer that supplied a proxy can act on a reported anchor,
            /// so only that consumer pays for the preference reader that collects
            /// them. See ScrollAnchorReporter.
            tracksAnchors: scrollProxy?.tracksAnchors == true,
            coordinatorBox: coordinator.coordinatorBox
        )
        coordinator.measuredWidth = availableWidth
        coordinator.lastWrapper = wrapper
        return wrapper
    }

    @MainActor
    private func configureScrollView(_ scrollView: NSScrollView) {
        scrollView.hasVerticalScroller        = true
        scrollView.hasHorizontalScroller      = false
        scrollView.autohidesScrollers         = style.autohidesScrollers
        scrollView.borderType                 = style.borderType
        if let backgroundColor = style.backgroundColor {
            scrollView.drawsBackground        = true
            scrollView.backgroundColor        = backgroundColor
        } else {
            scrollView.drawsBackground        = false
        }
        scrollView.verticalScrollElasticity   = style.verticalScrollElasticity
        scrollView.horizontalScrollElasticity = .none
        scrollView.wantsLayer                 = true
        scrollView.layerContentsRedrawPolicy  = .onSetNeedsDisplay
        /// Off by default (see `AppKitScrollStyle.automaticallyAdjustsContentInsets`): a
        /// scroll view that is not the window's direct content view under a titlebar never
        /// receives an automatic inset, so only the recomputation on every layout pass is
        /// being skipped here, not any inset the person would actually see.
        scrollView.automaticallyAdjustsContentInsets = style.automaticallyAdjustsContentInsets
        if !style.automaticallyAdjustsContentInsets {
            scrollView.contentInsets = NSEdgeInsets()
        }
    }
}

// MARK: - ━━━━━━━━━━ 2. SharedOpenPanel ━━━━━━━━━━
///
/// Generic, reusable NSOpenPanel helper: presents the panel as a sheet on the asking window
/// and returns the person's choice through `async`, so a call site is one `await` instead
/// of a completion handler and a hand-configured panel.
///
/// App-wide defaults live on `OpenPanelPresenter.defaults`, with per-call overrides for the
/// initial folder, the size, resizability and movability. `canCreateDirectories` and
/// `delegate` are left out of the panel unless given.

/// App-wide defaults for every panel `OpenPanelPresenter` shows. Set once, at launch,
/// through `OpenPanelPresenter.defaults`, only where they differ from these.
@MainActor
struct OpenPanelDefaults {
    /// Where a panel opens when its configuration names no `directoryURL`.
    enum Directory {
        /// `~/Desktop`. The default.
        case desktop
        /// `/Applications`, for browsing app bundles.
        case applications
        /// The home folder.
        case home
        /// A fixed folder.
        case url(URL)
        /// Leaves `directoryURL` unset, so AppKit opens wherever the last panel left off.
        case system

        var url: URL? {
            switch self {
            case .desktop:
                FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            case .applications:
                URL(fileURLWithPath: "/Applications", isDirectory: true)
            case .home:
                FileManager.default.homeDirectoryForCurrentUser
            case .url(let url):
                url
            case .system:
                nil
            }
        }
    }

    var directory: Directory = .desktop
    /// Applied with `setContentSize` before the sheet is shown.
    var contentSize = NSSize(width: 600, height: 400)
    /// `false` removes `.resizable` from the panel's style mask.
    var isResizable = false
    var isMovable = false
}

@MainActor
struct OpenPanelConfiguration {
    var canChooseFiles: Bool = true
    var canChooseDirectories: Bool = false
    var allowsMultipleSelection: Bool = false
    var allowedContentTypes: [UTType] = []
    /// Lets the person open packages such as app bundles and pick something inside them.
    var treatsFilePackagesAsDirectories: Bool = false

    var title: String?
    var message: String?
    var prompt: String?

    /// Optional initial directory. If `nil`, `OpenPanelPresenter.defaults.directory`
    /// decides (the Desktop, unless the project changed it).
    var directoryURL: URL?

    /// Per-panel overrides of `OpenPanelPresenter.defaults`. `nil` takes the default.
    var contentSize: NSSize?
    var isResizable: Bool?
    var isMovable: Bool?

    /// Whether the panel offers New Folder. `nil` keeps AppKit's default.
    var canCreateDirectories: Bool?
    /// Filters and validates what can be chosen, e.g. to allow only one kind of package. The
    /// panel holds its delegate weakly; the presenter keeps this one alive until it closes.
    var delegate: (any NSOpenSavePanelDelegate)?

    init(
        canChooseFiles: Bool = true,
        canChooseDirectories: Bool = false,
        allowsMultipleSelection: Bool = false,
        allowedContentTypes: [UTType] = [],
        treatsFilePackagesAsDirectories: Bool = false,
        title: String? = nil,
        message: String? = nil,
        prompt: String? = nil,
        directoryURL: URL? = nil,
        contentSize: NSSize? = nil,
        isResizable: Bool? = nil,
        isMovable: Bool? = nil,
        canCreateDirectories: Bool? = nil,
        delegate: (any NSOpenSavePanelDelegate)? = nil) {
        self.canChooseFiles = canChooseFiles
        self.canChooseDirectories = canChooseDirectories
        self.allowsMultipleSelection = allowsMultipleSelection
        self.allowedContentTypes = allowedContentTypes
        self.treatsFilePackagesAsDirectories = treatsFilePackagesAsDirectories
        self.title = title
        self.message = message
        self.prompt = prompt
        self.directoryURL = directoryURL
        self.contentSize = contentSize
        self.isResizable = isResizable
        self.isMovable = isMovable
        self.canCreateDirectories = canCreateDirectories
        self.delegate = delegate }
}

@MainActor
enum OpenPanelSelection { case canceled; case urls([URL]) }

/// Centralized helper for presenting NSOpenPanel as a sheet with consistent sizing.
@MainActor
enum OpenPanelPresenter {
    /// Applied to every panel; each value can be overridden per panel on its configuration.
    static var defaults = OpenPanelDefaults()

    /// Presents an NSOpenPanel configured with the provided options.
    /// - Parameters:
    ///   - configuration: Configuration options for the panel.
    ///   - window: The window to attach the sheet to. If nil, uses keyWindow or mainWindow.
    /// - Returns: '.urls([URL])' if the user confirmed, '.canceled' otherwise.
    static func present(
        configuration: OpenPanelConfiguration,
        attachedTo window: NSWindow? = nil
    ) async -> OpenPanelSelection {
        let panel = NSOpenPanel()

        /// Core configuration.
        panel.canChooseFiles = configuration.canChooseFiles
        panel.canChooseDirectories = configuration.canChooseDirectories
        panel.allowsMultipleSelection = configuration.allowsMultipleSelection
        panel.treatsFilePackagesAsDirectories = configuration.treatsFilePackagesAsDirectories

        if !configuration.allowedContentTypes.isEmpty {
            panel.allowedContentTypes = configuration.allowedContentTypes }

        /// The configuration's folder, else the project default (~/Desktop unless changed).
        if let directoryURL = configuration.directoryURL ?? defaults.directory.url {
            panel.directoryURL = directoryURL }

        if let title = configuration.title { panel.title = title }
        if let message = configuration.message { panel.message = message }
        if let prompt = configuration.prompt { panel.prompt = prompt }
        if let canCreate = configuration.canCreateDirectories { panel.canCreateDirectories = canCreate }
        panel.delegate = configuration.delegate

        /// Fixed size and non-resizable, immovable behavior unless the project or this
        /// panel says otherwise.
        if !(configuration.isResizable ?? defaults.isResizable) {
            panel.styleMask.remove(.resizable) }
        panel.setContentSize(configuration.contentSize ?? defaults.contentSize)
        panel.isMovable = configuration.isMovable ?? defaults.isMovable

        let targetWindow = window ?? NSApp.keyWindow ?? NSApp.mainWindow

        /// `panel.delegate` is weak; this reference holds the delegate until the panel closes.
        let delegate = configuration.delegate
        defer { withExtendedLifetime(delegate) {} }

        return await withCheckedContinuation { continuation in
            if let targetWindow {
                /// Present as sheet attached to the specified window
                panel.beginSheetModal(for: targetWindow) { response in
                    if response == .OK { continuation.resume(returning: .urls(panel.urls))
                    } else { continuation.resume(returning: .canceled) } }
            } else {
                /// Fallback: a standalone modeless panel, for when no window is available
                /// to attach a sheet to (should rarely happen). `begin` does not block the
                /// rest of the app.
                panel.begin { response in
                    if response == .OK { continuation.resume(returning: .urls(panel.urls))
                    } else { continuation.resume(returning: .canceled) } }
            }
        }
    }
}

// MARK: - ━━━━━━━━━━ 3. FieldEdge ━━━━━━━━━━
///
/// The edge every boxed surface wears — a field, a list, a card, a bar: a rounded plate, an
/// outline that holds its strength across the top and fades out toward the bottom, and an
/// understated drop shadow that carries the lower edge in its place.
///
///   • `FieldEdgeStyle` — the measures. `.standard` is the reference; a rounder or stronger
///     variant is a copy with only the differing fields changed.
///   • `.fieldEdgeChrome(_:fill:clipsContent:insetsInterior:shadow:)` — draws it in SwiftUI.
///   • `FieldEdgeLayers` — draws it with Core Animation layers, for AppKit views laid out
///     by hand.
///
/// One definition, so surfaces meant to look alike cannot drift apart.

/// The measures of a field edge.
nonisolated struct FieldEdgeStyle: Equatable, Sendable {
    var cornerRadius: CGFloat = 6
    var borderWidth: CGFloat = 1

    /// Strength of the outline, as a fraction of `separatorColor`'s own alpha; 1 is the
    /// system color at full strength. Low by default because the outline sits on the window
    /// background, not over a fill that would dilute it.
    var borderOpacity: Double = 0.2

    /// Fraction of the height at which the outline begins fading out. Above it the outline
    /// is at `borderOpacity`; at the bottom edge it is gone, so the shadow carries that edge.
    var borderFadeStart: Double = 0.1

    /// Deliberately understated by default — enough to seat the surface without reading as
    /// a raised control.
    var shadowOpacity: Double = 0.16
    var shadowRadius: CGFloat = 1.5
    var shadowOffsetY: CGFloat = 1

    static let standard = FieldEdgeStyle()

    /// The outline's shape, continuously rounded.
    var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    var shadowColor: Color { .black.opacity(shadowOpacity) }

    /// The outline's color, top to bottom.
    var borderGradient: LinearGradient {
        let edge = Color(NSColor.separatorColor)
        return LinearGradient(
            stops: [
                .init(color: edge.opacity(borderOpacity), location: 0.0),
                .init(color: edge.opacity(borderOpacity), location: borderFadeStart),
                .init(color: edge.opacity(0), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// What casts a field edge's shadow.
nonisolated enum FieldEdgeShadow: Sendable {
    /// The fill shape alone, behind the content. A solid rounded rect is a single-shape blur
    /// that Core Animation handles cheaply, and the content is never rendered offscreen to
    /// derive a silhouette — the cheaper choice whenever the fill is opaque, which makes the
    /// two look the same. With no fill, nothing is cast.
    case fill
    /// The finished view: clipped content, fill and outline together. For surfaces with no
    /// fill of their own, or whose content must contribute to the silhouette.
    case content
}

extension View {
    /// Draws a field edge around the view.
    ///
    /// - Parameters:
    ///   - style: The measures. `.standard` unless the surface is deliberately different.
    ///   - fill: The plate behind the content, or nil for none (the content paints its own).
    ///   - clipsContent: Clips the content to the shape, so rows scrolled or laid out past
    ///     the corners never paint outside it. Off for content that draws outside its bounds
    ///     on purpose, such as an exterior focus ring.
    ///   - insetsInterior: Stops the fill and the clip one border width inside the outline.
    ///     `strokeBorder` draws inward, so the outline then occupies a ring nothing else
    ///     paints under. `separatorColor` is translucent, so a fill or row background running
    ///     under it would tint the outline from below.
    ///   - shadow: What casts the shadow; see `FieldEdgeShadow`.
    ///
    /// The order is load-bearing and fixed here: clip, then fill, then outline, then (for
    /// `.content`) the shadow, so the shadow is cast by the finished shape. Apply any sizing
    /// before this modifier, so the shape resolves against the final bounds. The outline
    /// never takes a click from the content under it.
    nonisolated func fieldEdgeChrome(_ style: FieldEdgeStyle = .standard,
                                     fill: Color? = Color(NSColor.controlBackgroundColor),
                                     clipsContent: Bool = false,
                                     insetsInterior: Bool = false,
                                     shadow: FieldEdgeShadow = .fill) -> some View {
        modifier(FieldEdgeChrome(style: style, fill: fill, clipsContent: clipsContent,
                                 insetsInterior: insetsInterior, shadow: shadow))
    }
}

/// The modifier behind `.fieldEdgeChrome(...)`.
private struct FieldEdgeChrome: ViewModifier {
    let style: FieldEdgeStyle
    let fill: Color?
    let clipsContent: Bool
    let insetsInterior: Bool
    let shadow: FieldEdgeShadow

    private var interior: some InsettableShape {
        style.shape.inset(by: insetsInterior ? style.borderWidth : 0)
    }

    func body(content: Content) -> some View {
        let edged = clipped(content)
            .background { plate }
            .overlay {
                style.shape
                    .strokeBorder(style.borderGradient, lineWidth: style.borderWidth)
                    .allowsHitTesting(false)
            }
        return Group {
            if shadow == .content {
                edged.shadow(color: style.shadowColor, radius: style.shadowRadius,
                             x: 0, y: style.shadowOffsetY)
            } else {
                edged
            }
        }
    }

    @ViewBuilder
    private func clipped(_ content: Content) -> some View {
        if clipsContent {
            content.clipShape(interior)
        } else {
            content
        }
    }

    @ViewBuilder
    private var plate: some View {
        if let fill {
            if shadow == .fill {
                interior.fill(fill)
                    .shadow(color: style.shadowColor, radius: style.shadowRadius,
                            x: 0, y: style.shadowOffsetY)
            } else {
                interior.fill(fill)
            }
        }
    }
}

/// A field edge drawn with Core Animation layers, for an AppKit view that lays itself out:
/// a shape layer for the fill (which also casts the shadow, along an explicit path) and a
/// gradient layer masked to a stroked outline.
///
/// Usage, from a layer-backed view:
///
///     private let edge = FieldEdgeLayers()
///     init() { …; wantsLayer = true; layer?.masksToBounds = false; edge.install(in: layer!) }
///     override func layout() { super.layout(); edge.layout(in: bounds) }
///     override func updateLayer() { super.updateLayer(); edge.applyColors(appearance: effectiveAppearance) }
///     override func viewDidChangeEffectiveAppearance() { …; edge.applyColors(appearance: effectiveAppearance) }
///
/// Subviews added after `install(in:)` draw above both layers. To keep the outline above
/// them, raise `borderLayer.zPosition`.
@MainActor
final class FieldEdgeLayers {
    let style: FieldEdgeStyle
    /// The plate. Its fill is set by `applyColors`; it casts the shadow.
    let fillLayer = CAShapeLayer()
    /// The outline: the border colors, masked to the stroked shape.
    let borderLayer = CAGradientLayer()
    private let borderMask = CAShapeLayer()

    init(style: FieldEdgeStyle = .standard) {
        self.style = style
        fillLayer.shadowOpacity = Float(style.shadowOpacity)
        fillLayer.shadowRadius = style.shadowRadius
        fillLayer.shadowOffset = CGSize(width: 0, height: style.shadowOffsetY)
        fillLayer.shadowColor = NSColor.black.cgColor
        borderLayer.startPoint = CGPoint(x: 0.5, y: 0)
        borderLayer.endPoint = CGPoint(x: 0.5, y: 1)
        borderLayer.locations = [0, NSNumber(value: style.borderFadeStart), 1]
        borderMask.fillColor = nil
        borderMask.strokeColor = NSColor.black.cgColor
        borderMask.lineWidth = style.borderWidth
        borderLayer.mask = borderMask
    }

    /// Adds the fill, then the outline, as sublayers of `layer`. The host's layer must not
    /// mask to bounds, or the shadow is cut off.
    func install(in layer: CALayer) {
        layer.addSublayer(fillLayer)
        layer.addSublayer(borderLayer)
    }

    /// Fits both layers to `bounds`, in the host's coordinates. Call from `layout()`.
    func layout(in bounds: CGRect) {
        let path = style.shape.path(in: bounds).cgPath
        fillLayer.frame = bounds
        fillLayer.path = path
        fillLayer.shadowPath = path
        borderLayer.frame = bounds
        borderMask.frame = bounds
        /// The mask strokes centered on its path, so the path runs half a border width in,
        /// and the outline lands inside the bounds as `strokeBorder` draws it.
        let inset = style.borderWidth / 2
        borderMask.path = RoundedRectangle(cornerRadius: style.cornerRadius - inset, style: .continuous)
            .path(in: bounds.insetBy(dx: inset, dy: inset)).cgPath
    }

    /// Resolves the fill and outline colors for `appearance`. Layer colors are fixed
    /// `CGColor`s, so call this again whenever the appearance changes.
    func applyColors(fill: NSColor = .controlBackgroundColor, appearance: NSAppearance) {
        appearance.performAsCurrentDrawingAppearance {
            fillLayer.fillColor = fill.cgColor
            let edge = NSColor.separatorColor
            let strong = edge.withAlphaComponent(edge.alphaComponent * style.borderOpacity).cgColor
            borderLayer.colors = [strong, strong, edge.withAlphaComponent(0).cgColor]
        }
    }
}

// MARK: - ━━━━━━━━━━ 4. PathBar ━━━━━━━━━━
///
/// A folder or file path drawn as a breadcrumb in a bar with the `.standard` field edge, in
/// three forms:
///
///   • `PathBarView(url:isUnavailable:placeholder:icon:fill:)` — a location. The
///     last component (the item itself) is drawn primary and survives truncation; the
///     ancestors are secondary and squeezed first. A nil URL draws a dimmed empty state rather
///     than nothing, so the layout does not change the first time a path is set. The full path
///     shows on hover, and double-clicking the name reveals it in the Finder.
///   • `PathBarView(pathComponents:icon:fill:)` — plain components. The components exactly as given
///     (they may be a message such as "No file selected."), joined and drawn secondary, with
///     no hover text or double-click.
///   • `PathBarChrome { … }` — the shell only. Just the edge, at a fixed height, so a caller can
///     animate its own content without the outline taking part.
///
/// `.toolTip(_:)` is public because the bar needs it and so may its callers; see `ToolTipView`.

/// The visual shell of a path bar — the `.standard` field edge — at a fixed height,
/// accepting arbitrary content via a `@ViewBuilder` slot.
///
/// Separating chrome from content lets a caller keep the shell permanently visible while
/// animating only the content layer, so the bar outline never flickers during a crossfade.
struct PathBarChrome<Content: View>: View {
    private let height: CGFloat
    private let content: Content

    init(height: CGFloat = 24, @ViewBuilder content: () -> Content) {
        self.height = height
        self.content = content()
    }

    var body: some View {
        /// Content slot — caller controls opacity/animation; the shell around it is always
        /// rendered at full opacity.
        ZStack(alignment: .leading) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .fieldEdgeChrome()
    }
}

/// Displays a path as a breadcrumb, middle-truncated when it does not fit.
struct PathBarView: View {

    private enum Form {
        /// A real location: emphasized last component, hover text, double-click to reveal.
        case location(URL?, isUnavailable: Bool, placeholder: String)
        /// Components as given, drawn plain.
        case components([String])
    }

    private let form: Form
    private let icon: Image?
    private let fill: Color

    /// A location. A nil `url` draws the empty state with `placeholder`. `isUnavailable` (the
    /// item can't currently be reached) draws its name in red. `icon` defaults to a folder.
    /// `fill` is the bar's plate; set it to tell the bar apart from a surface of the same color.
    init(url: URL?, isUnavailable: Bool = false, placeholder: String = "No folder selected",
         icon: Image? = nil, fill: Color = Color(NSColor.controlBackgroundColor)) {
        form = .location(url, isUnavailable: isUnavailable, placeholder: placeholder)
        self.icon = icon
        self.fill = fill
    }

    /// Path components as given, joined with " › ".
    init(pathComponents: [String], icon: Image, fill: Color = Color(NSColor.controlBackgroundColor)) {
        form = .components(pathComponents)
        self.icon = icon
        self.fill = fill
    }

    var body: some View {
        switch form {
        case .components(let parts):
            HStack(spacing: 6) {
                iconView(dimmed: false)
                Text(parts.joined(separator: " › "))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(6)
            .fieldEdgeChrome(fill: fill)
        case .location(let url, let isUnavailable, let placeholder):
            location(url, isUnavailable: isUnavailable, placeholder: placeholder)
        }
    }

    private func iconView(dimmed: Bool) -> some View {
        (icon ?? Image(systemName: "folder.fill"))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 14, height: 14)
            /// Dimmed when empty, so the bar does not draw the eye to a value it lacks.
            .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
    }

    private func location(_ url: URL?, isUnavailable: Bool, placeholder: String) -> some View {
        /// Leading "/" dropped. Empty when there is no URL, which draws the empty state.
        let parts = url?.pathComponents.filter { $0 != "/" } ?? []
        /// Everything above the item, carrying its own trailing separator so the two `Text`s
        /// butt together.
        let ancestors = parts.count > 1 ? parts.dropLast().joined(separator: " › ") + " › " : nil
        return HStack(spacing: 6) {
            iconView(dimmed: parts.isEmpty)

            if parts.isEmpty {
                Text(placeholder)
                    .lineLimit(1)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                /// spacing 0: `ancestors` supplies its own trailing separator.
                HStack(spacing: 0) {
                    if let ancestors {
                        Text(ancestors)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            /// Lower priority than the name, so the ancestors are squeezed first.
                            .layoutPriority(0)
                    }
                    Text(parts.last ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.system(size: 12))
                        .foregroundStyle(isUnavailable ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        .layoutPriority(1)
                        /// Double-click, not single: a one-click target would put a
                        /// Finder-opening hotspot under a pointer just passing over it.
                        .onTapGesture(count: 2) {
                            /// A deleted or unmounted item simply opens no window, which is
                            /// the Finder's own behavior.
                            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                }
            }

            Spacer()
        }
        .padding(6)
        .fieldEdgeChrome(fill: fill)
        /// The full path and the double-click hint on hover, since the breadcrumb is
        /// truncated. `.toolTip` rather than `.help` — see `ToolTipView`.
        /// `url.path`, not the components rejoined: those had the leading "/" filtered out.
        .toolTip(parts.isEmpty ? nil : url.map {
            $0.path + "\nDouble-click the name to reveal it in the Finder."
        })
    }
}

// MARK: Tool Tips

/// A tooltip that actually appears.
///
/// SwiftUI's `.help(_:)` registers a tooltip RECT against the geometry the view had when
/// it was installed, and never re-registers it. Inside a scroll view, the content is
/// re-laid out often enough that the rect and the thing it describes part company, and the
/// tooltip stops appearing on hover.
///
/// This sets a real AppKit tooltip on an `NSView` through its `toolTip` property, which AppKit
/// keeps fitted to the view's bounds through every geometry and window change itself.
/// Attached as a BACKGROUND with `hitTest` returning nil, so it never takes a click from the
/// content it sits behind.
private struct ToolTipView: NSViewRepresentable {
    let text: String?

    func makeNSView(context: Context) -> TipView { TipView() }

    func updateNSView(_ view: TipView, context: Context) {
        let tip = text?.isEmpty == false ? text : nil
        if view.toolTip != tip { view.toolTip = tip }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TipView,
                      context: Context) -> CGSize? {
        /// Takes whatever the thing it is describing takes; it proposes nothing of its own.
        nil
    }

    final class TipView: NSView {
        /// Transparent to the mouse: the content this sits behind owns every click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// Attaches an AppKit tooltip. A nil or empty string attaches none.
    ///
    /// Use in place of `.help(_:)` wherever the view can be re-laid out after it appears —
    /// see `ToolTipView` for why that distinction matters.
    func toolTip(_ text: String?) -> some View {
        /// `.help` is kept alongside it to carry the string into the accessibility tree,
        /// which a bare tooltip rect does not. Two registrations cannot produce two
        /// tooltips — AppKit asks only the innermost rect under the pointer.
        background(ToolTipView(text: text).accessibilityHidden(true))
            .help(text ?? "")
    }
}

// MARK: - ━━━━━━━━━━ 5. GlyphBadge ━━━━━━━━━━
///
/// A filled circle with a glyph (an SF Symbol or a character) centered on it, a drop shadow
/// under the circle and another under the glyph. Unifies Film Tracker's `IndicatorBadge` /
/// `symbolBadge` / `characterBadge` (ReleasesTable) and its AppKit card composition
/// (`RSBShapeView` + `RSBSymbolView` + `RSBViewShadow`, RTabReleases), and CalShare's
/// animated `StatusBadge` (SharedViews).
///
///   GlyphBadge(color: .green) { Image(systemName: "checkmark").font(…) }   // any label
///   GlyphBadge(systemName: "checkmark", color: .green)                     // Film Tracker's table
///   GlyphBadge(character: "A", color: .orange, font: .system(size: 10, weight: .semibold))
///   SymbolBadge(systemName: state.glyph, color: state.color)               // CalShare's, animated
///   let badge = GlyphBadgeView(); badge.content = .symbol("checkmark")     // AppKit
///
/// Defaults are each original's: `GlyphBadge` and `GlyphBadgeView` draw Film Tracker's 14pt
/// circle with no circle shadow and no sheen; `SymbolBadge` draws CalShare's 16pt circle
/// with its soft circle shadow and top sheen. Every one of those is a parameter.

// MARK: - GlyphBadgeShadow

/// A black drop shadow, in SwiftUI's terms: `.shadow(color: .black.opacity(opacity),
/// radius: radius, y: offsetY)`.
struct GlyphBadgeShadow: Hashable, Sendable {
    var opacity: Double
    var radius: CGFloat
    var offsetY: CGFloat
    /// Whether `radius` and `offsetY` are fractions of the badge's diameter rather than points.
    var scalesWithDiameter: Bool

    init(opacity: Double, radius: CGFloat, offsetY: CGFloat, scalesWithDiameter: Bool = false) {
        self.opacity = opacity
        self.radius = radius
        self.offsetY = offsetY
        self.scalesWithDiameter = scalesWithDiameter
    }

    /// This shadow in points, for a badge of this diameter.
    func resolved(diameter: CGFloat) -> GlyphBadgeShadow {
        guard scalesWithDiameter else { return self }
        return GlyphBadgeShadow(opacity: opacity, radius: radius * diameter, offsetY: offsetY * diameter)
    }

    /// The glyph's half-point shadow, which holds a white glyph's edges on any saturated fill.
    static let ink = GlyphBadgeShadow(opacity: 0.5, radius: 0.5, offsetY: 0.5)

    /// CalShare's circle shadow: radius and drop a thirty-second of the diameter.
    static let soft = GlyphBadgeShadow(opacity: 0.2, radius: 1 / 32, offsetY: 1 / 32, scalesWithDiameter: true)

    /// NSShadow's blur radius for a SwiftUI shadow radius. Fitted against SwiftUI's
    /// rendering (Film Tracker): 2 was closest across 0.5–4.
    static let nsBlurScale: CGFloat = 2

    /// This shadow as a view's `NSShadow`. AppKit copies the offset onto the view's layer,
    /// which is geometry-flipped in a flipped view, so positive is down there; every
    /// caller's view should be flipped.
    func nsShadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(opacity)
        shadow.shadowBlurRadius = radius * Self.nsBlurScale
        shadow.shadowOffset = NSSize(width: 0, height: offsetY)
        return shadow
    }
}

// MARK: - GlyphBadge

/// A filled circle with any label centered on it. The circle's shadow goes on the circle
/// alone, so the label's is not doubled.
struct GlyphBadge<Label: View>: View {
    let color: Color
    /// The label's color. White suits every saturated fill; a white fill wants black.
    let ink: Color
    let diameter: CGFloat
    /// The circle's shadow; nil draws none.
    let circleShadow: GlyphBadgeShadow?
    /// The label's shadow; nil draws none (black on white needs none: it only muddies).
    let inkShadow: GlyphBadgeShadow?
    /// A light-to-dark sheen over the fill, as `Color.gradient` draws.
    let sheen: Bool
    let label: () -> Label

    init(color: Color,
         ink: Color = .white,
         diameter: CGFloat = 14,
         circleShadow: GlyphBadgeShadow? = nil,
         inkShadow: GlyphBadgeShadow? = .ink,
         sheen: Bool = false,
         @ViewBuilder label: @escaping () -> Label) {
        self.color = color
        self.ink = ink
        self.diameter = diameter
        self.circleShadow = circleShadow?.resolved(diameter: diameter)
        self.inkShadow = inkShadow
        self.sheen = sheen
        self.label = label
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
                .shadow(color: circleShadow.map { .black.opacity($0.opacity) } ?? .clear,
                        radius: circleShadow?.radius ?? 0, x: 0, y: circleShadow?.offsetY ?? 0)
                .overlay {
                    if sheen { Circle().fill(GlyphBadgeSheen.gradient) }
                }
            label()
                .foregroundStyle(ink)
                .shadow(color: inkShadow.map { .black.opacity($0.opacity) } ?? .clear,
                        radius: inkShadow?.radius ?? 0, x: 0, y: inkShadow?.offsetY ?? 0)
        }
    }
}

extension GlyphBadge where Label == GlyphBadgeSymbol {
    /// An SF Symbol badge. The glyph's point size defaults to Film Tracker's ratio, an 8pt
    /// glyph in a 14pt circle.
    init(systemName: String,
         color: Color,
         ink: Color = .white,
         weight: Font.Weight = .bold,
         diameter: CGFloat = 14,
         glyphSize: CGFloat? = nil,
         circleShadow: GlyphBadgeShadow? = nil,
         inkShadow: GlyphBadgeShadow? = .ink,
         sheen: Bool = false) {
        let size = glyphSize ?? GlyphBadgeSymbol.glyphSize(forDiameter: diameter)
        self.init(color: color, ink: ink, diameter: diameter, circleShadow: circleShadow,
                  inkShadow: inkShadow, sheen: sheen) {
            GlyphBadgeSymbol(systemName: systemName, size: size, weight: weight)
        }
    }
}

extension GlyphBadge where Label == Text {
    /// A single-character badge (a region letter, a count).
    init(character: String,
         color: Color,
         ink: Color = .white,
         font: Font = .system(size: 10, weight: .semibold),
         diameter: CGFloat = 14,
         circleShadow: GlyphBadgeShadow? = nil,
         inkShadow: GlyphBadgeShadow? = .ink,
         sheen: Bool = false) {
        self.init(color: color, ink: ink, diameter: diameter, circleShadow: circleShadow,
                  inkShadow: inkShadow, sheen: sheen) {
            Text(character).font(font)
        }
    }
}

/// The symbol label of `GlyphBadge(systemName:…)`, a named type so the initializer can
/// name its `Label`.
struct GlyphBadgeSymbol: View {
    let systemName: String
    let size: CGFloat
    let weight: Font.Weight

    /// An 8pt glyph in a 14pt circle.
    static func glyphSize(forDiameter diameter: CGFloat) -> CGFloat { diameter * 8 / 14 }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: weight))
    }
}

/// The sheen both renderers lay over the fill.
enum GlyphBadgeSheen {
    static let topOpacity: Double = 0.15
    static var gradient: LinearGradient {
        LinearGradient(colors: [.white.opacity(topOpacity), .clear], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - SymbolBadge

/// A symbol badge that animates a change of glyph or color: the new glyph comes in with
/// SwiftUI's SF Symbols replace transition, over the circle's crossfade to the new color.
///
/// It sets its own animations, whatever its surroundings turn off, so it behaves
/// identically wherever it sits; and it takes a new look in an update of its own, so a
/// layout change that comes with it does not slide the badge along too.
struct SymbolBadge: View {
    let glyph: String
    let color: Color
    let ink: Color
    let weight: Font.Weight
    let diameter: CGFloat
    /// The glyph's point size, when not the usual share of the diameter.
    let glyphSize: CGFloat?
    /// The circle's shadow; nil draws none.
    let circleShadow: GlyphBadgeShadow?
    /// The glyph's shadow; nil draws none. Its radius is a blur radius here.
    let inkShadow: GlyphBadgeShadow?
    let sheen: Bool
    /// The duration of the change animation.
    let animationDuration: Double
    /// Whether the badge sits on a text baseline the way an SF Symbol would, centered on
    /// the capitals.
    let alignsToTextBaseline: Bool

    init(systemName: String,
         color: Color,
         ink: Color = .white,
         weight: Font.Weight = .bold,
         diameter: CGFloat = 16,
         glyphSize: CGFloat? = nil,
         circleShadow: GlyphBadgeShadow? = .soft,
         inkShadow: GlyphBadgeShadow? = .ink,
         sheen: Bool = true,
         animationDuration: Double = 0.2,
         alignsToTextBaseline: Bool = true) {
        self.glyph = systemName
        self.color = color
        self.ink = ink
        self.weight = weight
        self.diameter = diameter
        self.glyphSize = glyphSize
        self.circleShadow = circleShadow?.resolved(diameter: diameter)
        self.inkShadow = inkShadow
        self.sheen = sheen
        self.animationDuration = animationDuration
        self.alignsToTextBaseline = alignsToTextBaseline
        _shown = State(initialValue: Look(glyph: systemName, color: color))
    }

    private struct Look: Equatable {
        var glyph: String
        var color: Color
    }

    /// What is on screen. A new look is taken in by `onChange`, in an update of its own.
    @State private var shown: Look

    var body: some View {
        ZStack {
            /// A flat fill (which can blend from one color to the next) under the sheen
            /// (which can't, so it stays put). The shadow is cast by the fill alone: on the
            /// fill and sheen together, each gets one, drawn offscreen on every frame of a scroll.
            Circle()
                .fill(shown.color)
                .shadow(color: circleShadow.map { .black.opacity($0.opacity) } ?? .clear,
                        radius: circleShadow?.radius ?? 0, y: circleShadow?.offsetY ?? 0)
                .overlay {
                    if sheen { Circle().fill(GlyphBadgeSheen.gradient) }
                }
            /// The glyph's shadow is a second copy of the glyph, darkened, blurred and
            /// dropped, playing the same effects at the same moments: a shadow modifier on
            /// the glyph is drawn outside its symbol effects and doesn't turn.
            ZStack {
                if let inkShadow {
                    glyphImage
                        .foregroundStyle(.black.opacity(inkShadow.opacity))
                        .blur(radius: inkShadow.radius)
                        .offset(y: inkShadow.offsetY)
                }
                glyphImage
                    .foregroundStyle(ink)
            }
            /// Flattened into one layer, with room for the blur: left live, the blur is a
            /// filter the compositor redraws on every frame of a scroll. The circle stays
            /// outside, since flattening it clips its shadow and shifts its color.
            .padding(2)
            .drawingGroup()
            .padding(-2)
        }
        .frame(width: diameter, height: diameter)
        /// The outer modifier applies first, so the new look's animation is set after the reset.
        .transaction(value: shown) { transaction in
            transaction.animation = .easeInOut(duration: animationDuration)
        }
        .transaction { transaction in
            transaction.disablesAnimations = false
            transaction.animation = nil
        }
        .onChange(of: Look(glyph: glyph, color: color)) { _, new in shown = new }
        .alignmentGuide(.firstTextBaseline) { dimensions in
            alignsToTextBaseline
                ? dimensions[VerticalAlignment.center] + diameter * 0.3
                : dimensions[.firstTextBaseline]
        }
    }

    private var glyphImage: some View {
        Image(systemName: shown.glyph)
            .font(.system(size: glyphSize ?? GlyphBadgeSymbol.glyphSize(forDiameter: diameter), weight: weight))
            .contentTransition(.symbolEffect(.replace))
    }
}

// MARK: - GlyphBadgeView

/// The AppKit `GlyphBadge`: a layer-drawn circle with its own shadow, and a symbol or
/// character over it with a view shadow. Flipped; sized by `diameter` through its
/// intrinsic content size, and centers the circle in whatever frame it is given.
///
/// Placement follows SwiftUI's, to the device pixel, so an AppKit badge matches a SwiftUI one
/// beside it: the symbol is drawn by `GlyphSymbolView`, and the character's text field is the
/// text's width plus 4 at x − 2 (a field that centers its own text starts the line between
/// pixels), both rounded where the window's pixels are. Give the view a frame on whole
/// pixels, as SwiftUI would.
final class GlyphBadgeView: NSView {
    enum Content: Equatable {
        /// An SF Symbol. A nil point size takes the usual share of the diameter.
        case symbol(String, weight: NSFont.Weight = .bold, pointSize: CGFloat? = nil)
        /// A character (a region letter, a count).
        case character(String, font: NSFont = .systemFont(ofSize: 10, weight: .semibold))
        case none
    }

    var content: Content = .none { didSet { if content != oldValue { applyContent() } } }
    /// The fill; nil draws no circle (a bare glyph).
    var fillColor: NSColor? = .systemGreen { didSet { applyColors() } }
    var ink: NSColor = .white { didSet { applyColors() } }
    var diameter: CGFloat = 14 {
        didSet { invalidateIntrinsicContentSize(); applyContent(); applyCircleShadow() }
    }
    var circleShadow: GlyphBadgeShadow? { didSet { applyCircleShadow() } }
    var inkShadow: GlyphBadgeShadow? = .ink { didSet { glyphHost.shadow = inkShadow?.nsShadow() } }
    var sheen = false { didSet { sheenLayer.isHidden = !sheen } }
    /// Whether the symbol centers by its drawn (vector) bounds horizontally, as SwiftUI centers
    /// an Image in a ZStack, rather than by its alignment rectangle. See `GlyphSymbolView`.
    var centersSymbolVectorBounds = true {
        didSet { symbolView.centersVectorBoundsHorizontally = centersSymbolVectorBounds }
    }
    /// The height of the character's line, centered on the circle. Nil takes the text field's
    /// own; pass SwiftUI's measure of the same text to sit where a SwiftUI `Text` would.
    var characterLineHeight: CGFloat? { didSet { needsLayout = true } }

    private let circle = CAShapeLayer()
    private let sheenLayer = CAGradientLayer()
    private let sheenMask = CAShapeLayer()
    /// Carries the glyph's view shadow, so the circle's layer shadow is not doubled.
    private let glyphHost = GlyphBadgeFlippedView()
    private let symbolView = GlyphSymbolView()
    private let characterField = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        circle.shadowColor = NSColor.black.cgColor
        layer?.addSublayer(circle)
        sheenLayer.colors = [NSColor.white.withAlphaComponent(GlyphBadgeSheen.topOpacity).cgColor,
                             NSColor.white.withAlphaComponent(0).cgColor]
        /// The layer is geometry-flipped with the view, so y = 0 is the top.
        sheenLayer.startPoint = CGPoint(x: 0.5, y: 0)
        sheenLayer.endPoint = CGPoint(x: 0.5, y: 1)
        sheenLayer.mask = sheenMask
        sheenLayer.isHidden = true
        layer?.addSublayer(sheenLayer)
        glyphHost.wantsLayer = true
        glyphHost.shadow = inkShadow?.nsShadow()
        addSubview(glyphHost)
        symbolView.centersVectorBoundsHorizontally = centersSymbolVectorBounds
        characterField.isBezeled = false
        characterField.drawsBackground = false
        glyphHost.addSubview(symbolView)
        glyphHost.addSubview(characterField)
        applyContent()
        applyCircleShadow()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layout() {
        super.layout()
        let disc = CGRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2,
                          width: diameter, height: diameter)
        /// A continuous capsule rather than an ellipse: on a square it is a hair squarer than
        /// a true circle, and it is the disc the AppKit cards drew before this view replaced them.
        let path = Capsule(style: .continuous).path(in: disc).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circle.frame = bounds
        circle.path = path
        circle.shadowPath = path
        sheenLayer.frame = bounds
        sheenMask.frame = bounds
        sheenMask.path = path
        CATransaction.commit()
        glyphHost.frame = bounds
        symbolView.frame = glyphHost.bounds
        /// The label rule (see the type's notes), rounded in window pixels as SwiftUI rounds.
        let size = characterField.intrinsicContentSize
        let textWidth = min(size.width, bounds.width)
        let height = characterLineHeight ?? size.height
        let scale = unsafe window?.backingScaleFactor ?? 2
        let origin = convert(NSPoint.zero, to: nil)
        let windowHeight = unsafe window?.contentView?.bounds.height ?? 0
        let top = windowHeight - origin.y
        func x(_ v: CGFloat) -> CGFloat { ((origin.x + v) * scale + 0.5).rounded(.down) / scale - origin.x }
        func y(_ v: CGFloat) -> CGFloat { ((top + v) * scale + 0.5).rounded(.down) / scale - top }
        let left = x((bounds.width - textWidth) / 2 - 2), upper = y((bounds.height - height) / 2)
        characterField.frame = CGRect(x: left, y: upper,
                                      width: x((bounds.width - textWidth) / 2 + textWidth + 2) - left,
                                      height: y((bounds.height + height) / 2) - upper)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyContent() {
        switch content {
        case let .symbol(name, weight, pointSize):
            symbolView.pointSize = pointSize ?? GlyphBadgeSymbol.glyphSize(forDiameter: diameter)
            symbolView.weight = weight
            symbolView.symbolName = name
            symbolView.isHidden = false
            characterField.isHidden = true
        case let .character(text, font):
            characterField.stringValue = text
            characterField.font = font
            characterField.isHidden = false
            symbolView.isHidden = true
        case .none:
            symbolView.isHidden = true
            characterField.isHidden = true
        }
        needsLayout = true
        applyColors()
    }

    private func applyCircleShadow() {
        let circleShadow = circleShadow?.resolved(diameter: diameter)
        circle.shadowOpacity = Float(circleShadow?.opacity ?? 0)
        circle.shadowRadius = circleShadow?.radius ?? 0
        circle.shadowOffset = CGSize(width: 0, height: circleShadow?.offsetY ?? 0)
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            circle.fillColor = fillColor?.cgColor
            circle.isHidden = fillColor == nil
        }
        sheenLayer.isHidden = !sheen || fillColor == nil
        symbolView.tint = ink
        characterField.textColor = ink
    }
}

// MARK: - GlyphSymbolView

/// An SF Symbol drawn where SwiftUI would draw `Image(systemName:)` at the same font, to the
/// device pixel. AppKit's own placement (an NSImageView's, or the image's size) lands up to
/// half a point off, which shows beside SwiftUI.
///
/// Vertically it centers the symbol's vector bounds, rounded to the device pixel. Horizontally
/// it centers the alignment rectangle's width, as SwiftUI does for an Image in a frame, or,
/// with `centersVectorBoundsHorizontally`, the vector bounds, as it does in a ZStack.
/// The vector bounds come from an 8× raster of the symbol, rounded out to the half point, and
/// are cached per symbol, size and weight.
class GlyphSymbolView: NSView {
    var symbolName: String? { didSet { if symbolName != oldValue { needsDisplay = true } } }
    /// The font the symbol is drawn at, as `.font(.system(size:weight:))` sets it on an Image.
    var pointSize: CGFloat = 11 { didSet { if pointSize != oldValue { needsDisplay = true } } }
    var weight: NSFont.Weight = .regular { didSet { if weight != oldValue { needsDisplay = true } } }
    var tint: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    /// Centers the symbol's vector bounds horizontally too, as SwiftUI does for an Image
    /// centered in a ZStack (a badge), rather than its alignment rectangle, as it does in a frame.
    var centersVectorBoundsHorizontally = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    private struct Symbol {
        let image: NSImage
        /// The symbol's vector bounds within `image`, top-left origin, in points.
        let bounds: CGRect
    }
    private struct Key: Hashable { let name: String; let pointSize: CGFloat; let weight: CGFloat }
    @MainActor private static var cache: [Key: Symbol] = [:]

    @MainActor private static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> Symbol? {
        let key = Key(name: name, pointSize: pointSize, weight: weight.rawValue)
        if let cached = cache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        /// The vector bounds, from an 8x raster's coverage, rounded out to the half point.
        let scale: CGFloat = 8
        let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
        guard let context = unsafe CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let cg = unsafe image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        /// Read the coverage back as bounds-checked Data rather than through the context's raw
        /// pointer, and step rows by the bitmap's actual bytesPerRow (Core Graphics may pad it).
        guard let raster = context.makeImage(), let cfData = raster.dataProvider?.data else { return nil }
        let data = cfData as Data
        let stride = raster.bytesPerRow
        guard stride >= w, data.count >= stride * (h - 1) + w else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where data[y * stride + x] > 64 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        /// Rows are top-down in the context's memory.
        func down(_ v: Int) -> CGFloat { (CGFloat(v) / scale * 2).rounded(.down) / 2 }
        func up(_ v: Int) -> CGFloat { (CGFloat(v) / scale * 2).rounded(.up) / 2 }
        let bounds = CGRect(x: down(minX), y: down(minY), width: up(maxX + 1) - down(minX), height: up(maxY + 1) - down(minY))
        let symbol = Symbol(image: image, bounds: bounds)
        cache[key] = symbol
        return symbol
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let symbolName, let symbol = Self.symbol(symbolName, pointSize: pointSize, weight: weight) else { return }
        let scale = unsafe window?.backingScaleFactor ?? 2
        func pixel(_ v: CGFloat) -> CGFloat { (v * scale + 0.5).rounded(.down) / scale }
        let b = symbol.bounds
        let align = symbol.image.alignmentRect
        let x = centersVectorBoundsHorizontally
            ? pixel((bounds.width - b.width) / 2) - b.minX
            : pixel((bounds.width - align.width) / 2) - align.minX
        let origin = CGPoint(x: x, y: pixel((bounds.height - b.height) / 2) - b.minY)
        let rect = NSRect(origin: origin, size: symbol.image.size)
        /// Replace the black with the tint, keeping its coverage, in an image of its own: a .sourceIn fill
        /// on the view's backing, at a rect off the pixel grid, could leave a dark seam in the glyph.
        let image = symbol.image, tint = tint
        let tinted = NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            tint.set()
            r.fill(using: .sourceIn)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// A flipped, otherwise plain view: `GlyphBadgeView`'s glyph host, so its NSShadow's
/// offset points down.
final class GlyphBadgeFlippedView: NSView {
    override var isFlipped: Bool { true }
}
