// MARK: - GalleryViewUI.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// UI interaction components for gallery view: custom collection view with marquee
// selection, drag/drop support, and smooth resizing grid layout.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Synchronization

// MARK: - Gallery Collection View (Marquee + Drag Support)
final class GalleryCollectionView: NSCollectionView {
    var onMarqueeSelectionChanged: ((Set<IndexPath>) -> Void)?
    /// Arrow-key navigation callback. Parameters: direction, withShift, isRepeat.
    /// `isRepeat` is `NSEvent.isARepeat`, set from the triggering keyDown. It is true only for the auto-repeat
    /// events of a held key, so consumers can tell a held arrow from rapid discrete presses without timing.
    var onArrowNavigation: ((ArrowDirection, Bool, Bool) -> Void)?
    /// Cmd+A typed with the grid focused. Returns whether it was handled. If not, keyDown passes the event to AppKit.
    var onSelectAll: (() -> Bool)?
    /// Fired at the start of every mouse-down, before selection or marquee handling. The Coordinator uses it to
    /// retire any pending scroll that could move the viewport (see claimViewportForUser()).
    var onUserViewportInteraction: (() -> Void)?
    var getDragFilmIDs: ((IndexPath?) -> Set<UUID>)?
    var getFilmID: ((IndexPath) -> UUID?)?
    var getPosterImage: ((UUID) -> NSImage?)?
    /// Called when the collection view becomes first responder by keyboard focus (Tab or programmatic) with no item selected.
    /// The Coordinator seeds `cursorIndexPath` at item 0, so arrow keys work without a prior click.
    ///
    /// Not called for mouse focus, when a selection already exists, or when the view has no items. Mouse focus
    /// on an item goes through mouseDown and didSelectItemsAt(_:), as described in mouseDown(with:).
    var onKeyboardFocusWithNoSelection: (() -> Void)?
    /// Supplies the contextual menu for the item at a given index path, via GallerySubview.Coordinator.
    /// contextMenu(forItemAt:). That method resolves the target films and may adjust the selection. Returning nil suppresses the menu.
    var getContextMenu: ((IndexPath) -> NSMenu?)?

    private weak var clipView: NSClipView?
    private var isMarqueeDragging = false
    private var marqueeStartPoint: NSPoint = .zero
    private var marqueeCurrentPoint: NSPoint = .zero
    private var preMarqueeSelection: Set<IndexPath> = []

    // Drag state (click tracking — drag execution delegated to GalleryDragEngine)
    private var isDragInitiated = false
    private var clickedOnItem = false
    /// Set in mouseDown on a plain click on an item already in the selection. The selection commit is deferred to
    /// mouseUp for that case only (see mouseDown(with:)).
    private var pendingPlainClickCollapse: IndexPath?

    // GalleryDragEngine handles the flyback window and NSDraggingSource protocol.
    private lazy var dragEngine: GalleryDragEngine = {
        let engine = GalleryDragEngine()
        engine.sourceView = self
        engine.getDragFilmIDs = { [weak self] point in
            guard let self else { return [] }
            let ip = self.indexPathForItem(at: point)
            return self.getDragFilmIDs?(ip) ?? []
        }
        engine.getClickedFilmID = { [weak self] point in
            guard let self else { return nil }
            guard let ip = self.indexPathForItem(at: point) else { return nil }
            return self.getFilmID?(ip)
        }
        engine.getPosterImage = { [weak self] filmID in
            self?.getPosterImage?(filmID)
        }
        return engine
    }()

    // MARK: - First Responder

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        guard result else { return false }

        // Seed item 0 only for keyboard focus (Tab or programmatic). Mouse focus is handled by didSelectItemsAt(_:),
        // which sets the cursor on the clicked item.
        let triggeringEventType = NSApp.currentEvent?.type
        let isMouseEvent = triggeringEventType == .leftMouseDown
                        || triggeringEventType == .rightMouseDown
                        || triggeringEventType == .otherMouseDown

        guard !isMouseEvent else { return result }

        // Snapshot the selection count synchronously. Reading it later could miss a selection cleared in between.
        let hadSelectionAtFocusTime = !selectionIndexPaths.isEmpty
        let hasItems = numberOfItems(inSection: 0) > 0

        guard !hadSelectionAtFocusTime, hasItems else { return result }

