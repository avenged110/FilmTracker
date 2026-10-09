// MARK: - GalleryItemView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Pure-AppKit gallery tile content. GalleryItem (23_40_GalleryItem.swift) pins
// GalleryTileContentView edge-to-edge inside the cell, alongside its own selection-ring
// and drop-shadow CALayers.
//
// Being pure AppKit means every single cell reuse, and every layout tick of a live window
// resize, involves no SwiftUI view-tree diffing or AttributeGraph node updates and no
// SwiftUI-managed layout pass. Image display is driven entirely by CALayer.contentsGravity
// = .resizeAspectFill (the AppKit/CoreAnimation equivalent of SwiftUI's `.scaledToFill()`):
// the GPU compositor scales and crops from the layer's own contents metadata, so there is no
// per-cell or per-layout-tick CPU image work at all. Everything else (placeholder icon/label,
// optional subtitle) is built from plain NSImageView/NSTextField instances, configured with a
// handful of property writes and no view-tree diffing of any kind.

import AppKit

// MARK: - Subtitle Provider
/// Closure that provides a subtitle string for a given film ID. Returns nil if no subtitle
/// should be displayed. A plain value type. GalleryView builds one instance per active view;
/// GallerySubview forwards it straight into GalleryItem.configure(with:subtitleProvider:) on
/// every cell (re)configuration, the same explicit-value-push discipline this pipeline uses
/// for everything else a cell needs to render itself.
struct GallerySubtitleProvider {
    /// Identifies WHICH subtitle this provider produces — not which instance it is.
    ///
    /// A closure has no usable identity, so before this existed the only thing
    /// downstream could compare about a provider was whether it was nil. That is
    /// enough to notice subtitles appearing or disappearing, but not enough to
    /// notice one KIND of subtitle being swapped for another — which is exactly
    /// what happens on every Recents sub-tab switch, where the provider goes
    /// from (say) "date added" to "last watched" while remaining non-nil
    /// throughout. `GallerySubview` compares this to decide whether already-
    /// configured cells still hold valid text; see the `subtitleKindChanged`
    /// handling in its `updateNSView`.
    ///
    /// Built from the `MetadataCache.DateType` the provider reads, so two
    /// providers for the same category compare equal no matter how many times
    /// they are reconstructed.
    let kind: String
    let subtitle: (UUID) -> String?

    init(kind: String, subtitle: @escaping (UUID) -> String?) {
        self.kind = kind
        self.subtitle = subtitle
    }
}

// MARK: - Shared Tile Geometry
/// Single source of truth for the poster's rect within a gallery cell of a given size --
/// consumed by both GalleryTileContentView's own layout() below and by GalleryItem's selection-
/// ring / drop-shadow CALayers (see GalleryItem.currentPosterRect(), which delegates here), so
/// the tile image, the ring, and the shadow can never disagree about the tile's geometry.
///
/// A 2pt inset on all sides around a box whose height is derived from its own (post-inset)
/// width at a fixed 2:3 (width:height) aspect ratio, top-aligned within the cell. Because
/// GalleryTileContentView is a plain, unflipped (y-up) NSView, this single computation serves
/// both the ring/shadow layers and the tile content directly, with no y-down -> y-up
/// conversion step required (see GalleryItem.swift's coordinate-system comment).
enum GalleryTileGeometry {
    /// Inset applied on all four sides of the cell before computing the poster box.
    static let posterPadding: CGFloat = 2
    /// Poster height as a multiple of its own (post-inset) width -- a fixed 2:3 (width:height)
    /// aspect ratio.
    static let posterHeightMultiplier: CGFloat = 1.5
    /// Clear space, in points, between the poster's edge and the selection ring's inner edge
    /// (see GalleryItem's ring geometry comment). Shared here -- rather than duplicated as a
    /// private literal in both GalleryItem (which draws the ring) and GalleryTileContentView
    /// (which uses it to keep the subtitle clear of the ring) -- so the two can never drift
    /// out of sync.
    static let ringGap: CGFloat = 1

