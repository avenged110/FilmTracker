// MARK: - DragDropSupport.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Centralized drag-and-drop support for FilmTracker gallery items.
// Uses simple pasteboard types (no Info.plist registration required).

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Pasteboard Type

extension NSPasteboard.PasteboardType {
    /// Custom pasteboard type for FilmTracker film ID drags.
    /// This is a simple string identifier - no UTType registration needed.
    static let filmIDs = NSPasteboard.PasteboardType("com.filmTracker.filmIDs")
}

// MARK: - Film Drag Payload

/// Codable payload for dragged film IDs.
/// Conforms to Transferable for SwiftUI drop destinations.
struct FilmDragPayload: Codable, Transferable, Sendable {
    /// The UUIDs of the films being dragged.
    let filmIDs: [UUID]
    
    init(filmIDs: Set<UUID>) {
        self.filmIDs = Array(filmIDs)
    }
    
    /// Returns the film IDs as a Set for efficient operations.
    var filmIDSet: Set<UUID> {
        Set(filmIDs)
    }
    
    // MARK: - Transferable
    
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

// MARK: - Pasteboard Writer (for NSCollectionView drag source)

/// NSPasteboardWriting implementation for film drag data.
/// Allows NSCollectionView to write film IDs to the pasteboard during drag operations.
final class FilmDragPasteboardWriter: NSObject, NSPasteboardWriting, Loggable {
    nonisolated static let logTag = "[FilmDragPasteboardWriter]"

    let payload: FilmDragPayload
    
    init(filmIDs: Set<UUID>) {
        self.payload = FilmDragPayload(filmIDs: filmIDs)
        super.init()
    }
    
    // MARK: - NSPasteboardWriting
    
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        // Provide both our custom type and a standard JSON type for SwiftUI Transferable
        return [.filmIDs, .init(UTType.json.identifier)]
    }
    
    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        // Encode the payload as JSON for both types
        do {
            let encoder = JSONEncoder()
            return try encoder.encode(payload)
        } catch {
            Self.log("ERROR: Failed to encode drag payload: \(error)")
            return nil
        }
    }
}

// MARK: - Drag Data Decoder

/// Utility for decoding film drag data from pasteboards.
@MainActor
struct FilmDragDecoder: Loggable {
    nonisolated static let logTag = "[FilmDragDecoder]"
    
    /// Decodes film IDs from an NSPasteboard.
    static func decode(from pasteboard: NSPasteboard) -> Set<UUID>? {
        // Try our custom type first
        if let data = pasteboard.data(forType: .filmIDs) {
            return decodeData(data)
        }
        
        // Fall back to JSON type (for SwiftUI Transferable compatibility)
        if let data = pasteboard.data(forType: .init(UTType.json.identifier)) {
            return decodeData(data)
        }
        
        log("No film drag data found on pasteboard")
        return nil
    }
    
    /// Decodes film IDs from NSDraggingInfo.
    static func decode(from draggingInfo: any NSDraggingInfo) -> Set<UUID>? {
        return decode(from: draggingInfo.draggingPasteboard)
    }
    
    private static func decodeData(_ data: Data) -> Set<UUID>? {
        do {
            let decoder = JSONDecoder()
            let payload = try decoder.decode(FilmDragPayload.self, from: data)
            log("Decoded \(payload.filmIDs.count) film ID(s)")
            return payload.filmIDSet
        } catch {
            log("ERROR: Failed to decode drag payload: \(error)")
            return nil
        }
    }
}

// MARK: - Drag Image Provider

/// Provides drag images for film drag operations.
@MainActor
struct FilmDragImageProvider {
    