        // Defer one run-loop cycle so any selection set in the same event lands first. seedInitialCursor declines to
        // seed over an existing selection, and the hadSelectionAtFocusTime guard covers a prior selection that was cleared.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.numberOfItems(inSection: 0) > 0 else { return }
            self.onKeyboardFocusWithNoSelection?()
        }
        return result
    }

    override func keyDown(with event: NSEvent) {
        // Case-folded, since charactersIgnoringModifiers reports "A" while CapsLock is on.
        if event.charactersIgnoringModifiers?.lowercased() == "a",
           event.modifierFlags.contains(.command),
           onSelectAll?() == true {
            return
        } else if let dir = ArrowDirection.from(event) {
            onArrowNavigation?(dir, event.modifierFlags.contains(.shift), event.isARepeat)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Contextual Menu

    /// Supplies the gallery contextual menu for a secondary-click (or Control-click) on an item. AppKit calls this on
    /// the deepest hit view first and walks up while the result is nil, so the event's location is still valid here.
    ///
    /// Returns nil for any point outside an item's frame, so padding and empty space do nothing. Super is not called,
    /// because NSCollectionView's own menu would appear for those points.
    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: location) else { return nil }
        return getContextMenu?(indexPath)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let cv = clipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: cv)
        }
        if let cv = unsafe superview as? NSClipView {
            clipView = cv
            cv.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipViewBoundsDidChange),
                                                   name: NSView.boundsDidChangeNotification, object: cv)
        } else {
            clipView = nil
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Mouse Handling
    //
    // SELECTION TIMING: AppKit normally defers didSelectItemsAt(_:) until mouseUp, so a drag can grab the whole
    // existing selection. Drag detection here is independent of AppKit's loop, and super.mouseDown is not needed for
    // item hits. The commit timing is split by case:
    //   - A click that changes the selection (an unselected item, or Shift/Cmd) commits immediately in mouseDown.
    //   - A plain click on an item already selected defers the collapse to mouseUp, so a drag still takes the group.
    //
    // Empty-space clicks start a marquee, which AppKit still handles through super so autoscroll works.
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let hitPath = indexPathForItem(at: location)

        // Defensive self-heal: close any stale click window, which is a no-op in normal flow.
        DragSessionMonitor.shared.clickWindowDidClose()

        // The user is acting on this viewport, so any pending scroll restore is stale and must not run on a later draw.
        onUserViewportInteraction?()

        isDragInitiated = false
        pendingPlainClickCollapse = nil

        guard let hitPath else {
            // Start marquee selection — unchanged.
            isMarqueeDragging = true
            clickedOnItem = false
            marqueeStartPoint = location
            marqueeCurrentPoint = location
            preMarqueeSelection = (NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command))
                ? selectionIndexPaths : []
            super.mouseDown(with: event)
            dragEngine.mouseDownForDrag(at: location, event: event)
            return
        }

        isMarqueeDragging = false
        clickedOnItem = true
        preMarqueeSelection = []

        // Opens the click-ambiguity window from mouseDown until the gesture resolves as a click (mouseUp) or a drag
        // (GalleryDragEngine.startManualDrag). Heavy consumers such as RightSidebar defer until then. Selection is still set
        // synchronously, so the focus ring is unaffected. Marquee clicks never open a window. See DragSessionMonitor.
        DragSessionMonitor.shared.clickWindowDidOpen()

        // Records the potential drag start at mouseDown, before any selection work.
        dragEngine.mouseDownForDrag(at: location, event: event)

        // Sets first responder before the selection branches below. The current event is still this mouseDown, so
        // becomeFirstResponder's mouse-versus-keyboard check sees this mouseDown.
        unsafe window?.makeFirstResponder(self)

        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        let commandHeld = NSEvent.modifierFlags.contains(.command)

        if !shiftHeld && !commandHeld && selectionIndexPaths.contains(hitPath) {
            // Plain click on an already-selected item: defer the collapse to mouseUp. selectionIndexPaths is left alone,
            // so a drag started here still grabs the full selection.
            pendingPlainClickCollapse = hitPath
            return
        }

        // A click that changes the selection commits now. Shift extends a range, Cmd toggles one item, and a plain click
        // on an unselected item has no group to keep.
        if commandHeld {
            // Cmd-click toggle. didSelectItemsAt(_:) trusts selectionIndexPaths, so the toggle is applied here first.
            var newSelection = selectionIndexPaths
            if newSelection.contains(hitPath) {
                newSelection.remove(hitPath)
            } else {
                newSelection.insert(hitPath)
            }
            selectionIndexPaths = newSelection
        }

        // Programmatic changes to selectionIndexPaths do not call the delegate, so the delegate is invoked here, as
        // AppKit would for a real click.
        delegate?.collectionView?(self, didSelectItemsAt: [hitPath])
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        if isMarqueeDragging {
            marqueeCurrentPoint = location
            updateLiveSelection()
            super.mouseDragged(with: event)
        } else if clickedOnItem && !isDragInitiated {
            if dragEngine.mouseDraggedForDrag(event: event, locationInView: location) {
                isDragInitiated = true
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isMarqueeDragging {
            marqueeCurrentPoint = convert(event.locationInWindow, from: nil)
            updateLiveSelection()
            isMarqueeDragging = false
            onMarqueeSelectionChanged?(selectionIndexPaths)
        } else if let pending = pendingPlainClickCollapse, !isDragInitiated {
            // The deferred click from mouseDown never turned into a drag — commit
            // the collapse to the single clicked item now, exactly where AppKit's
            // own internal tracking loop would have committed it. didSelectItemsAt's
            // plain-click branch does the actual selectionIndexPaths assignment.
            delegate?.collectionView?(self, didSelectItemsAt: [pending])
        }
        // If isDragInitiated is true here, a drag was started with the selection
        // left intact by the deferred branch above; there is nothing left to commit.
        pendingPlainClickCollapse = nil
        clickedOnItem = false
        isDragInitiated = false
        dragEngine.mouseUpForDrag()
        // Close the click-ambiguity deferral window: the gesture has fully resolved
        // as a plain click, so RightSidebar's deferred content resolution may now
        // flush (clickWindowDidClose posts .dragDeferralWindowDidEnd). Ordered AFTER
        // the pendingPlainClickCollapse commit above so the collapse's deferred
        // selection write is already enqueued ahead of the flush on the main queue.
        // For a gesture that became a drag, AppKit consumes the mouseUp (this method
        // never runs) and sessionWillBegin already absorbed the window — the flush
        // then happens at session end. Guarded internally, so marquee and
        // empty-space mouseUps (no window ever opened) are free no-ops.
        DragSessionMonitor.shared.clickWindowDidClose()
        super.mouseUp(with: event)
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard isMarqueeDragging, let window = unsafe window else { return }
        marqueeCurrentPoint = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        updateLiveSelection()
    }

    private func updateLiveSelection() {
        let rect = NSRect(x: min(marqueeStartPoint.x, marqueeCurrentPoint.x),
                          y: min(marqueeStartPoint.y, marqueeCurrentPoint.y),
                          width: abs(marqueeCurrentPoint.x - marqueeStartPoint.x),
                          height: abs(marqueeCurrentPoint.y - marqueeStartPoint.y))

        guard rect.width > 5 || rect.height > 5 else {
            if selectionIndexPaths != preMarqueeSelection { selectionIndexPaths = preMarqueeSelection }
            return
        }

        guard let layout = collectionViewLayout as? SmoothResizingGridLayout else { return }
        var newSelection = preMarqueeSelection
        // layoutAttributesForElements(in:) can also return section-divider decoration attributes
        // whose IndexPath lives in the same numeric namespace as real items
        // (item: 0, 1, 2...). Without this filter, a marquee drag sweeping over a divider band
        // would fold a bogus, colliding IndexPath into the selection. `.representedElementCategory
        // == .item` is the first-party way to recognize a real, selectable cell's attributes and
        // exclude decoration (and any future supplementary) views. This is a no-op for every
        // non-divider view, where all returned attributes are already `.item`.
        for attrs in layout.layoutAttributesForElements(in: rect) where attrs.representedElementCategory == .item {
            if let ip = attrs.indexPath { newSelection.insert(ip) }
        }
        if newSelection != selectionIndexPaths { selectionIndexPaths = newSelection }
    }
}

// MARK: - Arrow Direction
enum ArrowDirection {
    case up, down, left, right

    static func from(_ event: NSEvent) -> ArrowDirection? {
        switch event.specialKey {
        case .upArrow:    return .up
        case .downArrow:  return .down
        case .leftArrow:  return .left
        case .rightArrow: return .right
        default:          return nil
        }
    }
}