    /// The poster's rect within a cell of the given bounds, in the cell's own unflipped (y-up)
    /// coordinate space: inset by `posterPadding` on all sides, width-derived height, top-aligned
    /// (so a subtitle row's extra height below the poster never shrinks the poster itself).
    /// Returns nil for a degenerate (zero or negative) available width.
    static func posterRect(inCellBounds bounds: CGRect) -> CGRect? {
        let p = posterPadding
        let posterWidth = bounds.width - 2 * p
        guard posterWidth > 0 else { return nil }
        let posterHeight = posterWidth * posterHeightMultiplier
        let posterTopY = bounds.height - p
        let posterBottomY = posterTopY - posterHeight
        return CGRect(x: p, y: posterBottomY, width: posterWidth, height: posterHeight)
    }
}

// MARK: - Gallery Tile Content View
/// Pinned edge-to-edge inside GalleryItem, so its own `bounds` always equals the cell's
/// `view.bounds` -- GalleryTileGeometry.posterRect(inCellBounds:) therefore produces the
/// identical rect GalleryItem's ring/shadow layers already trace, with no geometry hand-off.
final class GalleryTileContentView: NSView {

    // MARK: - Subviews
    /// Clips the poster image (or placeholder) to the tile's rounded-rect shape. Its own frame
    /// is set to GalleryTileGeometry.posterRect(inCellBounds:) on every layout() pass.
    private let clippedContainer = NSView()
    private var imageContentView: NSView?
    private var placeholderImageView: NSImageView?
    private var placeholderLabel: NSTextField?
    private var subtitleLabel: NSTextField?
    /// Soft inner-shadow band over the poster's edges -- see 23.55 PosterEdgeSheen.swift. Added
    /// to clippedContainer in init (so its mask clips it); the image content view is always
    /// inserted at the BOTTOM of the stack, so the sheen stays above it by construction. Hidden
    /// while the placeholder is shown.
    private let edgeSheenView = PosterEdgeSheen.makeView()

    // MARK: - Current Configuration
    private var currentImage: NSImage?
    private var currentFilmID: UUID = UUID()
    private var currentSubtitle: String?

    // MARK: - Cached Text Metrics
    //
    // `NSTextField.intrinsicContentSize` is a real text-layout measurement, not a stored
    // property read. The subtitle label was measuring on every single layout() pass — i.e.
    // for every visible cell on every tick of a live window resize — even though its text,
    // font, and line count do not change during a resize at all. Only the cell's geometry
    // does, and the measurement does not depend on it: the subtitle is laid out at the full
    // cell width using only its natural HEIGHT.
    //
    // The memo is cleared in configure(), which is the sole entry point through which the
    // subtitle's string can change (updateSubtitle() sets it) and also the sole point at
    // which the label instance can be created or destroyed. Font and color are static
    // constants, and neither varies with effective appearance, so there is no other
    // invalidation source to account for.
    private var cachedSubtitleHeight: CGFloat?

    /// The point size centerLabel() last ESTIMATED for the placeholder label (see the note
    /// there on why the estimate rather than the applied size is the memo key), so a resize
    /// only touches `NSTextField.font` — and only measures — on the passes where the computed
    /// size actually changed. Also cleared in configure(), which is the only place the label
    /// can be replaced by a fresh instance carrying the base font instead of the fitted one.
    private var appliedPlaceholderFontSize: CGFloat?

    // MARK: - Styling
    private static let cornerRadius: CGFloat = Preferences.cornerRadius
    // Matches the prior SwiftUI placeholder fill exactly: `Color(nsColor: .windowBackgroundColor)`
    // (an earlier `Color.secondary.opacity(0.2)` was replaced with this opaque, dynamic fill so
    // nothing behind it -- e.g. the cell's own drop-shadow layer -- could show through).
    private static let placeholderBackgroundColor = NSColor.windowBackgroundColor
    // The placeholder's UUID-suffix label. Monospaced rather than the system face, for two
    // reasons: it is a hex identifier, which reads better in a fixed-advance font, and a
    // fixed advance is what lets centerLabel() compute the string's rendered width
    // arithmetically and pick a point size guaranteed to fit (see that method). The size
    // here is a placeholder -- centerLabel() replaces the font with the fitted one on the
    // first layout pass -- so it only has to be a valid font, not the right one.
    private static let smallLabelFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    /// Width of one character in the monospaced face above, per point of font size. Every
    /// glyph in a monospaced font advances identically, so measuring the em advance once at a
    /// known size yields the ratio for every size. Resolved once per session.
    private static let monospacedUnitAdvance: CGFloat = {
        let probe = NSFont.monospacedSystemFont(ofSize: 100, weight: .regular)
        return probe.maximumAdvancement.width / 100
    }()

