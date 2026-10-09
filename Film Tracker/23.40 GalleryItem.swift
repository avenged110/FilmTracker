// MARK: - GalleryItem.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// NSCollectionViewItem hosting a reused, pure-AppKit GalleryTileContentView for smooth
// scrolling (see 23_50_GalleryItemView.swift), alongside its own selection-ring and
// drop-shadow CALayers.

import Cocoa
// Imported solely for RoundedRectangle/Path in updateRingPath(posterRect:) (and, via
// CGPath.continuousRoundedRect, the poster shadow paths) -- used as a pure
// geometry calculator to obtain the system's continuous ("squircle") corner outline. No SwiftUI
// view, hosting view, layout pass, or view graph is involved anywhere in this file.
import SwiftUI

final class GalleryItem: NSCollectionViewItem, Loggable {
    nonisolated static let logTag = "[GalleryItem]"

    // Tile content view -- created once and reused (see GalleryTileContentView in
    // 23_50_GalleryItemView.swift).
    private var tileContentView: GalleryTileContentView?

    // Current state tracking for efficient updates.
    private var currentFilmID: UUID?
    private var currentPosterUID: String?
    private var currentSubtitleText: String?
    private var currentIsSelected: Bool = false

    /// In-flight asynchronous poster load for the current cell, started only when
    /// refreshTileContent misses the cache. Canceled on reuse and superseded whenever a
    /// new load begins, so a recycled cell can never be filled by a load started for the
    /// film it used to show.
    private var posterLoadTask: Task<Void, Never>?

    // MARK: - Selection Ring (CAShapeLayer)
    //
    // The ring is drawn as a CAShapeLayer directly on view.layer (masksToBounds = false),
    // letting it extend outside the cell frame without affecting the tile content's own layout.
    //
    // Coordinate system
    // -----------------
    // GalleryItem.view is a plain NSView() with isFlipped = false (the default). Its
    // backing CALayer therefore uses standard CoreAnimation y-up coordinates: origin at
    // the bottom-left of the cell, y increasing upward. All CGRect / CGPath values
    // passed to the ring CAShapeLayer must use this y-up convention.
    //
    // GalleryTileContentView (23_50_GalleryItemView.swift) is pinned edge-to-edge as a subview
    // and is ALSO unflipped (isFlipped = false), matching this view exactly. Because both views
    // share the same y-up space, GalleryTileGeometry.posterRect(inCellBounds:) -- the single
    // source of truth both this file and GalleryTileContentView consume -- needs no y-down/y-up
    // conversion step at all.
    //
    // Poster position in y-up layer coordinates
    // ------------------------------------------
    // GalleryTileGeometry insets the poster box by 2pt on all sides (posterPadding), then
    // derives its height from its own (post-inset) width at a fixed 2:3 (width:height) aspect
    // ratio:
    //
    //   posterTop_yup    = cellHeight - 2
    //   posterBottom_yup = cellHeight - 2 - (cellWidth-4)*1.5
    //
    // cellHeight = view.bounds.height = exactItemPts*1.5 (SmoothResizingGridLayout).
    // exactItemPts is the average column width and may differ from cellWidth by up to
    // 0.5 pt (Bresenham distribution). Using view.bounds.height and view.bounds.width
    // independently as the authoritative values for each axis keeps both axes exact.
    //
    // Ring geometry
    // -------------
    //   gap       = 1 pt   desired clear space between poster edge and ring inner edge
    //   lineWidth = 5 pt   Preferences.selectionLineWidth, stroke centered on path
    //   ringOutset = gap + lineWidth/2 = 1 + 2.5 = 3.5 pt
    //               distance from each poster edge to the ring path center (y-up)
    //
    //   Ring path rect in y-up layer coordinates:
    //     x      = posterLeft - ringOutset        = 2 - 3.5 = -1.5
    //     y      = posterBottom_yup - ringOutset  (origin = bottom-left of rect in y-up)
    //     width  = posterWidth + 2*ringOutset     = (cellWidth-4) + 7 = cellWidth + 3
    //     height = posterHeight + 2*ringOutset    = (cellWidth-4)*1.5 + 7
    //
    //   Corner radius = Preferences.cornerRadius + ringOutset = 12 + 3.5 = 15.5
    //   (follows the poster's curvature at the ring path center distance)
    //
    // Constants are private static lets -- computed once, not per-cell.
    private static let ringLineWidth: CGFloat = Preferences.selectionLineWidth  // 5
    // Shared with GalleryTileContentView's subtitle-clearance math (23_50_GalleryItemView.swift)
    // via GalleryTileGeometry -- the single source of truth -- so the two can never drift.
    private static let ringGap: CGFloat = GalleryTileGeometry.ringGap
    // Distance from poster edge to ring path center = gap + lineWidth/2 = 3.5
    private static let ringOutset: CGFloat = ringGap + ringLineWidth / 2
    // Corner radius of the ring path, matching poster curvature at ringOutset distance.
    private static let ringCornerRadius: CGFloat = Preferences.cornerRadius + ringOutset  // 15.5