// MARK: - Section Divider Decoration
//
// A gallery grid draws a labeled divider band at the start of every section that
// currently contains at least one film. Two things produce those sections: the Film
// Queue's "All" tab, whose three fixed sections ("Up Next", "Soon", "Later") describe the
// view's own structure, and — when that view's ViewState.showSectionDividers is on —
// every other gallery view, whose bands are derived from the sort option its films are
// ordered by (see GallerySections.swift). The band itself is identical either way; only
// the labels differ, which is why this decoration knows nothing about either producer.
// This is implemented as an AppKit decoration
// view (NSCollectionViewLayout's first-party mechanism for layout-managed, non-data-backed
// visual elements) rather than as a synthetic "pseudo item" injected into the real film
// array. That choice keeps the feature almost entirely non-invasive: `films`, the
// Selection, arrow navigation, marquee hit-testing, drag-and-drop, and the context menu all work with real
// film items and never see dividers. Only the layout's row math and up/down arrow navigation (which steps over a
// divider) are divider-aware. See SmoothResizingGridLayout and GallerySubview.Coordinator.handleArrowKey.
//
// Dividers are inert wherever no bands apply: every view except the Film Queue while sorting sections are off,
// and the purchase-date sort. Those cases publish no section breaks, so this decoration is never created.
let sectionDividerDecorationKind = "SectionDividerDecoration"

/// Layout attributes for a section-divider band. They carry the band's identity with its geometry.
///
/// A label cannot be derived from the frame's Y position, since a sort change can move bands onto the same Y positions
/// and AppKit would keep the old labels. Storing `section` and `filmCount` here makes them part of AppKit's comparison
/// (see `isEqual`), so a relabeled band always re-applies.
/// them part of AppKit's comparison (see `isEqual`), so a relabeled band always re-applies. The label is then a pure
/// function of the attributes, which come from the same sort that loaded the films.
final class SectionDividerLayoutAttributes: NSCollectionViewLayoutAttributes {
    // NSObject's isEqual, hash, and copy are nonisolated, but NSCollectionViewLayoutAttributes is @MainActor. The
    // fields therefore sit behind a Mutex, so nonisolated access is checked. Contention is negligible.
    private struct Fields { var section: GallerySection?; var filmCount = 0 }
    private nonisolated let fields = Mutex(Fields())

    nonisolated var section: GallerySection? {
        get { fields.withLock { $0.section } }
        set { fields.withLock { $0.section = newValue } }
    }
    nonisolated var filmCount: Int {
        get { fields.withLock { $0.filmCount } }
        set { fields.withLock { $0.filmCount = newValue } }
    }

    // Copies must carry `section`. Without it, a copy would read as "no label" at unpredictable moments.
    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        if let copy = copy as? SectionDividerLayoutAttributes {
            let current = fields.withLock { $0 }
            copy.fields.withLock { $0 = current }
        }
        return copy
    }

    // Equality must include the band's identity, not just its rectangle. Otherwise AppKit would skip re-applying a
    // relabeled band whose frame did not change.
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SectionDividerLayoutAttributes else { return false }
        return super.isEqual(object) && other.section == section && other.filmCount == filmCount
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(super.hash)
        hasher.combine(section)
        hasher.combine(filmCount)
        return hasher.finalize()
    }
}

/// The section-divider band's content: a bold section label above a hairline separator, bottom-anchored within
/// the full-height band the layout allocates. It draws no background and does not intercept hits, so a marquee that
/// starts on a divider behaves as it would on empty grid padding.
final class SectionDividerDecorationView: NSView, NSCollectionViewElement {
    private let sectionLabel = NSTextField(labelWithString: "")
    private let filmCountLabel = NSTextField(labelWithString: "")
    // A custom hairline view, since NSBox's separator draws at a fixed thickness.
    private let separatorLine = NSView()
    private static let separatorThickness: CGFloat = 2.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // A new CALayer's backgroundColor is already transparent, so no clear color is set.
        wantsLayer = true
        setUpSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUpSubviews() {
        sectionLabel.font = .systemFont(ofSize: 20, weight: .bold)
        sectionLabel.textColor = .labelColor
        sectionLabel.alignment = .left
        sectionLabel.lineBreakMode = .byTruncatingTail
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sectionLabel)

        filmCountLabel.font = .systemFont(ofSize: 10, weight: .regular)
        filmCountLabel.textColor = .secondaryLabelColor
        filmCountLabel.alignment = .right
        filmCountLabel.lineBreakMode = .byTruncatingTail
        filmCountLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filmCountLabel)

        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separatorLine)

        NSLayoutConstraint.activate([
            separatorLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorLine.heightAnchor.constraint(equalToConstant: Self.separatorThickness),

            sectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            sectionLabel.bottomAnchor.constraint(equalTo: separatorLine.topAnchor, constant: -6),

            filmCountLabel.leadingAnchor.constraint(greaterThanOrEqualTo: sectionLabel.trailingAnchor, constant: 8),
            filmCountLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            filmCountLabel.lastBaselineAnchor.constraint(equalTo: sectionLabel.lastBaselineAnchor)
        ])
    }

    // Resolved once in viewDidMoveToSuperview(), not on every reposition. It is weak because this view does not own
    // the layout.
    private weak var cachedLayout: SmoothResizingGridLayout?

    // AppKit sets `frame` from the layout's attributes. layout() does not reliably re-fire when only the origin moves,
    // which happens when a recycled divider view is reused for another row. Overriding setFrameOrigin and setFrameSize
    // refreshes the label on every reposition, so a recycled view never shows a stale name.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        refreshSectionLabel()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshSectionLabel()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        cachedLayout = resolveLayout()
        refreshSectionLabel()
    }

    /// Walks up to the owning layout. It is split out so refreshSectionLabel can retry it. If the first walk runs before
    /// the view is inside its scroll view, `cachedLayout` would stay nil for the view's whole life.
    private func resolveLayout() -> SmoothResizingGridLayout? {
        (enclosingScrollView?.documentView as? NSCollectionView)?
            .collectionViewLayout as? SmoothResizingGridLayout
    }

    // apply(_:) runs whenever AppKit re-applies attributes. That can happen with no frame change, such as when a film
    // moves between two other sections. The frame setters would miss that, so this hook also refreshes the label. It
    // short-circuits when the text is unchanged.
    func apply(_ layoutAttributes: NSCollectionViewLayoutAttributes) {
        // The authoritative path. The attributes carry the identity, so no layout lookup or geometry is needed.
        guard let attrs = layoutAttributes as? SectionDividerLayoutAttributes,
              let section = attrs.section else { return }
        setLabels(section: section, filmCount: attrs.filmCount)
    }

    // A CALayer color does not follow appearance changes, so it is re-resolved when the appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        separatorLine.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    /// Forces this band to re-read its identity from the layout. AppKit may or may not re-apply attributes for a
    /// relabeled band that keeps its frame, so this makes the refresh unconditional. The gallery calls it on each update
    /// pass once the collection view has laid out. Idle cost is one string comparison per visible band.
    func refreshFromLayout() {
        refreshSectionLabel()
    }

    /// Frame-driven fallback. It is the only path that relies on AppKit setting the frame from the attributes. It
    /// resolves from `dividerRows`, the same array `dividerAttributes` uses, so it always agrees with `apply(_:)`.
    private func refreshSectionLabel() {
        // Re-resolve if the walk at insertion time came up empty.
        if cachedLayout == nil { cachedLayout = resolveLayout() }
        guard let layout = cachedLayout, let section = layout.section(atDividerY: frame.minY) else { return }
        setLabels(section: section, filmCount: layout.filmCount(atDividerY: frame.minY) ?? 0)
    }

    /// The single writer for both labels. It skips the update when the text is unchanged.
    private func setLabels(section: GallerySection, filmCount: Int) {
        let text = section.displayName
        if sectionLabel.stringValue != text { sectionLabel.stringValue = text }

        let countText = UpNextSlots.sectionCountText(section: section, filmCount: filmCount)
        if filmCountLabel.stringValue != countText { filmCountLabel.stringValue = countText }
    }

    // Purely decorative — never intercept clicks/drags. See the type's doc comment.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Smooth Resizing Grid Layout