    /// Creates a semi-transparent drag image with a film count badge.
    /// This image represents all dragged items as a single "ghost" preview.
    /// The badge hangs partially off the bottom-right corner of the image.
    static func createDragImage(
        filmCount: Int,
        posterImage: NSImage? = nil,
        size: NSSize = NSSize(width: 80, height: 120)
    ) -> NSImage {
        // Badge overhang: portion of badge that extends beyond content area
        // Sized to accommodate badges with up to 5 digits (e.g., "99999")
        let badgeOverhang: CGFloat = 25
        
        // Expand canvas to accommodate badge overhang on right and bottom
        let canvasSize = NSSize(
            width: size.width + badgeOverhang,
            height: size.height + badgeOverhang
        )
        
        let image = NSImage(size: canvasSize)
        
        image.lockFocus()
        
        // Enable anti-aliasing for smooth edges
        NSGraphicsContext.current?.imageInterpolation = .high
        
        // Content area is shifted up to make room for badge below
        let contentRect = NSRect(
            x: 0,
            y: badgeOverhang,
            width: size.width,
            height: size.height
        )
        
        let cornerRadius: CGFloat = 6
        let insetRect = contentRect.insetBy(dx: 2, dy: 2)
        
        // Create clipping path for rounded corners (continuous, like the gallery's posters)
        let clipPath = NSBezierPath(cgPath: CGPath.continuousRoundedRect(insetRect, cornerRadius: cornerRadius))
        
        if let poster = posterImage {
            // Draw poster with semi-transparency (ghost effect)
            NSGraphicsContext.saveGraphicsState()
            clipPath.addClip()
            poster.draw(in: insetRect,
                       from: NSRect(origin: .zero, size: poster.size),
                       operation: .sourceOver,
                       fraction: 0.8)  // Semi-transparent ghost effect
            NSGraphicsContext.restoreGraphicsState()
        } else {
            // Draw placeholder background
            NSGraphicsContext.saveGraphicsState()
            clipPath.addClip()
            NSColor.controlBackgroundColor.withAlphaComponent(0.8).setFill()
            insetRect.fill()
            NSGraphicsContext.restoreGraphicsState()
            
            // Draw film icon centered
            if let icon = NSImage(systemSymbolName: "film.fill", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
                let configuredIcon = icon.withSymbolConfiguration(config) ?? icon
                let iconSize = configuredIcon.size
                let iconRect = NSRect(
                    x: (size.width - iconSize.width) / 2,
                    y: badgeOverhang + (size.height - iconSize.height) / 2,
                    width: iconSize.width,
                    height: iconSize.height
                )
                configuredIcon.draw(in: iconRect,
                                   from: NSRect(origin: .zero, size: configuredIcon.size),
                                   operation: .sourceOver,
                                   fraction: 0.5)
            }
        }
        
        // Draw subtle border
        NSColor.black.withAlphaComponent(0.2).setStroke()
        clipPath.lineWidth = 1
        clipPath.stroke()
        
        // Always draw count badge (positioned at bottom-right corner)
        drawCountBadge(count: filmCount, contentRect: contentRect)
        
        image.unlockFocus()
        
        return image
    }
    
    /// Draws a count badge at the bottom-right corner of the content area.
    /// The badge hangs partially inside and partially outside the content bounds.
    private static func drawCountBadge(count: Int, contentRect: NSRect) {
        let badgeText = "\(count)"
        let badgeFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let badgeAttributes: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: NSColor.white
        ]
        let badgeString = NSAttributedString(string: badgeText, attributes: badgeAttributes)
        let textSize = badgeString.size()
        
        let badgePadding: CGFloat = 4
        let minBadgeSize: CGFloat = 20
        let badgeWidth = max(textSize.width + badgePadding * 2, minBadgeSize)
        let badgeHeight = max(textSize.height + badgePadding, minBadgeSize)
        
        // Position badge at bottom-right corner, hanging about 35% off the edge
        // (offset inward by 65% of badge size from corner)
        let overhangFraction: CGFloat = 0.35
        let badgeRect = NSRect(
            x: contentRect.maxX - badgeWidth * (1 - overhangFraction),
            y: contentRect.minY - badgeHeight * overhangFraction,
            width: badgeWidth,
            height: badgeHeight
        )
        
        // Badge shadow
        let shadowPath = NSBezierPath(cgPath: CGPath.continuousCapsule(badgeRect.offsetBy(dx: 0, dy: -1)))
        NSColor.black.withAlphaComponent(0.3).setFill()
        shadowPath.fill()
        
        // Badge background (system red)
        let badgePath = NSBezierPath(cgPath: CGPath.continuousCapsule(badgeRect))
        NSColor.systemRed.setFill()
        badgePath.fill()
        
        // Badge text centered
        let textRect = NSRect(
            x: badgeRect.origin.x + (badgeWidth - textSize.width) / 2,
            y: badgeRect.origin.y + (badgeHeight - textSize.height) / 2 + 1,
            width: textSize.width,
            height: textSize.height
        )
        badgeString.draw(in: textRect)
    }
}

// MARK: - Drag Dismissal Notification

