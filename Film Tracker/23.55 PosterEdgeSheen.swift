// MARK: – PosterEdgeSheen.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// A soft, inward-fading "inner shadow" along the poster edges, so the hard edge fades into the image instead of
// reading as a sharp line.
//
// Performance: the band is rasterized once per (cornerRadius, inset) pair into a small RGBA texture, transparent in the
// center and translucent at the edges. Every poster then stretches that texture as a 9-slice image, so corners keep their
// rounded shape and the edges keep a fixed point width at any size. On the grid, each cell has one layer-backed view whose
// `contents` is the shared CGImage, so there is no CPU drawing on reuse, scroll, or resize. On the list, each row gets one
// `Image.resizable(capInsets:)` overlay that draws the same shared texture. PosterCache is unchanged.
//
// All of the effect lives in this file. Each call site is one line. To remove the effect, delete this file and the two
// call sites (GalleryTileContentView and PosterThumbnailView).

import AppKit
import SwiftUI

@MainActor
enum PosterEdgeSheen {

    // MARK: - Tuning
    /// One profile per poster site. `cornerRadius` must match the site's clip, so the corner fall-off hugs the visible corner.
    /// Every site clips with the continuous corner curve (`RoundedRectangle(style: .continuous)` in SwiftUI, or
    /// `CALayer.cornerCurve = .continuous` on the grid), and the texture is rendered to the same curve. `inset` is the shadow's
    /// blur radius, not the visible reach. The band fades to nothing at about half of it, and peaks at about `opacity` * 0.4 at
    /// the edge. It is scaled down where the grid's reach would swallow a small image.
    struct Profile: Hashable {
        var cornerRadius: CGFloat
        var inset: CGFloat
        /// Shadow color alpha, 0...1 (see above for the resulting edge darkness).
        var opacity: CGFloat

        /// Gallery grid tile (GalleryTileContentView) and the FilmSheet Poster tab preview.
        static let grid = Profile(cornerRadius: Preferences.cornerRadius, inset: 6, opacity: 0.55)
        /// Gallery list 24x36 thumbnail (PosterThumbnailView).
        static let list = Profile(cornerRadius: 2, inset: 3, opacity: 0.55)
        /// Right-sidebar Header 55x82 thumbnail (6pt corners).
        static let header = Profile(cornerRadius: 6, inset: 4, opacity: 0.55)
    }

    /// Texture pixel density. The texture is small, so 2x is always used, and the layer and image scale match it. A 1x screen
    /// downsamples it.
    private static let textureScale: CGFloat = 2

    // MARK: - Shared Textures
    private static var cache: [Profile: CGImage] = [:]

    /// The corner-tile size in points: enough to hold the full rounded corner plus the fade.
    static func cornerTile(for profile: Profile) -> CGFloat {
        profile.cornerRadius + profile.inset + 1
    }

    /// The shared 9-slice texture for `profile`, rendered on first request and cached forever.
    /// Main-thread only (all callers are view code).
    static func texture(for profile: Profile) -> CGImage {
        if let cached = cache[profile] { return cached }
        let image = render(profile)
        cache[profile] = image
        return image
    }

    /// Rasterizes an inner shadow of a rounded rect: the region OUTSIDE the rounded rect is
    /// filled while a shadow (blur = inset) is active and the context is clipped TO the rounded
    /// rect, so only the shadow's spill lands inside. The shadow is offset by nothing, giving a
    /// symmetric band on all four sides with a naturally rounded fall-off at each corner.
    private static func render(_ profile: Profile) -> CGImage {
        // Point-size of the texture: two corner tiles plus a 1pt stretchable center.
        let tile = cornerTile(for: profile)
        let sidePt = tile * 2 + 1
        let sidePx = Int((sidePt * textureScale).rounded(.up))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = unsafe CGContext(data: nil, width: sidePx, height: sidePx, bitsPerComponent: 8,
                            bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: textureScale, y: textureScale)

        let bounds = CGRect(x: 0, y: 0, width: sidePt, height: sidePt)
        // SwiftUI's RoundedRectangle is the one public API that emits a continuous-corner
        // path (CGPath(roundedRect:) and NSBezierPath only produce circular arcs); used here
        // purely as a geometry calculator, the same way GalleryItem builds its ring outline.
        let rounded = RoundedRectangle(cornerRadius: profile.cornerRadius, style: .continuous)
            .path(in: bounds).cgPath

        ctx.addPath(rounded)
        ctx.clip()

        // Outer region = a generously oversized rect minus the rounded rect (even-odd).
        let outer = bounds.insetBy(dx: -profile.inset * 4, dy: -profile.inset * 4)
        ctx.addRect(outer)
        ctx.addPath(rounded)
        ctx.setShadow(offset: .zero, blur: profile.inset,
                      color: CGColor(gray: 0, alpha: profile.opacity))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath(using: .evenOdd)

        return ctx.makeImage()!
    }

    /// `contentsCenter` / cap-inset fraction for a texture built for `profile`.
    private static func capFraction(for profile: Profile) -> CGFloat {
        let tile = cornerTile(for: profile)
        return tile / (tile * 2 + 1)
    }

    // MARK: - Grid (AppKit)
    /// A layer-backed view that paints the sheen over whatever subviews sit below it. Frame
    /// it to the poster's bounds; its 9-slice contents keep the band at a fixed point width
    /// at any size. A view (not a bare sublayer) so ordinary subview z-ordering keeps it above
    /// the poster image by construction, exactly as GalleryTileContentView orders everything
    /// else it hosts.
    final class SheenView: NSView {
        init(profile: Profile) {
            super.init(frame: .zero)
            wantsLayer = true
            let f = capFraction(for: profile)
            layer?.contents = texture(for: profile)
            layer?.contentsScale = textureScale
            layer?.contentsGravity = .resize
            layer?.contentsCenter = CGRect(x: f, y: f, width: 1 - 2 * f, height: 1 - 2 * f)
            // Snap on reuse/resize, matching the poster image view beneath it.
            layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                              "hidden": NSNull()]
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// AppKit rewrites a layer-backed view's `contentsScale` to the window's backing scale
        /// whenever that changes (e.g. the window moves to a 1x display). The 9-slice cap widths
        /// are derived from `contents` pixel size / `contentsScale`, so that rewrite would double
        /// the band's point width on a 1x display; the texture is always 2x, so pin it back.
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            layer?.contentsScale = PosterEdgeSheen.textureScale
        }

        /// Purely decorative; never the hit-test target, so clicks and drags land on the same
        /// view they did before the sheen existed.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    static func makeView(profile: Profile = .grid) -> SheenView { SheenView(profile: profile) }

    // MARK: - List (SwiftUI)
    /// An overlay for a SwiftUI poster. Use inside `.overlay { }` on a view whose layout size
    /// IS the visible poster rect (after any fixed `.frame`, before `.clipShape`); the
    /// enclosing clip keeps it inside the rounded rect.
    static func overlay(profile: Profile = .list) -> some View {
        let tile = cornerTile(for: profile)
        return Image(decorative: texture(for: profile), scale: textureScale)
            .resizable(capInsets: EdgeInsets(top: tile, leading: tile, bottom: tile, trailing: tile),
                       resizingMode: .stretch)
            .allowsHitTesting(false)
    }
}
