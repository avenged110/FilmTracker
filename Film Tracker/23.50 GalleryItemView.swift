// MARK: - GalleryItemView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Pure-AppKit gallery tile content. GalleryItem (23.40 GalleryItem.swift) pins GalleryTileContentView edge to
// edge inside the cell, alongside its own ring and shadow layers.
//
// Cell reuse and live resize involve no SwiftUI view diffing or layout pass. The image uses
// CALayer.contentsGravity = .resizeAspectFill, the AppKit equivalent of scaledToFill, so the compositor
// scales and crops it with no CPU image work per cell or per layout tick. The placeholder, label, and
// optional subtitle are plain NSImageView and NSTextField instances.

import AppKit

// MARK: - Subtitle Provider
/// Provides a subtitle string for a film ID, or nil when no subtitle should show. It is a plain value type.
/// GalleryView builds one per active view, and GallerySubview passes it to
/// GalleryItem.configure(with:subtitleProvider:) on every configuration.
struct GallerySubtitleProvider {
    /// Identifies which subtitle kind this provider produces. A closure has no usable identity, so before
    /// this existed, a provider could only be compared for nil. That detects a subtitle appearing or
    /// disappearing, but not a switch between kinds. A Recents sub-tab switch does exactly that while the
    /// provider stays non-nil. GallerySubview compares this in updateNSView to decide whether configured
    /// cells still hold valid text.
    ///
    /// It is built from the MetadataCache.DateType the provider reads, so two providers for the same category
    /// compare equal.
    let kind: String
    let subtitle: (UUID) -> String?

    init(kind: String, subtitle: @escaping (UUID) -> String?) {
        self.kind = kind
        self.subtitle = subtitle
    }
}

// MARK: - Shared Tile Geometry
/// Single source of truth for the poster's rect within a gallery cell of a given size.
/// GalleryTileContentView's layout() and GalleryItem's ring and shadow layers both use it, so the tile image,
/// ring, and shadow always agree.
///
/// The poster is inset 2 pt on each side. Its height is its own width times 2:3 (width:height), and it sits
/// at the top of the cell. The view is unflipped (y-up), so the same rect serves both the layers and the
/// content with no conversion.
enum GalleryTileGeometry {
    /// Inset applied on all four sides of the cell before the poster box is computed.
    static let posterPadding: CGFloat = 2
    /// Poster height as a multiple of its own width. The aspect ratio is a fixed 2:3 (width:height).
    static let posterHeightMultiplier: CGFloat = 1.5
    /// Clear space, in points, between the poster edge and the selection ring's inner edge. It is shared with
    /// GalleryItem's ring geometry and the subtitle clearance, so the two cannot drift apart.
    static let ringGap: CGFloat = 1

    /// The poster's rect within a cell of the given bounds, in the cell's own y-up space: inset by
    /// `posterPadding` on all sides, with a width-derived height, top-aligned. A subtitle row below the
    /// poster therefore never shrinks the poster. Returns nil when the available width is zero or negative.
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
/// Pinned edge to edge inside GalleryItem, so its bounds equal the cell's. posterRect(inCellBounds:) gives
/// the same rect that GalleryItem's ring and shadow layers use.
final class GalleryTileContentView: NSView {

    // MARK: - Subviews
    /// Clips the poster image (or placeholder) to the tile's rounded shape. Its frame is set to
    /// GalleryTileGeometry.posterRect(inCellBounds:) on every layout() pass.
    private let clippedContainer = NSView()
    private var imageContentView: NSView?
    private var placeholderImageView: NSImageView?
    private var placeholderLabel: NSTextField?
    private var subtitleLabel: NSTextField?
    /// The inner-shadow sheen over the poster edges (see PosterEdgeSheen). It is added to clippedContainer,
    /// so the mask clips it, and it is hidden while the placeholder shows. The image sits at the bottom of
    /// the stack, so the sheen stays above it.
    private let edgeSheenView = PosterEdgeSheen.makeView()

    // MARK: - Current Configuration
    private var currentImage: NSImage?
    private var currentFilmID: UUID = UUID()
    private var currentSubtitle: String?

    // MARK: - Cached Text Metrics intrinsicContentSize on an NSTextField is a real text measurement. The
    // subtitle was measured on every layout() pass, which runs for every visible cell during a resize. Its
    // text, font, and line count do not change during a resize, so the measurement is memoized. It is laid
    // out at the full cell width with only its natural height.
    //
    // The memo is cleared in configure(), the only place the subtitle string or label instance can change.
    // Font and color are static, so nothing else invalidates it.
    private var cachedSubtitleHeight: CGFloat?