extension Notification.Name {
    /// Posted by drop destinations' `concludeDragOperation` overrides (e.g.
    /// LeftSidebar) so a custom drag-preview window can be dismissed in lockstep
    /// with AppKit's synchronous drop teardown, rather than waiting for
    /// `draggingSessionEnded`/`endedAt`, which AppKit defers until after its own
    /// drag-completion rendering pass. Consumed by `GalleryDragEngine`'s list-path
    /// flyback window (see `dismissFlybackImmediately`); a no-op for the grid path,
    /// which uses the native dragging-item preview and has no window to dismiss.
    static let dismissDragPreviewImmediately = Notification.Name("FilmTracker.dismissDragPreviewImmediately")

    /// Posted by `GalleryDragEngine` from both of its session-end callbacks — the
    /// NSDraggingSource `draggingSession(_:endedAt:operation:)` (NSCollectionView grid
    /// path) and `draggingSessionEnded(at:operation:)` (NSTableView list path, forwarded
    /// by the table delegate's endedAt). AppKit defers these callbacks until after its
    /// own drag-completion rendering pass, which makes this notification the earliest
    /// structurally guaranteed moment at which the main thread is free of drag-teardown
    /// work. AlertHostView uses it to arm presentation of the Film Queue drop
    /// confirmation alert, so Core Animation can drive the alert's appear animation
    /// without contention. Posted unconditionally for every session end (successful,
    /// failed, or canceled); observers with nothing pending treat it as a no-op.
    static let dragSessionDidEnd = Notification.Name("FilmTracker.dragSessionDidEnd")

    /// Posted by `DragSessionMonitor.clickWindowDidClose()` when a gallery item-hit
    /// click gesture resolves as a plain click (mouseUp arrived without a drag session
    /// having begun). Together with `.dragSessionDidEnd`, this covers both possible
    /// resolutions of the click-ambiguity window that opens at item mouseDown — see
    /// `DragSessionMonitor.isDeferralWindowActive`. RightSidebar flushes its deferred
    /// selection-driven content resolution on receipt of either notification.
    static let dragDeferralWindowDidEnd = Notification.Name("FilmTracker.dragDeferralWindowDidEnd")

    /// Posted by `DragSessionMonitor.sessionWillBegin()` at the exact structural
    /// moment a drag session is committed to begin (mirrors `.dragSessionDidEnd`'s
    /// pairing at the other end of the session). RightSidebar uses this to clear any
    /// already-known-stale content immediately, rather than leaving it visible for
    /// the drag's duration — see `RightSidebar.handleDragSessionWillBegin()`.
    static let dragSessionWillBegin = Notification.Name("FilmTracker.dragSessionWillBegin")
}

// MARK: - Drag Session Monitor

/// Process-wide, main-actor-confined record of whether an app-originated drag session
/// (grid or list, via GalleryDragEngine) is currently in flight.
///
/// This exists so that consumers whose work is expensive but not time-critical — most
/// importantly RightSidebar's selection-driven content resolution — can structurally
/// defer that work while a drag session is in flight, rather than executing it inside
/// the drag session's run loop where it contends with drop-target tracking and
/// AppKit's own session servicing. (The preview image itself is now composited and
/// moved by the window server — see `GalleryDragEngine.nativeDragPreview` — so it can
/// no longer hitch from main-thread contention; this deferral keeps the *rest* of the
/// session, including drop-target highlighting and the session's start/teardown
/// frames, equally free of avoidable main-thread load.) The flag is flipped by GalleryDragEngine at the exact structural
/// boundaries of the session (immediately before `beginDraggingSession` /
/// `prepareDrag`, and inside both session-end callbacks), so it is never inferred from
/// timing and can never disagree with AppKit's own session lifecycle. Deferral
/// consumers pair a read of this flag with the `.dragSessionDidEnd` notification —
/// which GalleryDragEngine posts from those same end callbacks — to know exactly when
/// the deferred work may safely run.
///
/// A plain class (not @Observable) by design: consumers read it imperatively at
/// decision points; nothing should re-render merely because a drag started.
@MainActor
final class DragSessionMonitor {
    static let shared = DragSessionMonitor()
    private init() {}

    /// True from the moment a GalleryDragEngine drag session is committed to begin
    /// until its session-end callback fires.
    private(set) var isDragSessionActive = false