final class SmoothResizingGridLayout: NSCollectionViewLayout {
    // Fixed layout constants. They are `let`, since nothing configures them. GallerySubview reads them from the layout
    // for its scroll math, so the two cannot drift apart.
    let edgeInset: CGFloat = 16
    let itemSpacing: CGFloat = 16
    let lineSpacing: CGFloat = 16
    // Extra bottom padding for StatusBar. updateNSView rewrites it when the StatusBar is shown or hidden.
    var bottomInset: CGFloat = 0

    // Configurable by Coordinator when settings change.
    var hasSubtitles: Bool = false

    // Grid computation constants.
    private let minItemWidth: CGFloat = Preferences.galleryMinItemWidth
    // Set by GallerySubview from the largeGalleryGrid preference. The default is 7 columns; true gives 6.
    var maxColumns: Int = Preferences.galleryMaxColumns
    private let maxGridWidth: CGFloat = Preferences.galleryMaxGridWidth

    // Computed layout state — populated during prepare(), readable externally.
    private(set) var containerWidth: CGFloat = 0
    private(set) var columnsPerRow: Int = 1
    // There is no `itemWidth` property. The floored per-column width would be confused with the exact average the
    // vertical math uses. Column widths also vary by a backing pixel, so colWPx is the only authoritative width.
    private(set) var itemHeight: CGFloat = 150
    private(set) var gridOffsetX: CGFloat = 0
    private(set) var effectiveGridWidth: CGFloat = 0

    // MARK: - Section Dividers

    /// A single section-boundary break point, in the flat real-item index space. Dividers are not part of that space.
    /// See the Section Divider Decoration section above. `index` is the first real-item index of `section`'s run.
    /// divider band is inserted immediately before it — including at index 0, which labels the
    /// very first section the same way every later one is labeled. Set by
    /// GallerySubview.Coordinator.updateSectionDividers() from the current films array whenever
    /// the displayed contents change; empty whenever no bands apply at all, so the entire
    /// divider mechanism stays inert in that case. Must be sorted ascending by
    /// `index` — the Coordinator always hands these in that order, and rebuildSegments()
    /// defensively ignores any entry that doesn't advance past the point already reached.
    struct SectionBreak: Equatable {
        let index: Int
        let section: GallerySection
    }
    var sectionBreaks: [SectionBreak] = []

    // MARK: - "Up Next" Slots
    //
    // The Film Queue's "All" tab follows the "Up Next" films with empty placeholder slots,
    // one per vacancy up to FilmQueue.upNextCapacity (UpNextSlots.swift). They are laid
    // out exactly like cells, continuing the "Up Next" run's rows, but are decoration views
    // rather than items: the film index space, selection, marquee, drag and Left/Right
    // navigation never see them. Up/Down navigation steps over a row holding only slots
    // the same way it steps over a divider band. Nil everywhere else, which leaves every
    // other gallery's geometry exactly as it was.

    /// Where the slots go. `itemIndex` is the real-item index they follow (the end of the
    /// "Up Next" run); `firstNumber` is the 1-based slot number of the first one. When
    /// "Up Next" has no films, `leadingSection` is its band, drawn above the slots (the
    /// sectioning emits no band for an empty section).
    struct SlotRun: Equatable {
        let itemIndex: Int
        let firstNumber: Int
        let count: Int
        let leadingSection: GallerySection?
    }
    var slotRun: SlotRun?

    /// Fixed height for a section-divider band — deliberately independent of `itemHeight` (the
    /// poster tile height, which tracks window width continuously). The label + line are a
    /// constant size and bottom-anchored within their band; a fixed band height means the label
    /// sits at a constant offset from the band's edges throughout any resize, so only its
    /// absolute on-screen position moves (because content above it still grows/shrinks) —
    /// exactly the way any row's position moves during a resize — rather than the label
    /// appearing to "jump" within a stretching band. `let` for the same reason as the
    /// spacing constants above: nothing outside this class has ever assigned it.
    let dividerHeight: CGFloat = 46

    /// True when at least one section-divider band is currently laid out. Read by arrow-key
    /// navigation to choose between
    /// the divider-aware row/column stepping and the plain uniform-grid arithmetic, guaranteeing
    /// the latter is byte-for-byte unchanged for every non-divider grid.
    var hasSectionDividers: Bool { !dividerRows.isEmpty }

    /// Scroll correction computed during prepare() for viewport anchoring.
    var pendingScrollCorrection: NSPoint? = nil

    // Grid geometry stored per prepare() pass for on-demand attribute computation.
    // On-demand means layoutAttributesForItem(at:) and layoutAttributesForElements(in:)
    // synthesize NSCollectionViewLayoutAttributes from this geometry rather than reading
    // from a pre-built N-element cache. This makes prepare() O(1) in item count instead
    // of O(N), eliminating the dominant main-thread cost that was blocking CoreAnimation's
    // menu dismissal animation during gallery reloads on large libraries.
    private var itemCount: Int = 0
    private var colXPx: [Int] = []   // X origin in backing pixels for each column (max 7)
    private var colWPx: [Int] = []   // Width in backing pixels for each column (max 7)
    private var gridOffsetPx: Int = 0
    private var rowStride: CGFloat = 0
    private var layoutScale: CGFloat = 2.0
    private var contentHeight: CGFloat = 0

    // Previous layout state for viewport anchoring across prepare() calls.
    private var prevColumnsPerRow: Int = 0
    private var prevItemHeight: CGFloat = 0