    /// The point size centerLabel() last estimated for the placeholder label. The estimate, not the applied
    /// size, is the memo key, so a resize touches the font only when the estimate changes. It is also cleared
    /// in configure(), since that is where the label is recreated with the base font.
    private var appliedPlaceholderFontSize: CGFloat?

    // MARK: - Styling
    private static let cornerRadius: CGFloat = Preferences.cornerRadius
    // Matches the earlier SwiftUI placeholder fill: the opaque window background color. It is opaque so the
    // cell's shadow layer cannot show through.
    private static let placeholderBackgroundColor = NSColor.windowBackgroundColor
    // The placeholder's UUID-suffix label is monospaced. A hex ID reads better in a fixed-advance face, and
    // that lets centerLabel() compute the rendered width and choose a size that fits. The font is replaced on
    // the first layout pass, so this value is only a valid placeholder font.
    private static let smallLabelFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    /// Width of one character in the monospaced face, per point of font size. Each glyph advances the same
    /// amount, so one measurement gives the ratio for every size. It is resolved once per session.
    private static let monospacedUnitAdvance: CGFloat = {
        let probe = NSFont.monospacedSystemFont(ofSize: 100, weight: .regular)
        return probe.maximumAdvancement.width / 100
    }()

    /// Character count of the string the placeholder label renders. UUID.placeholderIDSuffix is its only
    /// producer.
    private static let placeholderLabelCharacterCount = 10
    /// Ceiling on the fitted point size, as a fraction of the poster box's height. A wide tile therefore
    /// cannot yield text taller than its glyph.
    private static let placeholderLabelHeightFactor: CGFloat = 0.14
    /// Floor on the fitted point size. Below it the text is unreadable, so overrunning the band is the better
    /// failure.
    private static let placeholderLabelMinFontSize: CGFloat = 8
    /// Horizontal space an NSTextField uses around its string: the line padding on each side, plus the cell's
    /// own margin. It is reserved before fitting, so the text fits inside the drawable area. centerLabel()
    /// checks the result with a real measurement, so over-reserving costs a fraction of a point, and
    /// under-reserving would cost a character.
    private static let placeholderLabelCellInset: CGFloat = 8
    private static let secondaryTextColor = NSColor.secondaryLabelColor
    // Matches the earlier placeholder icon, the film glyph inset 20 pt from the poster box on all sides.
    private static let placeholderIconInset: CGFloat = 20
    private static let placeholderIconAlpha: CGFloat = 0.4
    private static let placeholderLabelAlpha: CGFloat = 0.6

    // The subtitle is 10 pt semibold, the same size as the earlier SwiftUI subtitle, with a heavier weight
    // for legibility.
    private static let subtitleFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    // The selection ring (see GalleryItem.swift) is centered on a path offset ringGap + lineWidth / 2 beyond
    // the tile edge. Its outermost pixel therefore reaches ringGap + lineWidth past the tile once selected.
    // ringGap comes from GalleryTileGeometry, which GalleryItem also uses.
    private static let ringVisualOverhang: CGFloat =
        GalleryTileGeometry.ringGap + Preferences.selectionLineWidth  // 6
    // Gap between the tile's bottom edge and the subtitle. It equals the ring's full overhang, so the ring
    // and the subtitle meet without overlapping, even when selected.
    private static let subtitleTopGap: CGFloat = ringVisualOverhang  // 6
    // How far the subtitle label may extend past each side of the cell, into the inter-column gutter. The
    // widest dates can be wider than a narrow cell, so this gives the label room without a visible overflow.
    // The gutter is itemSpacing (16 pt). The cell does not mask to bounds, since the ring already overhangs
    // it, so nothing clips the label.
    private static let subtitleSideOverhang: CGFloat = 5

    // MARK: - Init
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        clippedContainer.wantsLayer = true
        clippedContainer.layer?.masksToBounds = true
        clippedContainer.layer?.cornerRadius = Self.cornerRadius
        // Uses the continuous ("squircle") corner curve, not CALayer's .circular default, so the straight
        // edge blends into the arc. It is the style every poster site uses (list thumbnail, sidebar header,
        // and FilmSheet poster, which round with SwiftUI's default, .continuous). The
        // sheen and the selection ring are built for this same curve.
        clippedContainer.layer?.cornerCurve = .continuous
        clippedContainer.layer?.backgroundColor = Self.placeholderBackgroundColor.cgColor
        clippedContainer.addSubview(edgeSheenView)
        addSubview(clippedContainer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The placeholder fill is a raw CALayer color, which is a snapshot of the appearance it was resolved
    // under and does not follow appearance changes. It is re-resolved when the appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        clippedContainer.layer?.backgroundColor = Self.placeholderBackgroundColor.cgColor
    }

