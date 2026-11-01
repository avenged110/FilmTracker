// MARK: - GalleryItem.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// NSCollectionViewItem hosting a reused, pure-AppKit tile (GalleryTileContentView) for smooth scrolling. It
// also draws its own selection ring and drop shadow.

import Cocoa
// Imported only for RoundedRectangle and Path, which give the system's continuous ("squircle") corner
// outline. SwiftUI is used purely as a geometry calculator, and no view, hosting view, or layout pass is
// involved.
import SwiftUI

final class GalleryItem: NSCollectionViewItem, Loggable {
    nonisolated static let logTag = "[GalleryItem]"

    // Tile content view. Created once and reused.
    private var tileContentView: GalleryTileContentView?

    // Current state, used to skip redundant updates.
    private var currentFilmID: UUID?
    private var currentPosterUID: String?
    private var currentSubtitleText: String?
    private var currentIsSelected: Bool = false
    /// The selection state the ring and ring-top shadow are drawn for. It is kept apart from
    /// currentIsSelected, because prepareForReuse resets that one while a recycled cell's layers still show
    /// the previous film's ring.
    private var ringShowsSelection = false

    /// The in-flight asynchronous poster load for this cell, started only on a cache miss. It is canceled on
    /// reuse and superseded when a new load begins, so a recycled cell cannot be filled with the previous
    /// film's poster.
    private var posterLoadTask: Task<Void, Never>?

    // MARK: - Selection Ring (CAShapeLayer)
    //
    // The ring is a CAShapeLayer on view.layer with masksToBounds = false, so it can extend outside the cell
    // frame.
    //
    // Coordinates: GalleryItem.view is unflipped, so its layer uses y-up coordinates, with the origin at the
    // bottom-left. GalleryTileContentView is also unflipped and pinned edge to edge, so both views share one
    // space. GalleryTileGeometry. posterRect(inCellBounds:) is the single source of the poster rect, and it
    // needs no conversion.
    //
    // Poster position (y-up): the poster is inset by 2 pt (posterPadding) on each side, and its height is its
    // width times 1.5.
    //   posterTop    = cellHeight - 2
    //   posterBottom = cellHeight - 2 - (cellWidth - 4) * 1.5
    // cellHeight is view.bounds.height, and cellWidth is view.bounds.width. Each axis uses its own bounds, so
    // both stay exact even though column widths can differ by up to 0.5 pt.
    //
    // Ring geometry:
    //   gap = 1 pt, the clear space between the poster edge and the ring's inner edge
    //   lineWidth = 5 pt (Preferences.selectionLineWidth), stroked centered on the path
    //   ringOutset = gap + lineWidth / 2 = 3.5 pt, the distance from each poster edge to the ring path
    //   Ring rect: x = 2 - 3.5 = -1.5; width = (cellWidth - 4) + 7; height = (cellWidth - 4) * 1.5 + 7
    //   Corner radius = Preferences.cornerRadius + ringOutset = 12 + 3.5 = 15.5, which is concentric with the
    //   poster corner
    //
    // These constants are static, so they are computed once and not per cell.
    private static let ringLineWidth: CGFloat = Preferences.selectionLineWidth  // 5
    // Shared with GalleryTileContentView's subtitle-clearance math (23.50 GalleryItemView.swift) via
    // GalleryTileGeometry -- the single source of truth -- so the two can never drift.
    private static let ringGap: CGFloat = GalleryTileGeometry.ringGap
    // Distance from poster edge to ring path center = gap + lineWidth/2 = 3.5
    private static let ringOutset: CGFloat = ringGap + ringLineWidth / 2
    // Corner radius of the ring path, matching poster curvature at ringOutset distance.
    private static let ringCornerRadius: CGFloat = Preferences.cornerRadius + ringOutset  // 15.5

    private var ringLayer: CAShapeLayer?