    /// True while a gallery item-hit click gesture is still ambiguous — i.e. between
    /// an item mouseDown and the moment the gesture resolves as either a plain click
    /// (mouseUp) or a drag (session begin). Selection is committed at mouseDown, so
    /// its one-turn-deferred SelectionState write — and therefore RightSidebar's
    /// content rebuild — would otherwise land squarely inside this window, exactly
    /// where a fast drag's session start needs the main thread. See
    /// `isDeferralWindowActive`.
    private var isClickWindowOpen = false

    /// The composite deferral gate consumers should read: true while EITHER a click
    /// gesture is still ambiguous OR a drag session is in flight. RightSidebar defers
    /// its selection-driven content resolution for the whole span, flushing on
    /// `.dragDeferralWindowDidEnd` (plain click) or `.dragSessionDidEnd` (drag) —
    /// both structural lifecycle boundaries, never wall-clock timers. The visible
    /// costs are bounded and deliberate: for a plain click the sidebar content
    /// arrives at mouseUp (the pre-mouseDown-commit historical timing; the focus
    /// ring itself still appears at mouseDown), and for a drag it arrives at session
    /// end — in exchange, a drag's session start can never contend with the sidebar
    /// rebuild on the main thread.
    var isDeferralWindowActive: Bool { isClickWindowOpen || isDragSessionActive }

    /// Called by the gallery views' mouseDown handling when a click lands on an item
    /// (the only clicks that can both commit a selection and turn into a drag).
    func clickWindowDidOpen() { isClickWindowOpen = true }

    /// Called by the gallery views when the click gesture has fully resolved without
    /// a drag (mouseUp / return from the table's tracking loop). Posts
    /// `.dragDeferralWindowDidEnd` only when the gesture genuinely ended as a plain
    /// click: if a session began mid-gesture, `sessionWillBegin()` already absorbed
    /// the window and the flush belongs to `.dragSessionDidEnd` at session end.
    /// Guarded so calls with no window open (empty-space clicks, marquee mouseUps)
    /// are free no-ops.
    func clickWindowDidClose() {
        guard isClickWindowOpen else { return }
        isClickWindowOpen = false
        guard !isDragSessionActive else { return }
        NotificationCenter.default.post(name: .dragDeferralWindowDidEnd, object: nil)
    }

    /// Called by GalleryDragEngine immediately before the session begins. Absorbs any
    /// open click window — its resolution is now the session's end.
    func sessionWillBegin() {
        isClickWindowOpen = false
        isDragSessionActive = true
        NotificationCenter.default.post(name: .dragSessionWillBegin, object: nil)
    }

    /// Called by GalleryDragEngine from its session-end callbacks (and its
    /// abnormal-termination safety net in `mouseUpForDrag`).
    func sessionDidEnd() { isDragSessionActive = false }
}

// MARK: - Gallery Drag Engine

/// Reusable drag engine that encapsulates the drag lifecycle used by both
/// GalleryCollectionView (NSCollectionView grid) and the List-based gallery view.
/// Each owning view holds its own instance, so the two mechanisms below never
/// interact or share state.
///
/// The grid path's visible drag preview is the session's own NATIVE
/// dragging-item image (composed once at drag start by `nativeDragPreview` and
/// handed to AppKit via `setDraggingFrame(_:contents:)`, from `startManualDrag`).
/// The window server composites and moves that image, and — with
/// `animatesToStartingPositionsOnCancelOrFail = true` — also drives the cancel
/// fly-back, so no per-frame main-thread work of any kind is required to keep
/// the preview glued to the cursor. This is what makes the grid's preview
/// structurally immune to main-thread contention: even if a heavy SwiftUI
/// commit (e.g. the RightSidebar content build for the selection committed at
/// mouseDown) lands mid-drag, the preview continues tracking at full frame rate
/// because the app process is not in its render loop at all.
///
/// The list path's visible drag preview is instead a separate, manually
/// positioned borderless NSWindow (the "flyback window" — see the Flyback
/// Window State fields and the NSTableView Drag Pipeline section below),
/// updated on every `draggingSession(_:movedTo:)` callback. This mirrors the
/// grid's own original design, before it was replaced with the native preview
/// above specifically to eliminate a main-thread-contention hitch. Re-adopting
/// it for the list path was a deliberate choice after the native preview proved
/// unable to track the cursor correctly for an NSTableView-originated session
/// across several independent fix attempts (screen-point vs. view-space frames,
/// NSEvent.mouseLocation vs. the delegate's own screenPoint, and the legacy
/// dragImageForRows offset parameter) — NSTableView's own native row-drag
/// machinery does not expose the same reliable frame-reconfiguration contract
/// the grid's manually-driven `beginDraggingSession` call does. The list path
/// does not have the grid's original hitch problem in the first place: the
/// RightSidebar content-rebuild contention that motivated retiring the flyback
/// window for the grid is now handled structurally, for both paths, by
/// DragSessionMonitor's deferral gate — so the flyback window's own per-frame
/// main-thread cost is no longer competing with that same problem here.
///
/// Callers provide two callbacks:
///   getDragFilmIDs  — returns the Set<UUID> to drag given the click point in the view
///   getPosterImage  — returns the NSImage for the film under the cursor (for the drag preview)
///
/// Usage pattern mirrors GalleryCollectionView: the owning view calls mouseDownForDrag,
/// mouseDraggedForDrag, and mouseUpForDrag from its own mouse event overrides.
@MainActor
final class GalleryDragEngine: NSObject, NSDraggingSource {