    /// Character count of the string the placeholder label renders -- see
    /// `UUID.placeholderIDSuffix`, which is the sole producer of that string.
    private static let placeholderLabelCharacterCount = 10
    /// Ceiling on the fitted point size, as a fraction of the poster box's height, so a tile
    /// that is wide relative to its height cannot yield text taller than the glyph behind it.
    private static let placeholderLabelHeightFactor: CGFloat = 0.14
    /// Floor on the fitted point size. Below this the text stops being readable at all, at
    /// which point letting it overrun its band is the better failure.
    private static let placeholderLabelMinFontSize: CGFloat = 8
    /// Horizontal space an `NSTextField` consumes around its string — the text container's
    /// line-fragment padding on each side plus the cell's own margin — and therefore the part
    /// of the label's frame the glyph run cannot use. Reserved before fitting the font, so the
    /// fitted string lands inside the drawable area rather than exactly on the frame it will
    /// then be truncated to fit. Deliberately a little generous; centerLabel() verifies the
    /// result against a real measurement, so over-reserving costs a fraction of a point of
    /// text size and under-reserving would cost a character.
    private static let placeholderLabelCellInset: CGFloat = 8
    private static let secondaryTextColor = NSColor.secondaryLabelColor
    // Matches the prior placeholder's `Image(systemName: "film").resizable().scaledToFit()
    // .padding(20)` -- the icon is inset this far from the poster box's own edges on all sides.
    private static let placeholderIconInset: CGFloat = 20
    private static let placeholderIconAlpha: CGFloat = 0.4
    private static let placeholderLabelAlpha: CGFloat = 0.6

    // Same 10pt size as the prior SwiftUI subtitle, one weight step heavier (regular -> semibold)
    // for improved legibility against the poster.
    private static let subtitleFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    // The selection ring (see GalleryItem.swift) strokes at Preferences.selectionLineWidth,
    // centered on a path offset (ringGap + lineWidth/2) beyond the tile's own edge -- so its
    // outermost visible pixel extends (ringGap + lineWidth) beyond the tile edge once a cell is
    // selected. ringGap comes from GalleryTileGeometry -- the single source of truth shared with
    // GalleryItem's own ring geometry -- so the two can never drift out of sync.
    private static let ringVisualOverhang: CGFloat =
        GalleryTileGeometry.ringGap + Preferences.selectionLineWidth  // 6
    // Gap between the tile's own bottom edge and the subtitle text below it -- exactly the
    // selection ring's full visual overhang, so the ring's outermost edge and the subtitle's
    // top edge just meet without overlapping, even when a cell is selected.
    private static let subtitleTopGap: CGFloat = ringVisualOverhang  // 6
    // How far the subtitle label may extend past EACH side edge of the cell, into the
    // inter-column gutter. At a 100pt minimum column width (Preferences.galleryMinItemWidth)
    // the widest date the subtitle can ever show -- "September 30, 2044" at 10pt semibold
    // measures ~104pt -- is a few points wider than the cell, so it was truncating by a
    // couple of characters right before the column count dropped. The gutter is 16pt
    // (SmoothResizingGridLayout.itemSpacing), so a 5pt reach into it on each side is
    // imperceptible as overflow yet gives the label 10pt more than the cell. The cell's
    // layer does not mask to bounds (the selection ring already overhangs it), so nothing
    // clips the overhang.
    private static let subtitleSideOverhang: CGFloat = 5