    private var ringLayer: CAShapeLayer?

    // MARK: - Poster Shadow (CALayer, shadowPath)
    //
    // A CALayer with an explicit shadowPath renders a path-defined shadow from geometry
    // alone and never samples layer content, so recomputing it on every viewDidLayout is
    // trivial rect/corner-radius arithmetic rather than a bitmap blur -- important since
    // viewDidLayout fires per-tick, for every visible cell, during a live window resize or
    // sidebar-toggle animation. It is inserted as the first sublayer (added before the tile
    // content view's own layer) so it paints behind the poster content, while the ring --
    // added after the tile content view -- continues to paint on top.
    //
    // A single fixed strength is used regardless of whether a cell shows a resolved
    // poster image or the placeholder.
    private var shadowLayer: CALayer?
    private static let tileShadowColor: CGColor = NSColor.black.cgColor
    private static let tileShadowRadius: CGFloat = 4
    // SwiftUI's y: 2 means "2pt further down"; GalleryItem.view is unflipped (y-up), so
    // the equivalent CALayer offset is negative.
    private static let tileShadowOffset = CGSize(width: 0, height: -2)
    private static let tileShadowOpacity: Float = 0.6

    // MARK: - Initialization
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        // Allow shadow and selection ring to extend beyond the cell bounds.
        view.layer?.masksToBounds = false