    /// Returns the film IDs to include in the drag, given the click location in the
    /// owning view's coordinate space. Return an empty set to suppress the drag.
    var getDragFilmIDs: ((NSPoint) -> Set<UUID>)?
    /// Returns the single film ID directly under the cursor at drag-start time.
    /// Used exclusively to select the poster image for the drag preview — the film
    /// the user actually grabbed, regardless of which IDs are in the drag set.
    var getClickedFilmID: ((NSPoint) -> UUID?)?
    /// Returns a poster NSImage for the given film ID, used as the drag preview image.
    var getPosterImage: ((UUID) -> NSImage?)?
    /// The NSView that will call `beginDraggingSession`. Must be set before any drag fires.
    weak var sourceView: NSView?

    // Drag state
    private var potentialDragStart: NSPoint = .zero
    private var isDragInitiated = false
    /// The original mouseDown event — stored so beginDraggingSession receives it.
    /// Apple requires the initiating mouse-down event; passing a drag event from a
    /// local monitor causes the session to silently fail.
    private var mouseDownEvent: NSEvent?

    // MARK: - Flyback Window State (NSTableView / list path only)
    //
    // The grid path (startManualDrag) uses the NATIVE, window-server-driven
    // dragging-item preview (see nativeDragPreview) and never touches any of the
    // fields below. The list path uses a separate, manually-positioned borderless
    // NSWindow instead — reinstated after the native per-item preview proved
    // unable to track the cursor correctly for NSTableView-originated sessions
    // (the session's own coordinate-space/anchor contract for reconfigured
    // dragging items did not behave as documented in practice, across several
    // independent fix attempts). This is a return to this app's original,
    // proven-reliable list-view drag preview mechanism, now integrated with
    // DragSessionMonitor's click-window/session bookkeeping.
    private var dragStartScreen: NSPoint = .zero
    private var dragImageSize: NSSize = .zero
    private var dragCursorOffset: NSPoint = .zero
    private var flybackWindow: NSWindow?

    // MARK: - Init / Deinit

    override init() {
        super.init()
        // Observe the cross-actor dismissal notification posted by drop
        // destinations' concludeDragOperation overrides (e.g. LeftSidebar), so the
        // flyback window can be hidden in lockstep with AppKit's synchronous drop
        // teardown rather than waiting for draggingSessionEnded, which AppKit defers
        // until after its own drag-completion rendering pass. A harmless no-op for
        // the grid path's own GalleryDragEngine instance, since flybackWindow is
        // never populated there.
        // Target/selector registration: NotificationCenter drops it when this object
        // deallocates, so no token (and no deinit) is needed. The post comes from
        // concludeDragOperation, on the main thread.
        NotificationCenter.default.addObserver(
            self, selector: #selector(dismissDragPreviewNotified(_:)),
            name: .dismissDragPreviewImmediately, object: nil)
    }

    @objc private func dismissDragPreviewNotified(_ notification: Notification) {
        dismissFlybackImmediately()
    }

    // MARK: - Mouse Event Hooks

    /// Call from the owning view's mouseDown override (after calling super).
    /// Pass the NSEvent so it can be forwarded to beginDraggingSession later.
    func mouseDownForDrag(at locationInView: NSPoint, event: NSEvent? = nil) {
        potentialDragStart = locationInView
        isDragInitiated = false
        mouseDownEvent = event
    }