    // MARK: - Init
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        clippedContainer.wantsLayer = true
        clippedContainer.layer?.masksToBounds = true
        clippedContainer.layer?.cornerRadius = Self.cornerRadius
        // Continuous (superellipse/"squircle") corner curve, where the straight edge blends
        // gradually into the arc, rather than CALayer's `.circular` default -- a constant-
        // radius quarter-circle that meets the straight edge more abruptly. This is the corner
        // style every poster site in the app uses (the list thumbnail, the RightSidebar Header
        // and the FilmSheet Poster tab all pass `style: .continuous` to their SwiftUI
        // RoundedRectangle -- SwiftUI's own default is `.circular`, so it must be explicit
        // there too), and the sheen overlay's corner fall-off (PosterEdgeSheen.Profile.grid)
        // and the selection ring (GalleryItem) are both built for this same curve.
        clippedContainer.layer?.cornerCurve = .continuous
        clippedContainer.layer?.backgroundColor = Self.placeholderBackgroundColor.cgColor
        clippedContainer.addSubview(edgeSheenView)
        addSubview(clippedContainer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The placeholder fill is a raw CALayer color, which — unlike an NSColor assigned to a
    // view property — is a snapshot of the appearance it was resolved under and never
    // updates itself. Cells are recycled rather than recreated, so without this a light ⇄
    // dark switch left every placeholder tile in the old appearance's fill for as long as
    // the gallery stayed mounted. Same remedy as SectionDividerDecorationView's rule.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        clippedContainer.layer?.backgroundColor = Self.placeholderBackgroundColor.cgColor
    }

    // Unflipped (y-up), matching GalleryItem.view and every CALayer it hosts -- see
    // GalleryTileGeometry's doc comment for why this removes the y-down -> y-up conversion
    // the prior NSHostingView-based implementation required.
    override var isFlipped: Bool { false }

    // MARK: - Configuration
    /// Sets all content. Cheap to call on every cell reuse: a handful of property writes and,
    /// only when the image actually changed, one CGImage extraction for the content layer's
    /// `contents` -- no view-tree diffing of any kind. The caller (GalleryItem) is responsible
    /// for only invoking this when something actually changed; this method itself always
    /// unconditionally rebuilds what it's given.
    func configure(image: NSImage?, filmID: UUID, subtitle: String?) {
        currentImage = image
        currentFilmID = filmID
        currentSubtitle = subtitle

        // Discard the cached text metrics before the label content below is rebuilt — see the
        // "Cached Text Metrics" section above. Cleared unconditionally rather than only when
        // the relevant string actually changed: this method already documents itself as
        // unconditionally rebuilding whatever it is given, and a redundant re-measure on the
        // next layout pass is far cheaper than any bookkeeping that could drift.
        appliedPlaceholderFontSize = nil
        cachedSubtitleHeight = nil

        updateImageContent()
        updateSubtitle()
        needsLayout = true
    }

    // MARK: - Layout
    override func layout() {
        super.layout()
        guard let posterRect = GalleryTileGeometry.posterRect(inCellBounds: bounds) else { return }

        // Snaps each of posterRect's four edges independently to the nearest DEVICE pixel
        // boundary (not just the nearest point) before handing it to clippedContainer. Unlike
        // the selection ring's 5pt stroke -- thick enough that a sub-device-pixel misalignment
        // is imperceptible -- clippedContainer's rounded-rect mask and the image content filling
        // it are a hard, high-contrast edge, where the same sub-pixel misalignment reads as a
        // visibly shaved sliver along whichever edge landed just inside a pixel boundary rather
        // than on it. This mirrors the exact rationale AppKit itself applies automatically to a
        // window's own content, snapping a fractional-point rect to whichever device pixel grid
        // is actually being rasterized to (2x on Retina, 1x otherwise) -- it does NOT change the
        // rect's nominal position or size by more than a fraction of a point, so it cannot
        // reopen or close the deliberate gap the selection ring's geometry (still computed from
        // this same unmodified posterRect via GalleryItem.currentPosterRect()) assumes exists.
        let renderedRect = devicePixelAlignedRect(posterRect)

        clippedContainer.frame = renderedRect
        let contentBounds = CGRect(origin: .zero, size: renderedRect.size)
        imageContentView?.frame = contentBounds
        edgeSheenView.frame = contentBounds
        if let placeholderImageView {
            layoutPlaceholderIcon(placeholderImageView, in: contentBounds)
        }
        if let placeholderLabel {
            centerLabel(placeholderLabel, in: contentBounds)
        }
        if let subtitleLabel {
            layoutSubtitle(subtitleLabel, tileBottomY: renderedRect.minY)
        }
    }