    // MARK: Section-Divider Geometry (rebuilt per prepare() pass)
    //
    // A maximal run of consecutive real items (all part of the same section run, or the entire
    // grid when there are no section breaks at all) that occupies contiguous rows starting at
    // `rowStart` (an abstract row index — used only for arrow-key navigation, which cares purely
    // about row counting, never pixel heights) and, in on-screen pixels, begins at `yStart`.
    private struct Segment {
        let itemStart: Int   // inclusive
        let itemEnd: Int     // exclusive
        let rowStart: Int    // abstract row index (navigation only)
        let rowCount: Int    // number of content rows this segment occupies
        let yStart: CGFloat  // on-screen Y where this segment's first row begins
        var slotCount = 0    // "Up Next" slots laid out after the segment's items
        var slotFirstNumber = 0
    }
    private struct DividerRow {
        let row: Int             // abstract row index (navigation only)
        let section: GallerySection
        let y: CGFloat           // on-screen Y where this divider band begins
        let itemIndex: Int       // the real-item index (SectionBreak.index) this band precedes
    }
    private var segments: [Segment] = []
    private var dividerRows: [DividerRow] = []
    /// O(1) test for whether a row is a divider row. It works on abstract row indexes, not pixels.
    private var dividerRowSet: Set<Int> = []
    // There is no stored `totalRowCount`. The `count > 0` guard in layoutAttributesForElements(in:) is equivalent
    // to `itemCount > 0`, so no extra field needs syncing.
    /// The running-Y accumulator's end after the last band, before the bottom inset and StatusBar reservation. It is
    /// stored so contentHeight is derived once.
    private var contentBodyEndY: CGFloat = 0

    @MainActor
    override func prepare() {
        super.prepare()

        guard let cv = collectionView else {
            resetToEmpty()
            return
        }

        let count = cv.numberOfItems(inSection: 0)
        guard count > 0 else {
            resetToEmpty()
            return
        }
        LaunchTimeline.mark("layoutFirstPrepare")

        let scrollWidth = cv.enclosingScrollView?.bounds.width ?? cv.bounds.width
        let scale = unsafe cv.window?.backingScaleFactor ?? 2.0

        // === Capture viewport anchor from the previous layout ===
        // Records the item at the top of the viewport and its pixel offset. After the new layout is computed, the
        // scroll correction is calculated from where that item now sits. `segments` and `dividerRows` still hold the
        // previous values here, so the search uses the geometry the viewport was last drawn with. With no dividers,
        // this is the single-segment row math.
        let anchor: (itemIndex: Int, viewportOffset: CGFloat)?
        if let scrollView = cv.enclosingScrollView,
           prevColumnsPerRow > 0, prevItemHeight > 0 {
            let visibleRect = scrollView.documentVisibleRect
            let oldRowStride = prevItemHeight + lineSpacing
            // Skip anchoring near the top, where items resize in place from the top edge.
            if visibleRect.minY > 1.0, oldRowStride > 0,
               let (anchorIdx, anchorY) = Self.anchorItem(atY: visibleRect.minY,
                                                          segments: segments,
                                                          dividerRows: dividerRows,
                                                          rowStride: oldRowStride,
                                                          columnsPerRow: prevColumnsPerRow),
               anchorIdx < count {
                anchor = (itemIndex: anchorIdx, viewportOffset: anchorY - visibleRect.minY)
            } else { anchor = nil }
        } else { anchor = nil }

        // === Compute new layout ===
        // Horizontal: integer backing-pixel math. The remainder is spread so the first columns get one extra backing
        // pixel, which removes horizontal jiggle during resize.
        // Vertical: exact fractional math, so item height tracks the width continuously with no stepping.
        // CATransaction.setDisableActions(true) in WidthObservingScrollView stops Core Animation from interpolating
        // between frames during resize.

        containerWidth = scrollWidth

        // Column count, in points.
        let availableWidth = scrollWidth - (edgeInset * 2)
        let theoreticalColumns = Int(floor((availableWidth + itemSpacing) / (minItemWidth + itemSpacing)))
        columnsPerRow = min(max(1, theoreticalColumns), maxColumns)

        // Converts fixed spacings to backing pixels.
        let edgePx = Int(edgeInset * scale)
        let spacingPx = Int(itemSpacing * scale)

        // Total backing pixels, and the fixed and flexible portions.
        let totalPx = Int(round(scrollWidth * scale))
        let fixedPx = 2 * edgePx + max(0, columnsPerRow - 1) * spacingPx
        var itemTotalPx = max(columnsPerRow, totalPx - fixedPx)
        var computedGridOffsetPx = 0

        // Applies the maximum grid width.
        let maxGridPx = Int(maxGridWidth * scale)
        let uncappedGridPx = fixedPx + itemTotalPx

        if uncappedGridPx > maxGridPx {
            itemTotalPx = max(columnsPerRow, maxGridPx - fixedPx)
            let actualGridPx = fixedPx + itemTotalPx
            computedGridOffsetPx = (totalPx - actualGridPx) / 2
        }

        // Bresenham distribution: the first `remainder` columns get one extra pixel.
        let baseItemPx = itemTotalPx / columnsPerRow
        let remainder = itemTotalPx % columnsPerRow

        // Column X positions and widths are stored so that attributes can be built on demand. The arrays are cleared
        // with keepingCapacity to avoid reallocating every frame during a continuous resize. Capacity is bounded by
        // maxColumns, so the retained storage is small.
        colXPx.removeAll(keepingCapacity: true)
        colWPx.removeAll(keepingCapacity: true)
        colXPx.reserveCapacity(columnsPerRow)
        colWPx.reserveCapacity(columnsPerRow)
        var xAccum = edgePx
        for col in 0..<columnsPerRow {
            let w = baseItemPx + (col < remainder ? 1 : 0)
            colXPx.append(xAccum)
            colWPx.append(w)
            xAccum += w + spacingPx
        }

        gridOffsetX = CGFloat(computedGridOffsetPx) / scale
        effectiveGridWidth = CGFloat(fixedPx + itemTotalPx) / scale

        // Vertical: exact fractional math from the precise average item width.
        let exactItemPts = CGFloat(itemTotalPx) / (CGFloat(columnsPerRow) * scale)
        let posterHeight = exactItemPts * GalleryTileGeometry.posterHeightMultiplier
        let subtitleHeight: CGFloat = hasSubtitles ? 20 : 0
        itemHeight = posterHeight + subtitleHeight

        // Stores geometry for on-demand attribute synthesis.
        itemCount = count
        rowStride = itemHeight + lineSpacing
        gridOffsetPx = computedGridOffsetPx
        layoutScale = scale

        // === Build segments and section-divider rows from sectionBreaks ===
        // With no section breaks, this produces one full-grid segment and no divider rows, so all geometry below matches
        // the grid without dividers. Segment count follows the number of sections, not the number of items.
        rebuildSegments(count: count)

        // Content height is the accumulator's end plus the bottom inset and StatusBar reservation. With no dividers,
        // this matches the closed-form grid height.
        contentHeight = contentBodyEndY + edgeInset + bottomInset

        // === Compute viewport anchor correction ===
        // The anchored item's new Y comes from makeAttributes, which is segment-aware.
        if let anchor = anchor, let scrollView = cv.enclosingScrollView,
           let newAttrs = makeAttributes(for: anchor.itemIndex) {
            let newItemY = newAttrs.frame.minY
            let targetScrollY = newItemY - anchor.viewportOffset
            let maxScrollY = max(0, contentHeight - scrollView.documentVisibleRect.height)
            let clampedY = max(0, min(targetScrollY, maxScrollY))
            var origin = scrollView.contentView.bounds.origin
            if abs(origin.y - clampedY) > 0.5 {
                origin.y = clampedY
                pendingScrollCorrection = origin
            }
        }

        prevColumnsPerRow = columnsPerRow
        prevItemHeight = itemHeight
    }