    /// Call from the owning view's mouseDragged override.
    /// Returns true if a drag session was started (caller should skip super if desired).
    @discardableResult
    func mouseDraggedForDrag(event: NSEvent, locationInView: NSPoint) -> Bool {
        guard !isDragInitiated else { return false }
        let dx = locationInView.x - potentialDragStart.x
        let dy = locationInView.y - potentialDragStart.y
        let dist = sqrt(dx * dx + dy * dy)
        guard dist >= 4 else { return false }
        isDragInitiated = true
        startManualDrag(with: mouseDownEvent ?? event, currentLocationInView: locationInView)
        return true
    }

    /// Call from the owning view's mouseUp override (after calling super).
    func mouseUpForDrag() {
        isDragInitiated = false
        mouseDownEvent = nil
        // Safety net for the (theoretical) case where sessionWillBegin() was marked
        // but the dragging session never actually tracked, so no session-end callback
        // will ever fire. During a genuine session AppKit consumes the mouseUp and this
        // method is never invoked, and after a normal session end the flag is already
        // false — so this branch is unreachable in every normal flow and exists purely
        // to guarantee the monitor (and any consumer waiting on .dragSessionDidEnd)
        // can never be left stuck by an abnormal session start.
        if DragSessionMonitor.shared.isDragSessionActive {
            DragSessionMonitor.shared.sessionDidEnd()
            NotificationCenter.default.post(name: .dragSessionDidEnd, object: nil)
        }
    }

    // MARK: - Drag Initiation