    /// Rounds each edge of `rect` independently to the nearest device pixel, using the actual
    /// backing scale factor of the screen this view is currently displayed on (2.0 on Retina,
    /// 1.0 otherwise). Falls back to the key window's screen, then the main screen, for the rare
    /// case this runs before the view is attached to a window -- a stale scale here only costs a
    /// redundant antialiasing pass on the next real layout, never a crash or a permanently
    /// misaligned edge.
    private func devicePixelAlignedRect(_ rect: CGRect) -> CGRect {
        let scale = unsafe window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        func aligned(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let left = aligned(rect.minX)
        let right = aligned(rect.maxX)
        let top = aligned(rect.maxY)
        let bottom = aligned(rect.minY)
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    /// Centers the UUID-suffix label on the placeholder glyph and sizes its font to the band
    /// it is allowed to occupy.
    ///
    /// The label used to be framed at its own `intrinsicContentSize` at a fixed 10pt, clamped
    /// to the poster box. That is what produced the truncated "XXXXXXXX…" at a size far below
    /// the glyph it labels: the text was laid out to whatever a 10pt string happened to
    /// measure, with nothing tying it to the space actually available.
    ///
    /// It is now the other way round — the band is fixed by geometry and the font is fitted to
    /// it. The band is inset by half of `placeholderIconInset` on each side, i.e. each of its
    /// edges sits halfway between the corresponding edge of the glyph (inset by the full
    /// amount) and of the poster box itself, so the text reads as belonging to the glyph
    /// without crowding either boundary.
    ///
    /// Fitting the font needs the rendered width of the string. A monospaced face is used (see
    /// `smallLabelFont`) so that width is arithmetic rather than a text-layout pass: every one
    /// of the ten hex characters advances by the same amount, so the glyph run measures
    /// `10 * unitAdvance * pointSize`. `placeholderLabelHeightFactor` then caps the result so a
    /// short, wide tile cannot produce text taller than the glyph.
    ///
    /// The glyph run is NOT the whole story, and this is what kept the ellipsis on screen after
    /// the band itself was already the right size: an `NSTextField` does not draw its string
    /// edge to edge. Its cell insets the text horizontally (the text container's line-fragment
    /// padding plus the cell's own margin), so a font sized to fill the band exactly overflows
    /// the drawable area inside it by a few points and the tail gets truncated — with ten
    /// characters that costs the last one or two plus an ellipsis, which is precisely the
    /// "8 characters and a …" symptom. `placeholderLabelCellInset` reserves that overhead
    /// before the division.
    ///
    /// Because that inset is an AppKit implementation detail rather than a documented constant,
    /// the arithmetic is treated as an estimate and verified once against the real thing: after
    /// the font is applied, `intrinsicContentSize` — the actual laid-out width, cell inset
    /// included — is compared to the band, and the size is scaled down and re-applied if it
    /// still does not fit. That runs only on the passes where the computed point size changed,
    /// never on the steady-state layout passes this class is careful about, and it makes the
    /// no-truncation guarantee independent of whether the estimate above is exactly right.
    private func centerLabel(_ label: NSTextField, in rect: CGRect) {
        let inset = Self.placeholderIconInset / 2
        let available = max(0, rect.width - inset * 2)
        let drawable = max(1, available - Self.placeholderLabelCellInset)

        let widthFitted = drawable / (CGFloat(Self.placeholderLabelCharacterCount)
                                      * Self.monospacedUnitAdvance)
        let heightCapped = rect.height * Self.placeholderLabelHeightFactor
        // Rounded DOWN so the fitted width stays at or under the band even after rounding,
        // and floored so a very small tile degrades to a legible size rather than to nothing.
        var pointSize = max(Self.placeholderLabelMinFontSize,
                            min(widthFitted, heightCapped).rounded(.down))
        // Memoized on the ESTIMATE, not on whatever the verification below settles on.
        // Keying it on the corrected size would compare this pass's fresh estimate against
        // the previous pass's correction, never match, and re-run the measurement on every
        // single layout pass — exactly the per-pass text layout this class avoids.
        let estimate = pointSize

        if appliedPlaceholderFontSize != estimate {
            label.font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)

            // The verification pass described above. One correction is sufficient: the
            // measured width is linear in the point size, so scaling by the ratio it reports
            // lands inside the band, and the floor keeps the loop from ever running away.
            let measured = label.intrinsicContentSize.width
            if measured > available, measured > 0 {
                pointSize = max(Self.placeholderLabelMinFontSize,
                                (pointSize * available / measured).rounded(.down))
                label.font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
            }
            appliedPlaceholderFontSize = estimate
        }

        // Font metrics, not a layout measurement: boundingRectForFont is a stored property of
        // the font itself and does not depend on the string.
        let height = (label.font?.boundingRectForFont.height ?? pointSize).rounded(.up)
        // The label is centered (see makeLabel), so the text centers itself inside the band.
        label.frame = CGRect(x: rect.minX + inset, y: rect.midY - height / 2,
                              width: available, height: height)
    }

    /// Top-aligns the subtitle label within the reserved band below the tile, with
    /// `subtitleTopGap` of clearance from the tile's own (device-pixel-aligned) bottom edge --
    /// exactly enough to clear the selection ring's full visual overhang, so the ring's
    /// outermost edge and the subtitle's top edge just meet without overlapping, even when the
    /// cell is selected. Horizontal centering matches the prior SwiftUI VStack's default
    /// (horizontal) alignment of `.center`.
    private func layoutSubtitle(_ label: NSTextField, tileBottomY: CGFloat) {
        let naturalHeight: CGFloat
        if let cached = cachedSubtitleHeight {
            naturalHeight = cached
        } else {
            naturalHeight = label.intrinsicContentSize.height
            cachedSubtitleHeight = naturalHeight
        }
        let topY = tileBottomY - Self.subtitleTopGap
        let originY = max(0, topY - naturalHeight)
        label.frame = CGRect(x: -Self.subtitleSideOverhang, y: originY,
                             width: bounds.width + 2 * Self.subtitleSideOverhang,
                             height: naturalHeight)
    }

    /// The unconfigured "film" system symbol, resolved once per session rather than on every
    /// call. `NSImage(systemSymbolName:)` is a catalog lookup, not a free reference.
    private static let placeholderIconBaseImage =
        NSImage(systemSymbolName: "film", accessibilityDescription: nil)

    /// Single-entry memo for the point-size-configured placeholder glyph, shared by every
    /// cell. Every visible tile in the grid is exactly the same size at any given instant, so
    /// one entry serves the whole viewport; were two grids ever mounted at different sizes
    /// simultaneously, the memo would simply thrash back to the previous per-call rebuild
    /// behavior, never to an incorrect image (the resolved instance is always assigned to the
    /// image view below). Static storage on an NSView subclass is MainActor-isolated under
    /// Swift 6 strict concurrency, matching every caller.
    private static var cachedPlaceholderIconPointSize: CGFloat = 0
    private static var cachedPlaceholderIcon: NSImage?

    private static func placeholderIcon(pointSize: CGFloat) -> NSImage? {
        if let cached = cachedPlaceholderIcon, cachedPlaceholderIconPointSize == pointSize {
            return cached
        }
        guard let base = placeholderIconBaseImage else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let configured = base.withSymbolConfiguration(config)
        cachedPlaceholderIcon = configured
        cachedPlaceholderIconPointSize = pointSize
        return configured
    }

    /// Positions the placeholder glyph and keeps its symbol configuration current.
    ///
    /// The glyph's requested point size is quantized to whole points. This is visually inert:
    /// the image view scales proportionally to fill `iconRect` regardless (`imageScaling =
    /// .scaleProportionallyUpOrDown`, set in showPlaceholder()), so the point size governs only
    /// the symbol's rasterization detail and stroke weight, never its rendered size or
    /// position. What it buys is that a live window resize — which sweeps the icon rect
    /// continuously — crosses a whole-point boundary a handful of times per second rather than
    /// producing a distinct configuration on every one of its ~60 layout ticks per second, for
    /// every placeholder cell on screen. Combined with the shared memo and the identity check
    /// below, the previous behavior (a fresh catalog lookup, a fresh SymbolConfiguration, a
    /// fresh configured NSImage, and an unconditional `imageView.image` write that dirtied the
    /// view for redisplay — all of it per cell, per tick) collapses to a frame assignment for
    /// the overwhelming majority of passes.
    private func layoutPlaceholderIcon(_ imageView: NSImageView, in bounds: CGRect) {
        let iconRect = bounds.insetBy(dx: Self.placeholderIconInset, dy: Self.placeholderIconInset)
        imageView.frame = iconRect
        let glyphPointSize = max(1, min(iconRect.width, iconRect.height)).rounded()
        let icon = Self.placeholderIcon(pointSize: glyphPointSize)
        // Identity, not equality: the memo hands back the very same instance for an unchanged
        // point size, so `!==` is an exact "nothing to do" test and avoids NSImage equality.
        if imageView.image !== icon { imageView.image = icon }
    }

    // MARK: - Image Content
    /// Displays the resolved poster image via a plain CALayer with `contentsGravity =
    /// .resizeAspectFill` -- the CoreAnimation equivalent of SwiftUI's `.scaledToFill()` -- or
    /// falls back to the placeholder (film glyph + UUID suffix) when no image is available.
    /// `contentsGravity` selects and scales the visible portion of the image at composite time
    /// from the layer's own metadata; there is no CPU-side cropping or redrawing on any call,
    /// including every layout tick of a live window resize.
    private func updateImageContent() {
        guard let image = currentImage else {
            imageContentView?.removeFromSuperview()
            imageContentView = nil
            edgeSheenView.isHidden = true
            showPlaceholder()
            return
        }
        hidePlaceholder()
        edgeSheenView.isHidden = false

        let contentView: NSView
        if let existing = imageContentView {
            contentView = existing
        } else {
            let newView = NSView()
            newView.wantsLayer = true
            // Disables implicit CA animations for these keys so the image layer's contents/frame
            // snap immediately on every reuse and every resize tick, rather than cross-fading or
            // lagging toward the new value at Core Animation's default ~0.25s -- the same
            // discipline GalleryItem's ring and drop-shadow layers already apply.
            newView.layer?.actions = ["contents": NSNull(), "contentsRect": NSNull(),
                                       "bounds": NSNull(), "position": NSNull()]
            // Ordinary NSView subview insertion (not a manually-inserted sublayer directly on
            // clippedContainer's own layer) -- positioned at the very bottom of its subview
            // stack so the placeholder (added the same way) can sit visually behind or in front
            // of it as needed via ordinary subview z-ordering, never via a hand-managed sublayer
            // array AppKit could reorder unpredictably.
            clippedContainer.addSubview(newView, positioned: .below, relativeTo: nil)
            imageContentView = newView
            contentView = newView
        }

        var proposedRect = NSRect(origin: .zero, size: image.size)
        let cgImage = unsafe image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        contentView.layer?.contents = cgImage
        contentView.layer?.contentsScale = unsafe window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2.0
        contentView.layer?.contentsGravity = .resizeAspectFill
    }

    private func showPlaceholder() {
        if placeholderImageView == nil {
            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.contentTintColor = Self.secondaryTextColor
            imageView.alphaValue = Self.placeholderIconAlpha
            clippedContainer.addSubview(imageView, positioned: .below, relativeTo: nil)
            placeholderImageView = imageView
        }
        if placeholderLabel == nil {
            let label = Self.makeLabel(font: Self.smallLabelFont, color: Self.secondaryTextColor,
                                        alignment: .center)
            label.alphaValue = Self.placeholderLabelAlpha
            clippedContainer.addSubview(label)
            placeholderLabel = label
        }
        placeholderLabel?.stringValue = currentFilmID.placeholderIDSuffix
    }

    private func hidePlaceholder() {
        placeholderImageView?.removeFromSuperview()
        placeholderImageView = nil
        placeholderLabel?.removeFromSuperview()
        placeholderLabel = nil
    }

    // MARK: - Subtitle
    /// Mirrors the prior SwiftUI conditional exactly: shown only when a subtitle provider
    /// supplied a non-nil string for this film (an empty string, if ever returned, is still
    /// shown -- the prior implementation never special-cased it either).
    private func updateSubtitle() {
        guard let text = currentSubtitle else {
            subtitleLabel?.removeFromSuperview()
            subtitleLabel = nil
            return
        }
        let label: NSTextField
        if let existing = subtitleLabel {
            label = existing
        } else {
            label = Self.makeLabel(font: Self.subtitleFont, color: Self.secondaryTextColor,
                                    alignment: .center)
            addSubview(label) // Sibling of clippedContainer, in the reserved band below the tile.
            subtitleLabel = label
        }
        label.stringValue = text
    }

    // MARK: - Shared Label Factory
    private static func makeLabel(font: NSFont, color: NSColor, alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = color
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.allowsDefaultTighteningForTruncation = false
        return label
    }
}