    /// Clears all geometry to the empty state, so no stale segments or divider bands remain once the view is empty.
    private func resetToEmpty() {
        itemCount = 0
        contentHeight = 0
        contentBodyEndY = 0
        segments.removeAll(keepingCapacity: true)
        dividerRows.removeAll(keepingCapacity: true)
        dividerRowSet.removeAll(keepingCapacity: true)
    }

    /// Rebuilds `segments`, `dividerRows`, `dividerRowSet`, and `contentBodyEndY` from `sectionBreaks`. Each band
    /// adds one `lineSpacing` gap before it, except the first. Arrays keep their capacity so a resize does not allocate.
    private func rebuildSegments(count: Int) {
        var currentItemStart = 0
        var currentRow = 0
        var currentY: CGFloat = edgeInset
        var isFirstBand = true

        func advanceForRows(_ n: Int) -> CGFloat {
            guard n > 0 else { return currentY }
            if !isFirstBand { currentY += lineSpacing }
            let start = currentY
            currentY += CGFloat(n) * itemHeight + CGFloat(max(0, n - 1)) * lineSpacing
            isFirstBand = false
            return start
        }
        func advanceForDivider() -> CGFloat {
            if !isFirstBand { currentY += lineSpacing }
            let start = currentY
            currentY += dividerHeight
            isFirstBand = false
            return start
        }

        segments.removeAll(keepingCapacity: true)
        dividerRows.removeAll(keepingCapacity: true)
        dividerRowSet.removeAll(keepingCapacity: true)

        // "Up Next" slots go to the segment that ends where the run says.
        var pendingSlots = (columnsPerRow > 0 ? slotRun : nil).flatMap { $0.count > 0 ? $0 : nil }
        func rows(items: Int, slots: Int) -> Int {
            let total = items + slots
            return total > 0 ? (total + columnsPerRow - 1) / columnsPerRow : 0
        }
        func takeSlots(endingAt end: Int) -> (count: Int, first: Int) {
            guard let run = pendingSlots, run.itemIndex == end else { return (0, 0) }
            pendingSlots = nil
            return (run.count, run.firstNumber)
        }
        // An empty "Up Next" still shows its band and slots, ahead of the rest.
        if let run = pendingSlots, let section = run.leadingSection, run.itemIndex == 0 {
            pendingSlots = nil
            let divY = advanceForDivider()
            dividerRows.append(DividerRow(row: currentRow, section: section, y: divY, itemIndex: 0))
            dividerRowSet.insert(currentRow)
            currentRow += 1
            let slotRows = rows(items: 0, slots: run.count)
            let segY = advanceForRows(slotRows)
            segments.append(Segment(itemStart: 0, itemEnd: 0, rowStart: currentRow,
                                    rowCount: slotRows, yStart: segY,
                                    slotCount: run.count, slotFirstNumber: run.firstNumber))
            currentRow += slotRows
        }

        // Walk sectionBreaks only when the column count is known. prepare() already guards against zero items.
        if columnsPerRow > 0 {
            // `lastBreakIndex` enforces that each break index strictly advances. A repeated index would stack an empty band
            // on the previous one. GallerySectioning never emits one, and the list style drops any remaining breaks, so both
            // consumers agree on malformed input.
            var lastBreakIndex = -1
            for brk in sectionBreaks {
                guard brk.index > lastBreakIndex, brk.index >= currentItemStart,
                      brk.index < count else { continue }
                lastBreakIndex = brk.index
                if brk.index > currentItemStart {
                    let segLen = brk.index - currentItemStart
                    let slots = takeSlots(endingAt: brk.index)
                    let rows = rows(items: segLen, slots: slots.count)
                    let segY = advanceForRows(rows)
                    segments.append(Segment(itemStart: currentItemStart, itemEnd: brk.index,
                                            rowStart: currentRow, rowCount: rows, yStart: segY,
                                            slotCount: slots.count, slotFirstNumber: slots.first))
                    currentRow += rows
                }
                let divY = advanceForDivider()
                dividerRows.append(DividerRow(row: currentRow, section: brk.section,
                                              y: divY, itemIndex: brk.index))
                dividerRowSet.insert(currentRow)
                currentRow += 1
                currentItemStart = brk.index
            }
        }

        let lastLen = count - currentItemStart
        let lastSlots = lastLen > 0 ? takeSlots(endingAt: count) : (count: 0, first: 0)
        let lastRows = columnsPerRow > 0 ? rows(items: lastLen, slots: lastSlots.count) : 0
        let lastY = advanceForRows(lastRows)
        segments.append(Segment(itemStart: currentItemStart, itemEnd: count,
                                rowStart: currentRow, rowCount: lastRows, yStart: lastY,
                                slotCount: lastSlots.count, slotFirstNumber: lastSlots.first))
        // No trailing `currentRow += lastRows`: nothing reads the accumulator after the final segment.

        contentBodyEndY = currentY
    }