    // Unflipped (y-up), matching GalleryItem.view and every CALayer it hosts -- see GalleryTileGeometry's doc
    // comment for why this removes the y-down -> y-up conversion the prior NSHostingView-based implementation
    // required.
    override var isFlipped: Bool { false }

    // MARK: - Configuration
    /// Sets all content. Cheap to call on every cell reuse: a handful of property writes and, only when the
    /// image actually changed, one CGImage extraction for the content layer's `contents` -- no view-tree
    /// diffing of any kind. The caller (GalleryItem) is responsible for only invoking this when something
    /// actually changed; this method itself always unconditionally rebuilds what it's given.
    func configure(image: NSImage?, filmID: UUID, subtitle: String?) {
        currentImage = image
        currentFilmID = filmID
        currentSubtitle = subtitle

        // Discard the cached text metrics before the label content below is rebuilt — see the "Cached Text
        // Metrics" section above. Cleared unconditionally rather than only when the relevant string actually
        // changed: this method already documents itself as unconditionally rebuilding whatever it is given,
        // and a redundant re-measure on the next layout pass is far cheaper than any bookkeeping that could
        // drift.
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

        // Snaps each of posterRect's four edges independently to the nearest DEVICE pixel boundary (not just
        // the nearest point) before handing it to clippedContainer. Unlike the selection ring's 5pt stroke --
        // thick enough that a sub-device-pixel misalignment is imperceptible -- clippedContainer's
        // rounded-rect mask and the image content filling it are a hard, high-contrast edge, where the same
        // sub-pixel misalignment reads as a visibly shaved sliver along whichever edge landed just inside a
        // pixel boundary rather than on it. This mirrors the exact rationale AppKit itself applies
        // automatically to a window's own content, snapping a fractional-point rect to whichever device pixel
        // grid is actually being rasterized to (2x on Retina, 1x otherwise) -- it does NOT change the rect's
        // nominal position or size by more than a fraction of a point, so it cannot reopen or close the
        // deliberate gap the selection ring's geometry (still computed from this same unmodified posterRect
        // via GalleryItem.currentPosterRect()) assumes exists.
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

    /// Rounds each edge of `rect` to the nearest device pixel, using the backing scale of the screen the view
    /// is on (2.0 on Retina, 1.0 otherwise). It falls back to the key window's screen, then the main screen,
    /// when the view is not yet in a window. A stale scale here costs only a redundant antialiasing pass on
    /// the next layout, never a crash or a misaligned edge.
    private func devicePixelAlignedRect(_ rect: CGRect) -> CGRect {
        let scale = unsafe window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        func aligned(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let left = aligned(rect.minX)
        let right = aligned(rect.maxX)
        let top = aligned(rect.maxY)
        let bottom = aligned(rect.minY)
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    /// Centers the UUID-suffix label on the placeholder glyph and fits its font to the band it may occupy.
    ///
    /// The label is fitted to the poster box, not set to a fixed point size, because a fixed size
    /// truncated the text well below the size of the glyph. The band is fixed by geometry, and the font is fitted to it. The band is
    /// inset by half of `placeholderIconInset`, so the text sits between the glyph and the poster edge.
    ///
    /// Fitting needs the string's width. A monospaced face (see `smallLabelFont`) makes that arithmetic: each
    /// of the ten hex characters advances the same amount, so the width is 10 * unitAdvance * pointSize.
    /// `placeholderLabelHeightFactor` then caps the height so a short, wide tile cannot yield text taller
    /// than the glyph.
    ///
    /// An NSTextField insets its text horizontally, so a font that fills the band exactly would overflow and
    /// truncate. The reserved inset (`placeholderLabelCellInset`) is subtracted before the division. That
    /// inset is an AppKit detail, so the estimate is verified once against the real laid-out width
    /// (intrinsicContentSize). If it is too wide, the size is scaled down and reapplied. This runs only when
    /// the computed size changes, not on steady-state layout passes.
    private func centerLabel(_ label: NSTextField, in rect: CGRect) {
        let inset = Self.placeholderIconInset / 2
        let available = max(0, rect.width - inset * 2)
        let drawable = max(1, available - Self.placeholderLabelCellInset)

        let widthFitted = drawable / (CGFloat(Self.placeholderLabelCharacterCount)
                                      * Self.monospacedUnitAdvance)
        let heightCapped = rect.height * Self.placeholderLabelHeightFactor
        // Rounded down, so the fitted width stays within the band. A very small tile is floored at a legible
        // size, not zero.
        var pointSize = max(Self.placeholderLabelMinFontSize,
                            min(widthFitted, heightCapped).rounded(.down))
        // Memoized on the estimate, not the corrected size. A corrected key would never match the next pass's
        // estimate, and the measurement would run on every layout.
        let estimate = pointSize

        if appliedPlaceholderFontSize != estimate {
            label.font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)

            // The verification pass. One correction is enough, because the measured width is linear in point
            // size. The floor stops the loop.
            let measured = label.intrinsicContentSize.width
            if measured > available, measured > 0 {
                pointSize = max(Self.placeholderLabelMinFontSize,
                                (pointSize * available / measured).rounded(.down))
                label.font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
            }
            appliedPlaceholderFontSize = estimate
        }

        // Font metrics, not a layout measurement. boundingRectForFont is a property of the font and does not
        // depend on the string.
        let height = (label.font?.boundingRectForFont.height ?? pointSize).rounded(.up)
        // The label is centered (see makeLabel), so the text centers within the band.
        label.frame = CGRect(x: rect.minX + inset, y: rect.midY - height / 2,
                              width: available, height: height)
    }

    /// Top-aligns the subtitle label in the band below the tile, with `subtitleTopGap` of clearance. That is
    /// exactly the ring's overhang, so the ring and subtitle just meet without overlap, even when selected.
    /// The subtitle is centered horizontally, as the earlier SwiftUI VStack's default alignment was.
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

    /// The placeholder "film" system symbol, resolved once per session. NSImage(systemSymbolName:) is a
    /// catalog lookup, not free.
    private static let placeholderIconBaseImage =
        NSImage(systemSymbolName: "film", accessibilityDescription: nil)

    /// A single-entry memo for the placeholder glyph at its point size, shared by every cell. Visible tiles
    /// are the same size, so one entry serves the viewport. If two grids of different sizes were mounted, the
    /// memo would rebuild on each call, which is correct but slower. Static storage on an NSView subclass is
    /// main-actor isolated under Swift 6, matching every caller.
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
    /// The point size is rounded to whole points. The image view scales the glyph to fill `iconRect` anyway
    /// (imageScaling is scaleProportionallyUpOrDown), so the size affects only rasterization and stroke
    /// weight. During a live resize, the icon rect changes every tick, so rounding means the configuration
    /// changes a few times a second rather than on every tick. Together with the memo and the identity check
    /// below, most passes reduce to a frame assignment.
    private func layoutPlaceholderIcon(_ imageView: NSImageView, in bounds: CGRect) {
        let iconRect = bounds.insetBy(dx: Self.placeholderIconInset, dy: Self.placeholderIconInset)
        imageView.frame = iconRect
        let glyphPointSize = max(1, min(iconRect.width, iconRect.height)).rounded()
        let icon = Self.placeholderIcon(pointSize: glyphPointSize)
        // Identity, not equality. The memo returns the same instance for an unchanged size, so !== means
        // nothing needs doing.
        if imageView.image !== icon { imageView.image = icon }
    }

    // MARK: - Image Content
    /// Displays the poster image in a plain CALayer with contentsGravity = .resizeAspectFill, the Core
    /// Animation equivalent of scaledToFill. With no image, it falls back to the placeholder (film glyph and
    /// UUID suffix). The compositor selects and scales the visible part of the image, so there is no CPU
    /// cropping or redrawing on any call.
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
            // Disables implicit Core Animation for these keys, so the image snaps to its new contents and
            // frame on every reuse and resize tick, rather than cross-fading over the default ~0.25 s.
            // GalleryItem's ring and shadow use the same approach.
            newView.layer?.actions = ["contents": NSNull(), "contentsRect": NSNull(),
                                       "bounds": NSNull(), "position": NSNull()]
            // The image is an ordinary subview, inserted at the bottom of the stack. The placeholder is added
            // the same way, so z-order comes from subview ordering and not a hand-managed sublayer array.
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
    /// Shown only when a subtitle provider returned a non-nil string for this film. An empty string is still
    /// shown.
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
