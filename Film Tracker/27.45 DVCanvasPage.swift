// MARK: - DVCanvasPage.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The Data Visualizations page: its eight sections built from DVCanvasKit nodes (27.44) —
// every card, figure and string, once — and drawn two ways: on the tab by one page view
// into cached Core Animation strips inside a plain NSScrollView, with the page's few controls
// as real AppKit subviews; and into the library PDF as vector blocks (DVPrintLayout).
//
// Why not hosted SwiftUI (the page's form until 2026-09-24): an NSHostingView of ~1,000
// leaves re-resolved every Text and re-rendered every drawing group whenever the window's key
// state flipped — which every sheet, popover and window switch does — inside AppKit's sheet
// animation, which stepped from the main thread and stuttered (`sheet-hitch`: 60–80 ms later
// first frame, 90–120 ms stalls mid-slide). Drawn here, nothing on the page redraws on a key
// change, the tab mounts in ~35 ms instead of ~290, a live-resize step costs ~6 ms instead of
// ~19, and a scroll step only moves drawn strips. `dataviz-render` (99.40) renders the page;
// `dataviz-canvas` measures it; `dataviz-window` (99.50) captures the real window.

import AppKit
import SwiftUI

// MARK: - Controls

/// A plain AppKit control embedded in the canvas, sized the way SwiftUI laid out the
/// representable (or SwiftUI control) it stands in for.
@MainActor
final class DVKControl: NSObject, DVControl {
    let control: NSControl
    var view: NSView { control }
    var fixedWidth: CGFloat?
    var fixedHeight: CGFloat?
    var onAction: ((NSControl) -> Void)?

    init(_ control: NSControl, width: CGFloat? = nil, height: CGFloat? = nil) {
        self.control = control
        self.fixedWidth = width
        self.fixedHeight = height
        super.init()
        control.target = self
        control.action = #selector(fire(_:))
    }

    @objc private func fire(_ sender: NSControl) { onAction?(sender) }

    /// The control's intrinsic size and first baseline, read once: AppKit answers both
    /// through the control's cell on every call (a resize step asked hundreds of times), and
    /// neither changes for these controls after they are made.
    private lazy var metrics: (size: CGSize, baseline: CGFloat) =
        (control.intrinsicContentSize, control.firstBaselineOffsetFromTop)

    func layoutSize(offer: CGFloat) -> CGSize {
        CGSize(width: fixedWidth ?? metrics.size.width, height: fixedHeight ?? metrics.size.height)
    }
    var sizing: DVSizing {
        let w = fixedWidth ?? metrics.size.width
        return DVSizing(min: w, max: w)
    }
    /// SwiftUI aligns a representable by the view's own `firstBaselineOffsetFromTop`, read as
    /// if measured from the top of its layout box (not corrected for the alignment-rect inset:
    /// measured, a small segmented control's title row is 18 pt, not 19).
    var baselineFromTop: CGFloat? {
        let h = fixedHeight ?? metrics.size.height
        return metrics.baseline + (h - metrics.size.height) / 2
    }

    static func segmented(_ titles: [String], selected: Int) -> DVKControl {
        let c = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: nil, action: nil)
        c.segmentStyle = .automatic
        c.segmentDistribution = .fillEqually
        c.controlSize = .small
        c.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        c.selectedSegment = selected
        return DVKControl(c, width: 160)
    }

    static func popUp(_ titles: [String], enabled: [Bool]? = nil, width: CGFloat) -> DVKControl {
        let b = NSPopUpButton(frame: .zero, pullsDown: false)
        b.bezelStyle = .rounded
        b.isBordered = true
        b.imagePosition = .noImage
        b.alignment = .natural
        b.controlSize = .small
        b.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (i, t) in titles.enumerated() {
            let item = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            item.isEnabled = enabled?[i] ?? true
            menu.addItem(item)
        }
        b.menu = menu
        return DVKControl(b, width: width, height: 16)
    }

    static func checkbox(_ title: String) -> DVKControl {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.controlSize = .small
        b.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        return DVKControl(b)
    }

    static func stepButton(_ symbol: String) -> DVKControl {
        let b = NSButton(title: "", target: nil, action: nil)
        b.bezelStyle = .push
        b.controlSize = .small
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageOnly
        return DVKControl(b)
    }
}

// MARK: - Page model

/// What the page shows, and the tab's state its controls write (the Viewing History span).
@MainActor
struct DVCanvasModel {
    let stats: LibraryStatistics
    let insights: LibraryInsights
    let period: ViewingPeriodStatistics?
    let navigation: DVNavigation
    let showInfoComplete: Bool
    let selectedYear: Binding<Int>
    let yearToDate: Binding<Bool>
    let compare: Binding<Bool>
    let compareYear: Binding<Int>
    /// Advanced by the tab whenever anything the page shows changes (a dataset or period
    /// applied, a control moved, a setting). An update carrying the revision already built
    /// is an unrelated SwiftUI pass and rebuilds nothing.
    var revision = 0
}

// MARK: - Page view

/// The whole page in one view: lays the section nodes out for its width, draws them into
/// cached strips (see `tileHeight`), places the embedded controls, and turns clicks on
/// actionable regions into their actions (tile taps, attention popovers).
@MainActor
final class DVCanvasPageView: NSView {
    override var isFlipped: Bool { true }

    var model: DVCanvasModel? { didSet { rebuild() } }
    /// Each card's scope switch or role pop-up choice, by key. Local to the page: reset
    /// when the tab is remounted.
    private var scopes: [String: Int] = [:]
    private var root: any DVNode = DVVStack(spacing: 0, [])
    /// Clickable regions, computed when first needed after a layout (a click, a cursor
    /// update) rather than on every resize step.
    private var cachedHotspots: [DVHotspot]?
    private var hotspots: [DVHotspot] {
        if let cachedHotspots { return cachedHotspots }
        var spots: [DVHotspot] = []
        root.hotspots(contentRect(width: bounds.width), into: &spots)
        cachedHotspots = spots
        return spots
    }
    private var controlsByKey: [String: DVKControl] = [:]
    private var laidOutWidth: CGFloat = -1
    private var popover: NSPopover?
    private var lastClipOrigin: CGPoint = .zero
    #if DEBUG
    static var drawCalls = 0
    static var drawnArea: CGFloat = 0
    static var drawMs: Double = 0
    static var drawMaxMs: Double = 0
    static var layoutMs: Double = 0
    /// Page rebuilds (a new model or a scope switch), for the `dataviz-tab` scenario.
    static var rebuilds = 0
    /// Every width the page was laid out at, with the time (`dataviz-measure`).
    static var debugLayoutLog: [(time: Double, width: CGFloat)] = []
    #endif

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The page is drawn by strips of this height, each its own CALayer that draws its whole
    /// strip once and keeps it: scrolling only moves drawn strips (compositing, as the hosted
    /// page's flattened layers did). A change marks every strip stale but redraws only the
    /// ones on screen; the rest are drawn ahead while the page is at rest (`schedulePrefetch`),
    /// or as they near the viewport if a scroll outruns that. (NSView strips would not do:
    /// AppKit backs a layer-backed view with its visible rect only and redraws the newly
    /// exposed band on every scroll step.)
    static let tileHeight: CGFloat = 256
    /// How far beyond the viewport stale strips are refreshed eagerly, in viewport heights:
    /// half a screen at rest, so a scroll finds them drawn; none mid-drag, when every step
    /// makes them stale again (measured: 512-pt strips with the margin, 25 ms a resize step;
    /// 256-pt strips, no margin, drawn asynchronously, 10).
    private var refreshMargin: CGFloat {
        #if DEBUG
        if Self.debugLiveResize { return 0 }
        #endif
        return inLiveResize ? 0 : 0.5
    }
    #if DEBUG
    /// Stands in for a live resize, which the harness cannot perform.
    static var debugLiveResize = false
    /// Turns the idle prefetch off, for the harness's A/B (`-FTDebugNoPrefetch YES`).
    static var debugNoPrefetch = UserDefaults.standard.bool(forKey: "FTDebugNoPrefetch")
    /// Strips drawn by the idle prefetch.
    static var prefetches = 0
    #endif
    private var tiles: [CALayer] = []
    private var staleTiles = IndexSet()

    private func syncTiles() {
        guard let host = layer else { return }
        let count = bounds.height > 0 ? Int((bounds.height / Self.tileHeight).rounded(.up)) : 0
        let scale = unsafe window?.backingScaleFactor ?? 2
        while tiles.count < count {
            let tile = CALayer()
            tile.delegate = self
            tile.needsDisplayOnBoundsChange = false
            tile.contentsScale = scale
            tile.anchorPoint = .zero
            // Recorded on the main thread, rasterized by Core Animation off it: half the
            // cost of a resize step (measured 6 ms vs 13.6).
            tile.drawsAsynchronously = true
            // Below the controls' layers.
            host.insertSublayer(tile, at: 0)
            tiles.append(tile)
            staleTiles.insert(tiles.count - 1)
        }
        while tiles.count > count { tiles.removeLast().removeFromSuperlayer(); staleTiles.remove(tiles.count) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, tile) in tiles.enumerated() {
            let frame = CGRect(x: 0, y: CGFloat(i) * Self.tileHeight, width: bounds.width,
                               height: min(Self.tileHeight, bounds.height - CGFloat(i) * Self.tileHeight))
            if tile.frame != frame { tile.frame = frame; staleTiles.insert(i) }
            if tile.contentsScale != scale { tile.contentsScale = scale; staleTiles.insert(i) }
        }
        CATransaction.commit()
        refreshVisibleTiles()
    }

    /// Redraws the stale strips that are on screen (or within half a screen of it), gives
    /// back the bitmaps of far strips over the backing budget, and schedules the idle
    /// prefetch for the rest.
    func refreshVisibleTiles() {
        let viewport = visibleRect
        guard !viewport.isEmpty else { return }
        // Nearest strips keep their bitmaps up to the budget (always those within two
        // screens); the farthest give theirs back and are drawn again on approach.
        let keep = keptTiles(viewport)
        for (i, tile) in tiles.enumerated() where tile.contents != nil && !keep.contains(i) {
            tile.contents = nil
            staleTiles.insert(i)
        }
        guard !staleTiles.isEmpty else { return }
        let visible = viewport.insetBy(dx: 0, dy: -viewport.height * refreshMargin)
        for i in staleTiles where i < tiles.count && tiles[i].frame.intersects(visible) {
            tiles[i].setNeedsDisplay()
            staleTiles.remove(i)
        }
        schedulePrefetch()
    }

    /// Backing the page may hold in drawn strips. The whole page at a typical width fits
    /// (1,148 pt × 5,000 pt ≈ 90 MB at 2×), so once prefetched a scroll anywhere draws nothing.
    static let backingBudgetMB: Double = 128

    private func tileMB(_ tile: CALayer) -> Double {
        Double(tile.bounds.width * tile.bounds.height * tile.contentsScale * tile.contentsScale * 4) / 1_048_576
    }

    /// The strips allowed a bitmap: every one within two screens of the viewport, then the
    /// nearest others while the budget lasts.
    private func keptTiles(_ viewport: CGRect) -> IndexSet {
        let near = viewport.insetBy(dx: 0, dy: -viewport.height * 2)
        var kept = IndexSet(), spent = 0.0
        let byDistance = tiles.indices.sorted { distance(tiles[$0].frame, viewport) < distance(tiles[$1].frame, viewport) }
        for i in byDistance {
            let mb = tileMB(tiles[i])
            guard tiles[i].frame.intersects(near) || spent + mb <= Self.backingBudgetMB else { continue }
            kept.insert(i)
            spent += mb
        }
        return kept
    }

    private func distance(_ frame: CGRect, _ viewport: CGRect) -> CGFloat {
        frame.maxY < viewport.minY ? viewport.minY - frame.maxY : max(0, frame.minY - viewport.maxY)
    }

    /// Stale strips off screen are drawn ahead of need while the page is at rest — one per
    /// run-loop turn, nearest first, starting a moment after the last scroll, change or
    /// resize step — so a scroll only moves drawn strips instead of drawing one on the frame
    /// it comes into view (≈3–7 ms each, most of a 120 Hz frame).
    private var prefetchTimer: Timer?
    static let prefetchDelay: TimeInterval = 0.15