    // MARK: - On-Demand Attribute Synthesis
    //
    // Attributes are built at query time rather than for every item in prepare(). A large library would otherwise
    // allocate thousands of layout attribute objects on each reloadData(). Only the attributes AppKit requests are built.
    /// Computes layout attributes for one item index from the stored geometry. Returns nil if the index is out of range
    /// or the grid is not prepared. The Y value comes from the containing segment's `yStart`, so later sections move
    /// down correctly around dividers.
    private func makeAttributes(for index: Int) -> NSCollectionViewLayoutAttributes? {
        guard index >= 0, index < itemCount, columnsPerRow > 0, rowStride > 0,
              let seg = segment(containing: index), index < seg.itemEnd else {
            return nil
        }
        let local = index - seg.itemStart
        let localRow = local / columnsPerRow
        let col = local % columnsPerRow
        let attrs = NSCollectionViewLayoutAttributes(
            forItemWith: IndexPath(item: index, section: 0))
        attrs.frame = NSRect(
            x: CGFloat(gridOffsetPx + colXPx[col]) / layoutScale,
            y: seg.yStart + CGFloat(localRow) * rowStride,
            width: CGFloat(colWPx[col]) / layoutScale,
            height: itemHeight)
        return attrs
    }

    /// Finds the segment covering real-item `index` by binary search. The segment count follows the number of sections,
    /// not the number of items, so this stays cheap.
    private func segment(containing index: Int) -> Segment? {
        var lo = 0, hi = segments.count - 1, result: Segment?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if segments[mid].itemStart <= index {
                result = segments[mid]
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return result
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: containerWidth, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard itemCount > 0, columnsPerRow > 0, rowStride > 0 else { return [] }

        var result: [NSCollectionViewLayoutAttributes] = []

        // Section-divider bands. dividerRows is empty where no bands apply, so this block is skipped. Both arrays are
        // Y-ascending, so a binary search finds the first band that could be visible.
        if !dividerRows.isEmpty {
            let startDividerIdx = firstDividerIndex(reaching: rect.minY)
            for ordinal in startDividerIdx..<dividerRows.count {
                let divider = dividerRows[ordinal]
                guard divider.y < rect.maxY else { break }
                if let attrs = dividerAttributes(atOrdinal: ordinal), attrs.frame.intersects(rect) {
                    result.append(attrs)
                }
            }
        }

        // "Up Next" slot decorations.
        if slotRun != nil {
            for seg in segments where seg.slotCount > 0 {
                for slot in 0..<seg.slotCount {
                    if let attrs = slotAttributes(in: seg, slot: slot), attrs.frame.intersects(rect) {
                        result.append(attrs)
                    }
                }
            }
        }

        // Item cells are scanned segment by segment. With no dividers there is one segment, which gives the single
        // contiguous row scan.
        let startSegIdx = dividerRows.isEmpty ? 0 : firstSegmentIndex(reaching: rect.minY)
        for segIdx in startSegIdx..<segments.count {
            let seg = segments[segIdx]
            guard seg.yStart < rect.maxY else { break }
            guard seg.rowCount > 0 else { continue }
            let localFirstRow = max(0, Int(floor((rect.minY - seg.yStart) / rowStride)))
            let localLastRow = min(seg.rowCount - 1, Int(floor((rect.maxY - seg.yStart) / rowStride)))
            guard localFirstRow <= localLastRow else { continue }
            for localRow in localFirstRow...localLastRow {
                let rowItemStart = seg.itemStart + localRow * columnsPerRow
                let rowItemEnd = min(rowItemStart + columnsPerRow, seg.itemEnd)
                guard rowItemStart < rowItemEnd else { continue }
                for index in rowItemStart..<rowItemEnd {
                    if let attrs = makeAttributes(for: index), attrs.frame.intersects(rect) {
                        result.append(attrs)
                    }
                }
            }
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        makeAttributes(for: indexPath.item)
    }

    override func layoutAttributesForDecorationView(ofKind elementKind: String,
                                                    at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        if elementKind == upNextSlotDecorationKind {
            guard let seg = segments.first(where: { $0.slotCount > 0 }),
                  indexPath.item >= seg.slotFirstNumber,
                  indexPath.item < seg.slotFirstNumber + seg.slotCount else { return nil }
            return slotAttributes(in: seg, slot: indexPath.item - seg.slotFirstNumber)
        }
        guard elementKind == sectionDividerDecorationKind else { return nil }
        return dividerAttributes(atOrdinal: indexPath.item)
    }

    /// Attributes for the `slot`th placeholder: the cell frame the next item would have had. Slots are indexed by
    /// number, so a slot keeps its identity as films come and go.
    private func slotAttributes(in seg: Segment, slot: Int) -> NSCollectionViewLayoutAttributes? {
        guard columnsPerRow > 0, slot >= 0, slot < seg.slotCount else { return nil }
        let local = (seg.itemEnd - seg.itemStart) + slot
        let col = local % columnsPerRow
        let number = seg.slotFirstNumber + slot
        let attrs = UpNextSlotLayoutAttributes(forDecorationViewOfKind: upNextSlotDecorationKind,
                                               with: IndexPath(item: number, section: 0))
        attrs.frame = NSRect(
            x: CGFloat(gridOffsetPx + colXPx[col]) / layoutScale,
            y: seg.yStart + CGFloat(local / columnsPerRow) * rowStride,
            width: CGFloat(colWPx[col]) / layoutScale,
            height: itemHeight)
        attrs.slotNumber = number
        attrs.hasSubtitles = hasSubtitles
        return attrs
    }

    /// True when `row` holds only "Up Next" slots, so Up and Down navigation steps over it like a divider band.
    func isSlotOnlyRow(_ row: Int) -> Bool {
        guard columnsPerRow > 0,
              let seg = segments.last(where: { row >= $0.rowStart && $0.slotCount > 0 }),
              row < seg.rowStart + seg.rowCount else { return false }
        return seg.itemStart + (row - seg.rowStart) * columnsPerRow >= seg.itemEnd
    }

    // MARK: - Section-Divider Lookup & Attribute Synthesis

    /// Builds decoration attributes for the divider at `ordinal` in `dividerRows`. The band spans the same width and
    /// centering as the item grid, less the edge inset, and has a fixed `dividerHeight`.
    private func dividerAttributes(atOrdinal ordinal: Int) -> NSCollectionViewLayoutAttributes? {
        guard ordinal >= 0, ordinal < dividerRows.count else { return nil }
        let divider = dividerRows[ordinal]
        let attrs = SectionDividerLayoutAttributes(
            forDecorationViewOfKind: sectionDividerDecorationKind,
            with: IndexPath(item: ordinal, section: 0))
        attrs.frame = NSRect(
            x: gridOffsetX + edgeInset,
            y: divider.y,
            width: max(0, effectiveGridWidth - 2 * edgeInset),
            height: dividerHeight)
        // The identity is carried on the attributes, not looked up from the frame. See SectionDividerLayoutAttributes.
        attrs.section = divider.section
        attrs.filmCount = filmCount(atOrdinal: ordinal)
        return attrs
    }

    /// Resolves the section a divider view should display from its frame's Y origin. The match is exact, since both
    /// the lookup and the frame come from the same stored value. Used by SectionDividerDecorationView.refreshSectionLabel().
    func section(atDividerY y: CGFloat) -> GallerySection? {
        dividerRows.first(where: { abs($0.y - y) < 0.5 })?.section
    }

    /// Resolves the number of films in the section at divider `y`, for the band's count label. It is the span from this
    /// divider's `itemIndex` to the next one (or `itemCount` for the last section). That always matches the items rendered.
    func filmCount(atDividerY y: CGFloat) -> Int? {
        guard let ordinal = dividerRows.firstIndex(where: { abs($0.y - y) < 0.5 }) else { return nil }
        return filmCount(atOrdinal: ordinal)
    }

    /// The span computation, addressed by ordinal. `dividerAttributes` calls it directly. The arithmetic lives in
    /// GallerySectioning.bandFilmCount, which the list style shares, so both gallery styles compute the same count.
    func filmCount(atOrdinal ordinal: Int) -> Int {
        guard ordinal >= 0, ordinal < dividerRows.count else { return 0 }
        let next = (ordinal + 1) < dividerRows.count ? dividerRows[ordinal + 1].itemIndex : nil
        return GallerySectioning.bandFilmCount(from: dividerRows[ordinal].itemIndex,
                                               nextBandIndex: next,
                                               totalCount: itemCount)
    }

    /// The on-screen Y where the divider band before `itemIndex` begins, or nil if no band precedes it. The Sort menu's
    /// "Jump to Section" uses it to place the band's top edge at the top of the viewport.
    func dividerY(forItemIndex itemIndex: Int) -> CGFloat? {
        // Last match wins: an empty "Up Next" band shares index 0 with the band after it.
        dividerRows.last(where: { $0.itemIndex == itemIndex })?.y
    }

    /// Binary-search index of the first divider whose band can reach down to `minY`. Band height is constant, so
    /// `y + dividerHeight` is non-decreasing, which makes the search valid.
    private func firstDividerIndex(reaching minY: CGFloat) -> Int {
        var lo = 0, hi = dividerRows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if dividerRows[mid].y + dividerHeight <= minY { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Binary-search index of the first segment whose rows can reach down to `minY`. Segments are Y-ascending,
    /// so this is a valid lower-bound search, like firstDividerIndex.
    private func firstSegmentIndex(reaching minY: CGFloat) -> Int {
        var lo = 0, hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let seg = segments[mid]
            let segEnd = seg.yStart + CGFloat(seg.rowCount) * itemHeight
                       + CGFloat(max(0, seg.rowCount - 1)) * lineSpacing
            if segEnd <= minY { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: - Arrow-Key Navigation Support (divider-aware)

    /// Returns the (row, col) grid coordinate for a real item index. A partial row before a divider or the grid's
    /// trailing partial row is counted correctly. Arrow-key navigation uses this to find its origin.
    func rowColumn(forItemIndex index: Int) -> (row: Int, col: Int)? {
        guard columnsPerRow > 0, let seg = segment(containing: index), index < seg.itemEnd else { return nil }
        let local = index - seg.itemStart
        return (row: seg.rowStart + local / columnsPerRow, col: local % columnsPerRow)
    }

    /// Returns the real item index at (row, col), or nil for a divider row, a missing row, or a column with no item.
    func itemIndex(atRow row: Int, col: Int) -> Int? {
        guard row >= 0, col >= 0, col < columnsPerRow, columnsPerRow > 0,
              !dividerRowSet.contains(row),
              let seg = segments.last(where: { row >= $0.rowStart })
        else { return nil }
        let localRow = row - seg.rowStart
        let index = seg.itemStart + localRow * columnsPerRow + col
        guard index >= seg.itemStart, index < seg.itemEnd else { return nil }
        return index
    }

    /// True when `row` is a divider band's row. Navigation hops over it, rather than clamping into a shorter content row.
    func isDividerRow(_ row: Int) -> Bool {
        dividerRowSet.contains(row)
    }

    /// Returns the real item index at the last populated column of content `row`. Returns nil if the row does not
    /// exist or is a divider. Arrow navigation uses it to land on the nearest item in a shorter row.
    func lastItemIndex(inRow row: Int) -> Int? {
        guard row >= 0, columnsPerRow > 0,
              !dividerRowSet.contains(row),
              let seg = segments.last(where: { row >= $0.rowStart })
        else { return nil }
        let localRow = row - seg.rowStart
        let rowStart = seg.itemStart + localRow * columnsPerRow
        guard rowStart < seg.itemEnd else { return nil }
        let rowEnd = min(rowStart + columnsPerRow, seg.itemEnd)
        return rowEnd - 1
    }

    /// Finds the real item at column 0 of the content row whose band contains pixel position `y`. It searches the
    /// geometry passed in, so prepare()'s anchor capture can read the previous pass. Returns nil on a divider band, and
    /// no correction is applied. The walk is allocation-free, since it runs on every resize frame.
    private static func anchorItem(atY y: CGFloat, segments: [Segment], dividerRows: [DividerRow],
                                   rowStride: CGFloat, columnsPerRow: Int) -> (index: Int, y: CGFloat)? {
        guard rowStride > 0, columnsPerRow > 0 else { return nil }

        func resolve(_ seg: Segment) -> (index: Int, y: CGFloat)? {
            guard seg.rowCount > 0 else { return nil }
            let localRow = min(seg.rowCount - 1, max(0, Int(floor((y - seg.yStart) / rowStride))))
            let index = seg.itemStart + localRow * columnsPerRow
            guard index < seg.itemEnd else { return nil }
            return (index: index, y: seg.yStart + CGFloat(localRow) * rowStride)
        }

        // Fast path with no dividers. segments has one entry, so this is a direct lookup.
        guard !dividerRows.isEmpty else {
            guard let seg = segments.first else { return nil }
            return resolve(seg)
        }

        var si = 0, di = 0
        var lastWasContent = false
        var lastSeg: Segment?
        while si < segments.count || di < dividerRows.count {
            let segY = si < segments.count ? segments[si].yStart : .greatestFiniteMagnitude
            let divY = di < dividerRows.count ? dividerRows[di].y : .greatestFiniteMagnitude
            if segY <= divY {
                guard segY <= y else { break }
                lastWasContent = true
                lastSeg = segments[si]
                si += 1
            } else {
                guard divY <= y else { break }
                lastWasContent = false
                di += 1
            }
        }
        guard lastWasContent, let seg = lastSeg else { return nil }
        return resolve(seg)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        // AppKit drives layout invalidation. When the scroll view resizes, prepare() runs once with the current bounds.
        abs(newBounds.width - containerWidth) > 0.01
    }
}