        // Order matters: shadow layer first (bottom of paint order), then the tile content
        // view (its own layer is appended next), then the ring layer, then the ring-top
        // shadow last (top of paint order) -- see each layer's doc comment above.
        createShadowLayerIfNeeded()
        createTileContentViewIfNeeded()
        createRingLayerIfNeeded()
        createRingShadowLayerIfNeeded()
    }

    override func prepareForReuse() {
        super.prepareForReuse()

        cancelPosterLoad()

        // Clear tracking states so configure() starts from a clean slate.
        currentFilmID = nil
        currentPosterUID = nil
        currentSubtitleText = nil
        currentIsSelected = false
    }

    // MARK: - Layout
    // Recompute the shadow, ring, and ring-shadow geometry whenever the cell is laid
    // out so they always match the live cell frame. Cells resize with the window width,
    // and this fires per-tick, for every visible cell, during a live resize -- so
    // posterRect is resolved once here and threaded through to all three updates rather
    // than each independently recomputing the same rect from view.bounds.
    override func viewDidLayout() {
        super.viewDidLayout()
        syncLayerContentsScale()
        guard let posterRect = currentPosterRect() else { return }
        updateShadowPath(posterRect: posterRect)
        // The selection ring and its ring-top shadow are invisible (clear stroke / zero
        // shadow opacity) for the overwhelming majority of cells -- typically 0 or 1
        // selected item exists anywhere in the grid at once -- yet updateRingPath() and
        // updateRingShadowGeometry() each build a fresh rounded-rect CGPath from scratch.
        // Doing that for EVERY visible cell on EVERY layout tick (a live window resize or
        // sidebar-toggle animation) multiplies directly by the number of on-screen cells,
        // for no visible benefit -- a hidden ring's stale path is never drawn, so it costs
        // nothing to skip. Deferred here to only the (at most a handful of) currently-
        // selected cells; updateRingVisibility() below recomputes both immediately the
        // instant a cell's selection actually turns on, using view.bounds' already-current
        // value at that moment -- so this is exactly as correct as recomputing every frame
        // would have been, just without the wasted work for cells nobody can see it on.
        if currentIsSelected {
            updateRingPath(posterRect: posterRect)
            updateRingShadowGeometry(posterRect: posterRect)
        }
    }

    // MARK: - Selection
    // NSCollectionView's isSelected provides immediate visual feedback during user interaction.
    override var isSelected: Bool {
        didSet {
            if isSelected != currentIsSelected {
                currentIsSelected = isSelected
                updateRingVisibility()
            }
        }
    }

    // MARK: - Configuration
    /// Accepts a FilmSnapshot value type -- no live SwiftData object references.
    ///
    /// `subtitleProvider`, when non-nil, is queried for this film's subtitle text on every
    /// call. GallerySubview's Coordinator pushes the actual provider closure here explicitly
    /// on every (re)configuration -- the same explicit-value-push discipline used for the
    /// film and poster themselves. Comparing the RESOLVED subtitle string (rather than
    /// tracking the provider's identity separately) is deliberate: it uniformly covers a
    /// provider appearing, disappearing, or being swapped for a different one (e.g.
    /// switching Recents categories), with a single cheap String? equality check and no
    /// separate bookkeeping that could drift.
    func configure(with film: FilmSnapshot, subtitleProvider: GallerySubtitleProvider?) {
        let filmID = film.id
        let posterUID = film.posterUID
        let subtitleText = subtitleProvider?.subtitle(filmID)

        let filmChanged     = currentFilmID       != filmID
        let posterChanged   = currentPosterUID    != posterUID
        let subtitleChanged = currentSubtitleText != subtitleText

        currentFilmID       = filmID
        currentPosterUID    = posterUID
        currentSubtitleText = subtitleText
        currentIsSelected   = isSelected

        if filmChanged || posterChanged || subtitleChanged { refreshTileContent() }

        // Ring visibility must always match, even when no other property changed
        // (e.g. a cell is recycled directly onto a selected index path).
        updateRingVisibility()
    }

    // MARK: - Tile Content View Management
    private func createTileContentViewIfNeeded() {
        guard tileContentView == nil else { return }

        let newContentView = GalleryTileContentView()
        newContentView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(newContentView)
        NSLayoutConstraint.activate([
            newContentView.topAnchor.constraint(equalTo: view.topAnchor),
            newContentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            newContentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            newContentView.bottomAnchor.constraint(equalTo: view.bottomAnchor)])

        tileContentView = newContentView
    }

    /// Resolves the poster image and pushes it, along with the currently tracked film ID and
    /// subtitle text, into the tile content view. Called only when configure(with:) detects an
    /// actual change, so this can safely do its resolution work unconditionally each time.
    ///
    /// CACHE-ONLY, BY DESIGN. This deliberately does NOT use PosterCache.getImageWithFallback,
    /// whose cache-miss path performs a synchronous disk read and ImageIO decode on the calling
    /// thread. Cells are reconfigured from inside main-thread work that AppKit has elevated to
    /// User-Interactive QoS -- most sharply during GalleryCollectionView.mouseDown, where the
    /// makeFirstResponder/selection change reconfigures cells while still inside the event's
    /// tracking loop. A User-Interactive thread blocking on the lower-QoS kernel/IO threads that
    /// service that read is a priority inversion, which the Thread Performance Checker reports
    /// as "Thread running at User-interactive quality-of-service class waiting on a lower QoS
    /// thread running at Default quality-of-service class."
    ///
    /// This is the same hazard, and the same remedy, already applied to the drag-preview path in
    /// PosterCache.dragPreviewImage -- which likewise refuses to fall back to disk for exactly
    /// this reason. Here the poster is not cosmetic, so instead of accepting the miss the load
    /// is handed to the asynchronous path, which performs the read on a background executor and
    /// fills the tile in when it lands.
    private func refreshTileContent() {
        guard let tileContentView, let filmID = currentFilmID else { return }

        // Any load still in flight was started for a previous configuration of this cell.
        cancelPosterLoad()

        guard let posterUID = currentPosterUID, !posterUID.isEmpty else {
            tileContentView.configure(image: nil, filmID: filmID, subtitle: currentSubtitleText)
            return
        }

        // Cache hit: the overwhelmingly common case, since PosterCache's background restore
        // keeps the cache warm. Resolves synchronously with no disk access at all.
        if let image = PosterCache.shared.getImageSync(for: posterUID) {
            tileContentView.configure(image: image, filmID: filmID, subtitle: currentSubtitleText)
            return
        }

        // Miss: show the tile immediately without a poster, then fill it in.
        tileContentView.configure(image: nil, filmID: filmID, subtitle: currentSubtitleText)
        beginPosterLoad(posterUID: posterUID, filmID: filmID)
    }

    /// Loads a missing poster off the main thread and applies it only if this cell is still
    /// showing the same film and poster when it arrives.
    private func beginPosterLoad(posterUID: String, filmID: UUID) {
        posterLoadTask = Task { @MainActor [weak self] in
            let image = await PosterCache.shared.getImageAsync(for: posterUID)
            guard let self, !Task.isCancelled, let image else { return }

            // Re-check identity rather than trusting cancellation alone: a cell recycled and
            // reconfigured between the await and its resumption would otherwise be filled with
            // the previous film's poster.
            guard self.currentFilmID == filmID,
                  self.currentPosterUID == posterUID,
                  let tileContentView = self.tileContentView else { return }

            tileContentView.configure(
                image: image, filmID: filmID, subtitle: self.currentSubtitleText)
        }
    }

    private func cancelPosterLoad() {
        posterLoadTask?.cancel()
        posterLoadTask = nil
    }

    // MARK: - Shadow Layer Management

    private func createShadowLayerIfNeeded() {
        guard shadowLayer == nil, let layer = view.layer else { return }

        let shadow = CALayer()
        shadow.shadowColor = Self.tileShadowColor
        shadow.shadowRadius = Self.tileShadowRadius
        shadow.shadowOffset = Self.tileShadowOffset
        shadow.shadowOpacity = Self.tileShadowOpacity
        // A shadow needs no fill of its own -- only its shadowPath contributes visually.
        shadow.backgroundColor = nil
        // Disable implicit CA animations so the shadow tracks the live tile in lock-step
        // during resize, with no lag/morph artifact, matching the ring's approach.
        shadow.actions = ["shadowPath": NSNull(), "shadowOpacity": NSNull(),
                           "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(shadow)
        shadowLayer = shadow
    }

    /// The poster's own rect in layer y-up coordinates, hugging its edges directly (no
    /// outset) -- shared by the bottom cell-shadow and, below, the ring-top shadow, so
    /// both always agree on exactly the same shape. Delegates to
    /// GalleryTileGeometry.posterRect(inCellBounds:) (23_50_GalleryItemView.swift), the single
    /// source of truth also consumed directly by GalleryTileContentView's own layout(), so the
    /// tile image, the ring, and the shadow can never disagree about the tile's geometry.
    private func currentPosterRect() -> CGRect? {
        GalleryTileGeometry.posterRect(inCellBounds: view.bounds)
    }

    /// The cell bounds the shadow layer's frame and shadowPath were last built for.
    /// `.null` (never equal to any real rect, including .zero) means "not yet built", so the
    /// very first layout pass always performs a full build.
    ///
    /// Deliberately NOT reset in prepareForReuse: this memo and the shadow layer it describes
    /// live on the same GalleryItem instance and are never torn down independently, so they
    /// stay in lockstep across every reuse. A recycled cell landing at an unchanged size
    /// already carries the correct shadow geometry; one landing at a different size gets a
    /// layout pass (bounds changed), which rebuilds it here.
    private var lastShadowBounds: CGRect = .null

    /// Rebuilds the shadow's path from the poster's actual rect (shared with the ring and
    /// ring-shadow layers via viewDidLayout, so all three always agree on the same shape).
    ///
    /// Short-circuits when the cell's bounds are unchanged since the last build. `posterRect`
    /// is a pure function of `view.bounds` (see GalleryTileGeometry.posterRect(inCellBounds:)),
    /// so equal bounds means an identical path and an identical layer frame — rebuilding both
    /// would be byte-for-byte redundant. This costs nothing during a live resize (where the
    /// bounds genuinely change every tick) and eliminates the CGPath allocation plus the
    /// shadow-bitmap regeneration it forces on every OTHER layout pass, of which AppKit issues
    /// a fair number at identical geometry (a second pass within the same cycle, a re-layout
    /// after a window occlusion/appearance change, the settle pass at the end of a
    /// sidebar-toggle animation), multiplied by every visible cell each time.
    private func updateShadowPath(posterRect: CGRect) {
        guard let shadow = shadowLayer else { return }
        let bounds = view.bounds
        guard bounds != lastShadowBounds else { return }
        lastShadowBounds = bounds

        shadow.frame = bounds
        shadow.shadowPath = CGPath.continuousRoundedRect(posterRect, cornerRadius: Preferences.cornerRadius)
    }

    // MARK: - Ring Layer Management

    private func createRingLayerIfNeeded() {
        guard ringLayer == nil, let layer = view.layer else { return }

        let ring = CAShapeLayer()
        ring.fillColor = nil
        ring.lineWidth = Self.ringLineWidth
        ring.strokeColor = NSColor.clear.cgColor
        // Disable implicit CA animations so the ring snaps on/off immediately and
        // the path updates without morphing during window resize.
        ring.actions = ["strokeColor": NSNull(), "path": NSNull()]
        layer.addSublayer(ring)
        ringLayer = ring
    }

    /// Rebuilds the ring path in layer y-up coordinates from the poster's actual rect.
    ///
    /// `posterRect` is the same single-source-of-truth rect GalleryTileContentView's own
    /// layout() uses for the tile content itself and updateShadowPath()/
    /// updateRingShadowGeometry() use for the drop shadows -- outset by `ringOutset` on all
    /// four sides via CGRect.insetBy(dx:dy:) with a negative amount (which grows, rather than
    /// shrinks, the rect symmetrically).
    ///
    /// Corner style: the system's CONTINUOUS ("squircle") curve, matching the poster it
    /// surrounds. GalleryTileContentView rounds the poster via Core Animation
    /// (`layer.cornerRadius` + `layer.cornerCurve = .continuous`), which has no path-producing
    /// counterpart: `CGPath(roundedRect:cornerWidth:cornerHeight:)` and
    /// `NSBezierPath(roundedRect:xRadius:yRadius:)` both offer exactly one corner style -- a
    /// constant-radius quarter-circle arc -- so a stroked path built from either can never
    /// agree with the poster's own corners.
    ///
    /// SwiftUI's `RoundedRectangle(cornerRadius:style:)` DOES accept `.continuous`, and every
    /// SwiftUI `Shape` can hand back the concrete outline it would draw for a given rect
    /// (`path(in:)` -> `Path` -> `.cgPath`). That is used here purely as a geometry calculator:
    /// the curve is computed by Apple's own code rather than approximated locally, and the
    /// resulting CGPath is handed to the same CAShapeLayer, stroked the same way, as before.
    /// No SwiftUI view is instantiated, mounted, or laid out -- see the import note at the top
    /// of this file, and the deliberate all-AppKit design of GalleryTileContentView.
    ///
    /// A hand-rolled superellipse approximation was tried here previously and rejected on
    /// visual comparison: a superellipse's exponent is a single global parameter controlling
    /// how "flat vs. pinched" the ENTIRE corner is, which is a fundamentally different degree
    /// of freedom from what Apple's continuous curve actually does (a piecewise curve, built
    /// from multiple Bezier segments matched for curvature continuity, that keeps a well-formed
    /// corner while extending the straight-edge-to-curve transition further than a circular
    /// arc). Asking SwiftUI for the real curve sidesteps that dead end entirely.
    ///
    /// One deliberate simplification: the ring is a parallel offset of the poster outline at
    /// `ringOutset` distance, and the exact parallel offset of a continuous curve is not itself
    /// a continuous curve of a larger radius. `Preferences.cornerRadius + ringOutset` is the
    /// same concentric-radius rule Apple uses for nested rounded rects throughout its own UI,
    /// and at a 3.5 pt offset the difference is well below one pixel.
    private func updateRingPath(posterRect: CGRect) {
        guard let ring = ringLayer else { return }

        let o = Self.ringOutset
        let ringRect = posterRect.insetBy(dx: -o, dy: -o)

        // RoundedRectangle honors the origin of the rect it is given, so the returned path is
        // already positioned in the layer's coordinate space -- no translation needed. The
        // shape is symmetric on both axes, so the layer's y-up (unflipped) orientation is
        // immaterial. Both radii come from the single ringCornerRadius constant, so the curve
        // stays uniform on all four corners regardless of the tile's 2:3 aspect ratio.
        ring.path = RoundedRectangle(cornerRadius: Self.ringCornerRadius, style: .continuous)
            .path(in: ringRect)
            .cgPath
    }

    /// Toggles the ring color between accent and clear, and refreshes the ring/ring-shadow
    /// geometry if the cell just became selected.
    private func updateRingVisibility() {
        guard let ring = ringLayer else { return }
        ring.strokeColor = currentIsSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        // The ring-top shadow only ever makes sense alongside a visible ring -- see the
        // ringShadowLayer doc comment below.
        ringShadowLayer?.shadowOpacity = currentIsSelected ? Self.tileShadowOpacity : 0

        // Selection can flip to true with no intervening viewDidLayout pass at all (an
        // ordinary click outside of a live resize) -- and viewDidLayout above now only
        // keeps the ring/ring-shadow geometry current while currentIsSelected is already
        // true, so a cell that just became selected needs its geometry refreshed right
        // here, once, rather than waiting for the next incidental layout pass. Safe to call
        // unconditionally whenever selection just turned on: view.bounds is already
        // authoritative at this point regardless of when the last layout pass ran, and this
        // method only runs on an actual selection-state change (isSelected's didSet, or
        // configure(with:) for a recycled cell landing directly on a selected index path)
        // -- never per-frame.
        if currentIsSelected, let posterRect = currentPosterRect() {
            updateRingPath(posterRect: posterRect)
            updateRingShadowGeometry(posterRect: posterRect)
        }
    }

    // MARK: - Ring-Top Shadow
    //
    // A selected cell's ring is meant to read with a subtle shadowed/dimmed band along its
    // inner edge -- a deliberate 3D-ish accent on selection. The plain CALayer shadowPath
    // used for the cell shadow (above) can't produce this by itself: moving it above the
    // ring would darken the entire poster interior too, since nothing there would mask it.
    // Instead, a second shadow -- identical in shape, color, radius, and offset to the
    // cell's own shadow, so it reads as "the same shadow" -- is added as the topmost
    // sublayer (above the ring), then masked with a copy of the ring's own stroked path.
    // The mask confines its visible area to exactly the ring's band, so only the ring
    // itself is ever dimmed; the poster interior is untouched. Its opacity is toggled with
    // the ring's own visibility in updateRingVisibility() above, so it only ever appears
    // alongside a visible (selected) ring.
    private var ringShadowLayer: CALayer?
    private var ringShadowMaskLayer: CAShapeLayer?

    private func createRingShadowLayerIfNeeded() {
        guard ringShadowLayer == nil, let layer = view.layer else { return }

        let shadow = CALayer()
        shadow.shadowColor = Self.tileShadowColor
        shadow.shadowRadius = Self.tileShadowRadius
        shadow.shadowOffset = Self.tileShadowOffset
        shadow.shadowOpacity = 0 // hidden until a cell is selected -- see updateRingVisibility()
        shadow.backgroundColor = nil
        shadow.actions = ["shadowPath": NSNull(), "shadowOpacity": NSNull(),
                           "bounds": NSNull(), "position": NSNull()]

        // A mask layer reveals its host layer's content only where the mask itself has
        // opaque pixels. Stroking the mask with the ring's own path/line width confines
        // the shadow above to exactly the ring's band.
        let mask = CAShapeLayer()
        mask.fillColor = nil
        mask.strokeColor = NSColor.white.cgColor // opacity-only; not a real display color
        mask.lineWidth = Self.ringLineWidth
        mask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        shadow.mask = mask
        ringShadowMaskLayer = mask

        // Added last, after the ring, so it paints on top of both the ring and the poster.
        layer.addSublayer(shadow)
        ringShadowLayer = shadow
    }

    /// Keeps the ring-top shadow's silhouette (poster-shaped, same as the cell shadow)
    /// and its mask (the ring's own band) in sync with the live cell geometry.
    private func updateRingShadowGeometry(posterRect: CGRect) {
        guard let ring = ringLayer, let shadow = ringShadowLayer, let mask = ringShadowMaskLayer
        else { return }

        shadow.frame = view.bounds
        mask.frame = view.bounds
        mask.path = ring.path
        shadow.shadowPath = CGPath.continuousRoundedRect(posterRect, cornerRadius: Preferences.cornerRadius)
    }

    // MARK: - Backing Scale Sync

    /// The backing scale factor the four manually-added sublayers were last synced to.
    /// 0 (never a real backing scale factor) means "not yet synced", so the first
    /// syncLayerContentsScale() pass always performs the full sync.
    private var lastSyncedContentsScale: CGFloat = 0

    /// Keeps every manually-added sublayer's `contentsScale` matched to the window's actual
    /// backing scale factor. Unlike an NSView's own primary layer -- which AppKit keeps
    /// synced to the window's backing scale automatically -- a plain CALayer added via
    /// `addSublayer(_:)` does NOT inherit this automatically and defaults to 1.0. Left
    /// unset, the shadow, ring, and ring-shadow layers would render their content (their
    /// shadow bitmaps and stroked paths) into a 1x-resolution backing store that the
    /// compositor then upscales for a Retina display, which can introduce soft, unevenly-
    /// distributed antialiasing along their edges -- and would go stale on its own if the
    /// window later moves from a Retina display to a non-Retina external monitor after
    /// these layers were already created. Called from every viewDidLayout pass (which also
    /// fires after a screen change moves/resizes the window), so this can never go stale;
    /// each write is guarded by an equality check first, so this is a cheap no-op on every
    /// call once the scale is already correct.
    ///
    /// Two allocation-free refinements, both of which matter because this runs for every
    /// visible cell on every layout tick of a live window resize:
    ///
    ///  • The scale actually applied to the four layers is memoized, so the common case is a
    ///    single CGFloat comparison rather than four optional unwraps and four property reads.
    ///    Safe because all four layers are created together in loadView(), before any layout
    ///    pass can run — there is no path by which a layer can appear later and miss a sync
    ///    the memo then suppresses — and because the memo's initial 0 can never equal a real
    ///    backing scale factor, so the first pass always performs the full sync.
    ///  • The four layers are written straight-line instead of through an array literal. The
    ///    literal built a fresh 4-element Swift Array (a heap allocation plus ARC traffic on
    ///    each element) on every single call, purely to iterate a fixed, statically known set.
    ///
    /// Each individual write is still guarded by its own equality check, exactly as before.
    private func syncLayerContentsScale() {
        let scale = unsafe view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2.0
        guard scale != lastSyncedContentsScale else { return }
        lastSyncedContentsScale = scale

        if let layer = shadowLayer, layer.contentsScale != scale { layer.contentsScale = scale }
        if let layer = ringLayer, layer.contentsScale != scale { layer.contentsScale = scale }
        if let layer = ringShadowLayer, layer.contentsScale != scale { layer.contentsScale = scale }
        if let layer = ringShadowMaskLayer, layer.contentsScale != scale { layer.contentsScale = scale }
    }
}