    private func schedulePrefetch() {
        prefetchTimer?.invalidate()
        prefetchTimer = nil
        guard !staleTiles.isEmpty, unsafe window != nil else { return }
        let timer = Timer(timeInterval: Self.prefetchDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.prefetchNextTile() }
        }
        RunLoop.main.add(timer, forMode: .default)
        prefetchTimer = timer
    }

    private func prefetchNextTile() {
        prefetchTimer = nil
        let viewport = visibleRect
        guard let window = unsafe window, !viewport.isEmpty, !staleTiles.isEmpty else { return }
        // Not under a sheet (its animation owns the frames) or mid-resize (every step makes
        // strips stale again); the sheet's close or the drag's end reschedules.
        guard window.attachedSheet == nil, !inLiveResize else { return }
        #if DEBUG
        guard !Self.debugLiveResize, !Self.debugNoPrefetch else { return }
        #endif
        let keep = keptTiles(viewport)
        guard let next = staleTiles.filter({ $0 < tiles.count && keep.contains($0) })
            .min(by: { distance(tiles[$0].frame, viewport) < distance(tiles[$1].frame, viewport) }) else { return }
        staleTiles.remove(next)
        tiles[next].setNeedsDisplay()
        tiles[next].displayIfNeeded()
        #if DEBUG
        Self.prefetches += 1
        #endif
        guard staleTiles.contains(where: { keep.contains($0) }) else { return }
        let timer = Timer(timeInterval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.prefetchNextTile() }
        }
        RunLoop.main.add(timer, forMode: .default)
        prefetchTimer = timer
    }

    #if DEBUG
    /// Backing held by drawn strips, in MB (width × height × scale² × 4 bytes).
    var debugStripBackingMB: Double {
        tiles.filter { $0.contents != nil }.reduce(0.0) {
            $0 + Double($1.bounds.width * $1.bounds.height * $1.contentsScale * $1.contentsScale * 4)
        } / 1_048_576
    }
    #endif

    private func redrawTiles() {
        staleTiles = IndexSet(integersIn: 0..<tiles.count)
        refreshVisibleTiles()
    }

    // Both observers are target/selector registrations: NotificationCenter drops them when
    // the page deallocates, so no tokens (and no deinit) are needed. Each is re-pointed at
    // its new object on every move. Both notifications are posted on the main thread.

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didEndSheetNotification, object: nil)
        prefetchTimer?.invalidate()
        prefetchTimer = nil
        guard let window = unsafe window else { return }
        // A prefetch that waited out a sheet resumes when it closes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidEndSheet(_:)),
            name: NSWindow.didEndSheetNotification, object: window)
        schedulePrefetch()
    }

    @objc private func windowDidEndSheet(_ notification: Notification) { schedulePrefetch() }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let clip = unsafe superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: clip)
        lastClipOrigin = clip.bounds.origin
    }

    @objc private func clipBoundsDidChange(_ notification: Notification) {
        guard let clip = notification.object as? NSClipView else { return }
        // A scroll moves the popover's anchor out from under it; close it as every
        // other popover in the app does on scroll. A resize keeps the origin.
        let origin = clip.bounds.origin
        if origin != lastClipOrigin {
            lastClipOrigin = origin
            hideHover()
            if popover?.isShown == true { popover?.close() }
        }
        refreshVisibleTiles()
    }

    /// A control kept across rebuilds, so a rebuild never recreates a control being used.
    func control(_ key: String, make: () -> DVKControl) -> DVKControl {
        if let c = controlsByKey[key] { return c }
        let c = make()
        controlsByKey[key] = c
        addSubview(c.control)
        return c
    }

    private func rebuild() {
        guard let model else { return }
        #if DEBUG
        Self.rebuilds += 1
        #endif
        root = DVCanvasSections.page(model, view: self)
        anchorCache = nil
        laidOutWidth = -1
        cachedHotspots = nil
        needsLayout = true
        redrawTiles()
    }

    /// A card's current scope (or role) and the control that switches it: a small
    /// segmented control or, with `popUpWidth`, a pop-up (People's role).
    func scope(_ key: String, default value: Int, titles: [String], popUpWidth: CGFloat? = nil) -> (Int, DVKControl) {
        let selected = scopes[key] ?? value
        let c = control(key) {
            popUpWidth.map { .popUp(titles, width: $0) } ?? .segmented(titles, selected: selected)
        }
        if let seg = c.control as? NSSegmentedControl { seg.selectedSegment = selected }
        if let pop = c.control as? NSPopUpButton { pop.selectItem(at: selected) }
        c.onAction = { [weak self] sender in
            let index = (sender as? NSSegmentedControl)?.selectedSegment ?? (sender as? NSPopUpButton)?.indexOfSelectedItem ?? value
            guard let self, index >= 0, self.scopes[key] != index else { return }
            self.scopes[key] = index
            self.rebuild()
        }
        return (selected, c)
    }

    /// Page padding: 8 top, 24 sides, 32 bottom; sections at most 1500 wide, centered.
    private func contentRect(width: CGFloat) -> CGRect {
        let available = max(0, width - 48)
        let w = min(Preferences.galleryMaxGridWidth, available)
        return CGRect(x: 24 + (available - w) / 2, y: 8, width: w, height: root.height(w))
    }

    /// What a live resize keeps in place, in reading order, in page coordinates: every
    /// section band, every card of a flow row, every other row whole. Cached for the last
    /// width (the previous resize step's), so a step lays out only the new width.
    private var anchorCache: (width: CGFloat, rects: [CGRect])?
    func anchorRects(width: CGFloat) -> [CGRect] {
        if let anchorCache, anchorCache.width == width { return anchorCache.rects }
        var out: [CGRect] = []
        let content = contentRect(width: width)
        if let stack = root as? DVVStack {
            for (section, sr) in zip(stack.children, stack.rects(content)) {
                guard let rows = section as? DVVStack else { out.append(sr); continue }
                for (row, r) in zip(rows.children, rows.rects(sr)) {
                    if let flow = row as? DVFlow {
                        out += flow.frames(r.width).frames.map { $0.offsetBy(dx: r.minX, dy: r.minY) }
                    } else {
                        out.append(r)
                    }
                }
            }
        }
        anchorCache = (width, out)
        return out
    }

    /// Each section's top in page coordinates at `width` (heights are memoized per width).
    func sectionTops(width: CGFloat) -> [CGFloat] {
        guard let stack = root as? DVVStack else { return [] }
        let w = min(Preferences.galleryMaxGridWidth, max(0, width - 48))
        var y: CGFloat = 8
        return stack.children.map { child in defer { y += child.height(w) }; return y }
    }

    #if DEBUG
    /// Opens the first Needs Attention row's popover as a click would (harness); true when
    /// it is shown.
    func debugOpenFirstAttentionPopover() -> Bool {
        guard let spot = hotspots.first(where: { if case .popover = $0.action { return true }; return false }),
              case .popover(let id) = spot.action else { return false }
        showAttentionPopover(id, from: spot.anchor ?? spot.rect)
        let shown = popover?.isShown == true
        popover?.close()
        return shown
    }

    /// Opens the first popover hotspot and leaves it open (harness): its window, and the
    /// rect it points at in screen space.
    func debugShowFirstPopover() -> (NSWindow, CGRect)? {
        guard let spot = hotspots.first(where: { if case .popover = $0.action { return true }; return false }),
              case .popover(let id) = spot.action, let host = unsafe window else { return nil }
        let anchor = spot.anchor ?? spot.rect
        showAttentionPopover(id, from: anchor)
        guard let w = unsafe popover?.contentViewController?.view.window else { return nil }
        return (w, host.convertToScreen(convert(anchor, to: nil)))
    }

    /// Each section's height at `width` (harness).
    func debugSectionHeights(width: CGFloat) -> [CGFloat] {
        guard let stack = root as? DVVStack else { return [] }
        let w = min(Preferences.galleryMaxGridWidth, max(0, width - 48))
        return stack.children.map { $0.height(w) }
    }
    #endif

    func fittingHeight(width: CGFloat) -> CGFloat { contentRect(width: width).maxY + 32 }

    override func layout() {
        super.layout()
        syncTiles()
        guard bounds.width != laidOutWidth else { return }
        #if DEBUG
        let t0 = CACurrentMediaTime()
        Self.debugLayoutLog.append((t0, bounds.width))
        defer { Self.layoutMs += (CACurrentMediaTime() - t0) * 1000 }
        #endif
        laidOutWidth = bounds.width
        let rect = contentRect(width: bounds.width)
        cachedHotspots = nil
        hideHover()
        var placed: [(any DVControl, CGRect)] = []
        root.controls(rect, into: &placed)
        let live = Set(placed.map { ObjectIdentifier($0.0.view) })
        for (control, r) in placed {
            control.view.isHidden = false
            control.view.frame = control.view.frame(forAlignmentRect: r)
        }
        for c in controlsByKey.values where !live.contains(ObjectIdentifier(c.control)) { c.control.isHidden = true }
        unsafe window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        needsLayout = true
        if widthChanged { redrawTiles() }
    }

    /// Draws the part of the page in `rect` (page coordinates) into the current context.
    func drawPage(_ rect: CGRect, in ctx: CGContext) {
        #if DEBUG
        Self.drawCalls += 1
        Self.drawnArea += rect.width * rect.height
        let t0 = CACurrentMediaTime()
        defer {
            let ms = (CACurrentMediaTime() - t0) * 1000
            Self.drawMs += ms
            Self.drawMaxMs = max(Self.drawMaxMs, ms)
        }
        #endif
        let g = unsafe DVGraphics(ctx: ctx, scale: window?.backingScaleFactor ?? 2, dirty: rect)
        root.draw(g, contentRect(width: bounds.width))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redrawTiles()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        refreshVisibleTiles()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func resetCursorRects() {
        for spot in hotspots where spot.pointer { addCursorRect(spot.rect, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Innermost region wins: rows inside cards were appended after their card.
        guard let spot = hotspots.last(where: { !$0.isHover && $0.rect.contains(p) }) else { return super.mouseDown(with: event) }
        switch spot.action {
        case .perform(let action): action()
        case .popover(let id): showAttentionPopover(id, from: spot.anchor ?? spot.rect)
        case .hover: break
        }
    }

    // MARK: Hover tips

    /// The tip a `.hover` region shows (a year bar's year and count): a small label above
    /// the hovered mark, which gets a faint highlight. Both are their own layers over the
    /// strips, so moving across a chart redraws nothing.
    private lazy var hoverTip: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        f.textColor = .labelColor
        f.alignment = .center
        f.wantsLayer = true
        f.layer?.cornerRadius = 4
        f.layer?.borderWidth = 0.5
        f.isHidden = true
        addSubview(f)
        return f
    }()
    private lazy var hoverMark: CALayer = {
        let l = CALayer()
        l.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
        l.cornerRadius = 2
        l.isHidden = true
        l.zPosition = 1
        layer?.addSublayer(l)
        return l
    }()
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if hoverTracking == nil {
            let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(t)
            hoverTracking = t
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideHover()
    }

    private func updateHover(_ p: CGPoint) {
        guard let spot = hotspots.last(where: { $0.isHover && $0.rect.contains(p) }),
              case .hover(let tip) = spot.action, let (text, anchor) = tip(p) else { return hideHover() }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hoverTip.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            hoverTip.layer?.borderColor = NSColor.separatorColor.cgColor
            hoverMark.backgroundColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
        }
        hoverTip.stringValue = text
        let size = hoverTip.intrinsicContentSize
        let w = ceil(size.width) + 12, h = ceil(size.height) + 4
        // Above the mark, kept inside the region horizontally.
        let x = min(max(spot.rect.minX, anchor.midX - w / 2), spot.rect.maxX - w)
        hoverTip.frame = CGRect(x: x, y: anchor.minY - h - 4, width: w, height: h)
        hoverTip.isHidden = false
        hoverMark.frame = anchor
        hoverMark.isHidden = false
    }

    private func hideHover() {
        guard hoverTracking != nil else { return }
        hoverTip.isHidden = true
        hoverMark.isHidden = true
    }

    /// Opens the film-list popover behind `id`: a Needs Attention row, the Recordable Discs
    /// tile or Coming Up Next Month's View All row.
    func showAttentionPopover(_ id: String, from rect: CGRect) {
        guard let model, let list = DVCanvasSections.popoverList(model, id: id) else { return }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: DVAttentionPopover(label: list.label, items: list.items) { [weak pop] in
            pop?.performClose(nil)
        })
        // Its real size before it is shown: the hosting controller starts at a default size,
        // and when the content then settled the window shrank away from the arrow's side,
        // leaving the arrow 20 pt short of what it points at.
        pop.contentSize = DVAttentionPopover.size
        pop.show(relativeTo: rect, of: self, preferredEdge: .minX)
        popover = pop
    }
}