    // MARK: - Poster Shadow (CALayer, shadowPath)
    //
    // The shadow uses an explicit shadowPath, so it is drawn from geometry alone and never samples layer
    // content. Recomputing it on every layout is cheap, which matters because layout runs for every visible
    // cell during a resize. The shadow layer is inserted first, so it paints behind the poster. The ring,
    // added later, paints on top.
    //
    // The shadow strength is fixed, whether the cell shows a poster or a placeholder.
    private var shadowLayer: CALayer?
    private static let tileShadowColor: CGColor = NSColor.black.cgColor
    private static let tileShadowRadius: CGFloat = 4
    // The y offset is 2 pt down in SwiftUI. Because this view is unflipped, the layer offset is negative.
    private static let tileShadowOffset = CGSize(width: 0, height: -2)
    private static let tileShadowOpacity: Float = 0.6

    // MARK: - Initialization
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        // Lets the shadow and selection ring extend beyond the cell bounds.
        view.layer?.masksToBounds = false

        // Order matters: the shadow is painted first, then the tile content, then the ring, then the ring-top
        // shadow.
        createShadowLayerIfNeeded()
        createTileContentViewIfNeeded()
        createRingLayerIfNeeded()
        createRingShadowLayerIfNeeded()
    }

    override func prepareForReuse() {
        super.prepareForReuse()

        cancelPosterLoad()

        // Clears the tracking state so configure() starts clean.
        currentFilmID = nil
        currentPosterUID = nil
        currentSubtitleText = nil
        currentIsSelected = false
    }

    // MARK: - Layout Recomputes the shadow, ring, and ring-shadow geometry on every layout, so they match the
    // live frame. posterRect is resolved once and shared by all three, rather than each one recomputing it
    // from view.bounds.
    override func viewDidLayout() {
        super.viewDidLayout()
        syncLayerContentsScale()
        guard let posterRect = currentPosterRect() else { return }
        updateShadowPath(posterRect: posterRect)
        // The ring and ring-top shadow are invisible for nearly every cell, since usually zero or one cell is
        // selected. Building their paths for every cell on every layout would be wasted work, so this is
        // deferred to the selected cells only. updateRingVisibility() rebuilds both when a cell becomes
        // selected, so the result is the same as rebuilding every frame.
        if currentIsSelected {
            updateRingPath(posterRect: posterRect)
            updateRingShadowGeometry(posterRect: posterRect)
        }
    }

    // MARK: - Selection NSCollectionView's isSelected provides immediate visual feedback during user
    // interaction.
    override var isSelected: Bool {
        didSet {
            currentIsSelected = isSelected
            if ringShowsSelection != isSelected { updateRingVisibility() }
        }
    }

    // MARK: - Configuration
    /// Accepts a FilmSnapshot value type, with no live model-object references.
    ///
    /// `subtitleProvider`, when non-nil, is queried for this film's subtitle on every call. GallerySubview's
    /// Coordinator pushes the provider here on every configuration, as it does for the film and poster. The
    /// subtitle is compared as resolved text, not as a provider identity. That covers a provider appearing,
    /// disappearing, or changing, such as switching Recents categories, with a single String? comparison.
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

        // Ring visibility must match what the cell last drew. Cells recycled onto or off a selected index
        // path need it. Only a mismatch triggers a re-stroke, since re-stroking each visible cell on every
        // film edit is wasted work.
        if ringShowsSelection != currentIsSelected { updateRingVisibility() }
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

    /// Resolves the poster image and pushes it, with the film ID and subtitle, into the tile content view. It
    /// runs only when configure(with:) detects a real change.
    ///
    /// CACHE-ONLY. This does not use PosterCache.getImageWithFallback, because its miss path reads and
    /// decodes from disk on the calling thread. Cells are often reconfigured during mouseDown, which runs at
    /// User-Interactive QoS. Blocking that thread on a lower-QoS disk read causes a priority inversion, which
    /// the Thread Performance Checker reports. The drag-preview path avoids disk for the same reason. A miss
    /// here starts an asynchronous load instead, and the tile is filled when it lands.
    private func refreshTileContent() {
        guard let tileContentView, let filmID = currentFilmID else { return }

        // Any load still in flight belongs to a previous configuration, so it is canceled.
        cancelPosterLoad()

        guard let posterUID = currentPosterUID, !posterUID.isEmpty else {
            tileContentView.configure(image: nil, filmID: filmID, subtitle: currentSubtitleText)
            return
        }

        // Cache hit, which is the usual case because the background restore keeps the cache warm. No disk
        // access.
        if let image = PosterCache.shared.getImageSync(for: posterUID) {
            tileContentView.configure(image: image, filmID: filmID, subtitle: currentSubtitleText)
            return
        }

        // Miss: the tile shows at once, without a poster, and is filled in later.
        tileContentView.configure(image: nil, filmID: filmID, subtitle: currentSubtitleText)
        beginPosterLoad(posterUID: posterUID, filmID: filmID)
    }

    /// Loads a missing poster off the main thread and applies it only if this cell still shows the same film
    /// and poster.
    private func beginPosterLoad(posterUID: String, filmID: UUID) {
        posterLoadTask = Task { @MainActor [weak self] in
            let image = await PosterCache.shared.getImageAsync(for: posterUID)
            guard let self, !Task.isCancelled, let image else { return }

            // Re-checks identity, since cancellation alone is not enough. A recycled cell could be
            // reconfigured while the load is awaited, and it would then be filled with the old film's poster.
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
        // The shadow has no fill of its own. Only its shadowPath is visible.
        shadow.backgroundColor = nil
        // Disables implicit Core Animation so the shadow tracks the tile in step during resize, with no lag.
        shadow.actions = ["shadowPath": NSNull(), "shadowOpacity": NSNull(),
                           "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(shadow)
        shadowLayer = shadow
    }

    /// The poster's rect in layer y-up coordinates, with no outset. The cell shadow and the ring-top shadow
    /// both use it, so they match. It comes from GalleryTileGeometry.posterRect(inCellBounds:), which
    /// GalleryTileContentView also uses.
    private func currentPosterRect() -> CGRect? {
        GalleryTileGeometry.posterRect(inCellBounds: view.bounds)
    }

    /// The cell bounds the shadow layer's frame and shadowPath were last built for. `.null` (never equal to
    /// any real rect, including .zero) means "not yet built", so the very first layout pass always performs a
    /// full build.
    ///
    /// Deliberately NOT reset in prepareForReuse: this memo and the shadow layer it describes live on the
    /// same GalleryItem instance and are never torn down independently, so they stay in lockstep across every
    /// reuse. A recycled cell landing at an unchanged size already carries the correct shadow geometry; one
    /// landing at a different size gets a layout pass (bounds changed), which rebuilds it here.
    private var lastShadowBounds: CGRect = .null

    /// Rebuilds the shadow's path from the poster's actual rect (shared with the ring and ring-shadow layers
    /// via viewDidLayout, so all three always agree on the same shape).
    ///
    /// Short-circuits when the cell's bounds are unchanged since the last build. `posterRect` is a pure
    /// function of `view.bounds` (see GalleryTileGeometry.posterRect(inCellBounds:)), so equal bounds means
    /// an identical path and an identical layer frame — rebuilding both would be byte-for-byte redundant.
    /// This costs nothing during a live resize (where the bounds genuinely change every tick) and eliminates
    /// the CGPath allocation plus the shadow-bitmap regeneration it forces on every OTHER layout pass, of
    /// which AppKit issues a fair number at identical geometry (a second pass within the same cycle, a
    /// re-layout after a window occlusion/appearance change, the settle pass at the end of a sidebar-toggle
    /// animation), multiplied by every visible cell each time.
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
        // Disable implicit CA animations so the ring snaps on/off immediately and the path updates without
        // morphing during window resize.
        ring.actions = ["strokeColor": NSNull(), "path": NSNull()]
        layer.addSublayer(ring)
        ringLayer = ring
    }

    /// Rebuilds the ring path in layer y-up coordinates from the poster's rect, outset by `ringOutset` on all
    /// sides.
    ///
    /// The poster is rounded by Core Animation with `cornerCurve = .continuous`. Path APIs such as
    /// CGPath(roundedRect:) and NSBezierPath only produce circular corners, so they cannot match it.
    /// SwiftUI's RoundedRectangle(style: .continuous) does, and its path(in:) gives the same outline. That
    /// outline is used here only for geometry, so no SwiftUI view is created.
    ///
    /// A superellipse was tried earlier and rejected, because its single exponent does not match Apple's
    /// continuous curve.
    ///
    /// The ring is a parallel offset of the poster outline. The exact offset of a continuous curve is not
    /// itself continuous, so `cornerRadius + ringOutset` is used, which is the concentric-radius rule. At 3.5
    /// pt the difference is under one pixel.
    private func updateRingPath(posterRect: CGRect) {
        guard let ring = ringLayer else { return }

        let o = Self.ringOutset
        let ringRect = posterRect.insetBy(dx: -o, dy: -o)

        // RoundedRectangle keeps the origin of the rect it is given, so the path is already in layer
        // coordinates. The shape is symmetric, so the y-up orientation does not matter. Both radii use
        // ringCornerRadius, so all four corners match.
        ring.path = RoundedRectangle(cornerRadius: Self.ringCornerRadius, style: .continuous)
            .path(in: ringRect)
            .cgPath
    }

    /// Toggles the ring between the accent color and clear. If the cell just became selected, it also
    /// refreshes the ring geometry.
    private func updateRingVisibility() {
        guard let ring = ringLayer else { return }
        #if DEBUG
        GalleryRefreshProbe.ringRefreshes += 1
        #endif
        ringShowsSelection = currentIsSelected
        ring.strokeColor = currentIsSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        // The ring-top shadow only shows alongside a visible ring. See ringShadowLayer below.
        ringShadowLayer?.shadowOpacity = currentIsSelected ? Self.tileShadowOpacity : 0

        // Selection can turn on without a layout pass, such as a plain click. viewDidLayout only refreshes
        // the ring while the cell is already selected, so the geometry is refreshed here. view.bounds is
        // current at this point, and this runs only when the ring is drawn for a selection change, never per
        // frame.
        if currentIsSelected, let posterRect = currentPosterRect() {
            updateRingPath(posterRect: posterRect)
            updateRingShadowGeometry(posterRect: posterRect)
        }
    }

    #if DEBUG
    /// Whether the ring is currently stroked. Used by the debug harness.
    var debugRingShowsSelection: Bool { (ringLayer?.strokeColor?.alpha ?? 0) > 0 }
    #endif

    // MARK: - Ring-Top Shadow A selected ring is meant to read with a shadowed inner edge. The cell shadow
    // cannot do this, because a shadow above the ring would also darken the poster. So a second shadow, the
    // same shape and offset as the cell shadow, sits above the ring and is masked to the ring's band. Only
    // the ring is dimmed, and the poster is untouched. Its opacity follows the ring's visibility in
    // updateRingVisibility().
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

        // A mask shows its host's content only where the mask is opaque. Stroking the mask with the ring's
        // path and line width confines the shadow to the ring's band.
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

    /// Keeps the ring-top shadow's silhouette (poster-shaped, as the cell shadow is) and its mask (the ring's
    /// band) in sync with the live cell geometry.
    private func updateRingShadowGeometry(posterRect: CGRect) {
        guard let ring = ringLayer, let shadow = ringShadowLayer, let mask = ringShadowMaskLayer
        else { return }

        shadow.frame = view.bounds
        mask.frame = view.bounds
        mask.path = ring.path
        shadow.shadowPath = CGPath.continuousRoundedRect(posterRect, cornerRadius: Preferences.cornerRadius)
    }

    // MARK: - Backing Scale Sync
    /// The backing scale factor the four manually-added sublayers were last synced to. 0 (never a real
    /// backing scale factor) means "not yet synced", so the first syncLayerContentsScale() pass always
    /// performs the full sync.
    private var lastSyncedContentsScale: CGFloat = 0

    /// Keeps each manually added sublayer's `contentsScale` matched to the window's backing scale. A plain
    /// CALayer added with addSublayer(_:) defaults to 1.0, unlike the view's own layer. Without this sync,
    /// the shadow, ring, and ring-shadow content would be drawn at 1x and upscaled on Retina. It would also
    /// go stale when the window moves between displays. It runs from every viewDidLayout, and each write is
    /// guarded by an equality check, so the call is cheap when the scale is correct.
    ///
    /// Two refinements avoid allocations, since this runs for every visible cell on every resize tick:
    ///
    ///  • The applied scale is memoized, so the usual case is one CGFloat comparison. This is safe because all four layers are
    ///    created in loadView(), before any layout, and the memo's initial 0 never matches a real scale.
    ///  • The four layers are written straight through, not in an array literal, which would allocate on every call.
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