    /// - Parameter currentLocationInView: the LIVE cursor position at the moment the
    ///   drag distance threshold was crossed. Used only for the drag preview's visual
    ///   starting point (the native dragging item's anchored frame) — never
    ///   for resolving WHICH film(s) are being dragged. Identity resolution instead
    ///   uses `potentialDragStart`, the position recorded at mouseDown: by the time
    ///   the ≥4pt threshold trips, the cursor has necessarily moved away from that
    ///   point, and even a few points of drift can land `indexPathForItem(at:)` on a
    ///   neighboring grid cell — silently swapping in an adjacent film. Freezing
    ///   identity to the original mouseDown point guarantees the film actually
    ///   grabbed is always the one the user clicked, regardless of how far (or in
    ///   which direction) the cursor has since moved.
    private func startManualDrag(with event: NSEvent, currentLocationInView: NSPoint) {
        guard let sourceView,
              let getDragFilmIDs else {
            return
        }
        let filmIDs = getDragFilmIDs(potentialDragStart)
        guard !filmIDs.isEmpty else { return }

        // Use the film actually clicked at mouseDown for the poster preview — not
        // whatever is currently under the (moved) cursor — so the image always
        // reflects what the user grabbed.
        let clickedID = getClickedFilmID?(potentialDragStart)
        let posterID = clickedID ?? filmIDs.first
        let posterImage: NSImage? = posterID.flatMap { getPosterImage?($0) }

        let pasteboardItem = NSDraggingItem(pasteboardWriter: FilmDragPasteboardWriter(filmIDs: filmIDs))

        // Native, window-server-driven drag preview: the composed ghost-poster image
        // becomes the dragging item's own contents, anchored so it sits relative to
        // the cursor exactly where the retired flyback window used to. From here on,
        // AppKit and the window server keep it glued to the cursor with zero app-side
        // per-frame work — see the class-level comment.
        let preview = Self.nativeDragPreview(
            filmCount: filmIDs.count,
            posterImage: posterImage,
            cursorLocationInView: currentLocationInView,
            in: sourceView
        )
        pasteboardItem.setDraggingFrame(preview.frame, contents: preview.image)

        // Mark the session live BEFORE beginDraggingSession: the run loop may drain
        // queued main-queue work (including SelectionState's deferred selection write)
        // as soon as the session starts, and any deferral consumer reading
        // DragSessionMonitor must already see the session as active at that point.
        DragSessionMonitor.shared.sessionWillBegin()
        let session = sourceView.beginDraggingSession(with: [pasteboardItem], event: event, source: self)
        // Let AppKit drive the cancel fly-back natively: on a canceled/failed drop the
        // system slides the dragging image back to its starting frame off the app's
        // main thread — replacing the custom performFlyBack window animation, and with
        // the bonus that draggingSession(_:endedAt:) (and therefore .dragSessionDidEnd
        // and RightSidebar's deferred content flush) is delivered only after that
        // return animation has fully settled.
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    // MARK: - Native Drag Preview

    /// Composes the drag preview image (ghost poster + count badge, via
    /// FilmDragImageProvider) together with the cursor anchor offset: the cursor
    /// rests one quarter of the poster's width and height in from the image's visual
    /// top-left corner. Shared by both paths — the grid path's `startManualDrag`
    /// (via `nativeDragPreview` below) and the list path's `prepareDrag` — so the
    /// poster size and cursor-anchor ratio can never drift out of sync between them.
    private static func composeDragPreview(
        filmCount: Int,
        posterImage: NSImage?
    ) -> (image: NSImage, cursorOffset: NSPoint) {
        let posterSize = NSSize(width: 48, height: 72)
        let image = FilmDragImageProvider.createDragImage(
            filmCount: filmCount,
            posterImage: posterImage,
            size: posterSize
        )
        return (image, NSPoint(x: posterSize.width / 4, y: posterSize.height / 4))
    }

    /// Preview math used by the grid path's `startManualDrag`: frame expressed in
    /// `view`'s own coordinate space, as required when the dragging item is
    /// configured BEFORE `beginDraggingSession(with:event:source:)` (AppKit
    /// interprets pre-session dragging frames in the source view's space). The
    /// list path does not use this — see the Flyback Window State fields and the
    /// class-level doc comment above for why. The unflipped branch below is
    /// handled anyway so the math can never silently break for a future source
    /// view, even though the grid's real source view is flipped.
    static func nativeDragPreview(
        filmCount: Int,
        posterImage: NSImage?,
        cursorLocationInView location: NSPoint,
        in view: NSView
    ) -> (image: NSImage, frame: NSRect) {
        let (image, cursorOffset) = composeDragPreview(filmCount: filmCount, posterImage: posterImage)
        let size = image.size
        // Visually, the image's left edge sits cursorOffset.x left of the cursor and
        // its top edge cursorOffset.y above it.
        let originY = view.isFlipped
            ? location.y - cursorOffset.y                   // flipped: minY is the visual top
            : location.y - (size.height - cursorOffset.y)   // unflipped: minY is the visual bottom
        let frame = NSRect(
            x: location.x - cursorOffset.x,
            y: originY,
            width: size.width,
            height: size.height
        )
        return (image, frame)
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // The native dragging image's teardown — instant hide on a successful drop,
        // system-driven fly-back on cancel/fail — is fully AppKit's responsibility
        // now; there is nothing visual left to dismiss here.
        //
        // Clear the monitor BEFORE posting .dragSessionDidEnd below, so any observer
        // reacting to the notification already reads the session as inactive.
        DragSessionMonitor.shared.sessionDidEnd()
        // Announce the session's true end — AppKit delivers this callback only after
        // its drag-completion rendering pass (including the native cancel fly-back
        // animation, when one runs), so observers (AlertHostView's deferred Film Queue
        // drop confirmation, RightSidebar's deferred content resolution) can now do
        // their work without teardown contention.
        NotificationCenter.default.post(name: .dragSessionDidEnd, object: nil)
    }

    // MARK: - NSTableView Drag Pipeline
    //
    // NSTableView detects drag gestures from within its own mouseDown event-tracking
    // loop and calls the delegate. We hook in here rather than via mouseDown overrides.
    //
    // This path uses a separate, manually-positioned borderless NSWindow (the
    // "flyback window") as the visible drag preview, rather than the grid path's
    // native dragging-item image. See the "Flyback Window State" fields above for
    // why: the native per-item preview, reconfigured mid-session via
    // `enumerateDraggingItems`, could not be made to track the cursor correctly
    // for an NSTableView-originated session across several independent attempts
    // (screen-point vs. view-space frames, NSEvent.mouseLocation vs. the
    // delegate's own screenPoint, and the legacy dragImageForRows offset
    // parameter). The flyback window sidesteps all of that: it is positioned by
    // simple, direct screen-point arithmetic in `prepareFlybackWindow` and
    // `dragMoved(to:)`, with no dependency on any AppKit-native per-item frame
    // contract at all.

    /// Called by the NSTableViewDelegate's willBeginAt callback. Marks the session
    /// live in DragSessionMonitor and prepares the flyback window at the drag's
    /// starting screen point. filmCount and posterImage are resolved by the
    /// delegate before this call.
    ///
    /// willBeginAt fires only for a session that has genuinely begun, and AppKit
    /// guarantees an endedAt for every begun session, so the sessionWillBegin() here
    /// is perfectly paired with draggingSessionEnded(at:operation:) below.
    func prepareDrag(filmCount: Int,
                     posterImage: NSImage?,
                     startScreenPoint: NSPoint,
                     sourceView view: NSView) {
        sourceView      = view
        isDragInitiated = true
        DragSessionMonitor.shared.sessionWillBegin()

        // Shares the grid path's own composeDragPreview helper (rather than
        // recomputing the same poster size and cursor-anchor ratio independently)
        // so the two paths' preview geometry can never silently drift apart.
        let (image, cursorOffset) = Self.composeDragPreview(
            filmCount: filmCount,
            posterImage: posterImage
        )
        dragImageSize    = image.size
        dragCursorOffset = cursorOffset
        dragStartScreen  = startScreenPoint

        prepareFlybackWindow(with: image, at: startScreenPoint)
    }

    /// Called by `DraggableListTableView.draggingSession(_:movedTo:)` to keep the
    /// flyback window in sync with the cursor during an NSTableView-originated drag.
    func dragMoved(to screenPoint: NSPoint) {
        guard let window = flybackWindow else { return }
        window.setFrameOrigin(NSPoint(
            x: screenPoint.x - dragCursorOffset.x,
            y: screenPoint.y - (dragImageSize.height - dragCursorOffset.y)
        ))
    }

    /// Called by the NSTableViewDelegate's endedAt callback. Mirrors the behavior of
    /// the NSDraggingSource endedAt callback used on the NSCollectionView path, but
    /// also tears down the flyback window: an animated fly-back to the drag's start
    /// point on cancel/fail (operation == []), or an immediate hide on a successful
    /// drop (concludeDragOperation's .dismissDragPreviewImmediately notification has
    /// normally already done this by the time endedAt is delivered — AppKit defers
    /// endedAt until after its own drag-completion rendering pass — so this is a
    /// safety net; dismissFlybackImmediately() no-ops if already dismissed).
    func draggingSessionEnded(at screenPoint: NSPoint, operation: NSDragOperation) {
        isDragInitiated = false
        mouseDownEvent  = nil
        if operation == [] {
            performFlyBack(from: screenPoint, to: dragStartScreen)
        } else {
            dismissFlybackImmediately()
        }
        // Clear the monitor BEFORE posting .dragSessionDidEnd below, so any observer
        // reacting to the notification already reads the session as inactive.
        DragSessionMonitor.shared.sessionDidEnd()
        // Same session-end announcement as the grid path (see .dragSessionDidEnd
        // documentation).
        NotificationCenter.default.post(name: .dragSessionDidEnd, object: nil)
    }

    // MARK: - Flyback Window

    private func prepareFlybackWindow(with image: NSImage, at screenPoint: NSPoint) {
        let size = image.size
        let frame = NSRect(
            x: screenPoint.x - dragCursorOffset.x,
            y: screenPoint.y - (size.height - dragCursorOffset.y),
            width: size.width, height: size.height
        )
        let window = NSWindow(contentRect: frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.hasShadow = false

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = image
        imageView.imageScaling = .scaleNone
        imageView.wantsLayer = true
        window.contentView = imageView

        flybackWindow = window
        window.orderFront(nil)
    }

    /// Immediately hides the flyback window without animation.
    ///
    /// Call this from a drop destination's `concludeDragOperation` override so the
    /// drag preview disappears in lockstep with the sidebar highlight clearing and
    /// the cursor reverting — all of which AppKit applies synchronously at that
    /// moment. Waiting for `draggingSessionEnded`/`endedAt` introduces a
    /// multi-frame delay, since AppKit defers that callback until after its own
    /// drag-completion rendering pass.
    func dismissFlybackImmediately() {
        guard let window = flybackWindow else { return }
        flybackWindow = nil
        window.orderOut(nil)
    }

    private func performFlyBack(from end: NSPoint, to start: NSPoint) {
        guard let window = flybackWindow else { return }
        let endFrame = NSRect(
            x: start.x - dragCursorOffset.x,
            y: start.y - (dragImageSize.height - dragCursorOffset.y),
            width: dragImageSize.width, height: dragImageSize.height
        )
        flybackWindow = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            window.animator().setFrame(endFrame, display: true)
        }) {
            // AppKit calls completion handlers on the main thread, but the SDK types
            // them as nonisolated @Sendable closures.
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.2
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    ctx.allowsImplicitAnimation = true
                    window.animator().alphaValue = 0
                }) {
                    MainActor.assumeIsolated { window.orderOut(nil) }
                }
            }
        }
    }
}