// `@preconcurrency`: CALayerDelegate is a nonisolated protocol, but strips draw synchronously
// in the main thread's Core Animation commit. The conformance lets `draw` be main-actor
// isolated, with the same runtime main-thread check `MainActor.assumeIsolated` made.
extension DVCanvasPageView: @preconcurrency CALayerDelegate {
    /// A strip's drawing: the page's content under it, in the page's appearance.
    func draw(_ layer: CALayer, in ctx: CGContext) {
        let frame = layer.frame
        // The page's layer is geometry-flipped (a flipped view), so a strip's context is
        // already y-down; only the strip's offset in the page is applied.
        if !layer.contentsAreFlipped() {
            ctx.translateBy(x: 0, y: frame.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.translateBy(x: -frame.minX, y: -frame.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            drawPage(frame, in: ctx)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// No implicit animations for strip contents or geometry.
    nonisolated func action(for layer: CALayer, forKey event: String) -> (any CAAction)? { NSNull() }
}

// MARK: - Scroll host

/// The tab's scroll view for the canvas page: a plain NSScrollView whose document is the page.
@MainActor
final class DVCanvasScrollNSView: NSScrollView {
    let page = DVCanvasPageView(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        borderType = .noBorder
        horizontalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets()
        documentView = page
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Where the reader was when the tab was last left (a section and how far into it),
    /// restored in the first sizing that has real geometry — inside layout, before anything
    /// is drawn, so the page never shows at the top first.
    var pendingAnchor: DVScrollAnchor?

    /// The section at the top of the viewport and how far the viewport sits into it.
    func currentAnchor() -> DVScrollAnchor? {
        let width = page.frame.width
        guard width > 0 else { return nil }
        let tops = page.sectionTops(width: width)
        let y = contentView.bounds.minY
        guard let i = tops.indices.last(where: { tops[$0] <= y }) else { return DVScrollAnchor(section: 0, offset: y) }
        return DVScrollAnchor(section: i, offset: y - tops[i])
    }

    override func tile() {
        super.tile()
        sizePage()
    }

    /// Sizes the page to the clip view's width. When the width changes, the card (or band,
    /// or full-width row) at the top of the viewport keeps its place on screen, as the
    /// gallery keeps its top item: everything above it reflows, and the scroll follows that
    /// card's new top, plus the same share of its height the viewport was into it, on every
    /// step of a live resize (nothing shifts under the reader, nothing snaps at the end).
    func sizePage() {
        let width = contentView.bounds.width
        let oldWidth = page.frame.width
        // The old rects first (cached from the previous step, so no relayout at the old width).
        let oldRects = oldWidth > 0 && oldWidth != width ? page.anchorRects(width: oldWidth) : []
        let height = page.fittingHeight(width: width)
        guard page.frame.size != CGSize(width: width, height: height) || pendingAnchor != nil else { return }
        var shift: CGFloat = 0
        let viewTop = contentView.bounds.minY
        // The first item in reading order still showing at the top (or the next one below a gap).
        if viewTop > 0, let i = oldRects.firstIndex(where: { $0.maxY > viewTop }) {
            let newRects = page.anchorRects(width: width)
            if newRects.count == oldRects.count {
                let old = oldRects[i], new = newRects[i]
                let into = viewTop - old.minY
                let scaled = into > 0 && old.height > 0 ? into * new.height / old.height : into
                shift = new.minY + scaled - viewTop
            }
        }
        page.setFrameSize(CGSize(width: width, height: height))
        if let anchor = pendingAnchor, width > 0, contentView.bounds.height > 0 {
            pendingAnchor = nil
            let tops = page.sectionTops(width: width)
            let y = (tops.indices.contains(anchor.section) ? tops[anchor.section] : 0) + anchor.offset
            let clip = contentView
            clip.setBoundsOrigin(NSPoint(x: 0, y: min(max(0, height - clip.bounds.height), max(0, y))))
            reflectScrolledClipView(clip)
        } else if shift != 0 {
            let clip = contentView
            let maxY = max(0, height - clip.bounds.height)
            clip.setBoundsOrigin(NSPoint(x: 0, y: min(maxY, max(0, clip.bounds.minY + shift))))
            reflectScrolledClipView(clip)
        }
    }
}

struct DVCanvasScrollView: NSViewRepresentable {
    let model: DVCanvasModel

    func makeNSView(context: Context) -> DVCanvasScrollNSView {
        let v = DVCanvasScrollNSView(frame: .zero)
        if Preferences.maintainScrollPositionOnViewSwitch {
            v.pendingAnchor = ReportsState.shared.visualizationsScrollAnchor
        }
        v.page.model = model
        v.sizePage()
        return v
    }

    func updateNSView(_ v: DVCanvasScrollNSView, context: Context) {
        guard v.page.model?.revision != model.revision else { return }
        v.page.model = model
        v.sizePage()
    }

    /// Banks the reading position for the next visit (restored only while "maintain scroll
    /// position" is on). A restore that never got real geometry keeps the old position.
    static func dismantleNSView(_ v: DVCanvasScrollNSView, coordinator: ()) {
        ReportsState.shared.visualizationsScrollAnchor = v.pendingAnchor ?? v.currentAnchor()
    }
}

/// A reading position on the page: a section, and how far past its top the viewport sits.
/// By section rather than by point, so it survives the page reflowing at another width.
struct DVScrollAnchor: Equatable {
    let section: Int
    let offset: CGFloat
}

// MARK: - Print Layout

/// The page as the library PDF draws it (see ReportsPDFExporter): the same sections, built
/// for print (see DVBuild), as blocks no taller than a row of cards so the PDF can break
/// pages between them rather than through a card. The viewing span is the tab's default —
/// the current year to date against the same span of the prior year.
@MainActor
enum DVPrintLayout {
    /// The width the blocks are laid out at before being scaled onto the page: wide enough
    /// that every row keeps the column count it has in a full-width window.
    static let width: CGFloat = 1240

    static func blocks(for dataset: DVDataset, showInfoComplete: Bool) -> [any DVNode] {
        let period = defaultPeriod(for: dataset)
        return DVCanvasSections.printBlocks(DVCanvasModel(
            stats: dataset.stats, insights: dataset.insights, period: period, navigation: DVNavigation(appState: nil),
            showInfoComplete: showInfoComplete, selectedYear: .constant(period.year), yearToDate: .constant(true),
            compare: .constant(true), compareYear: .constant(period.compareYear)))
    }

    /// Draws a block laid out at `width` into a context whose origin is its bottom-left
    /// corner, y up (a PDF page's), as vectors: paths, glyphs and symbol outlines.
    static func draw(_ block: any DVNode, in ctx: CGContext) {
        let height = block.height(width)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        block.draw(DVGraphics(ctx: ctx, scale: 2, dirty: .infinite, vector: true), CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    /// The span the tab opens on: the current year to date against the same span of the
    /// prior year, each moved to the nearest year with viewings exactly as
    /// `DataVisualizationsView.apply` moves the stepper.
    static func defaultPeriod(for dataset: DVDataset, today: Date = Date()) -> ViewingPeriodStatistics {
        let calendar = AppCalendar.current
        let viewingYears = dataset.insights.viewingYears
        var year = calendar.component(.year, from: today)
        if !viewingYears.contains(year), let last = viewingYears.last { year = last }
        let comparable = viewingYears.filter { $0 != year }
        let compareYear = comparable.contains(year - 1) ? year - 1 : (comparable.last ?? year - 1)
        return ViewingPeriodStatistics(viewings: dataset.viewingRecords, year: year, yearToDate: true,
                                       compareYear: compareYear, today: today, calendar: calendar)
    }
}

// MARK: - Card Parts

/// The Collection Growth card's fixed parts.
@MainActor
enum DVGrowthCard {
    static let chartHeight: CGFloat = 240
    /// Films between gridlines.
    static let tickStep: Double = 250
    static let emptyText = "Nothing to plot yet: films need a Date Added, and purchased releases a purchase date."
    static let legend: [(label: String, color: NSColor)] = [("Films", .systemBlue), ("Purchased releases", .systemGreen)]

    /// The scope switch: the whole span (the default), or the last five years.
    static let scopes = ["All Time", "Past 5 Years"]
    static let defaultScope = 0

    static func growth(_ g: DVGrowth, scope: Int) -> DVGrowth { scope == 0 ? g : g.lastYears(5) }

    /// "Since:" the first month plotted, then what the chart leaves out, each on its own line.
    static func subtitle(_ g: DVGrowth) -> String? {
        var lines: [String] = []
        if !g.isEmpty,
           let first = AppCalendar.current.date(from: DateComponents(year: g.firstMonth / 12, month: g.firstMonth % 12 + 1, day: 1)) {
            lines.append("Since: \(DVFormat.monthYear.string(from: first))")
        }
        if g.undatedPurchases > 0 {
            lines.append("\(DVFormat.count(g.undatedPurchases)) release\(g.undatedPurchases == 1 ? "" : "s") containing no purchase date were omitted.")
        }
        if g.undatedFilms > 0 {
            lines.append("\(DVFormat.count(g.undatedFilms)) film\(g.undatedFilms == 1 ? "" : "s") with no Date Added omitted.")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func spec(_ g: DVGrowth) -> DVLineChartSpec {
        DVLineChartSpec(series: [DVLineChartSpec.Series(values: g.films.map(Double.init), color: legend[0].color),
                                 DVLineChartSpec.Series(values: g.purchases.map(Double.init), color: legend[1].color)],
                        marks: g.yearMarks.map { DVLineChartSpec.Mark(index: $0.index, value: $0.year, text: String($0.year)) },
                        tickStep: tickStep)
    }
}

/// The Needs Attention card's rows: every possible row, minus whichever are gated off,
/// minus whichever have nothing to show — a row with a count of zero is dead weight in a
/// "needs attention" list by definition, so it is dropped rather than drawn empty. The
/// page's popovers look rows up here by id.
@MainActor
enum DVAttentionRows {
    struct Row: Identifiable {
        let id: String
        let label: String
        let count: Int
        let tint: NSColor
        let items: [DVNamedFilm]
    }

    static let emptyText = "Nothing needs attention at this time."

    static func rows(stats: LibraryStatistics, insights: LibraryInsights, showInfoComplete: Bool) -> [Row] {
        var rows: [Row] = [
            Row(id: "overdue", label: "Overdue for rotation", count: insights.overdue, tint: .systemRed,
                items: insights.overdueItems),
            Row(id: "missingExternalIDs", label: "Missing External Identifiers", count: insights.missingExternalIdentifiers, tint: .systemOrange,
                items: insights.missingExternalIdentifiersItems),
            Row(id: "outOfPrint", label: "Unpurchased and out-of-print", count: insights.unpurchasedOutOfPrint, tint: .systemOrange,
                items: insights.unpurchasedOutOfPrintItems),
            Row(id: "neverWatchedSince", label: "Never watched since buying", count: insights.purchasedNeverWatchedSince, tint: .systemOrange,
                items: insights.purchasedNeverWatchedSinceItems),
            Row(id: "interlaced", label: "Releases with interlaced transfers", count: insights.interlacedAll, tint: .systemYellow,
                items: insights.interlacedAllItems),
            Row(id: "digitalBelowBest", label: "Digital rip backlog", count: insights.digitalBelowBestDisc, tint: .systemYellow,
                items: insights.digitalBelowBestDiscItems),
            Row(id: "lossyBD", label: "Lossy Blu-ray audio", count: stats.lossyBDAudio, tint: .systemYellow,
                items: stats.lossyBDAudioItems),
            Row(id: "notYetRated", label: "Not yet rated", count: stats.notYetRatedFilms, tint: .systemGray,
                items: stats.notYetRatedFilmsItems),
            Row(id: "missingPoster", label: "Missing poster", count: stats.missingArtwork, tint: .systemGray,
                items: stats.missingArtworkItems),
            Row(id: "missingReleaseArtwork", label: "Missing release artwork", count: stats.missingReleaseArtwork, tint: .systemGray,
                items: stats.missingReleaseArtworkItems),
            Row(id: "waitingForEdit", label: "Waiting for edit", count: insights.waitingForEdit, tint: .systemGray,
                items: insights.waitingForEditItems),
        ]
        if showInfoComplete {
            rows.append(Row(id: "dataIncomplete", label: "Data incomplete", count: stats.infoCompleteItems.count, tint: .systemGray,
                            items: stats.infoCompleteItems))
        }
        return rows.filter { $0.count > 0 }
    }
}


// MARK: - Sections

/// What a page is being built for. On screen, each card's scope switch, the year stepper and
/// the role pop-up are live AppKit controls the page view owns. In print (the library PDF) a
/// control cannot be drawn, so each is replaced by the caption of its choice, and a card with
/// a scope switch prints once per choice.
@MainActor
enum DVBuild {
    case screen(DVCanvasPageView)
    case print

    var isPrint: Bool {
        if case .print = self { return true }
        return false
    }
}

/// The page's eight sections — every card, figure and string on the tab and in the PDF's
/// Visualizations and Insights sheet, which draw from these same builders.
@MainActor
enum DVCanvasSections {
    /// A section's band and its rows. On screen the rows stack under the band; in print each
    /// row is one block of the PDF (the first beneath the band), so a page breaks between
    /// rows, never through a card.
    struct Section {
        let title: String
        var detail: String? = nil
        let rows: [any DVNode]
    }

    private static func films(_ n: Int) -> String { "\(DVFormat.count(n)) film\(n == 1 ? "" : "s")" }
    private static func pct(_ n: Int) -> String { "\(n)%" }

    static func sections(_ m: DVCanvasModel, _ b: DVBuild) -> [Section] {
        [overview(m, b), viewing(m, b), rotation(m, b), purchases(m, b), collection(m, b), decades(m), people(m, b), technical(m, b)]
    }

    static func page(_ m: DVCanvasModel, view: DVCanvasPageView) -> any DVNode {
        DVVStack(spacing: 0, sections(m, .screen(view)).enumerated().map { i, section in
            DVK.section(section.title, detail: section.detail, first: i == 0, section.rows)
        })
    }

    /// The PDF's blocks: every section's rows in print form, the band above each first row.
    static func printBlocks(_ m: DVCanvasModel) -> [any DVNode] {
        sections(m, .print).flatMap { section in
            section.rows.enumerated().map { i, row in
                i == 0 ? DVK.section(section.title, detail: section.detail, first: true, [row]) : row
            }
        }
    }

    /// A card with a control on its title plane: on screen one card, carrying the live
    /// control (a scope switch, or with `popUpWidth` a pop-up) and showing its choice; in
    /// print one card per choice, the choice's caption in the control's place.
    private static func switchable(_ b: DVBuild, key: String, default value: Int = 0, titles: [String] = allOrPurchased,
                                   popUpWidth: CGFloat? = nil, caption: @MainActor (String) -> any DVNode = scopeCaption,
                                   _ card: (Int, any DVNode) -> any DVNode) -> [any DVNode] {
        switch b {
        case .screen(let view):
            let (selected, control) = view.scope(key, default: value, titles: titles, popUpWidth: popUpWidth)
            return [card(selected, DVControlNode(control: control))]
        case .print:
            return titles.indices.map { card($0, caption(titles[$0])) }
        }
    }

    private static let allOrPurchased = ["All", "Purchased Only"]
    private static func scopeCaption(_ title: String) -> any DVNode { DVText(title, .system(11, .medium), .secondary) }
    /// Stands in, in print, for the card a scope pair's row has one fewer of.
    private static let emptyCell: any DVNode = DVBox(height: 0) { _, _ in }

    // MARK: 1. Library Overview

    static func overview(_ m: DVCanvasModel, _ b: DVBuild) -> Section {
        let stats = m.stats, insights = m.insights
        var viewingsFootnote = "\(DVFormat.count(insights.totalViewings)) viewings recorded"
        if let year = insights.firstViewingYear { viewingsFootnote += " since \(year)" }
        let backlogFootnote: String = {
            if let date = insights.backlogClearDate { return "Cleared by \(DVFormat.monthYear.string(from: date)) at the current pace" }
            return insights.unwatchedFilms == 0 ? "Nothing left unwatched" : "No first-time viewings in the last year from which to project"
        }()
        let tiles = DVFlow(minColumnWidth: DVStyle.minWideTileWidth, spacing: DVStyle.tileGap, maxColumns: 5, [
            DVK.statTile(title: "Total Films", value: DVFormat.count(stats.totalFilms), color: .systemBlue,
                         footnote: "\(DVFormat.hours(insights.totalRuntimeMinutes)) total runtime"),
            DVK.statTile(title: "Average Rating", value: stats.averageRating, color: .systemPurple,
                         footnote: "\(DVFormat.count(stats.totalFilms - stats.notYetRatedFilms)) rated\n\(stats.notYetRatedFilms) not yet rated"),
            DVK.statTile(title: "Watched", value: DVFormat.count(insights.watchedFilms), color: .systemPurple,
                         trailing: pct(DVFormat.percent(insights.watchedFilms, of: stats.totalFilms)), footnote: viewingsFootnote),
            DVK.statTile(title: "Unwatched Backlog", value: DVFormat.count(insights.unwatchedFilms), color: .systemRed,
                         trailing: "\(pct(DVFormat.percent(insights.unwatchedFilms, of: stats.totalFilms))) (\(DVFormat.hours(insights.unwatchedRuntimeMinutes)))",
                         footnote: backlogFootnote, action: m.navigation.unwatched(.unwatched)),
            DVK.statTile(title: "Hall of Fame", value: DVFormat.count(insights.hallOfFameFilms), color: .systemYellow,
                         trailing: insights.hallOfFameFilms > 0 ? "avg. rating: \(insights.hallOfFameAverageRating)" : nil,
                         footnote: insights.hallOfFameFilms > 0
                             ? "\(insights.hallOfFameNotOnDisc) unpurchased\n\(insights.hallOfFameUnwatchedOverYear) unwatched in over a year"
                             : "No positions set",
                         action: m.navigation.hallOfFame),
        ])

        // Ownership
        let rows = stats.formatBreakdown
        let segments = [
            DVKSegment(label: "Purchased on 4K UHD", count: rows.first?.count ?? 0, color: .systemIndigo),
            DVKSegment(label: "Purchased on Blu-ray only", count: rows.count > 1 ? rows[1].count : 0, color: .systemCyan),
            DVKSegment(label: "Purchased on DVD only", count: rows.count > 2 ? rows[2].count : 0, color: .systemGreen),
            DVKSegment(label: "Unpurchased, available on disc", count: stats.unpurchasedOnDisc, color: .systemYellow),
            DVKSegment(label: "Digital only", count: stats.digitalOnlyFilms, color: .systemOrange),
        ]
        let notes = ["(Combo-packs included)", "", "", "", ""]
        let ownershipRows = DVVStack(spacing: 2, segments.enumerated().map { i, s in
            DVDecorated(child: DVHStack(spacing: 8, [
                DVBox(width: 10, height: 10) { g, r in g.fill(r, DVPaint(color: s.color, opacity: DVStyle.fillOpacity), radius: 2) },
                DVText(s.label, .system(12), .primary),
                notes[i].isEmpty ? nil : DVText(notes[i], .system(10), .secondary),
                DVSpacer(minLength: 8),
                DVFrame(child: DVText(DVFormat.count(s.count), .mono(11, .semibold), .primary), width: 44, hAlign: .trailing),
                DVFrame(child: DVText(pct(DVFormat.percent(s.count, of: stats.totalFilms)), .system(10), .secondary), width: 34, hAlign: .trailing),
            ], priorities: [0, 1, -1, 0, 0, 0]),
                        insets: NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8), background: DVK.rowPaint, radius: 4)
        })
        let ownership = DVK.card(title: "Ownership",
                                 trailing: "\(films(stats.filmsOnDisc)) purchased (\(pct(stats.filmsOnDiscPercent)) ownership)",
                                 subtitle: "Rows are mutually exclusive and sum to \(films(stats.totalFilms)).",
                                 [DVK.stackedBar(segments, height: 24), ownershipRows])

        // Catalog Health
        let healthSubtitle = insights.emptiestField.map { e -> String in
            e.blank > 0 ? "Emptiest metadata field: \(e.name) (\(DVFormat.count(e.blank)) blank)" : "Every metadata field is filled on every film"
        } ?? "Every metadata field is filled on every film"
        func health(_ label: String, _ percent: Int, _ color: NSColor, _ count: Int) -> any DVNode {
            DVK.barRow(label: label, fraction: Double(percent) / 100, color: color, count: DVFormat.count(count),
                       percent: pct(percent), labelWidth: 150, barHeight: 12)
        }
        var healthRows: [any DVNode] = []
        if m.showInfoComplete { healthRows.append(health("Info complete", stats.infoCompletePercent, .systemGreen, stats.infoComplete)) }
        healthRows += [
            health("Edited films", stats.editedPercent, .systemBlue, stats.editedFilms),
            health("Alternate versions owned", DVFormat.percent(insights.alternateVersionFilms, of: stats.totalFilms), .systemBlue, insights.alternateVersionFilms),
            health("Not yet rated", stats.notYetRatedPercent, .systemRed, stats.notYetRatedFilms),
            health("Missing poster", stats.missingArtworkPercent, .systemRed, stats.missingArtwork),
            health("Waiting for edit", DVFormat.percent(insights.waitingForEdit, of: stats.totalFilms), .systemOrange, insights.waitingForEdit),
        ]
        let catalog = DVK.card(title: "Catalog Health", subtitle: healthSubtitle, [DVVStack(spacing: 6, healthRows)])

        // Ratings
        let rated = stats.totalFilms - stats.notYetRatedFilms
        let bars = stats.ratingsBreakdown.map { item in
            DVKBar(label: "\(item.rating)", value: Double(item.count),
                   color: NSColor.systemBlue.withAlphaComponent(0.3 + CGFloat(item.rating) / 10.0 * 0.7),
                   valueLabel: DVFormat.count(item.count))
        }
        let eightPlus = stats.ratingsBreakdown.filter { $0.rating >= 8 }.reduce(0) { $0 + $1.count }
        let ratings = DVK.card(title: "Ratings Breakdown", trailing: "\(films(rated)) rated",
                               subtitle: rated > 0 ? "\(pct(DVFormat.percent(eightPlus, of: rated))) of rated films have been given an 8 or higher" : "No ratings yet",
                               bottomAligned: true, [DVK.verticalBars(bars, height: 300, spacing: 6)])

        let cards = DVFlow(minColumnWidth: DVStyle.minWideCardWidth, weights: [2, 1], [
            DVVStack(spacing: DVStyle.gap, [ownership, catalog]),
            ratings,
        ])

        // Collection Growth
        let legend = DVK.legend(DVGrowthCard.legend.map { DVKSegment(label: $0.label, count: 0, color: $0.color) }, showCounts: false)
        let growthCards = switchable(b, key: "growth", default: DVGrowthCard.defaultScope, titles: DVGrowthCard.scopes) { scope, control in
            let growth = DVGrowthCard.growth(insights.growth, scope: scope)
            return DVK.card(title: "Collection Growth", trailingNode: DVHStack(spacing: 12, [control, legend]),
                            subtitle: DVGrowthCard.subtitle(growth), bottomAligned: true,
                            [growth.isEmpty ? DVK.footnote(DVGrowthCard.emptyText)
                                            : DVK.lineChart(DVGrowthCard.spec(growth), height: DVGrowthCard.chartHeight)])
        }

        // Needs Attention
        let attention = attentionRows(m)
        let attentionCard = DVK.card(title: "Needs Attention", [
            attention.isEmpty
                ? DVK.footnote(DVAttentionRows.emptyText)
                : DVVStack(spacing: 4, attention.map { DVK.attentionListRow(label: $0.label, count: $0.count, tint: $0.tint, popoverID: $0.id) }),
        ])
        // In print All Time spans the page on its own row and Past 5 Years sits beside
        // Needs Attention.
        let growthRows: [any DVNode] = b.isPrint
            ? [growthCards[0], DVFlow(minColumnWidth: DVStyle.minWideCardWidth, weights: [2, 1], [growthCards[1], attentionCard])]
            : [DVFlow(minColumnWidth: DVStyle.minWideCardWidth, weights: [2, 1], [growthCards[0], attentionCard])]
        return Section(title: "Library Overview", rows: [tiles, cards] + growthRows)
    }

    /// The Needs Attention card's rows (DVAttentionRows); popovers look them up by id.
    static func attentionRows(_ m: DVCanvasModel) -> [DVAttentionRows.Row] {
        DVAttentionRows.rows(stats: m.stats, insights: m.insights, showInfoComplete: m.showInfoComplete)
    }

    static let recordablePopoverID = "recordable"
    static let comingUpPopoverID = "comingUp"
    static let fourKUpgradesPopoverID = "fourKUpgrades"
    static let overridesPopoverID = "honesty.overrides"
    static let autoAddPopoverID = "honesty.autoAdd"
    static let staleYearPopoverID = "honesty.staleYear"
    static let neverViewedPopoverID = "honesty.neverViewed"

    /// The films a popover lists, and the name a list made from them is offered.
    static func popoverList(_ m: DVCanvasModel, id: String) -> (label: String, items: [DVNamedFilm])? {
        switch id {
        case recordablePopoverID: return ("Recordable Discs", m.insights.recordableAllItems)
        case comingUpPopoverID: return ("Coming Up Next Month", m.insights.comingUpNextMonthItems)
        case fourKUpgradesPopoverID: return ("4K Upgrades", m.insights.habits.fourKUpgrades.map(\.film))
        case overridesPopoverID: return ("Threshold Overrides", m.insights.thresholdOverrideItems)
        case autoAddPopoverID: return ("Auto-add to Queue Enabled", m.insights.autoAddToQueueItems)
        case staleYearPopoverID: return ("Last Viewed Over One Year Ago", m.insights.viewedOverOneYearAgoItems)
        case neverViewedPopoverID: return ("Unwatched", m.insights.neverViewedItems)
        default: return attentionRows(m).first(where: { $0.id == id }).map { ($0.label, $0.items) }
        }
    }

    // MARK: 2. Viewing History

    static func viewing(_ m: DVCanvasModel, _ b: DVBuild) -> Section {
        let insights = m.insights
        let title = "Viewing History"
        // In print the span is stated in words where the Stepper and its pop-ups sit.
        let detail = b.isPrint ? "Viewing figures are for the span named below; the rest of the report is not scoped."
                               : "The Stepper scopes select data in this section only."
        guard let p = m.period, insights.totalViewings > 0 else {
            return Section(title: title, detail: detail,
                           rows: [DVK.card([DVK.footnote("No viewings recorded yet. Dates added to a film's Viewing History appear here by year.")])])
        }
        let compare = m.compare.wrappedValue
        let span = compare ? "\(p.spanLabel) vs. \(p.comparisonLabel)." : "\(p.spanLabel)."

        // Tiles.
        let tiles = DVFlow(minColumnWidth: DVStyle.minTileWidth, spacing: DVStyle.tileGap, maxColumns: 6, [
            DVK.statTile(title: "Viewings", value: DVFormat.count(p.viewings), color: .systemPurple,
                         delta: compare ? DVDelta(current: p.viewings, prior: p.priorViewings) : nil,
                         footnote: p.projectedYearEnd.map { "On pace for \($0) by year end" }),
            DVK.statTile(title: "Distinct Films", value: DVFormat.count(p.distinctFilms), color: .systemPurple,
                         delta: compare ? DVDelta(current: p.distinctFilms, prior: p.priorDistinctFilms) : nil),
            DVK.statTile(title: "First-time Viewings", value: DVFormat.count(p.firstTimeWatches), color: .systemBlue,
                         delta: compare ? DVDelta(current: p.firstTimeWatches, prior: p.priorFirstTimeWatches) : nil,
                         footnote: p.viewings > 0 ? "\(pct(DVFormat.percent(p.firstTimeWatches, of: p.viewings))) of viewings" : nil),
            DVK.statTile(title: "Rewatches", value: DVFormat.count(p.rewatches), color: .systemBlue,
                         delta: compare ? DVDelta(current: p.rewatches, prior: p.priorRewatches) : nil),
            DVK.statTile(title: "Hours Watched", value: DVFormat.count(p.hoursWatchedMinutes / 60), color: .systemOrange,
                         delta: compare ? DVDelta(current: p.hoursWatchedMinutes / 60, prior: p.priorHoursWatchedMinutes / 60, suffix: " h") : nil,
                         footnote: p.timedViewings > 0 ? "\(DVFormat.hoursMinutes(p.hoursWatchedMinutes / p.timedViewings)) average runtime" : nil),
            DVK.statTile(title: "Average Rating", value: p.averageRating.map { Fmt.fixed($0, 1) } ?? "—", color: .systemPurple,
                         delta: compare ? DVDelta.decimal(current: p.averageRating, prior: p.priorAverageRating) : nil),
        ])

        // Month chart: each bar banded by chroma, release decade or genre (the menu; print
        // shows all three, each captioned), the band legend where a subtitle would be.
        let months = AppCalendar.current.shortMonthSymbols
        let monthCards = switchable(b, key: "monthBands", default: 0, titles: ["Chroma", "Release Decade", "Genre"],
                                    popUpWidth: 120) { mode, control in
            let band = monthBands(p, mode: mode, compare: compare)
            let monthBars = (0..<12).map { i in
                DVKMonthBar(label: months[i], value: p.byMonth[i], bands: band.current[i],
                            ghost: compare ? p.priorByMonth[i] : nil, ghostBands: band.prior[i],
                            dimmed: p.currentMonthIndex == i, valueLabel: p.byMonth[i] > 0 ? "\(p.byMonth[i])" : nil)
            }
            let legend = DVHStack(spacing: 10, [
                DVHStack(spacing: 5, [yearSwatch(prior: false, mode: mode), DVText(String(p.year), .system(11), .primary)]),
                compare ? DVHStack(spacing: 5, [yearSwatch(prior: true, mode: mode), DVText(String(p.compareYear), .system(11), .primary)]) : nil,
                control,
            ])
            let bandLegend = DVK.legend(band.keys.indices.map { i in
                DVKSegment(label: band.keys[i].label, count: 0, color: band.paints[i].color, fillOpacity: band.paints[i].opacity)
            }, showCounts: false)
            // Bottom-aligned: the row is as tall as Most Rewatched, and the chart's month labels
            // sit on the card's bottom padding rather than the extra height sitting under them.
            return DVK.card(title: "Viewings by Month", trailingNode: legend, subtitleNode: bandLegend, bottomAligned: true,
                            [DVK.monthColorBars(monthBars, paints: band.paints, priorPaints: band.priorPaints, height: 180, spacing: 10)])
        }

        // Most Rewatched. On screen all-time by default: the current span is unlikely to
        // hold a second viewing of anything, while all-time reliably has content. The list's
        // height is fixed (ten rows' worth) so switching scope never resizes the row.
        let rewatched = switchable(b, key: "rewatched", default: 1, titles: ["This Year", "All Time"]) { scope, trailing in
            let rows = scope == 0 ? p.mostRewatched : insights.mostRewatchedAllTime
            let list: any DVNode = rows.isEmpty
                ? DVK.footnote(scope == 0 ? "No film watched twice in this span" : "No film watched twice yet")
                : DVVStack(spacing: 6, rows.enumerated().map { i, row in
                    DVK.rankRow(rank: i + 1, name: row.name, value: row.value, compact: true, year: row.year)
                })
            return DVK.card(title: "Most Rewatched", trailingNode: trailing,
                            [DVFrame(child: list, height: DVStyle.mostRewatchedListHeight, vAlign: .top)])
        }

        // Detail cards.
        let bands = insights.rewatchesByRatingBand
        var rewatchesFootnote = "Average viewings per film by your rating."
        if bands.count == 5 {
            let high = Double(bands[3].count + bands[4].count) / 2 / 100, mid = Double(bands[1].count) / 100
            if mid > 0, high > 0 {
                rewatchesFootnote = "Average viewings per film by your rating. Films rated 9–10 are rewatched \(Fmt.fixed(high / mid, 1))× as often as 6–7."
            }
        }
        let veryShort = AppCalendar.current.veryShortMonthSymbols
        let peak = insights.seasonality.max() ?? 0
        let seasonBars = (0..<12).map { i in
            DVKBar(label: veryShort[i], value: insights.seasonality[i], color: .systemOrange, dimmed: peak > 0 && insights.seasonality[i] < peak)
        }
        let yearsCount = insights.viewingYears.count
        var seasonalityFootnote = "Average viewings per calendar month across \(yearsCount) recorded year\(yearsCount == 1 ? "" : "s")."
        if let leader = insights.seasonalityLeader { seasonalityFootnote += " \(leader) leads." }
        let details = DVFlow(minColumnWidth: DVStyle.minCardWidth, maxColumns: 4, [
            DVK.card(title: "Versions Watched", subtitle: "Untagged entries are assumed to be Theatrical versions and counted as such.",
                     bottomAligned: true,
                     [p.versionsWatched.isEmpty ? DVK.footnote("No viewings in this span") : DVK.tallyRows(p.versionsWatched, color: .systemBlue, labelWidth: 96)]),
            DVK.card(title: "Where the Year Went", subtitle: "Share of the span's viewings by the film's release decade.", bottomAligned: true,
                     [p.decadeShare.isEmpty ? DVK.footnote("No viewings in this span") : DVK.tallyRows(p.decadeShare, color: .systemPurple, labelWidth: 60)]),
            DVK.card(title: "Rewatches by Rating", trailing: "All time", subtitle: rewatchesFootnote, bottomAligned: true,
                     [DVK.verticalBars(bands.map { DVKBar(label: $0.label, value: Double($0.count) / 100, color: .systemPurple,
                                                          valueLabel: Fmt.fixed(Double($0.count) / 100, 1)) }, height: 96)]),
            DVK.card(title: "Seasonality", trailing: "All time", subtitle: seasonalityFootnote, bottomAligned: true,
                     [DVK.verticalBars(seasonBars, height: 96, spacing: 4)]),
        ])
        let habitsRow = DVFlow(minColumnWidth: DVStyle.minTextCardWidth, maxColumns: 2, [discoveryCard(insights.habits), viewingAgeCard(insights.habits)])

        switch b {
        case .screen(let view):
            // Wider than the standard wide-card minimum: the Most Rewatched card's scope
            // switch needs more than a third of 360 pt beside its title.
            return Section(title: title, detail: detail, rows: [
                viewingControls(m, view: view, span: span), tiles,
                DVFlow(minColumnWidth: 420, weights: [2, 1], [monthCards[0]] + rewatched),
                details,
                habitsRow,
            ])
        case .print:
            // Both Most Rewatched scopes print beside the Chroma month chart; the Release
            // Decade and Genre charts share the row below.
            return Section(title: title, detail: detail, rows: [
                DVVStack(spacing: DVStyle.gap, [DVText(span, .system(12, .medium), .secondary, lineLimit: nil), tiles]),
                DVFlow(minColumnWidth: 280, weights: [2, 1, 1], [monthCards[0]] + rewatched),
                DVFlow(minColumnWidth: 280, Array(monthCards.dropFirst())),
                details,
                habitsRow,
            ])
        }
    }

    /// The year stepper, the span pop-up, the Compare checkbox and year, and the span in
    /// words: the row of controls that scopes the Viewing History section on screen.
    private static func viewingControls(_ m: DVCanvasModel, view: DVCanvasPageView, span: String) -> any DVNode {
        let compare = m.compare.wrappedValue
        let currentYear = AppCalendar.current.component(.year, from: Date())
        let years = m.insights.viewingYears.isEmpty ? [currentYear] : m.insights.viewingYears
        let selectedYear = m.selectedYear.wrappedValue
        let back = view.control("year-back") { .stepButton("chevron.left") }
        let forward = view.control("year-forward") { .stepButton("chevron.right") }
        back.control.isEnabled = !(years.first.map { selectedYear <= $0 } ?? true)
        forward.control.isEnabled = !(years.last.map { selectedYear >= $0 } ?? true)
        func step(_ d: Int) {
            guard let index = years.firstIndex(of: m.selectedYear.wrappedValue) ?? years.firstIndex(where: { $0 > m.selectedYear.wrappedValue }) else { return }
            let next = index + d
            if years.indices.contains(next) { m.selectedYear.wrappedValue = years[next] }
        }
        back.onAction = { _ in step(-1) }
        forward.onAction = { _ in step(1) }
        let spanPopUp = view.control("span") { .popUp(["Year to date", "Full year"], width: 120) }
        (spanPopUp.control as? NSPopUpButton)?.selectItem(at: (selectedYear == currentYear ? m.yearToDate.wrappedValue : false) ? 0 : 1)
        spanPopUp.control.isEnabled = selectedYear == currentYear
        spanPopUp.onAction = { c in m.yearToDate.wrappedValue = (c as? NSPopUpButton)?.indexOfSelectedItem == 0 }
        let check = view.control("compare") { .checkbox("Compare with") }
        (check.control as? NSButton)?.state = compare ? .on : .off
        check.onAction = { c in m.compare.wrappedValue = (c as? NSButton)?.state == .on }
        let yearPop = view.control("compare-year-\(years.map(String.init).joined(separator: ","))") {
            .popUp(years.map(String.init), width: 76)
        }
        if let pop = yearPop.control as? NSPopUpButton {
            for (i, y) in years.enumerated() { pop.item(at: i)?.isEnabled = y != selectedYear }
            if let i = years.firstIndex(of: m.compareYear.wrappedValue) { pop.selectItem(at: i) }
        }
        yearPop.control.isEnabled = compare && years.contains { $0 != selectedYear }
        yearPop.onAction = { c in
            if let i = (c as? NSPopUpButton)?.indexOfSelectedItem, years.indices.contains(i) { m.compareYear.wrappedValue = years[i] }
        }
        return DVHStack(spacing: 12, [
            DVHStack(spacing: 0, [
                DVControlNode(control: back),
                DVFrame(child: DVText(String(selectedYear), .system(13, .semibold), .primary), width: 48),
                DVControlNode(control: forward),
            ]),
            DVControlNode(control: spanPopUp, width: 120, layoutHeight: 16),
            DVHStack(spacing: 0, [DVControlNode(control: check), DVControlNode(control: yearPop, width: 76, layoutHeight: 16)]),
            DVText(span, .system(10), .secondary),
            DVSpacer(minLength: 0),
        ])
    }

    /// The month chart's legend swatch: the bar's color share over its gray share, split on
    /// the diagonal, in the year shown's colors or (`prior`) the comparison year's.
    /// The month chart's bands for one mode (0 chroma, 1 release decade, 2 genre): the
    /// categories top first, their paints for the year and the comparison year, and each
    /// month's counts in that order (summing to the month's viewings).
    static func monthBands(_ p: ViewingPeriodStatistics, mode: Int, compare: Bool)
        -> (keys: [(key: String, label: String)], paints: [DVPaint], priorPaints: [DVPaint], current: [[Int]], prior: [[Int]]) {
        if mode == 0 {
            return ([("color", "Color films"), ("bw", "Black-and-white films")],
                    [DVK.monthBlue, DVK.monthGray], [DVK.monthPriorBlue, DVK.monthPriorGray],
                    (0..<12).map { [p.byMonthColor[$0], p.byMonth[$0] - p.byMonthColor[$0]] },
                    (0..<12).map { [p.priorByMonthColor[$0], p.priorByMonth[$0] - p.priorByMonthColor[$0]] })
        }
        let current = mode == 1 ? p.byMonthDecade : p.byMonthGenre
        let prior = mode == 1 ? p.priorByMonthDecade : p.priorByMonthGenre
        // Only categories with a viewing in a year on the chart; the comparison year's
        // only when it is shown.
        var present = Set(current.flatMap { $0.filter { $0.value > 0 }.keys })
        if compare { present.formUnion(prior.flatMap { $0.filter { $0.value > 0 }.keys }) }
        let keys: [(key: String, label: String)]
        let colors: [NSColor]
        if mode == 1 {
            // Newest decade on top; one ramp from violet (oldest) to orange (newest).
            let decades = present.filter { $0 != "Unknown" }.sorted(by: >)
            keys = decades.map { ($0, $0) } + (present.contains("Unknown") ? [("Unknown", "Unknown")] : [])
            let ramp: [NSColor] = [.systemPurple, .systemIndigo, .systemBlue, .systemTeal, .systemGreen, .systemYellow, .systemOrange]
            colors = decades.indices.map { i in
                let t = decades.count > 1 ? CGFloat(decades.count - 1 - i) / CGFloat(decades.count - 1) * CGFloat(ramp.count - 1) : CGFloat(ramp.count - 1)
                let lo = Int(t.rounded(.down)), hi = min(ramp.count - 1, lo + 1)
                return DVK.blend(ramp[lo], t - CGFloat(lo), ramp[hi])
            } + (present.contains("Unknown") ? [.systemGray] : [])
        } else {
            let genres: [(String, String, NSColor)] = [
                ("Action and Adventure", "Action and Adventure", .systemOrange), ("Comedy", "Comedy", .systemYellow),
                ("Drama", "Drama", .systemBlue), ("Horror", "Horror", .systemRed),
                ("Kids and Family", "Kids and Family", .systemGreen), ("Sci-Fi and Fantasy", "Sci-Fi and Fantasy", .systemPurple),
                ("Thriller", "Thriller", .systemTeal),
            ]
            let known = Set(genres.map(\.0))
            let shown = genres.filter { present.contains($0.0) }
            // Any other stored value (and a blank genre) is banded together as "No genre".
            let other = present.contains { !known.contains($0) }
            keys = shown.map { ($0.0, $0.1) } + (other ? [("", "No genre")] : [])
            colors = shown.map(\.2) + (other ? [.systemGray] : [])
            func fold(_ months: [[String: Int]]) -> [[Int]] {
                months.map { m in
                    shown.map { m[$0.0] ?? 0 } + (other ? [m.filter { !known.contains($0.key) }.values.reduce(0, +)] : [])
                }
            }
            return (keys, colors.map { DVPaint(color: $0, opacity: DVStyle.fillOpacity) },
                    colors.map { DVPaint(color: $0, opacity: DVStyle.fillOpacity * 0.5) }, fold(current), fold(prior))
        }
        return (keys, colors.map { DVPaint(color: $0, opacity: DVStyle.fillOpacity) },
                colors.map { DVPaint(color: $0, opacity: DVStyle.fillOpacity * 0.5) },
                current.map { m in keys.map { m[$0.key] ?? 0 } }, prior.map { m in keys.map { m[$0.key] ?? 0 } })
    }

    /// A year's legend swatch: chroma's color-over-gray split, or for the other modes a
    /// neutral swatch at the year's opacity (the bands' colors are in the band legend).
    static func yearSwatch(prior: Bool, mode: Int) -> any DVNode {
        if mode == 0 { return diagonalSwatch(prior: prior) }
        return DVBox(width: 10, height: 10) { g, r in
            g.fill(r, DVPaint(color: .systemGray, opacity: prior ? DVStyle.fillOpacity * 0.5 : DVStyle.fillOpacity), radius: 2)
        }
    }

    static func diagonalSwatch(prior: Bool) -> any DVNode {
        DVBox(width: 10, height: 10) { g, r in
            g.withState {
                g.clip(r, radius: 2)
                let tl = CGMutablePath()
                tl.move(to: CGPoint(x: r.minX, y: r.minY)); tl.addLine(to: CGPoint(x: r.maxX, y: r.minY)); tl.addLine(to: CGPoint(x: r.minX, y: r.maxY)); tl.closeSubpath()
                g.fillPath(tl, prior ? DVK.monthPriorBlue : DVK.monthBlue)
                let br = CGMutablePath()
                br.move(to: CGPoint(x: r.maxX, y: r.minY)); br.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); br.addLine(to: CGPoint(x: r.minX, y: r.maxY)); br.closeSubpath()
                g.fillPath(br, prior ? DVK.monthPriorGray : DVK.monthGray)
            }
        }
    }

    // MARK: 3. Rotation

    static func rotation(_ m: DVCanvasModel, _ b: DVBuild) -> Section {
        let insights = m.insights
        let segments = [
            DVKSegment(label: "Overdue", count: insights.overdue, color: .systemRed),
            DVKSegment(label: "Due within 30 days", count: insights.dueWithin30Days, color: .systemOrange),
            DVKSegment(label: "Due within 90 days", count: insights.dueWithin90Days, color: .systemYellow),
            DVKSegment(label: "On schedule", count: insights.onSchedule, color: .systemGreen, fillOpacity: 0.35),
        ]
        let status = DVK.card(title: "Status",
                              subtitle: "Films with a special-sorting parameter are excluded and unwatched films are not eligible for rotation scheduling.", [
            DVK.stackedBar(segments),
            DVVStack(spacing: 4, [
                DVK.attentionRowCompact(label: "Overdue", count: insights.overdue, tint: .systemRed, action: m.navigation.upForRotation),
                DVK.factRow(label: "More than 6 months overdue", value: DVFormat.count(insights.overdueOverSixMonths), valueColor: .secondaryLabelColor,
                            indented: true, indentWidth: 24, reserveChevronSpace: true, compactLabel: "More than 6 mo overdue"),
                DVK.attentionRowCompact(label: "Due within 30 days", count: insights.dueWithin30Days, tint: .systemOrange),
                DVK.attentionRowCompact(label: "Due within 90 days", count: insights.dueWithin90Days, tint: .systemYellow),
                DVK.attentionRowCompact(label: "On schedule", count: insights.onSchedule, tint: .systemGreen),
            ]),
        ])
        // Six films (best rated, then most viewed, then most purchased releases), and in a
        // seventh row a View All button opening the whole list when there are more. The
        // rows open up to fill the card's height (DVSpread) but never set it: seven compact
        // rows at their tightest are no taller than the six standard rows they replaced.
        let pool = insights.comingUpNextMonthItems.count
        // Every film due, best ranked first; DVFitRows shows as many as the card's height
        // holds, the View All button after them when some are left out.
        let upcomingRows: [any DVNode] = insights.comingUp.map { DVK.rankRow(name: $0.name, value: "", compact: true, year: $0.year) }
        var viewAll: (any DVNode)?
        if case .screen(let view) = b {
            let button = view.control("comingUpViewAll") {
                let c = DVKControl(NSButton(title: "View All", target: nil, action: nil))
                (c.control as? NSButton)?.bezelStyle = .push
                return c
            }
            // The bezel, not the frame: a push button's frame reaches past its visible edge.
            button.onAction = { [weak view] sender in view?.showAttentionPopover(comingUpPopoverID, from: sender.alignmentRect(forFrame: sender.frame)) }
            viewAll = DVFrame(child: DVControlNode(control: button), maxInfinity: true, hAlign: .center)
        }
        let monthStart = AppCalendar.current.dateInterval(of: .month, for: insights.spendingAsOf)?.start ?? insights.spendingAsOf
        let nextMonth = AppCalendar.current.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        let comingUp = DVK.card(title: "Coming Up Next Month", trailing: "\(films(pool)) (\(DVFormat.shortMonthDay.string(from: nextMonth)))",
                                subtitle: "Rotation threshold due dates roll to the 1st of the following month.", [
            insights.comingUp.isEmpty
                ? DVK.footnote("Nothing comes up for rotation next month")
                : DVFitRows(rows: upcomingRows, more: viewAll),
        ])
        let honesty = DVK.card(title: "Threshold Honesty",
                               subtitle: "If the median gap regularly exceeds the median threshold, the default threshold is merely aspirational.", [
            DVVStack(spacing: 4, [
                DVK.factRow(label: "Median viewing gap", value: insights.medianGapMonths.map { "\(Fmt.fixed($0, 1)) months" } ?? "—",
                            reserveInfoSpace: true),
                DVK.factRow(label: "Median threshold", value: insights.medianThreshold.map { "\($0) months" } ?? "—", reserveInfoSpace: true),
                DVK.factRow(label: "Last gap within threshold", value: insights.lastGapWithinThresholdPercent.map { pct($0) } ?? "—",
                            reserveInfoSpace: true),
                DVK.factRow(label: "Overrides", value: DVFormat.count(insights.thresholdOverrides), popoverID: overridesPopoverID),
                DVK.factRow(label: "\"Auto-add to Queue\" enabled", value: DVFormat.count(insights.autoAddToQueueEnabled), popoverID: autoAddPopoverID),
                DVK.factRow(label: "Last viewed over one year ago", value: DVFormat.count(insights.viewedOverOneYearAgo), popoverID: staleYearPopoverID),
                DVK.factRow(label: "Unwatched", value: DVFormat.count(insights.neverViewed), popoverID: neverViewedPopoverID),
            ]),
        ])
        // "24 months" reads "2 years", as the threshold does everywhere else it is shown.
        let years = Double(Preferences.defaultRotationThreshold) / 12
        let threshold = years == 1 ? "1 year" : (years.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(years)) years" : "\(years) years")
        return Section(title: "Rotation", detail: "\(films(insights.rotationEligible)) eligible; default threshold: \(threshold).", rows: [
            DVFlow(minColumnWidth: DVStyle.minCardWidth, maxColumns: 3, [status, comingUp, honesty]),
        ])
    }

    /// A swatch-label-count-percent table row (Ownership, Digital Sources).
    private static func swatchRow(_ s: DVKSegment, _ labelFont: DVFont, count: Int, percent: Int, vertical: CGFloat) -> any DVNode {
        DVDecorated(child: DVHStack(spacing: 8, [
            DVBox(width: 10, height: 10) { g, r in g.fill(r, DVPaint(color: s.color, opacity: s.fillOpacity), radius: 2) },
            DVText(s.label, labelFont, .primary),
            DVSpacer(minLength: 8),
            DVFrame(child: DVText(DVFormat.count(count), .mono(11, .semibold), .primary), width: 44, hAlign: .trailing),
            DVFrame(child: DVText(pct(percent), .system(10), .secondary), width: 34, hAlign: .trailing),
        ]), insets: NSEdgeInsets(top: vertical, left: 8, bottom: vertical, right: 8), background: DVK.rowPaint, radius: 4)
    }

    /// A subheading set 4 pt below the group above it.
    private static func subheadingTop(_ text: String) -> any DVNode {
        DVDecorated(child: DVK.subheading(text), insets: NSEdgeInsets(top: 4, left: 0, bottom: 0, right: 0))
    }

    // MARK: 4. Purchases and Spending

    /// Purchase → Next Viewing, by severity: green within a month, through yellow to orange
    /// as the wait grows, and red only for never.
    private static let purchaseToViewingColors: [NSColor] = [
        .systemGreen, DVK.blend(.systemGreen, 0.5, .systemYellow), .systemYellow,
        DVK.blend(.systemYellow, 0.5, .systemOrange), .systemOrange, .systemRed,
    ]

    static func purchases(_ m: DVCanvasModel, _ b: DVBuild) -> Section {
        let stats = m.stats, insights = m.insights
        let title = "Purchases and Spending"
        let detail = "\(DVFormat.count(stats.totalPurchasedReleases)) purchased releases across \(films(stats.filmsOnDisc))"
        guard stats.hasPurchaseData else {
            return Section(title: title, detail: detail,
                           rows: [DVK.card([DVK.footnote("No purchased releases yet. Mark a release as purchased to see spending and format statistics.")])])
        }

        // Tiles.
        let condition = DVDecorated(child: DVVStack(spacing: 5, [
            DVText("Condition", .system(11), .secondary),
            DVK.stackedBar([DVKSegment(label: "New", count: stats.newReleases, color: .systemGreen),
                            DVKSegment(label: "Used", count: stats.usedReleases, color: .systemOrange)], height: 20),
            DVFrame(child: DVText("New \(pct(stats.newReleasesPercent))\nUsed \(pct(stats.usedReleasesPercent))", .system(10), .secondary, lineLimit: 2),
                    maxInfinity: true, hAlign: .leading),
        ]), insets: DVK.cardInsets, background: DVK.cardPaint,
            radius: DVStyle.cardRadius, fillsHeight: true)
        let tiles = DVFlow(minColumnWidth: DVStyle.minWideTileWidth, spacing: DVStyle.tileGap, maxColumns: 6, [
            DVK.statTile(title: "Purchased Releases", value: DVFormat.count(stats.totalPurchasedReleases), color: .systemPurple,
                         footnote: "\(DVFormat.count(insights.physicalDiscs)) physical discs\n\(insights.comboPacks) combo-packs"),
            DVK.statTile(title: "Total Spent", value: DVFormat.wholeMoney(insights.totalSpent), color: .systemBlue,
                         footnote: stats.filmsOnDisc > 0 ? "\(DVFormat.money(insights.totalSpent / Double(stats.filmsOnDisc))) per film on disc" : nil),
            DVK.statTile(title: "Spent This Year", value: DVFormat.wholeMoney(insights.spentThisYear), color: .systemBlue,
                         delta: DVDelta.money(current: insights.spentThisYear, prior: insights.spentPriorYearSameSpan),
                         footnote: "Versus the same span last year"),
            DVK.statTile(title: "Average Cost", value: stats.averageCost, color: .systemBlue,
                         footnote: insights.medianCost.map { "Median \(DVFormat.money($0))" }),
            condition,
            DVK.statTile(title: "Recordable Discs", value: DVFormat.count(insights.recordableAll), color: .systemBlue,
                         footnote: "\(DVFormat.count(insights.recordable)) of these have been purchased.",
                         popoverID: recordablePopoverID),
        ])

        // Formats table.
        // The release cards' format tints (ReleaseCard, RTabReleases): near-black 4K, navy
        // Blu-ray, gray DVD.
        let colors: [NSColor] = [NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1),
                                 NSColor(srgbRed: 0.10, green: 0.22, blue: 0.42, alpha: 1), NSColor(white: 0.30, alpha: 1)]
        let labels = ["4K UHD", "Blu-ray only", "DVD only"]
        let medians = [insights.medianCostByFormat.fourK, insights.medianCostByFormat.bluRay, insights.medianCostByFormat.dvd]
        func header(_ text: String, _ width: CGFloat?) -> any DVNode {
            let t = DVText(text, .system(10), .secondary)
            return width.map { DVFrame(child: t, width: $0, hAlign: .trailing) } ?? DVFrame(child: t, maxInfinity: true, hAlign: .leading)
        }
        let headerRow = DVDecorated(child: DVHStack(spacing: 8, [
            DVBox(width: 10, height: 1) { _, _ in },
            header("Format", nil), header("Films", 44), header("Share", 40), header("Avg. cost", 64),
            header("Median", 64), header("Unpurchased", 76),
        ]), insets: NSEdgeInsets(top: 0, left: 8, bottom: 2, right: 8))
        func formatRow(_ color: NSColor?, _ label: String, _ count: Int, _ percent: Double, _ avg: String, _ median: String,
                       _ unpurchased: Int) -> any DVNode {
            DVDecorated(child: DVHStack(spacing: 8, [
                DVBox(width: 10, height: 10) { g, r in if let color { g.fill(r, DVPaint(color: color), radius: 2) } },
                DVFrame(child: DVText(label, .system(12), color == nil ? .secondary : .primary), maxInfinity: true, hAlign: .leading),
                DVFrame(child: DVText(DVFormat.count(count), .mono(11, .semibold), .primary), width: 44, hAlign: .trailing),
                DVFrame(child: DVText("\(Int(percent.rounded()))%", .system(10), .secondary), width: 40, hAlign: .trailing),
                DVFrame(child: DVText(avg, .mono(11, .semibold), .primary), width: 64, hAlign: .trailing),
                DVFrame(child: DVText(median, .mono(11), .secondary), width: 64, hAlign: .trailing),
                DVFrame(child: DVText(unpurchased > 0 ? DVFormat.count(unpurchased) : "—", .mono(11), .secondary),
                        width: 76, hAlign: .trailing),
            ]), insets: NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8), background: DVK.rowPaint, radius: 4)
        }
        var formatRows: [any DVNode] = [headerRow]
        for i in 0..<min(3, stats.formatBreakdown.count) {
            let row = stats.formatBreakdown[i]
            let unpurchased = i < stats.unpurchasedFormatBreakdown.count ? stats.unpurchasedFormatBreakdown[i].count : 0
            formatRows.append(formatRow(colors[i], labels[i], row.count, row.percent, row.avgCost,
                                        medians[i].map(DVFormat.money) ?? "—", unpurchased))
        }
        formatRows.append(DVBox(height: 1) { g, r in g.fill(g.snap(r), DVK.separator) })
        formatRows.append(formatRow(nil, "All", stats.filmsOnDisc, 100, stats.averageCost,
                                    insights.medianCost.map(DVFormat.money) ?? "—", stats.unpurchasedOnDisc))
        // The rows open up to fill the card's height (DVSpread) but never set it.
        let formats = DVK.card(title: "Formats", trailing: "Per-film",
                               subtitle: "\(DVFormat.count(insights.unpurchasedOutOfPrint)) of the unpurchased films are out-of-print.",
                               [DVSpread(minSpacing: 2, formatRows)])

        // 4K UHD and HDR: every 4K release, or the purchased ones.
        let f = stats.fourKStats
        let fourK = switchable(b, key: "fourK") { scope, trailing in
            let allTab = scope == 0
            let rootCount = allTab ? f.filmsWithFourK : f.filmsWithPurchasedFourK
            let rootPercent = allTab ? f.filmsWithFourKPercent : f.fourKPurchaseRate
            let nativeCount = allTab ? f.filmsWithNativeFourK : f.filmsWithPurchasedNativeFourK
            let upscaledCount = allTab ? f.filmsWithUpscaledFourK : f.filmsWithPurchasedUpscaledFourK
            let hdrRows = allTab ? insights.hdrOnAll4K : insights.hdrOnPurchased4K
            let hdrDiscs = hdrRows.reduce(0) { $0 + $1.count }
            let hdrSegments = hdrRows.enumerated().map { i, t in
                DVKSegment(label: t.label, count: t.count, color: .systemIndigo, fillOpacity: [0.85, 0.65, 0.45, 0.25][i])
            }
            return DVK.card(title: "4K UHD and HDR", trailingNode: trailing, [
                DVK.subheading("Master type"),
                DVVStack(spacing: 6, [
                    DVK.barRow(label: allTab ? "4K release available to buy" : "Purchased 4K release", fraction: Double(rootPercent) / 100,
                               color: .systemIndigo, count: DVFormat.count(rootCount), percent: pct(rootPercent), labelWidth: 170, barHeight: 12),
                    DVK.barRow(label: "    Native 4K", fraction: Double(DVFormat.percent(nativeCount, of: rootCount)) / 100, color: .systemBlue,
                               count: DVFormat.count(nativeCount), percent: pct(DVFormat.percent(nativeCount, of: rootCount)),
                               labelWidth: 170, barHeight: 12, fillOpacity: 0.5),
                    DVK.barRow(label: "    Upscaled", fraction: Double(DVFormat.percent(upscaledCount, of: rootCount)) / 100, color: .systemPurple,
                               count: DVFormat.count(upscaledCount), percent: pct(DVFormat.percent(upscaledCount, of: rootCount)),
                               labelWidth: 170, barHeight: 12, fillOpacity: 0.5),
                ]),
                subheadingTop("HDR format"),
                DVK.stackedBar(hdrSegments, height: 14),
                DVK.legend(hdrSegments, total: hdrDiscs),
            ])
        }

        // Purchases by year.
        let allRows = stats.purchaseYearTable.sorted { $0.year < $1.year }
        let unconditioned = allRows.reduce(0) { $0 + max($1.count - $1.newCount - $1.usedCount, 0) }
        var legend = [DVKSegment(label: "New", count: stats.newReleases, color: .systemGreen),
                      DVKSegment(label: "Used", count: stats.usedReleases, color: .systemOrange)]
        if unconditioned > 0 {
            legend.append(DVKSegment(label: "No condition recorded", count: unconditioned, color: .secondaryLabelColor, fillOpacity: 0.3))
        }
        // Past 10 Years: this calendar year and the nine before it.
        let firstRecentYear = AppCalendar.current.component(.year, from: Date()) - 9
        let yearCharts = switchable(b, key: "purchaseYears", default: 0, titles: ["All Time", "Past 10 Years"]) { scope, control in
            let rows = scope == 0 ? allRows : allRows.filter { (Int($0.year) ?? 0) >= firstRecentYear }
            return DVK.card(title: "Purchases by Year", trailingNode: DVHStack(spacing: 12, [DVK.legend(legend, showCounts: false), control]),
                            subtitle: "Percentages denote the number of items purchased at or below the all-time, all-format average cost of \(stats.averageCost).",
                            [stackedYearBars(rows, height: 150)])
        }
        var facts: [any DVNode] = []
        if let busiest = insights.busiestYear {
            facts.append(DVK.factRow(label: "Busiest year", value: "\(busiest.year) (\(busiest.count) for \(DVFormat.wholeMoney(busiest.spent)))"))
        }
        if let mo = insights.busiestMonth { facts.append(DVK.factRow(label: "Busiest month", value: "\(mo.label) (\(mo.count))")) }
        facts.append(DVK.factRow(label: "Avg. per month, trailing 12", value: Fmt.fixed(insights.averagePurchasesPerMonthTrailing12, 1)))
        if let g = insights.longestPurchaseGap { facts.append(DVK.factRow(label: "Longest gap", value: "\(g.days) days (\(g.year))")) }
        if insights.usedShareByYearTrend.count >= 2 {
            facts.append(DVK.factRow(label: "Used share by year", value: insights.usedShareByYearTrend.map { "\($0.percent)%" }.joined(separator: " → ")))
        }
        facts.append(DVK.factRow(label: "Paid above lowest recorded price",
                                 value: insights.paidAboveLowest.count > 0 ? "\(insights.paidAboveLowest.count) (\(DVFormat.wholeMoney(insights.paidAboveLowest.over)) over)" : "0",
                                 valueColor: insights.paidAboveLowest.count > 0 ? .systemRed : .labelColor))
        facts.append(DVK.factRow(label: "Purchased at lowest recorded price", value: DVFormat.count(insights.boughtAtLowest),
                                 valueColor: insights.boughtAtLowest > 0 ? .systemGreen : .labelColor))
        let yearFacts = DVK.card(title: "Purchase Facts", trailing: "All time", [DVVStack(spacing: 4, facts)])

        // Spending Trends.
        let highlights = DVSpendingTrends.highlights(stats: stats, insights: insights)
        let trends = DVK.card(title: "Spending Trends", [
            highlights.isEmpty ? DVK.footnote(DVSpendingTrends.emptyText) : DVVStack(spacing: 8, highlights.map(DVK.highlightRow)),
        ])

        // Summary row.
        let toViewing = DVK.card(title: "Purchase → Next Viewing", trailingNode: insights.purchaseToFirstViewingMedianDays.map { d in
                                     DVFirstFit(texts: ["Median: \(d) days", "Median: \(d) d"].map { DVText($0, .system(10), .secondary) }) },
                                 subtitle: "Releases must have a recorded purchase date to be counted here.", bottomAligned: true, [
            DVK.verticalBars(insights.purchaseToFirstViewing.enumerated().map { i, t in
                DVKBar(label: t.label, value: Double(t.count), color: Self.purchaseToViewingColors[i],
                       valueLabel: DVFormat.count(t.count))
            }, height: 96),
        ])
        var value: [any DVNode] = [DVK.factRow(label: "Cost per viewing since purchase", value: insights.costPerViewing.map(DVFormat.money) ?? "—")]
        // Film names go on an indented sub-row so a long title can never squeeze the figure
        // beside it; the release year follows the name, as in Most Rewatched.
        if let best = insights.bestValue {
            value.append(DVK.factRow(label: "Best value (lowest cost per viewing)", value: DVFormat.money(best.perViewing)))
            value.append(DVK.factRow(label: best.name, year: best.year, value: "", valueColor: .secondaryLabelColor, indented: true))
        }
        if let priciest = insights.mostExpensiveUnwatchedSincePurchase {
            value.append(DVK.factRow(label: "Priciest unwatched since purchase", value: DVFormat.money(priciest.cost)))
            value.append(DVK.factRow(label: priciest.name, year: priciest.year, value: "", valueColor: .secondaryLabelColor, indented: true))
        }
        value.append(DVK.factRow(label: "Spent, never watched since purchase", value: DVFormat.wholeMoney(insights.spentNeverWatchedSincePurchase),
                                 valueColor: insights.spentNeverWatchedSincePurchase > 0 ? .systemRed : .labelColor))
        value.append(DVK.factRow(label: "Spent on duplicative copies",
                                 value: "\(DVFormat.wholeMoney(insights.spentOnSecondCopies.amount)) (\(films(insights.spentOnSecondCopies.films)))",
                                 compactValue: "\(DVFormat.wholeMoney(insights.spentOnSecondCopies.amount)) (\(DVFormat.count(insights.spentOnSecondCopies.films)))"))
        let valueCard = DVK.card(title: "Value Realized",
                                 subtitle: "Viewings counted from each release's most recent purchase date forward.",
                                 [DVVStack(spacing: 4, value)])
        // Opens the Release Wishlist report, where the ranked list is.
        let wishlist = DVK.card(title: "Wishlist", action: m.navigation.releaseWishlist, [
            DVVStack(spacing: 4, [
                DVK.factRow(label: "Items", value: DVFormat.count(insights.wishlistItems)),
                DVK.factRow(label: "Cost at entered prices", value: DVFormat.wholeMoney(insights.wishlistEstimatedCost)),
                DVK.factRow(label: "By format (4K, Blu-ray, DVD)",
                            value: "\(insights.wishlistByFormat.fourK), \(insights.wishlistByFormat.bluRay), \(insights.wishlistByFormat.dvd)"),
                DVK.factRow(label: "Out-of-print or import only", value: DVFormat.count(insights.wishlistOutOfPrintOrImport),
                            valueColor: insights.wishlistOutOfPrintOrImport > 0 ? .systemOrange : .labelColor),
                DVK.factRow(label: "Temporarily unavailable", value: DVFormat.count(insights.wishlistTemporarilyUnavailable)),
                DVK.factRow(label: "Added in the last 90 days", value: DVFormat.count(insights.wishlistAddedLast90Days)),
            ]),
        ])

        return Section(title: title, detail: detail, rows: [
            tiles,
            // The Formats table carries five fixed numeric columns, so it needs more room
            // than a standard wide card before it can share a row. In print both 4K scopes
            // sit beside it, the table weighted to the width its columns need.
            b.isPrint ? DVFlow(minColumnWidth: 280, weights: [1.5, 1, 1], [formats] + fourK)
                      : DVFlow(minColumnWidth: 480, [formats] + fourK),
        ] + (b.isPrint
            // In print All Time spans the page and Past 10 Years sits beside the facts.
            ? [yearCharts[0], DVFlow(minColumnWidth: 300, weights: [1.8, 1], [yearCharts[1], yearFacts])]
            : [DVFlow(minColumnWidth: 300, weights: [1.8, 1], [yearCharts[0], yearFacts])]) + [
            trends,
            DVFlow(minColumnWidth: DVStyle.minCardWidth, maxColumns: 3, [toViewing, valueCard, wishlist]),
            DVFlow(minColumnWidth: DVStyle.minCardWidth, maxColumns: 3,
                   [purchaseMonthCard(insights.habits), priceByRatingCard(insights.habits), fourKUpgradesCard(insights.habits, b)]),
        ])
    }

    /// DVStackedYearBars and the two label rows under it: new-over-used columns per purchase
    /// year, bottom-aligned, then each year and its at-or-below-average share.
    private static func stackedYearBars(_ rows: [PurchaseYearRow], height: CGFloat) -> any DVNode {
        let labelHeight = DVFont.system(10).lineHeight
        return DVBox(height: height + 4 + labelHeight + 4 + DVFont.mono(10).lineHeight) { g, rect in
            guard !rows.isEmpty else { return }
            let peak = Double(max(rows.map(\.count).max() ?? 1, 1))
            let usable = height - 16
            let n = CGFloat(rows.count)
            let colW = (rect.width - 8 * (n - 1)) / n
            for (i, row) in rows.enumerated() {
                let x = rect.minX + CGFloat(i) * (colW + 8)
                let newH = max(row.newCount > 0 ? 2 : 0, CGFloat(Double(row.newCount) / peak) * usable)
                let usedH = max(row.usedCount > 0 ? 2 : 0, CGFloat(Double(row.usedCount) / peak) * usable)
                let other = max(row.count - row.newCount - row.usedCount, 0)
                let otherH = max(other > 0 ? 2 : 0, CGFloat(Double(other) / peak) * usable)
                var y = rect.minY + height
                let otherRect = g.snap(CGRect(x: x, y: y - otherH, width: colW, height: otherH)); y -= otherH
                let usedRect = g.snap(CGRect(x: x, y: y - usedH, width: colW, height: usedH)); y -= usedH
                let newRect = g.snap(CGRect(x: x, y: y - newH, width: colW, height: newH)); y -= newH
                g.fill(otherRect, DVPaint(color: .secondaryLabelColor, opacity: 0.3))
                g.fill(usedRect, DVPaint(color: .systemOrange, opacity: DVStyle.fillOpacity))
                if newRect.height > 0 { g.fillPath(DVShapes.topRounded(newRect, 3), DVPaint(color: .systemGreen, opacity: DVStyle.fillOpacity)) }
                // Each band's own count inside it, as the Viewings by Month bars do.
                for (band, n) in [(newRect, row.newCount), (usedRect, row.usedCount), (otherRect, other)] where n > 0 && band.height >= 14 {
                    let line = DVLine.plain(DVFormat.count(n), .mono(8))
                    let w = min(band.width, line.width(scale: g.scale))
                    g.draw(line, at: CGPoint(x: g.snap(band.midX - w / 2), y: band.minY + 2), width: w, paint: DVPaint(color: .white, opacity: 0.55))
                }
                let count = DVLine.plain(DVFormat.count(row.count), .mono(10))
                let cw = min(colW, count.width(scale: g.scale))
                g.draw(count, at: CGPoint(x: g.snap(x + colW / 2 - cw / 2), y: g.snap(y - 3 - labelHeight)), width: cw,
                       paint: .secondary, scaleToFit: 0.6)
                let year = DVLine.plain(row.year, .system(10))
                let yw = min(colW, year.width(scale: g.scale))
                g.draw(year, at: CGPoint(x: g.snap(x + colW / 2 - yw / 2), y: rect.minY + height + 4), width: yw,
                       paint: .secondary, scaleToFit: 0.6)
                let share = DVLine.plain("\(Int(row.atOrBelowAveragePercentOfYear.rounded()))%", .mono(10))
                let sw = min(colW, share.width(scale: g.scale))
                g.draw(share, at: CGPoint(x: g.snap(x + colW / 2 - sw / 2), y: rect.minY + height + 4 + labelHeight + 4), width: sw,
                       paint: DVPaint(color: .systemBlue), scaleToFit: 0.6)
            }
            g.fill(g.snap(CGRect(x: rect.minX, y: rect.minY + height - 1, width: rect.width, height: 1)), DVK.separator)
        }
    }

    // MARK: 5. Collection Structure

    static func collection(_ m: DVCanvasModel, _ b: DVBuild) -> Section {
        let stats = m.stats, insights = m.insights
        let duplicates = DVK.card(title: "Duplicates and Upgrades",
                                  subtitle: "\"Available\" means a release of that format has been entered for the film, but not yet purchased.", [
            DVVStack(spacing: 4, [
                DVK.factRow(label: "Owned in more than one format",
                            value: "\(DVFormat.count(insights.multiFormatFilms)) (\(pct(DVFormat.percent(insights.multiFormatFilms, of: stats.filmsOnDisc))))"),
                DVK.factRow(label: "Releases with 2+ copies", value: DVFormat.count(insights.multiCopyReleases)),
                DVK.factRow(label: "DVD only, upgrade available", value: "\(insights.dvdOnlyWithUpgradeAvailable) of \(insights.dvdOnlyFilms)",
                            valueColor: insights.dvdOnlyWithUpgradeAvailable > 0 ? .systemOrange : .labelColor),
                DVK.factRow(label: "Blu-ray only, 4K available", value: "\(insights.bluRayOnlyWith4KAvailable) of \(insights.bluRayOnlyFilms)"),
                DVK.factRow(label: "Discs marked as remastered", value: "\(DVFormat.count(insights.remasteredReleases))"),
                DVK.factRow(label: "Owned, now out-of-print",
                            value: "\(DVFormat.count(insights.ownedOutOfPrint)) (\(pct(DVFormat.percent(insights.ownedOutOfPrint, of: stats.totalPurchasedReleases))))"),
                DVK.factRow(label: "Steelbooks", value: DVFormat.count(insights.steelbooks)),
                DVK.factRow(label: "Discs per film on disc",
                            value: stats.filmsOnDisc > 0 ? Fmt.fixed(Double(insights.physicalDiscs) / Double(stats.filmsOnDisc), 2) : "—"),
            ]),
        ])
        let studios = switchable(b, key: "studios") { scope, trailing in
            let rows = scope == 0 ? insights.studiosAll : insights.studios
            return DVK.card(title: "Studios and Labels", trailingNode: trailing, [
                rows.isEmpty ? DVK.footnote("No studio recorded on any release")
                             : DVK.tallyRows(rows, color: .systemCyan, scaleToMax: true, showPercent: false),
            ])
        }
        let regions = switchable(b, key: "regions") { scope, trailing in
            let all = scope == 0
            let origins = all ? insights.originsAll : insights.origins
            let locks = all ? insights.blurayRegionLocksAll : insights.blurayRegionLocks
            let lockColors: [NSColor] = [.systemGreen, .systemBlue, .systemOrange, .systemOrange, .systemGray]
            let lockSegments = locks.enumerated().map { i, t in
                DVKSegment(label: t.label, count: t.count, color: lockColors[i], fillOpacity: i == 3 ? 0.4 : DVStyle.fillOpacity)
            }
            return DVK.card(title: "Regions", trailingNode: trailing, [
                DVK.subheading("National origin"),
                origins.isEmpty ? DVK.footnote("No origin recorded on any release")
                                : DVK.tallyRows(origins, color: .systemGreen, labelWidth: 100, scaleToMax: true, showPercent: false),
                subheadingTop("Blu-ray region locks"),
                DVK.stackedBar(lockSegments, height: 14),
                DVK.legend(lockSegments),
            ])
        }
        // In print each scope pair takes its own row.
        let rows: [[any DVNode]] = b.isPrint ? [[duplicates] + studios, [emptyCell] + regions] : [[duplicates] + studios + regions]
        return Section(title: "Collection Structure",
                       rows: rows.map { DVFlow(minColumnWidth: DVStyle.minTextCardWidth, maxColumns: 3, $0) })
    }

    // MARK: 6. Release Decades, Runtime, and Picture

    static func decades(_ m: DVCanvasModel) -> Section {
        let stats = m.stats, insights = m.insights
        let span: String? = {
            guard let o = insights.oldestYear, let n = insights.newestYear else { return nil }
            return "\(o) - \(n)"
        }()
        let decadeSubtitle = insights.bestRatedDecade.map { "Average rating peaks in the \($0.label) at \(Fmt.fixed($0.average, 1))." }
            ?? "Decades of the films' release years."
        let decadesCard = DVK.card(title: "Films by Release Decade", trailing: span, subtitle: decadeSubtitle, bottomAligned: true, [
            stats.filmsByDecade.isEmpty
                ? DVK.footnote("No release years recorded")
                : DVK.verticalBars(stats.filmsByDecade.map {
                    DVKBar(label: $0.decade, value: Double($0.count), color: .systemBlue, valueLabel: DVFormat.count($0.count))
                }, height: 150, spacing: 6),
        ])
        var lines: [String] = []
        // The title is cut here, in the string, rather than by the subtitle's line limit: the
        // subtitle is one text over two lines, so a limit would cap the lines, not this one.
        if let l = insights.longestFilm {
            let name = l.name.count > 40 ? String(l.name.prefix(40)) + "…" : l.name
            lines.append("Longest film: \(name) (\(DVFormat.hoursMinutes(l.minutes)))")
        }
        if insights.editedTrimmedMinutes > 0 { lines.append("Editing films has trimmed \(DVFormat.hours(insights.editedTrimmedMinutes)) in total.") }
        let runtime = DVK.card(title: "Runtime", trailing: insights.averageRuntimeMinutes.map { "Average length: \(DVFormat.hours($0))" },
                               subtitle: lines.joined(separator: "\n"), bottomAligned: true, [
            DVK.verticalBars(insights.runtimeBuckets.map {
                DVKBar(label: $0.label, value: Double($0.count), color: .systemOrange, valueLabel: DVFormat.count($0.count))
            }, height: 150, spacing: 6),
        ])
        func ratioColor(_ c: String) -> NSColor {
            switch c {
            case "Pillarboxed": return .systemYellow
            case "Fullscreen": return .systemGreen
            case "Letterboxed": return .systemBlue
            case "Hybrid": return .systemPurple
            default: return .secondaryLabelColor
            }
        }
        var picture: [any DVNode] = [DVK.subheading("Aspect ratio by class")]
        if stats.aspectRatioDistribution.isEmpty {
            picture.append(DVK.footnote("No aspect ratios recorded"))
        } else {
            let ratio = stats.aspectRatioDistribution.map { DVKSegment(label: $0.ratio, count: $0.count, color: ratioColor($0.ratio)) }
            picture += [DVK.stackedBar(ratio), DVK.legend(ratio)]
        }
        let chroma = [DVKSegment(label: "Color", count: stats.colorFilms, color: .systemBlue),
                      DVKSegment(label: "B&W", count: stats.bwFilms, color: .systemGray, fillOpacity: 0.5)]
        picture += [subheadingTop("Chroma"), DVK.stackedBar(chroma), DVK.legend(chroma)]
        if !insights.frameRates.isEmpty {
            let frames = insights.frameRates.enumerated().map { i, t in
                DVKSegment(label: t.label, count: t.count, color: .systemIndigo, fillOpacity: [0.85, 0.5, 0.28, 0.15][min(i, 3)])
            }
            picture += [subheadingTop("Frame rates"), DVK.stackedBar(frames), DVK.legend(frames)]
        }
        let pictureCard = DVK.card(title: "Picture", subtitle: "Releases marked as open-matte share their bare ratio's band.", picture)
        let peakYear = stats.filmsByYear.max { $0.count < $1.count }
        let yearsCard = DVK.card(title: "Films by Release Year", trailing: span,
                                 subtitle: peakYear.map { "Most films from one year: \(DVFormat.count($0.count)), in \(String($0.year))." }, [
            stats.filmsByYear.isEmpty
                ? DVK.footnote("No release years recorded")
                : DVYearBars(values: stats.filmsByYear, chartHeight: 150),
        ])
        return Section(title: "Release Decades, Runtime, and Picture", rows: [
            yearsCard,
            DVFlow(minColumnWidth: DVStyle.minTextCardWidth, maxColumns: 3, [decadesCard, runtime, pictureCard]),
            DVFlow(minColumnWidth: DVStyle.minTextCardWidth, maxColumns: 2, [ratingByDecadeCard(insights), ownershipByDecadeCard(insights.habits)]),
        ])
    }

    // MARK: Collector habits (all time)

    /// Viewing History: first-time viewings against rewatches, year by year.
    static func discoveryCard(_ h: DVHabits) -> any DVNode {
        let first = DVKSegment(label: "First-time", count: 0, color: .systemBlue)
        let again = DVKSegment(label: "Rewatch", count: 0, color: .systemPurple)
        var lines: [String] = []
        if let from = h.trackedFrom, h.hasSparseEarlierYears {
            lines.append("Years before \(from) have too few recorded viewings to compare.")
        }
        lines.append("The percentage above each bar denotes rewatches as a share of that year's viewings.")
        let bars = h.viewingYears.map {
            DVKMonthBar(label: String($0.year), value: $0.total, bands: [$0.firstTime, $0.rewatches],
                        valueLabel: $0.total > 0 ? "\($0.rewatchPercent)%" : nil)
        }
        return DVK.card(title: "Discovery vs. Revisiting", trailingNode: DVK.legend([first, again], showCounts: false),
                        subtitle: lines.joined(separator: " "), bottomAligned: true, [
            bars.isEmpty
                ? DVK.footnote("No viewings recorded yet")
                : DVK.monthColorBars(bars, paints: [DVPaint(color: .systemBlue, opacity: DVStyle.fillOpacity),
                                                    DVPaint(color: .systemPurple, opacity: DVStyle.fillOpacity)],
                                     priorPaints: [DVPaint(color: .systemBlue, opacity: DVStyle.fillOpacity * 0.5),
                                                   DVPaint(color: .systemPurple, opacity: DVStyle.fillOpacity * 0.5)],
                                     height: 120, spacing: 8),
        ])
    }

    /// Viewing History: how old films are when they are watched.
    static func viewingAgeCard(_ h: DVHabits) -> any DVNode {
        let total = h.viewingAgeBuckets.reduce(0) { $0 + $1.count }
        let new = h.viewingAgeBuckets.first?.count ?? 0
        let old = h.viewingAgeBuckets.suffix(2).reduce(0) { $0 + $1.count }
        var subtitle = "Years between a film's release and each viewing."
        if total > 0 {
            subtitle += " \(DVFormat.percent(old, of: total))% of viewings are of films over 30 years old; \(DVFormat.percent(new, of: total))% are of films within one year of their release."
        }
        return DVK.card(title: "Film Age at Viewing", trailing: h.medianViewingAge.map { "Median: \($0) years" }, subtitle: subtitle,
                        bottomAligned: true, [
            total == 0
                ? DVK.footnote("No viewings of films with a release year")
                : DVK.verticalBars(h.viewingAgeBuckets.map {
                    DVKBar(label: $0.label, value: Double($0.count), color: .systemTeal, valueLabel: "\($0.percent ?? 0)%")
                }, height: 120, spacing: 6),
        ])
    }

    /// Purchases and Spending: dated purchases by calendar month.
    static func purchaseMonthCard(_ h: DVHabits) -> any DVNode {
        let letters = AppCalendar.current.veryShortMonthSymbols
        let peak = h.purchasesByMonth.max() ?? 0
        return DVK.card(title: "Purchases by Month", trailing: "All time",
                        subtitle: h.busiestMonthSentence ?? "Dated purchases by calendar month.", bottomAligned: true, [
            h.datedPurchases == 0
                ? DVK.footnote("No purchase has a purchase date yet")
                : DVK.verticalBars((0..<12).map { i in
                    DVKBar(label: letters[i], value: Double(h.purchasesByMonth[i]), color: .systemGreen,
                           dimmed: h.purchasesByMonth[i] < peak, valueLabel: DVFormat.count(h.purchasesByMonth[i]))
                }, height: 120, spacing: 4),
        ])
    }

    /// Purchases and Spending: what is paid, and on what format, by your rating.
    static func priceByRatingCard(_ h: DVHabits) -> any DVNode {
        let top = h.ratingBand(9...10), low = h.ratingBand(1...5)
        var subtitle = "By your rating of the film."
        if let a = top.averagePaid, let b = low.averagePaid, let x = top.fourKPercent, let y = low.fourKPercent {
            subtitle = "Films rated 9–10 average \(DVFormat.money(a)) per release and \(x)% 4K ownership, versus \(DVFormat.money(b)) and \(y)% for those rated 1–5."
        }
        let price = DVK.verticalBars((0..<10).map { i in
            DVKBar(label: "\(i + 1)", value: h.averagePaidByRating[i] ?? 0, color: .systemGreen,
                   valueLabel: h.averagePaidByRating[i].map { DVFormat.wholeMoney($0) })
        }, height: 70, spacing: 4)
        let share = DVK.verticalBars((0..<10).map { i in
            DVKBar(label: "\(i + 1)", value: Double(h.fourKShareByRating[i] ?? 0), color: .systemIndigo,
                   valueLabel: h.fourKShareByRating[i].map { "\($0)%" })
        }, height: 70, spacing: 4)
        return DVK.card(title: "Price and Format by Rating", trailing: "All time", subtitle: subtitle, bottomAligned: true, [
            DVK.subheading("Average paid per release"), price,
            subheadingTop("Purchased films with a 4K release"), share,
        ])
    }

    /// Purchases and Spending: films rated 8+ with a 4K release entered but not bought.
    static func fourKUpgradesCard(_ h: DVHabits, _ b: DVBuild) -> any DVNode {
        // Every film as a row; DVFitRows shows as many as the card's height holds, the View
        // All button after them when some are left out.
        let rows: [any DVNode] = h.fourKUpgrades.map {
            DVK.rankRow(name: $0.film.name, value: "\($0.rating)", compact: true, year: $0.film.year)
        }
        var more: (any DVNode)?
        if case .screen(let view) = b {
            let button = view.control("fourKUpgradesViewAll") {
                let c = DVKControl(NSButton(title: "View All", target: nil, action: nil))
                (c.control as? NSButton)?.bezelStyle = .push
                return c
            }
            button.onAction = { [weak view] sender in
                view?.showAttentionPopover(fourKUpgradesPopoverID, from: sender.alignmentRect(forFrame: sender.frame))
            }
            more = DVFrame(child: DVControlNode(control: button), maxInfinity: true, hAlign: .center)
        }
        return DVK.card(title: "4K Upgrades by Rating", trailing: films(h.fourKUpgrades.count),
                        subtitle: "Films you rated \(DVHabits.upgradeMinimumRating) or higher with a 4K release entered, but none purchased. Highest rated first.", [
            rows.isEmpty ? DVK.footnote("Every film rated \(DVHabits.upgradeMinimumRating)+ with a 4K release has been purchased on 4K") : DVFitRows(rows: rows, more: more),
        ])
    }

    /// Release Decades: the decades ranked by the average rating of their rated films.
    static func ratingByDecadeCard(_ i: LibraryInsights) -> any DVNode {
        let subtitle = "Decades with fewer than \(LibraryInsights.minimumRatedFilmsPerDecadeWords) rated films are omitted."
        let peak = i.decadesByRating.first?.average
        return DVK.card(title: "Average Rating by Release Decade", subtitle: subtitle, bottomAligned: true, [
            i.decadesByRating.isEmpty
                ? DVK.footnote("No decade has \(LibraryInsights.minimumRatedFilmsPerDecadeWords) rated films yet")
                : DVK.verticalBars(i.decadesByRating.map {
                    DVKBar(label: $0.label, value: $0.average, color: .systemYellow, dimmed: $0.average < (peak ?? 0),
                           valueLabel: Fmt.fixed($0.average, 1), insideLabel: DVFormat.count($0.rated))
                }, height: 100, spacing: 6),
        ])
    }

    /// Release Decades: the share of each decade's cataloged films owned on disc.
    static func ownershipByDecadeCard(_ h: DVHabits) -> any DVNode {
        let subtitle = "Films with a purchased release as a share of those in your library from each decade."
        return DVK.card(title: "Ownership by Release Decade", subtitle: subtitle, bottomAligned: true, [
            h.ownershipByDecade.isEmpty
                ? DVK.footnote("No release years recorded")
                : DVK.verticalBars(h.ownershipByDecade.map {
                    let p = DVFormat.percent($0.owned, of: $0.films)
                    return DVKBar(label: $0.decade, value: Double(p), color: .systemGreen, valueLabel: "\(p)%", insideLabel: DVFormat.count($0.films))
                }, height: 100, spacing: 6),
        ])
    }

    // MARK: 7. People and Genres

    static func people(_ m: DVCanvasModel, _ b: DVBuild) -> Section {
        let insights = m.insights
        func twoLine(_ a: String, _ b: String) -> any DVNode {
            DVVStack(spacing: 0, align: .trailing, [DVText(a, .system(10), .secondary), DVText(b, .system(10), .secondary)])
        }
        // The role pop-up takes the "Name" header's place, which it describes better; in
        // print, where every role gets its own card, the role's name sits there instead.
        let peopleCards = switchable(b, key: "role", titles: ["Directors", "Cast", "Composers", "Screenwriters"], popUpWidth: 130,
                                     caption: { DVText($0, .system(13, .semibold), .primary) }) { role, picker in
            let people: [DVRank] = [insights.directors, insights.cast, insights.composers, insights.screenwriters][role]
            guard !people.isEmpty else { return DVK.card([picker, DVK.footnote("No names recorded in this field")]) }
            return DVK.card([
                DVDecorated(child: DVHStack(spacing: 4, [
                    DVBox(width: 20, height: 1) { _, _ in },
                    picker,
                    DVSpacer(minLength: 4),
                    DVFrame(child: DVText("Films", .system(10), .secondary), minWidth: 34, hAlign: .trailing),
                    DVFrame(child: twoLine("Avg.", "rating"), minWidth: 44, hAlign: .trailing),
                    DVFrame(child: twoLine("Views/", "film"), minWidth: 44, hAlign: .trailing),
                ], priorities: [0, 0, 0, 1, 0, 0]), insets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)),
                DVVStack(spacing: 4, people.enumerated().map { i, row in
                    DVK.rankRow(rank: i + 1, name: row.name, value: row.value, extras: row.extras, extraWidth: 44)
                }),
            ])
        }

        let genreHeader = DVHStack(spacing: 8, [
            DVFrame(child: DVText("Films", .system(10), .secondary), width: 34, hAlign: .trailing),
            DVFrame(child: twoLine("Avg.", "rating"), width: 40, hAlign: .trailing),
        ])
        let genres: any DVNode
        if insights.genres.isEmpty {
            genres = DVK.card(title: "Genres", trailingNode: genreHeader, [DVK.footnote("No genres recorded")])
        } else {
            let peak = Double(insights.genres.compactMap { Int($0.value) }.max() ?? 1)
            genres = DVK.card(title: "Genres", trailingNode: genreHeader, [
                DVVStack(spacing: 6, insights.genres.map { g in
                    DVK.barRow(label: g.name, fraction: Double(Int(g.value) ?? 0) / max(peak, 1), color: .systemBlue,
                               count: g.value, percent: g.extras.first ?? "", labelWidth: 112, countWidth: 34, percentWidth: 40,
                               fillOpacity: g.name == "Other" ? 0.3 : DVStyle.fillOpacity)
                }),
            ])
        }

        var tags: [any DVNode] = []
        if insights.contentRatings.isEmpty {
            tags.append(DVK.footnote("No content ratings recorded"))
        } else {
            // By rating, not by row: only ratings in use are listed, so a row's position
            // says nothing about which rating it is (with no G film, PG is the first row).
            func tint(_ rating: String) -> (NSColor, CGFloat) {
                switch rating {
                case "G": return (.systemGreen, DVStyle.fillOpacity)
                case "PG": return (.systemGreen, 0.45)
                case "PG-13": return (.systemYellow, DVStyle.fillOpacity)
                case "R": return (.systemOrange, DVStyle.fillOpacity)
                case "NC-17": return (.systemRed, DVStyle.fillOpacity)
                default: return (.systemGray, DVStyle.fillOpacity)
                }
            }
            let segments = insights.contentRatings.map { t in
                DVKSegment(label: t.label, count: t.count, color: tint(t.label).0, fillOpacity: tint(t.label).1)
            }
            tags += [DVK.stackedBar(segments), DVK.legend(segments)]
        }
        tags.append(subheadingTop("Tags, most used first"))
        if insights.tags.isEmpty {
            tags.append(DVK.footnote("No tags in use"))
        } else {
            tags.append(DVFlow(minColumnWidth: 110, spacing: 6, maxColumns: 4, insights.tags.prefix(9).map { tag in
                DVDecorated(child: DVHStack(spacing: 6, [
                    DVText(tag.label, .system(11), .primary),
                    DVSpacer(minLength: 4),
                    DVText(DVFormat.count(tag.count), .mono(11), .secondary),
                ]), insets: NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8), background: DVK.rowPaint, radius: 4)
            }))
        }
        let ratingsCard = DVK.card(title: "MPAA Ratings and Tags", tags)
        // In print the four role cards take a row of their own.
        return Section(title: "People and Genres", rows: b.isPrint
            ? [DVFlow(minColumnWidth: 280, maxColumns: 4, peopleCards),
               DVFlow(minColumnWidth: DVStyle.minTextCardWidth, maxColumns: 2, [genres, ratingsCard])]
            : [DVFlow(minColumnWidth: DVStyle.minTextCardWidth, maxColumns: 3, peopleCards + [genres, ratingsCard])])
    }

    // MARK: 8. Audio, Sources, and Technical

    /// A hue per tier of the source ladder — cyan for Blu-ray rips, green for DVD rips, orange
    /// for the better downloads, red below 540p — each source its own shade (a remastered rip
    /// deeper than a plain one), so no two neighboring bands share a color. By decoded value rather than row position, so a tier the ladder gains
    /// cannot shift every color below it.
    private static func sourceTint(_ stored: String) -> (NSColor, CGFloat) {
        let (source, remastered) = FilmDigitalSource.decompose(stored)
        switch source {
        case FilmDigitalSource.blurayDisc: return (.systemCyan, remastered ? 0.9 : 0.65)
        case FilmDigitalSource.dvd: return (.systemGreen, remastered ? 0.8 : 0.55)
        case FilmDigitalSource.download4K: return (.systemOrange, 0.95)
        case FilmDigitalSource.download1080p: return (.systemOrange, 0.75)
        case FilmDigitalSource.download720p: return (.systemOrange, 0.55)
        case FilmDigitalSource.download540p: return (.systemOrange, 0.38)
        case FilmDigitalSource.download480p: return (.systemRed, 0.85)
        case FilmDigitalSource.download360p: return (.systemRed, 0.6)
        default: return (.systemRed, 0.4)
        }
    }

    /// Per audio codec, in `ReleaseAudioFormat.hdOptions` order: the Dolby codecs in one hue,
    /// LPCM in its own, the DTS codecs in a third, each family in descending shades.
    ///
    /// Indexed by position in `hdOptions`, so it must have exactly one entry per option —
    /// a codec added there without a tint here traps the Audio card. The five DTS shades
    /// were re-spaced (from four) when DTS-ES joined the list.
    private static let codecTints: [(NSColor, CGFloat)] = [
        (.systemIndigo, 0.9), (.systemIndigo, 0.65), (.systemIndigo, 0.4), (.systemTeal, 0.75),
        (.systemOrange, 0.85), (.systemOrange, 0.69), (.systemOrange, 0.53), (.systemOrange, 0.39),
        (.systemOrange, 0.27),
    ]

    static func technical(_ m: DVCanvasModel, _ b: DVBuild) -> Section {
        let stats = m.stats, insights = m.insights
        let sourceRows = stats.sourceDistribution.filter { $0.0 != "---" }
        let total = sourceRows.reduce(0) { $0 + $1.1 }
        let sourceSegments = sourceRows.map { r -> DVKSegment in
            let t = sourceTint(r.0)
            return DVKSegment(label: r.0, count: r.1, color: t.0, fillOpacity: t.1)
        }
        let sources = DVK.card(title: "Digital Sources", subtitle: "\(DVFormat.count(stats.totalFilms - total)) films have no source recorded.", [
            DVK.stackedBar(sourceSegments),
            DVVStack(spacing: 2, sourceSegments.map { swatchRow($0, .system(11), count: $0.count, percent: DVFormat.percent($0.count, of: total), vertical: 3) }),
        ])

        // The Audio card in either scope, or (`widest`) with every codec's legend entry at
        // its longest — the larger scope's total, at 100% — the most lines its legend can
        // wrap to at a width.
        func audioCard(allAudio: Bool, widest: Bool = false, trailing: (any DVNode)?) -> any DVNode {
            let channelRows = allAudio ? stats.audioChannelDistributionAll : stats.audioChannelDistribution
            let channelDenominator = allAudio ? stats.audioChannelDenominatorAll : stats.audioChannelDenominator
            let codecRows = allAudio ? stats.audioCodecsAll : stats.audioCodecs
            let codecTotal = codecRows.reduce(0) { $0 + $1.count }
            let widestCount = max(stats.audioCodecsAll.reduce(0) { $0 + $1.count }, stats.audioCodecs.reduce(0) { $0 + $1.count })
            let codecSegments = codecRows.enumerated().map { i, t in
                DVKSegment(label: t.label, count: widest ? widestCount : t.count, color: codecTints[i].0, fillOpacity: codecTints[i].1)
            }
            return DVK.card(title: "Audio", trailingNode: trailing,
                            subtitle: "\(DVFormat.count(stats.lossyBDAudio)) (\(pct(stats.lossyBDAudioPercent))) of \(films(insights.filmsOnBDOr4K)) contain only lossy audio on Blu-ray.", [
                DVK.subheading("Channels by class"),
                DVVStack(spacing: 6, channelRows.map { row in
                    DVK.barRow(label: row.0, fraction: Double(DVFormat.percent(row.1, of: channelDenominator)) / 100, color: .systemPurple,
                               count: DVFormat.count(row.1), percent: pct(DVFormat.percent(row.1, of: channelDenominator)), labelWidth: 100)
                }),
                subheadingTop("Codecs"),
                DVK.stackedBar(codecSegments, height: 14),
                DVK.legend(codecSegments, total: widest ? max(widestCount, 1) : codecTotal),
            ])
        }

        func discsCard(all: Bool, trailing: (any DVNode)?) -> any DVNode {
            let videoCodecRows = all ? insights.videoCodecsAll : insights.videoCodecs
            let rfRows = all ? insights.handbrakeRFAll : insights.handbrakeRF
            let subtitlesYes = all ? insights.subtitlesYesAll : insights.subtitlesYes
            let subtitlesDisc = all ? insights.subtitlesOnDiscOnlyAll : insights.subtitlesOnDiscOnly
            let subtitlesRip = all ? insights.subtitlesDigitalRipOnlyAll : insights.subtitlesDigitalRipOnly
            let subtitlesTotal = all ? stats.totalFilms : insights.subtitlesPurchasedFilmCount
            let subtitlesNone = max(0, subtitlesTotal - subtitlesYes - subtitlesDisc - subtitlesRip)
            let codecColors: [NSColor] = [.systemIndigo, .systemCyan, .systemCyan, .systemGreen]
            let codecs = videoCodecRows.enumerated().map { i, t in
                DVKSegment(label: t.label, count: t.count, color: codecColors[i], fillOpacity: i == 2 ? 0.4 : DVStyle.fillOpacity)
            }
            let subtitleSegments = [
                DVKSegment(label: "Yes", count: subtitlesYes, color: .systemGreen),
                DVKSegment(label: "On-disc only", count: subtitlesDisc, color: .systemBlue),
                DVKSegment(label: "Digital rip only", count: subtitlesRip, color: .systemPurple),
                DVKSegment(label: "None", count: subtitlesNone, color: .secondaryLabelColor, fillOpacity: 0.3),
            ]
            var disc: [any DVNode] = [
                DVK.subheading("Video codec"), DVK.stackedBar(codecs, height: 14), DVK.legend(codecs),
                subheadingTop("Subtitles"), DVK.stackedBar(subtitleSegments, height: 14), DVK.legend(subtitleSegments, total: subtitlesTotal),
            ]
            if rfRows.contains(where: { $0.count > 0 }) {
                let rf = rfRows.enumerated().map { i, t in
                    DVKSegment(label: t.label, count: t.count, color: .systemOrange, fillOpacity: [0.3, 0.62, 0.95][i])
                }
                disc += [subheadingTop("HandBrake \"RF\" value"), DVK.stackedBar(rf, height: 14), DVK.legend(rf)]
            }
            if let notOnBluRay = stats.notAvailableOnBluRay {
                disc.append(DVDecorated(child: DVK.factRow(label: "Not available on Blu-ray or 4K", value: DVFormat.count(notOnBluRay)),
                                        insets: NSEdgeInsets(top: 4, left: 0, bottom: 0, right: 0)))
            }
            return DVK.card(title: "Subtitles and Encoding", trailingNode: trailing, disc)
        }

        // The three cards are one height at every width, whatever the scopes and wherever
        // the row wraps: the tallest of the Audio card with its legend at its longest, each
        // card in each scope, and Digital Sources, all with the title row the scope switch
        // gives them.
        let measureTrailing: any DVNode = {
            if case .screen(let view) = b { return DVControlNode(control: view.scope("audio", default: 0, titles: allOrPurchased).1) }
            return scopeCaption("Purchased Only")
        }()
        let measured = [audioCard(allAudio: true, widest: true, trailing: measureTrailing),
                        audioCard(allAudio: false, widest: true, trailing: measureTrailing),
                        audioCard(allAudio: true, trailing: measureTrailing), audioCard(allAudio: false, trailing: measureTrailing),
                        discsCard(all: true, trailing: measureTrailing), discsCard(all: false, trailing: measureTrailing),
                        sources]
        let heightMemo = DVMemo<CGFloat>()
        let rowHeight: (CGFloat) -> CGFloat = { w in heightMemo.get(w) { measured.map { $0.height(w) }.max() ?? 0 } }
        let sourcesCard = DVMinHeight(child: sources, minHeight: rowHeight)

        let audio = switchable(b, key: "audio") { scope, trailing in
            DVMinHeight(child: audioCard(allAudio: scope == 0, trailing: trailing), minHeight: rowHeight)
        }
        let discs = switchable(b, key: "discs") { scope, trailing in
            DVMinHeight(child: discsCard(all: scope == 0, trailing: trailing), minHeight: rowHeight)
        }

        // In print each scope pair takes its own row.
        let rows: [[any DVNode]] = b.isPrint ? [[sourcesCard] + audio, [emptyCell] + discs] : [[sourcesCard] + audio + discs]
        return Section(title: "Audio, Sources, and Technical",
                       rows: rows.map { DVFlow(minColumnWidth: DVStyle.minTextCardWidth, maxColumns: 3, $0) })
    }
}
