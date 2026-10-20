// MARK: - DVCanvasKit.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// A small retained layout-and-drawing vocabulary the Data Visualizations page (27.45) is
// drawn with, by Core Graphics / Core Text, into the tab's one AppKit view and into the
// library PDF alike. Its layout follows SwiftUI's rules — stacks with spacing, layout
// priority and flexibility ordering, fixed / min / max-width frames, padding, backgrounds
// clipped to continuous rounded rects, single- and multi-line text boxes with SwiftUI's
// line metrics — so the page reads and resizes like the SwiftUI page it replaced.

import AppKit
import SwiftUI   // Shape paths (RoundedRectangle geometry) and, in a PDF, symbol outlines.

// MARK: - Graphics

/// A flipped (y-down) Core Graphics surface: an NSView's draw(_:) or a PDF page.
@MainActor
struct DVGraphics {
    let ctx: CGContext
    /// Device pixels per point, for snapping like SwiftUI's layout rounding.
    let scale: CGFloat
    /// What needs drawing; nodes wholly outside it return early.
    let dirty: CGRect
    /// Drawing into a PDF: symbols are drawn as vector glyphs rather than bitmap masks.
    var vector = false

    func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
    func snap(_ r: CGRect) -> CGRect {
        let x0 = snap(r.minX), y0 = snap(r.minY)
        return CGRect(x: x0, y: y0, width: snap(r.maxX) - x0, height: snap(r.maxY) - y0)
    }

    func fill(_ rect: CGRect, _ paint: DVPaint, radius: CGFloat = 0) {
        guard rect.width > 0, rect.height > 0 else { return }
        ctx.setFillColor(paint.cgColor)
        if radius > 0 {
            ctx.addPath(DVShapes.rounded(rect, radius))
            ctx.fillPath()
        } else {
            ctx.fill(rect)
        }
    }

    func fillPath(_ path: CGPath, _ paint: DVPaint) {
        ctx.setFillColor(paint.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
    }

    func clip(_ rect: CGRect, radius: CGFloat) {
        ctx.addPath(DVShapes.rounded(rect, radius))
        ctx.clip()
    }

    func withState(_ body: () -> Void) {
        ctx.saveGState(); body(); ctx.restoreGState()
    }
}

/// Shape paths from SwiftUI's own shapes, so corners are the continuous curves the rest of
/// the app draws (RoundedRectangle's default style). Cached by size and radius.
@MainActor
enum DVShapes {
    private static var cache: [String: CGPath] = [:]

    static func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        let key = "r\(rect.width)x\(rect.height)r\(radius)"
        let base: CGPath
        if let hit = cache[key] {
            base = hit
        } else {
            base = RoundedRectangle(cornerRadius: radius).path(in: CGRect(origin: .zero, size: rect.size)).cgPath
            if cache.count > 4000 { cache.removeAll() }
            cache[key] = base
        }
        return translated(base, to: rect.origin)
    }

    /// The cached shape moved to `origin`. `addPath(_:transform:)` is the pointer-free
    /// spelling of `copy(using:)`: the same elements, transformed.
    private static func translated(_ base: CGPath, to origin: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.addPath(base, transform: CGAffineTransform(translationX: origin.x, y: origin.y))
        return path
    }

    static func topRounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        let key = "t\(rect.width)x\(rect.height)r\(radius)"
        let base: CGPath
        if let hit = cache[key] {
            base = hit
        } else {
            base = UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius)
                .path(in: CGRect(origin: .zero, size: rect.size)).cgPath
            if cache.count > 4000 { cache.removeAll() }
            cache[key] = base
        }
        return translated(base, to: rect.origin)
    }
}

// MARK: - Paint

/// A (possibly dynamic) NSColor and an opacity, resolved against the appearance being drawn in.
struct DVPaint {
    let color: NSColor
    var opacity: CGFloat = 1

    static let primary = DVPaint(color: .labelColor)
    static let secondary = DVPaint(color: .secondaryLabelColor)
    static let tertiary = DVPaint(color: .tertiaryLabelColor)

    func opacity(_ o: CGFloat) -> DVPaint { DVPaint(color: color, opacity: opacity * o) }

    /// Resolved for NSAppearance.currentDrawing(), which AppKit sets to the view's effective
    /// appearance around draw(_:).
    var cgColor: CGColor {
        let resolved = color.cgColor
        return opacity == 1 ? resolved : resolved.copy(alpha: resolved.alpha * opacity) ?? resolved
    }
}

// MARK: - Text

/// A font as the page names it: SwiftUI's `.system(size:weight:design:)`.
struct DVFont: Hashable {
    let size: CGFloat
    var weight: NSFont.Weight = .regular
    var mono = false

    static func system(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> DVFont { DVFont(size: size, weight: weight) }
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> DVFont { DVFont(size: size, weight: weight, mono: true) }

    func hash(into h: inout Hasher) { h.combine(size); h.combine(weight.rawValue); h.combine(mono) }
    static func == (a: DVFont, b: DVFont) -> Bool { a.size == b.size && a.weight == b.weight && a.mono == b.mono }

    @MainActor var nsFont: NSFont { DVFontBook.font(self) }
    /// SwiftUI's one-line Text box: the ascender and descender each rounded out to whole
    /// points (measured: 10 pt → 13 tall with its baseline 10 down; 20 pt → 24 / 19).
    @MainActor var lineHeight: CGFloat { DVFontBook.metrics(self).height }
    @MainActor var baseline: CGFloat { DVFontBook.metrics(self).baseline }
}

@MainActor
enum DVFontBook {
    private static var fonts: [DVFont: NSFont] = [:]
    private static var metricsCache: [DVFont: (height: CGFloat, baseline: CGFloat)] = [:]

    static func font(_ f: DVFont) -> NSFont {
        if let hit = fonts[f] { return hit }
        let font = f.mono ? NSFont.monospacedSystemFont(ofSize: f.size, weight: f.weight)
                          : NSFont.systemFont(ofSize: f.size, weight: f.weight)
        fonts[f] = font
        return font
    }

    static func metrics(_ f: DVFont) -> (height: CGFloat, baseline: CGFloat) {
        if let hit = metricsCache[f] { return hit }
        let font = font(f)
        let baseline = font.ascender.rounded()
        let m = (height: baseline + (-font.descender).rounded(.up), baseline: baseline)
        metricsCache[f] = m
        return m
    }
}

/// One run of styled text.
struct DVRun {
    let string: String
    let paint: DVPaint
}

/// A shaped single line, cached by content. Colors come from the context at draw time so a
/// cached line serves both appearances; multi-color lines are rebuilt per appearance.
@MainActor
final class DVLine {
    let ctLine: CTLine
    /// Typographic width, unrounded.
    let rawWidth: CGFloat
    let font: DVFont

    private init(ctLine: CTLine, font: DVFont) {
        self.ctLine = ctLine
        self.font = font
        self.rawWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
    }

    private static var cache: [String: DVLine] = [:]

    static func plain(_ string: String, _ font: DVFont) -> DVLine {
        let key = "\(font.size)|\(font.weight.rawValue)|\(font.mono)|\(string)"
        if let hit = cache[key] { return hit }
        let attr = NSAttributedString(string: string, attributes: [
            .font: font.nsFont,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = DVLine(ctLine: CTLineCreateWithAttributedString(attr), font: font)
        if cache.count > 6000 { cache.removeAll() }
        cache[key] = line
        return line
    }

    /// A line whose runs carry their own colors, resolved now (so for one appearance).
    static func runs(_ runs: [DVRun], _ font: DVFont) -> DVLine {
        let attr = NSMutableAttributedString()
        for run in runs {
            attr.append(NSAttributedString(string: run.string, attributes: [
                .font: font.nsFont,
                .foregroundColor: NSColor(cgColor: run.paint.cgColor) ?? run.paint.color,
            ]))
        }
        return DVLine(ctLine: CTLineCreateWithAttributedString(attr), font: font)
    }

    /// Width of the box SwiftUI gives this text: rounded up to a device pixel.
    func width(scale: CGFloat) -> CGFloat { (rawWidth * scale).rounded(.up) / scale }

    private static var ellipses: [DVFont: CTLine] = [:]
    func truncated(to width: CGFloat) -> CTLine {
        let token: CTLine
        if let hit = Self.ellipses[font] {
            token = hit
        } else {
            token = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: [
                .font: font.nsFont,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]))
            Self.ellipses[font] = token
        }
        return CTLineCreateTruncatedLine(ctLine, Double(max(0, width)), .end, token) ?? ctLine
    }
}

extension DVGraphics {
    /// Draws `line` with its box's top-left at `origin`, truncating to `width` when it is
    /// wider. `paint` colors a line built with context colors.
    @MainActor
    func draw(_ line: DVLine, at origin: CGPoint, width: CGFloat, paint: DVPaint, scaleToFit: CGFloat? = nil) {
        var ct = line.ctLine
        var scaleFactor: CGFloat = 1
        // Snapping a box to device pixels can take up to a pixel off a width that was laid
        // out at exactly the text's own: that much is rounding, not too little room.
        let tolerance = 1 / max(scale, 1) + 0.01
        if line.rawWidth > width + tolerance {
            if let minScale = scaleToFit {
                scaleFactor = max(minScale, width / line.rawWidth)
                if line.rawWidth * scaleFactor > width + tolerance { ct = line.truncated(to: width / scaleFactor) }
            } else {
                ct = line.truncated(to: width)
            }
        }
        ctx.saveGState()
        ctx.setFillColor(paint.cgColor)
        if scaleFactor != 1 {
            // Shrunk about the box's leading baseline, the way minimumScaleFactor shrinks a
            // centered one-line box: same box, smaller glyphs, vertically centered.
            let lh = line.font.lineHeight, bl = line.font.baseline
            let shrunkBaseline = (lh - lh * scaleFactor) / 2 + bl * scaleFactor
            ctx.translateBy(x: origin.x, y: origin.y + shrunkBaseline)
            ctx.scaleBy(x: scaleFactor, y: scaleFactor)
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = .zero
        } else {
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: origin.x, y: origin.y + line.font.baseline)
        }
        CTLineDraw(ct, ctx)
        ctx.restoreGState()
    }
}

/// Wrapped text laid out at a width: each line's range, for up to `lineLimit` lines (the
/// last one truncated when text remains).
@MainActor
final class DVParagraph {
    let lines: [CTLine]
    let widths: [CGFloat]

    private init(lines: [CTLine], widths: [CGFloat]) { self.lines = lines; self.widths = widths }

    private static var cache: [String: DVParagraph] = [:]

    static func layout(_ runs: [DVRun], _ font: DVFont, width: CGFloat, lineLimit: Int?) -> DVParagraph {
        let text = runs.map(\.string).joined()
        let key = "\(font.size)|\(font.weight.rawValue)|\(font.mono)|\(width)|\(lineLimit ?? 0)|\(text)"
        let multicolor = Set(runs.map { "\($0.paint.color)\($0.paint.opacity)" }).count > 1
        if !multicolor, let hit = cache[key] { return hit }
        let attr = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: font.nsFont]
            if multicolor {
                attributes[.foregroundColor] = NSColor(cgColor: run.paint.cgColor) ?? run.paint.color
            } else {
                attributes[NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)] = true
            }
            attr.append(NSAttributedString(string: run.string, attributes: attributes))
        }
        let typesetter = CTTypesetterCreateWithAttributedString(attr)
        let length = attr.length
        var lines: [CTLine] = [], widths: [CGFloat] = []
        var start = 0
        while start < length {
            if let limit = lineLimit, lines.count == limit - 1 {
                // The last allowed line: whatever is left, truncated at the tail.
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length - start))
                let restWidth = CGFloat(CTLineGetTypographicBounds(rest, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(rest))
                if restWidth > width + 0.01 {
                    // The ellipsis in the attributes of the character it replaces: that one
                    // character's run, with its text swapped out (attributes are kept). Read
                    // this way rather than through attributes(at:effectiveRange:), whose
                    // out-pointer is unsafe even when passed nil.
                    let ellipsis = NSMutableAttributedString(attributedString:
                        attr.attributedSubstring(from: NSRange(location: start, length: 1)))
                    ellipsis.mutableString.setString("\u{2026}")
                    let token = CTLineCreateWithAttributedString(ellipsis)
                    let t = CTLineCreateTruncatedLine(rest, Double(width), .end, token) ?? rest
                    lines.append(t); widths.append(min(width, restWidth))
                } else {
                    lines.append(rest); widths.append(restWidth)
                }
                break
            }
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            guard count > 0 else { break }
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            lines.append(line)
            widths.append(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)))
            start += count
        }
        let p = DVParagraph(lines: lines, widths: widths)
        if !multicolor {
            if cache.count > 3000 { cache.removeAll() }
            cache[key] = p
        }
        return p
    }
}

// MARK: - Nodes

/// A width-independent value computed once per node (its horizontal sizing).
final class DVOnce<T> {
    var value: T?
    @inline(__always) func get(_ make: () -> T) -> T {
        if let value { return value }
        let v = make(); value = v; return v
    }
}

/// The last layout a container computed, keyed by width: every node is asked for its height
/// by its parent and again when drawn, so without this a deep tree re-measures its leaves
/// once per ancestor query.
final class DVMemo<T> {
    var width: CGFloat = .nan
    var value: T?
    @inline(__always) func get(_ w: CGFloat, _ make: () -> T) -> T {
        if w == width, let value { return value }
        let v = make(); width = w; value = v; return v
    }
}

/// How a node answers an HStack's width offer: never narrower than `min`, never wider than
/// `max` (∞ = takes whatever it is offered).
struct DVSizing {
    var min: CGFloat
    var max: CGFloat
    static let flexible = DVSizing(min: 0, max: .infinity)
    func take(_ offer: CGFloat) -> CGFloat { Swift.max(min, Swift.min(max, offer)) }
}

/// A clickable region of the page, with what it does.
struct DVHotspot {
    enum Action {
        case perform(() -> Void)
        case popover(id: String)
        /// Not clickable: while the pointer is over the region, the page shows a small tip
        /// with the text this returns for the point, above its rect (nil hides the tip).
        case hover((CGPoint) -> (text: String, anchor: CGRect)?)
    }
    let rect: CGRect
    let action: Action
    let pointer: Bool
    /// The content inside the region's padding: what a popover's arrow points at, so it
    /// touches the content's edge rather than the padded box's.
    var anchor: CGRect? = nil
    var isHover: Bool { if case .hover = action { return true }; return false }
}

@MainActor
protocol DVNode {
    /// Horizontal sizing, for an HStack's offers. Default: fills whatever it is offered.
    var sizing: DVSizing { get }
    /// Height at `width` (the width the parent assigned).
    func height(_ width: CGFloat) -> CGFloat
    /// True when the node grows to fill a taller proposal (a Spacer, a card's maxHeight
    /// frame); false when it keeps its own height.
    var fillsHeight: Bool { get }
    func draw(_ g: DVGraphics, _ rect: CGRect)
    /// Distance from the top to the first / last text baseline at `width`, if any.
    func firstBaseline(_ width: CGFloat) -> CGFloat?
    func lastBaseline(_ width: CGFloat) -> CGFloat?
    func hotspots(_ rect: CGRect, into: inout [DVHotspot])
    /// Embedded AppKit controls, with the frame each takes in page coordinates.
    func controls(_ rect: CGRect, into: inout [(any DVControl, CGRect)])
}

extension DVNode {
    var sizing: DVSizing { .flexible }
    var fillsHeight: Bool { false }
    func firstBaseline(_ width: CGFloat) -> CGFloat? { nil }
    func lastBaseline(_ width: CGFloat) -> CGFloat? { nil }
    func hotspots(_ rect: CGRect, into: inout [DVHotspot]) {}
    func controls(_ rect: CGRect, into: inout [(any DVControl, CGRect)]) {}
}

/// A node that lays out `children` and does nothing else itself: HStack, VStack and
/// Spread. Each supplies only its layout (`rects`); drawing, hit areas and embedded
/// controls are delegated to the children in those rects here, rather than in three
/// identical copies.
fileprivate protocol DVContainer: DVNode {
    var children: [any DVNode] { get }
    /// Each child's rect within `rect`, in `children` order.
    func rects(_ rect: CGRect) -> [CGRect]
}

extension DVContainer {
    func draw(_ g: DVGraphics, _ rect: CGRect) {
        guard rect.intersects(g.dirty) else { return }
        for (child, r) in zip(children, rects(rect)) { child.draw(g, g.snap(r)) }
    }
    func hotspots(_ rect: CGRect, into: inout [DVHotspot]) {
        for (child, r) in zip(children, rects(rect)) { child.hotspots(r, into: &into) }
    }
    func controls(_ rect: CGRect, into: inout [(any DVControl, CGRect)]) {
        for (child, r) in zip(children, rects(rect)) { child.controls(r, into: &into) }
    }
}

/// An AppKit control embedded in the page. Laid out as SwiftUI laid out the representable it
/// replaces: by `layoutSize`, with the control's frame positioned so its alignment rect
/// fills that box.
@MainActor
protocol DVControl: AnyObject {
    var view: NSView { get }
    /// Layout size for an offered width (the representable's sizeThatFits).
    func layoutSize(offer: CGFloat) -> CGSize
    var baselineFromTop: CGFloat? { get }
    var sizing: DVSizing { get }
}

// MARK: Text node

/// SwiftUI `Text` with `.font`, `.foregroundStyle`, `.lineLimit`, tail truncation, and
/// optionally `.minimumScaleFactor`.
@MainActor
struct DVText: DVNode {
    let runs: [DVRun]
    let font: DVFont
    /// nil = unlimited (wraps to as many lines as it needs).
    var lineLimit: Int? = 1
    var minimumScale: CGFloat? = nil
    var scale: CGFloat = 2
    private let ideal = DVOnce<CGFloat>()

    init(_ string: String, _ font: DVFont, _ paint: DVPaint = .primary, lineLimit: Int? = 1, minimumScale: CGFloat? = nil) {
        self.runs = [DVRun(string: string, paint: paint)]
        self.font = font
        self.lineLimit = lineLimit
        self.minimumScale = minimumScale
    }

    init(runs: [DVRun], _ font: DVFont, lineLimit: Int? = 1) {
        self.runs = runs
        self.font = font
        self.lineLimit = lineLimit
    }

    var string: String { runs.map(\.string).joined() }
    private var isSingleLine: Bool { lineLimit == 1 && !string.contains("\n") }

    /// The widest line unwrapped (what SwiftUI answers for an unconstrained proposal).
    var idealWidth: CGFloat { ideal.get(computeIdealWidth) }

    private func computeIdealWidth() -> CGFloat {
        if isSingleLine { return DVLine.plain(string, font).width(scale: scale) }
        let lines = string.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { DVLine.plain(String($0), font).width(scale: scale) }.max() ?? 0
    }

    var sizing: DVSizing { DVSizing(min: 0, max: idealWidth) }

    func height(_ width: CGFloat) -> CGFloat {
        if string.isEmpty { return font.lineHeight }
        if isSingleLine { return font.lineHeight }
        let p = DVParagraph.layout(runs, font, width: width, lineLimit: lineLimit)
        return CGFloat(max(1, p.lines.count)) * font.lineHeight
    }

    func firstBaseline(_ width: CGFloat) -> CGFloat? { font.baseline }
    func lastBaseline(_ width: CGFloat) -> CGFloat? { height(width) - font.lineHeight + font.baseline }

    func draw(_ g: DVGraphics, _ rect: CGRect) {
        guard rect.intersects(g.dirty) else { return }
        if isSingleLine {
            if runs.count == 1 {
                g.draw(DVLine.plain(string, font), at: rect.origin, width: rect.width, paint: runs[0].paint,
                       scaleToFit: minimumScale)
            } else {
                g.draw(DVLine.runs(runs, font), at: rect.origin, width: rect.width, paint: .primary)
            }
            return
        }
        let p = DVParagraph.layout(runs, font, width: rect.width, lineLimit: lineLimit)
        g.withState {
            g.ctx.setFillColor(runs[0].paint.cgColor)
            g.ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            for (i, line) in p.lines.enumerated() {
                g.ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + CGFloat(i) * font.lineHeight + font.baseline)
                CTLineDraw(line, g.ctx)
            }
        }
    }
}

// MARK: Primitive boxes

/// A shape or drawing of fixed or flexible size: a swatch, a dot, a fill bar, a rule.
@MainActor
struct DVBox: DVNode {
    var width: CGFloat? = nil
    var minWidth: CGFloat = 0
    let fixedHeight: CGFloat
    let paint: (DVGraphics, CGRect) -> Void

    init(width: CGFloat? = nil, minWidth: CGFloat = 0, height: CGFloat, _ paint: @escaping (DVGraphics, CGRect) -> Void) {
        self.width = width
        self.minWidth = minWidth
        self.fixedHeight = height
        self.paint = paint
    }

    var sizing: DVSizing { width.map { DVSizing(min: $0, max: $0) } ?? DVSizing(min: minWidth, max: .infinity) }
    func height(_ width: CGFloat) -> CGFloat { fixedHeight }
    func draw(_ g: DVGraphics, _ rect: CGRect) {
        guard rect.intersects(g.dirty) else { return }
        paint(g, rect)
    }
}

/// `Spacer(minLength:)`.
struct DVSpacer: DVNode {
    var minLength: CGFloat = 0
    var sizing: DVSizing { DVSizing(min: minLength, max: .infinity) }
    func height(_ width: CGFloat) -> CGFloat { 0 }
    var fillsHeight: Bool { true }
    func draw(_ g: DVGraphics, _ rect: CGRect) {}
}

/// An SF Symbol drawn as `Image(systemName:).font(.system(size:weight:))` draws it.
@MainActor
struct DVSymbol: DVNode {
    let name: String
    let pointSize: CGFloat
    var weight: NSFont.Weight = .regular
    var paint: DVPaint = .secondary
    var opacity: CGFloat = 1

    private static var images: [String: NSImage] = [:]
    private var image: NSImage? {
        let key = "\(name)|\(pointSize)|\(weight.rawValue)"
        if let hit = Self.images[key] { return hit }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        Self.images[key] = img
        return img
    }

    var size: CGSize { image?.size ?? .zero }
    var sizing: DVSizing { DVSizing(min: size.width, max: size.width) }
    func height(_ width: CGFloat) -> CGFloat { size.height }

    func draw(_ g: DVGraphics, _ rect: CGRect) {
        guard opacity > 0, rect.intersects(g.dirty), let image else { return }
        let box = CGRect(x: rect.minX, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        if g.vector {
            // In a PDF the mask below, or the symbol image drawn directly, embeds a bitmap;
            // SwiftUI's renderer records the symbol's outline as paths.
            let color = NSColor(cgColor: paint.opacity(opacity).cgColor) ?? paint.color
            let fontWeight: Font.Weight = weight == .semibold ? .semibold : (weight == .medium ? .medium : (weight == .bold ? .bold : .regular))
            let renderer = ImageRenderer(content: Image(systemName: name)
                .font(.system(size: pointSize, weight: fontWeight))
                .foregroundStyle(Color(nsColor: color)))
            renderer.render { rendered, draw in
                g.withState {
                    // The renderer draws y-up from its bottom-left corner; centered in the box.
                    g.ctx.translateBy(x: box.midX - rendered.width / 2, y: box.midY + rendered.height / 2)
                    g.ctx.scaleBy(x: 1, y: -1)
                    draw(g.ctx)
                }
            }
            return
        }
        // Tinted by filling the symbol's mask.
        g.withState {
            var proposed = CGRect(origin: .zero, size: size)
            guard let cg = unsafe image.cgImage(forProposedRect: &proposed, context: NSGraphicsContext(cgContext: g.ctx, flipped: true), hints: nil) else { return }
            g.ctx.translateBy(x: box.minX, y: box.maxY)
            g.ctx.scaleBy(x: 1, y: -1)
            g.ctx.clip(to: CGRect(origin: .zero, size: box.size), mask: cg)
            g.ctx.setFillColor(paint.opacity(opacity).cgColor)
            g.ctx.fill(CGRect(origin: .zero, size: box.size))
        }
    }
}

// MARK: Frame, padding, background

/// `.frame(width:)`, `.frame(minWidth:)`, `.frame(maxWidth: .infinity)`,
/// `.frame(height:)`, `.frame(minHeight:)` with an alignment, around one child.
@MainActor
struct DVFrame: DVNode {
    enum HAlign { case leading, center, trailing }
    enum VAlign { case top, center, bottom }
    let child: any DVNode
    var width: CGFloat? = nil
    var minWidth: CGFloat? = nil
    var maxInfinity = false
    var height: CGFloat? = nil
    var minHeight: CGFloat? = nil
    var hAlign: HAlign = .center
    var vAlign: VAlign = .center

    var sizing: DVSizing {
        if let width { return DVSizing(min: width, max: width) }
        let c = child.sizing
        return DVSizing(min: max(minWidth ?? 0, c.min), max: maxInfinity ? .infinity : max(minWidth ?? 0, c.max))
    }
    var fillsHeight: Bool { child.fillsHeight && height == nil }

    /// The width the child takes inside a frame `outer` points wide.
    func childWidth(_ outer: CGFloat) -> CGFloat { min(outer, child.sizing.take(outer)) }

    func height(_ width: CGFloat) -> CGFloat {
        if let height { return height }
        return max(child.height(childWidth(width)), minHeight ?? 0)
    }

    /// The child's rect inside the frame's rect, aligned.
    func childRect(_ rect: CGRect) -> CGRect {
        let w = childWidth(rect.width)
        let h = child.fillsHeight ? rect.height : child.height(w)
        let x: CGFloat
        switch hAlign {
        case .leading: x = rect.minX
        case .center: x = rect.minX + (rect.width - w) / 2
        case .trailing: x = rect.maxX - w
        }
        let y: CGFloat
        switch vAlign {
        case .top: y = rect.minY
        case .center: y = rect.minY + (rect.height - h) / 2
        case .bottom: y = rect.maxY - h
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func firstBaseline(_ width: CGFloat) -> CGFloat? {
        guard let b = child.firstBaseline(childWidth(width)) else { return nil }
        return childRect(CGRect(x: 0, y: 0, width: width, height: height(width))).minY + b
    }
    func lastBaseline(_ width: CGFloat) -> CGFloat? {
        guard let b = child.lastBaseline(childWidth(width)) else { return nil }
        return childRect(CGRect(x: 0, y: 0, width: width, height: height(width))).minY + b
    }

    func draw(_ g: DVGraphics, _ rect: CGRect) {
        guard rect.intersects(g.dirty) else { return }
        child.draw(g, g.snap(childRect(rect)))
    }
    func hotspots(_ rect: CGRect, into: inout [DVHotspot]) { child.hotspots(childRect(rect), into: &into) }
    func controls(_ rect: CGRect, into: inout [(any DVControl, CGRect)]) { child.controls(childRect(rect), into: &into) }
}

/// A node at least `minHeight(width)` tall, its child filling the height it is given — a
/// card kept as tall as the tallest content a sibling card could ever need at that width.
@MainActor
struct DVMinHeight: DVNode {
    let child: any DVNode
    let minHeight: (CGFloat) -> CGFloat

    var sizing: DVSizing { child.sizing }
    var fillsHeight: Bool { true }
    func height(_ width: CGFloat) -> CGFloat { max(child.height(width), minHeight(width)) }
    func firstBaseline(_ width: CGFloat) -> CGFloat? { child.firstBaseline(width) }
    func lastBaseline(_ width: CGFloat) -> CGFloat? { child.lastBaseline(width) }
    func draw(_ g: DVGraphics, _ rect: CGRect) { child.draw(g, rect) }
    func hotspots(_ rect: CGRect, into: inout [DVHotspot]) { child.hotspots(rect, into: &into) }
    func controls(_ rect: CGRect, into: inout [(any DVControl, CGRect)]) { child.controls(rect, into: &into) }
}

/// `.padding(...)`, then optionally `.background(paint).clipShape(.rect(cornerRadius:))`,
/// and optionally a tap target / pointer over the whole decorated box.
@MainActor
struct DVDecorated: DVNode {
    let child: any DVNode
    var insets: NSEdgeInsets = NSEdgeInsets()
    var background: DVPaint? = nil
    var radius: CGFloat = 0
    var action: DVHotspot.Action? = nil
    var pointer = false
    /// `.frame(maxWidth: .infinity, maxHeight: .infinity)` inside the padding.
    var fillsHeight = false

    var sizing: DVSizing {
        let c = child.sizing
        let h = insets.left + insets.right
        return DVSizing(min: c.min + h, max: c.max == .infinity ? .infinity : c.max + h)
    }
    func height(_ width: CGFloat) -> CGFloat {
        child.height(width - insets.left - insets.right) + insets.top + insets.bottom
    }
    private func inner(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + insets.left, y: rect.minY + insets.top,
               width: rect.width - insets.left - insets.right, height: rect.height - insets.top - insets.bottom)
    }
    func firstBaseline(_ width: CGFloat) -> CGFloat? {
        child.firstBaseline(width - insets.left - insets.right).map { $0 + insets.top }
    }
    func lastBaseline(_ width: CGFloat) -> CGFloat? {
        child.lastBaseline(width - insets.left - insets.right).map { $0 + insets.top }
    }
    func draw(_ g: DVGraphics, _ rect: CGRect) {
        guard rect.intersects(g.dirty) else { return }
        let box = g.snap(rect)
        if let background {
            g.fill(box, background, radius: radius)
        }
        if radius > 0 {
            g.withState { g.clip(box, radius: radius); child.draw(g, inner(rect)) }
        } else {
            child.draw(g, inner(rect))
        }
    }
    func hotspots(_ rect: CGRect, into: inout [DVHotspot]) {
        if let action { into.append(DVHotspot(rect: rect, action: action, pointer: pointer, anchor: inner(rect))) }
        child.hotspots(inner(rect), into: &into)
    }
    func controls(_ rect: CGRect, into: inout [(any DVControl, CGRect)]) { child.controls(inner(rect), into: &into) }
}

// MARK: Stacks

/// `HStack(alignment:spacing:)`, sized by SwiftUI's stack rule: children are offered the
/// remaining width in priority order (highest `layoutPriority` first, with the minimum widths
/// of every lower-priority child held back), and within a priority from least to most
/// flexible, each offered an equal share of what is left.
@MainActor
struct DVHStack: DVContainer {
    enum Alignment { case center, top, bottom, firstBaseline, lastBaseline }
    let children: [any DVNode]
    var spacing: CGFloat = 8
    var alignment: Alignment = .center
    var priorities: [Double] = []
    private let memo = DVMemo<(widths: [CGFloat], heights: [CGFloat], tops: [CGFloat], height: CGFloat)>()

    init(spacing: CGFloat = 8, alignment: Alignment = .center, _ children: [(any DVNode)?], priorities: [Double] = []) {
        var kept: [(index: Int, node: any DVNode)] = []
        for (i, child) in children.enumerated() { if let child { kept.append((i, child)) } }
        self.children = kept.map(\.node)
        self.priorities = priorities.isEmpty ? [] : kept.map { priorities.indices.contains($0.index) ? priorities[$0.index] : 0 }
        self.spacing = spacing
        self.alignment = alignment
    }

    private let sizingOnce = DVOnce<DVSizing>()
    var sizing: DVSizing { sizingOnce.get(computeSizing) }
    private func computeSizing() -> DVSizing {
        let s = children.map(\.sizing)
        let gaps = spacing * CGFloat(max(0, children.count - 1))
        let maxW = s.contains { $0.max == .infinity } ? CGFloat.infinity : s.reduce(0) { $0 + $1.max } + gaps
        return DVSizing(min: s.reduce(0) { $0 + $1.min } + gaps, max: maxW)
    }

    func widths(_ total: CGFloat) -> [CGFloat] {
        let n = children.count
        guard n > 0 else { return [] }
        let sizings = children.map(\.sizing)
        var result = [CGFloat](repeating: 0, count: n)
        var remaining = total - spacing * CGFloat(n - 1)
        let prio = priorities.isEmpty ? [Double](repeating: 0, count: n) : priorities
        let groups = Set(prio).sorted(by: >)
        var minByPriority: [Double: CGFloat] = [:]
        for i in 0..<n { minByPriority[prio[i], default: 0] += sizings[i].min }
        for (gi, p) in groups.enumerated() {
            var lowerMin: CGFloat = 0
            for q in groups[(gi + 1)...] { lowerMin += minByPriority[q] ?? 0 }
            var available = remaining - lowerMin
            // Spacers go last and take what the others leave; until then only their
            // minimum lengths are held back.
            let isSpacer = (0..<n).map { children[$0] is DVSpacer }
            var members = (0..<n).filter { prio[$0] == p && !isSpacer[$0] }
            members.sort { (sizings[$0].max - sizings[$0].min) < (sizings[$1].max - sizings[$1].min) }
            let spacers = (0..<n).filter { prio[$0] == p && isSpacer[$0] }
            var spacerMin = spacers.reduce(CGFloat(0)) { $0 + sizings[$1].min }
            // Room for every member at its widest: each takes it. An even split would
            // short a member wider than the share while a narrower one left room unused.
            let allFit = members.reduce(CGFloat(0)) { $0 + sizings[$1].max } <= available - spacerMin + 0.001
            var left = members.count
            for i in members {
                let offer = allFit ? sizings[i].max : max(0, (available - spacerMin) / CGFloat(left))
                let w = sizings[i].take(offer)
                result[i] = w
                available -= w
                remaining -= w
                left -= 1
            }
            left = spacers.count
            for i in spacers {
                spacerMin -= sizings[i].min
                let w = sizings[i].take(max(0, available / CGFloat(left)))
                result[i] = w
                available -= w
                remaining -= w
                left -= 1
            }
        }
        return result
    }

    private func layout(_ width: CGFloat) -> (widths: [CGFloat], heights: [CGFloat], tops: [CGFloat], height: CGFloat) {
        memo.get(width) { computeLayout(width) }
    }

    private func computeLayout(_ width: CGFloat) -> (widths: [CGFloat], heights: [CGFloat], tops: [CGFloat], height: CGFloat) {
        let ws = widths(width)
        let hs = zip(children, ws).map { $0.height($1) }
        var tops = [CGFloat](repeating: 0, count: children.count)
        var height: CGFloat = hs.max() ?? 0
        switch alignment {
        case .center:
            for i in children.indices { tops[i] = (height - hs[i]) / 2 }
        case .top: break
        case .bottom:
            for i in children.indices { tops[i] = height - hs[i] }
        case .firstBaseline, .lastBaseline:
            let first = alignment == .firstBaseline
            let bases = children.indices.map { i in
                (first ? children[i].firstBaseline(ws[i]) : children[i].lastBaseline(ws[i])) ?? hs[i]
            }
            let maxBase = bases.max() ?? 0
            for i in children.indices { tops[i] = maxBase - bases[i] }
            let minTop = tops.min() ?? 0
            for i in children.indices { tops[i] -= minTop }
            height = children.indices.map { tops[$0] + hs[$0] }.max() ?? 0
        }
        return (ws, hs, tops, height)
    }

    func height(_ width: CGFloat) -> CGFloat { layout(width).height }

    /// A row's first baseline is its topmost child baseline and its last the lowest (measured:
    /// a Text beside a two-line stack aligns by the stack's first line, not its own).
    func firstBaseline(_ width: CGFloat) -> CGFloat? {
        let l = layout(width)
        return children.indices.compactMap { i in children[i].firstBaseline(l.widths[i]).map { l.tops[i] + $0 } }.min()
    }
    func lastBaseline(_ width: CGFloat) -> CGFloat? {
        let l = layout(width)
        return children.indices.compactMap { i in children[i].lastBaseline(l.widths[i]).map { l.tops[i] + $0 } }.max()
    }

    fileprivate func rects(_ rect: CGRect) -> [CGRect] {
        let l = layout(rect.width)
        let extra = rect.height - l.height
        var x = rect.minX
        return children.indices.map { i in
            var top = l.tops[i]
            if alignment == .center { top = (rect.height - l.heights[i]) / 2 } else if alignment == .bottom { top += extra }
            defer { x += l.widths[i] + spacing }
            return CGRect(x: x, y: rect.minY + top, width: l.widths[i], height: l.heights[i])
        }
    }

}

/// `VStack(alignment: .leading, spacing:)`. Every child is offered the full width; children
/// narrower than it sit at the leading edge (each draws within its own sizing). When placed
/// taller than its natural height, the extra goes to its Spacers (children that fill).
@MainActor
struct DVVStack: DVContainer {
    let children: [any DVNode]
    var spacing: CGFloat = 8
    /// Horizontal alignment of children narrower than the stack.
    var align: DVFrame.HAlign = .leading
    private let memo = DVMemo<[CGFloat]>()

    init(spacing: CGFloat = 8, align: DVFrame.HAlign = .leading, _ children: [(any DVNode)?]) {
        self.children = children.compactMap { $0 }
        self.spacing = spacing
        self.align = align
    }

    private let sizingOnce = DVOnce<DVSizing>()
    var sizing: DVSizing {
        sizingOnce.get {
            let s = children.map(\.sizing)
            return DVSizing(min: s.map(\.min).max() ?? 0, max: s.map(\.max).max() ?? 0)
        }
    }
    var fillsHeight: Bool { children.contains { $0.fillsHeight } }

    private func childWidth(_ child: any DVNode, _ width: CGFloat) -> CGFloat { min(width, child.sizing.take(width)) }

    private func natural(_ width: CGFloat) -> [CGFloat] {
        memo.get(width) { children.map { $0.height(childWidth($0, width)) } }
    }

    func height(_ width: CGFloat) -> CGFloat {
        natural(width).reduce(0, +) + spacing * CGFloat(max(0, children.count - 1))
    }

    func firstBaseline(_ width: CGFloat) -> CGFloat? {
        var y: CGFloat = 0
        for c in children {
            let w = childWidth(c, width)
            if let b = c.firstBaseline(w) { return y + b }
            y += c.height(w) + spacing
        }
        return nil
    }

    /// Each child's height when the stack is placed `total` tall. At its natural height that
    /// is each child's own; taller, SwiftUI's stack rule applies: children are offered the
    /// height left in order from least to most flexible, each an equal share of what remains,
    /// and each takes its share clamped to its own range (a fixed child keeps its height, a
    /// filling child never goes below its natural height).
    func heights(_ width: CGFloat, total: CGFloat) -> [CGFloat] {
        let natural = natural(width)
        let gaps = spacing * CGFloat(max(0, children.count - 1))
        guard total > natural.reduce(0, +) + gaps + 0.001 else { return natural }
        var result = natural
        var remaining = total - gaps
        var order = Array(children.indices)
        order.sort { (children[$0].fillsHeight ? 1 : 0) < (children[$1].fillsHeight ? 1 : 0) }
        var left = order.count
        for i in order {
            let offer = remaining / CGFloat(left)
            let h = children[i].fillsHeight ? max(natural[i], offer) : natural[i]
            result[i] = h
            remaining -= h
            left -= 1
        }
        return result
    }

    func rects(_ rect: CGRect) -> [CGRect] {
        let hs = heights(rect.width, total: rect.height)
        var y = rect.minY
        return children.indices.map { i in
            let w = childWidth(children[i], rect.width)
            let x: CGFloat
            switch align {
            case .leading: x = rect.minX
            case .center: x = rect.minX + (rect.width - w) / 2
            case .trailing: x = rect.maxX - w
            }
            defer { y += hs[i] + spacing }
            return CGRect(x: x, y: y, width: w, height: hs[i])
        }
    }

}

/// A column of rows that fills whatever height its card gives it by opening up the gaps
/// between rows equally (never below `minSpacing`); its own height is only its natural one,
/// so it can never make the card taller. Each child keeps its natural height.
@MainActor
struct DVSpread: DVContainer {
    let children: [any DVNode]
    var minSpacing: CGFloat = 4

    init(minSpacing: CGFloat = 4, _ children: [any DVNode]) {
        self.children = children
        self.minSpacing = minSpacing
    }

    var fillsHeight: Bool { true }
    private func childWidth(_ child: any DVNode, _ width: CGFloat) -> CGFloat { min(width, child.sizing.take(width)) }
    func height(_ width: CGFloat) -> CGFloat {
        children.reduce(0) { $0 + $1.height(childWidth($1, width)) } + minSpacing * CGFloat(max(0, children.count - 1))
    }
    func rects(_ rect: CGRect) -> [CGRect] {
        let hs = children.map { $0.height(childWidth($0, rect.width)) }
        let gap = children.count > 1 ? max(minSpacing, (rect.height - hs.reduce(0, +)) / CGFloat(children.count - 1)) : 0
        var y = rect.minY
        return children.indices.map { i in
            defer { y += hs[i] + gap }
            return CGRect(x: rect.minX, y: y, width: childWidth(children[i], rect.width), height: hs[i])
        }
    }
    func firstBaseline(_ width: CGFloat) -> CGFloat? { children.first?.firstBaseline(width) }
}

/// As many of `rows` as the height it is given holds, spread to fill it as DVSpread
/// spreads; when some are left out, `more` (a View All button) follows the last shown.
/// Its own height is `minimumRows` items — every row when they fit, else one fewer row and
/// `more` — so it never sets a card's height above that: a taller neighbor lets it show more.
@MainActor
struct DVFitRows: DVNode {
    let rows: [any DVNode]
    var more: (any DVNode)? = nil
    var minimumRows = 7
    var minSpacing: CGFloat = 4

    var fillsHeight: Bool { true }
    private func items(_ count: Int) -> [any DVNode] { Array(rows.prefix(count)) + (count < rows.count ? [more].compactMap { $0 } : []) }
    private func need(_ items: [any DVNode], _ width: CGFloat) -> CGFloat {
        items.reduce(0) { $0 + $1.height(min(width, $1.sizing.take(width))) } + minSpacing * CGFloat(max(0, items.count - 1))
    }
    func height(_ width: CGFloat) -> CGFloat {
        need(items(rows.count <= minimumRows ? rows.count : minimumRows - 1), width)
    }
    /// The most rows (with `more` when any are left out) that fit in `rect`; at least one.
    func fittingCount(_ rect: CGRect) -> Int {
        var count = rows.count
        while count > 1, need(items(count), rect.width) > rect.height + 0.5 { count -= 1 }
        return count
    }
    private func shown(_ rect: CGRect) -> DVSpread { DVSpread(minSpacing: minSpacing, items(fittingCount(rect))) }
    func firstBaseline(_ width: CGFloat) -> CGFloat? { rows.first?.firstBaseline(width) }
    func draw(_ g: DVGraphics, _ rect: CGRect) { shown(rect).draw(g, rect) }
    func hotspots(_ rect: CGRect, into: inout [DVHotspot]) { shown(rect).hotspots(rect, into: &into) }
    func controls(_ rect: CGRect, into: inout [(any DVControl, CGRect)]) { shown(rect).controls(rect, into: &into) }
}

/// `ZStack(alignment: .top)` of a background drawing and one child.
@MainActor
struct DVOverlay: DVNode {
    let base: any DVNode
    let overlay: (DVGraphics, CGRect) -> Void
    var sizing: DVSizing { base.sizing }
    var fillsHeight: Bool { base.fillsHeight }
    func height(_ width: CGFloat) -> CGFloat { base.height(width) }
    func firstBaseline(_ width: CGFloat) -> CGFloat? { base.firstBaseline(width) }
    func lastBaseline(_ width: CGFloat) -> CGFloat? { base.lastBaseline(width) }
    func draw(_ g: DVGraphics, _ rect: CGRect) {
        guard rect.intersects(g.dirty) else { return }
        base.draw(g, rect)
        overlay(g, rect)
    }
    func hotspots(_ rect: CGRect, into: inout [DVHotspot]) { base.hotspots(rect, into: &into) }
    func controls(_ rect: CGRect, into: inout [(any DVControl, CGRect)]) { base.controls(rect, into: &into) }
}

/// The first variant that fits the width it is given, as `ViewThatFits(in: .horizontal)`:
/// each variant carries the width it needs to show without truncating, and the last is
/// used (truncating) when none fits. Lets a card shorten its wording ("days" → "d") rather
/// than clip it, re-chosen on every layout so it expands again as the window widens.
@MainActor
struct DVFirstFit: DVNode {
    let variants: [(needs: CGFloat, node: any DVNode)]

    /// Text variants of one string, each needing its unwrapped width.
    init(texts: [DVText]) { variants = texts.map { ($0.idealWidth, $0) } }
    init(_ variants: [(needs: CGFloat, node: any DVNode)]) { self.variants = variants }

    private func pick(_ width: CGFloat) -> any DVNode {
        (variants.first { $0.needs <= width + 0.001 } ?? variants[variants.count - 1]).node
    }
    var sizing: DVSizing { DVSizing(min: variants.last!.node.sizing.min, max: variants[0].node.sizing.max) }
    var fillsHeight: Bool { variants[0].node.fillsHeight }
    func height(_ width: CGFloat) -> CGFloat { pick(width).height(width) }
    func firstBaseline(_ width: CGFloat) -> CGFloat? { pick(width).firstBaseline(width) }
    func lastBaseline(_ width: CGFloat) -> CGFloat? { pick(width).lastBaseline(width) }
    func draw(_ g: DVGraphics, _ rect: CGRect) { pick(rect.width).draw(g, rect) }
    func hotspots(_ rect: CGRect, into: inout [DVHotspot]) { pick(rect.width).hotspots(rect, into: &into) }
    func controls(_ rect: CGRect, into: inout [(any DVControl, CGRect)]) { pick(rect.width).controls(rect, into: &into) }
}

/// An embedded AppKit control as a layout node.
@MainActor
struct DVControlNode: DVNode {
    let control: any DVControl
    /// `.frame(width:height:)` at the call site, if any.
    var width: CGFloat? = nil
    var layoutHeight: CGFloat? = nil
    var sizing: DVSizing { width.map { DVSizing(min: $0, max: $0) } ?? control.sizing }
    func height(_ width: CGFloat) -> CGFloat { layoutHeight ?? control.layoutSize(offer: width).height }
    func firstBaseline(_ width: CGFloat) -> CGFloat? { control.baselineFromTop }
    func lastBaseline(_ width: CGFloat) -> CGFloat? { control.baselineFromTop }
    func draw(_ g: DVGraphics, _ rect: CGRect) {}
    func controls(_ rect: CGRect, into: inout [(any DVControl, CGRect)]) { into.append((control, rect)) }
}


/// A segment of a stacked bar or legend.
struct DVKSegment {
    let label: String
    let count: Int
    let color: NSColor
    var fillOpacity = DVStyle.fillOpacity
}

/// One bar of a vertical chart.
struct DVKBar {
    let label: String
    let value: Double
    var color: NSColor = .systemBlue
    var dimmed = false
    var valueLabel: String? = nil
    /// Drawn inside the bar near its top, small and faint, as the Purchases by Year bands
    /// show their counts; omitted when the bar is too short to hold it.
    var insideLabel: String? = nil
}

/// One month of the Viewings by Month chart.
struct DVKMonthBar {
    let label: String
    let value: Int
    /// `value` split into the chart's bands, top first (they sum to `value`).
    let bands: [Int]
    var ghost: Int? = nil
    var ghostBands: [Int] = []
    var dimmed = false
    var valueLabel: String? = nil
}

@MainActor
enum DVK {
    static let cardPaint = DVPaint(color: .controlBackgroundColor)
    /// A card's (and a stat tile's) padding on every side.
    static let cardInsets = NSEdgeInsets(top: DVStyle.cardPadding, left: DVStyle.cardPadding,
                                         bottom: DVStyle.cardPadding, right: DVStyle.cardPadding)
    static let rowPaint = DVPaint(color: .controlBackgroundColor, opacity: 0.5)
    static let separator = DVPaint(color: .separatorColor)

    // MARK: Section

    /// A section's band: a 20 pt bold title, a 10 pt detail at its baseline, and a 2 pt rule
    /// along the bottom of a 46 pt band, like the gallery's section dividers.
    static func sectionBand(_ title: String, _ detail: String?) -> any DVNode {
        let row = DVHStack(spacing: 8, alignment: .lastBaseline, [
            DVText(title, .system(20, .bold), .primary),
            detail.map { _ in DVSpacer(minLength: 8) },
            detail.map { DVText($0, .system(10), .secondary) },
        ])
        let stack = DVVStack(spacing: 4, [
            DVSpacer(),
            row,
            DVBox(height: 2) { g, r in g.fill(r, separator) },
        ])
        return DVFrame(child: stack, height: 46)
    }

    /// A section: the band (24 pt below the previous section) and the rows, 16 apart.
    static func section(_ title: String, detail: String? = nil, first: Bool = false, _ content: [any DVNode]) -> any DVNode {
        let band = DVDecorated(child: sectionBand(title, detail),
                               insets: NSEdgeInsets(top: first ? 0 : 24, left: 0, bottom: 0, right: 0))
        return DVVStack(spacing: DVStyle.gap, [band] + content)
    }

    // MARK: Card

    /// A card: a title row (title, and a trailing note or node — a legend, a scope control),
    /// an optional wrapping subtitle, then the content. With `action` the whole card is
    /// clickable and its title row ends in a chevron, centered on the title. `subtitleNode`
    /// (a legend) sits where a subtitle would. The title keeps its full width first; the
    /// trailing note or node takes the rest, so a legend wraps only when the title row is
    /// truly full rather than at an even split with the title.
    static func card(title: String? = nil, trailing: String? = nil, trailingNode: (any DVNode)? = nil,
                     subtitle: String? = nil, subtitleNode: (any DVNode)? = nil, bottomAligned: Bool = false, action: (() -> Void)? = nil,
                     _ content: [any DVNode]) -> any DVNode {
        var outer: [any DVNode] = []
        if action != nil {
            outer.append(DVHStack(spacing: 8, alignment: .center, [
                title.map { DVText($0, .system(13, .semibold), .primary) },
                DVSpacer(minLength: 0),
                trailingNode ?? trailing.map { DVText($0, .system(10), .secondary) },
                DVSymbol(name: "chevron.right", pointSize: 10, weight: .semibold, paint: .secondary),
            ], priorities: [2, 0, 1, 0]))
        } else if title != nil || trailing != nil || trailingNode != nil {
            outer.append(DVHStack(spacing: 8, alignment: .firstBaseline, [
                title.map { DVText($0, .system(13, .semibold), .primary) },
                DVSpacer(minLength: 0),
                trailingNode ?? trailing.map { DVText($0, .system(10), .secondary) },
            ], priorities: [2, 0, 1]))
        }
        var inner: [any DVNode] = []
        if let subtitle {
            inner.append(DVFrame(child: DVText(subtitle, .system(10), .secondary, lineLimit: nil),
                                 maxInfinity: true, hAlign: .leading))
        }
        if let subtitleNode { inner.append(subtitleNode) }
        if bottomAligned { inner.append(DVSpacer()) }
        inner += content
        outer.append(DVVStack(spacing: 8, inner))
        return DVDecorated(child: DVVStack(spacing: 8, outer),
                           insets: cardInsets,
                           background: cardPaint, radius: DVStyle.cardRadius,
                           action: action.map { .perform($0) }, pointer: action != nil, fillsHeight: true)
    }

    /// A 12 pt medium secondary heading for a group inside a card.
    static func subheading(_ text: String) -> any DVNode { DVText(text, .system(12, .medium), .secondary) }

    /// A 10 pt secondary note, full width.
    static func footnote(_ text: String) -> any DVNode {
        DVFrame(child: DVText(text, .system(10), .secondary), maxInfinity: true, hAlign: .leading)
    }

    // MARK: Tiles

    /// A delta's chip: the change in its direction's color on a tint of it.
    static func deltaChip(_ delta: DVDelta) -> any DVNode {
        let color: NSColor = delta.direction == .up ? .systemGreen : (delta.direction == .down ? .systemRed : .secondaryLabelColor)
        return DVDecorated(child: DVText(delta.text, .system(10, .semibold), DVPaint(color: color)),
                           insets: NSEdgeInsets(top: 1, left: 5, bottom: 1, right: 5),
                           background: DVPaint(color: color, opacity: 0.14), radius: 4)
    }

    /// A stat tile: title, value (with an optional delta chip or trailing note, and a chevron
    /// when it opens something — or, with `popoverID`, an info glyph, the tile opening that
    /// popover as a Needs Attention row does), and a two-line footnote.
    static func statTile(title: String, value: String, color: NSColor = .labelColor, trailing: String? = nil,
                         delta: DVDelta? = nil, footnote: String? = nil, action: (() -> Void)? = nil,
                         popoverID: String? = nil) -> any DVNode {
        let valueRow = DVHStack(spacing: 6, alignment: .center, [
            DVText(value, .system(20, .semibold), DVPaint(color: color), minimumScale: 0.7),
            delta.map(deltaChip),
            trailing.map { DVText($0, .system(10), .secondary) },
            DVSpacer(minLength: 0),
            popoverID != nil
                ? DVSymbol(name: "info.circle", pointSize: 11, weight: .semibold, paint: .secondary)
                : DVSymbol(name: "chevron.right", pointSize: 10, weight: .semibold, paint: .secondary, opacity: action != nil ? 1 : 0),
        ], priorities: [0, 1, 0, 0, 0])
        let foot = DVFrame(child: DVFrame(child: DVText(footnote ?? " ", .system(10), .secondary, lineLimit: 2),
                                          maxInfinity: true, hAlign: .leading, vAlign: .top),
                           height: 26, vAlign: .top)
        let stack = DVVStack(spacing: 5, [DVText(title, .system(11), .secondary), valueRow, foot])
        return DVDecorated(child: DVFrame(child: stack, maxInfinity: true, hAlign: .leading),
                           insets: cardInsets,
                           background: cardPaint, radius: DVStyle.cardRadius,
                           action: popoverID.map { .popover(id: $0) } ?? action.map { .perform($0) },
                           pointer: action != nil || popoverID != nil)
    }

    // MARK: Bars

    /// A tinted track with a leading-anchored fill.
    static func fillBar(_ fraction: Double, _ color: NSColor, height: CGFloat = 20,
                        fillOpacity: CGFloat = DVStyle.fillOpacity, minWidth: CGFloat = 0) -> any DVNode {
        DVBox(minWidth: minWidth, height: height) { g, r in
            g.withState {
                g.clip(r, radius: 4)
                g.fill(r, DVPaint(color: color, opacity: DVStyle.trackOpacity))
                let f = CGFloat(max(0, min(1, fraction)))
                g.fill(CGRect(x: r.minX, y: r.minY, width: r.width * f, height: r.height), DVPaint(color: color, opacity: fillOpacity))
            }
        }
    }

    /// Label · bar · count · percent, the report's standard horizontal-bar row.
    static func barRow(label: String, fraction: Double, color: NSColor, count: String? = nil, percent: String? = nil,
                       labelWidth: CGFloat = 110, countWidth: CGFloat = 40, percentWidth: CGFloat = 36,
                       barHeight: CGFloat = 20, fillOpacity: CGFloat = DVStyle.fillOpacity) -> any DVNode {
        DVHStack(spacing: 8, [
            DVFrame(child: DVText(label, .system(11), .secondary), width: labelWidth, hAlign: .leading),
            fillBar(fraction, color, height: barHeight, fillOpacity: fillOpacity, minWidth: 24),
            count.map { DVFrame(child: DVText($0, .mono(11), .primary), width: countWidth, hAlign: .trailing) },
            percent.map { DVFrame(child: DVText($0, .system(10), .secondary), width: percentWidth, hAlign: .trailing) },
        ])
    }

    /// Bar rows for tallies: each bar its share (or, `scaleToMax`, its fraction of the largest).
    static func tallyRows(_ rows: [DVTally], color: NSColor, labelWidth: CGFloat = 110,
                          scaleToMax: Bool = false, showPercent: Bool = true) -> any DVNode {
        let maxCount = max(rows.map(\.count).max() ?? 1, 1)
        return DVVStack(spacing: 6, rows.map { row in
            barRow(label: row.label,
                   fraction: scaleToMax ? Double(row.count) / Double(maxCount) : Double(row.percent ?? 0) / 100,
                   color: color, count: DVFormat.count(row.count),
                   percent: showPercent ? row.percent.map { "\($0)%" } : nil, labelWidth: labelWidth)
        })
    }

    /// One bar split proportionally among its segments.
    static func stackedBar(_ segments: [DVKSegment], height: CGFloat = 20) -> any DVNode {
        DVBox(height: height) { g, r in
            g.withState {
                g.clip(r, radius: 4)
                g.fill(r, DVPaint(color: .secondaryLabelColor, opacity: DVStyle.trackOpacity))
                let total = Double(segments.reduce(0) { $0 + $1.count })
                guard total > 0 else { return }
                var x = r.minX
                for s in segments where s.count > 0 {
                    let w = r.width * CGFloat(Double(s.count) / total)
                    g.fill(CGRect(x: x, y: r.minY, width: w, height: r.height), DVPaint(color: s.color, opacity: s.fillOpacity))
                    x += w
                }
            }
        }
    }

    /// Swatch + label items flowed onto as many rows as they need, never split mid-item.
    static func legend(_ segments: [DVKSegment], showCounts: Bool = true, total: Int? = nil) -> any DVNode {
        let denominator = total ?? segments.reduce(0) { $0 + $1.count }
        let items: [any DVNode] = segments.map { s in
            var text = s.label
            if showCounts {
                let pct = denominator > 0 ? " (\(DVFormat.percent(s.count, of: denominator))%)" : ""
                text = "\(s.label): \(DVFormat.count(s.count))\(pct)"
            }
            return DVHStack(spacing: 5, [
                DVBox(width: 10, height: 10) { g, r in g.fill(r, DVPaint(color: s.color, opacity: s.fillOpacity), radius: 2) },
                DVText(text, .system(11), .primary),
            ])
        }
        return DVWrap(items: items, spacing: 14, lineSpacing: 4)
    }

    // MARK: Vertical charts

    /// Columns grown upward from a shared baseline, value labels riding on top.
    static func verticalBars(_ bars: [DVKBar], height: CGFloat = 150, spacing: CGFloat = 8) -> any DVNode {
        let peak = bars.reduce(0.0) { max($0, $1.value) }
        let scale = peak > 0 ? peak : 1
        return DVColumns(count: bars.count, spacing: spacing, chartHeight: height, draw: { g, i, col in
            let bar = bars[i]
            let usable = height - 16
            let barH: CGFloat = bar.value > 0 ? max(2, CGFloat(bar.value / scale) * usable) : 0
            let barRect = CGRect(x: col.minX, y: col.maxY - barH, width: col.width, height: barH)
            if barH > 0 {
                g.fillPath(DVShapes.topRounded(g.snap(barRect), 3),
                           DVPaint(color: bar.color, opacity: bar.dimmed ? DVStyle.fillOpacity * 0.5 : DVStyle.fillOpacity))
            }
            if let inside = bar.insideLabel, barRect.height >= 14 {
                let line = DVLine.plain(inside, .mono(8))
                let w = min(col.width, line.width(scale: g.scale))
                g.draw(line, at: CGPoint(x: g.snap(barRect.midX - w / 2), y: barRect.minY + 2), width: w,
                       paint: DVPaint(color: .white, opacity: 0.55))
            }
            if let label = bar.valueLabel {
                let line = DVLine.plain(label, .mono(10))
                let w = min(col.width, line.width(scale: g.scale))
                let lh = DVFont.mono(10).lineHeight
                g.draw(line, at: CGPoint(x: g.snap(col.midX - w / 2), y: barRect.minY - 3 - lh), width: w,
                       paint: .secondary, scaleToFit: 0.6)
            }
        }, labels: bars.map(\.label))
    }

    /// The Viewings by Month palette. The comparison year is the same color-over-gray split,
    /// dimmed and shifted in hue (blue toward indigo, gray toward blue); dynamic, so each
    /// blend resolves in the drawing appearance.
    static let monthBlue = DVPaint(color: .systemBlue, opacity: DVStyle.fillOpacity)
    static let monthGray = DVPaint(color: .systemGray, opacity: DVStyle.fillOpacity)
    static let monthPriorBlue = DVPaint(color: blend(.systemBlue, 0.4, .systemIndigo), opacity: DVStyle.fillOpacity * 0.5)
    static let monthPriorGray = DVPaint(color: blend(.systemGray, 0.25, .systemBlue), opacity: DVStyle.fillOpacity * 0.5)

    static func blend(_ a: NSColor, _ fraction: CGFloat, _ b: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var result = a
            appearance.performAsCurrentDrawingAppearance {
                result = a.usingColorSpace(.sRGB)?.blended(withFraction: fraction, of: b.usingColorSpace(.sRGB) ?? b) ?? a
            }
            return result
        }
    }

    /// Fills `rect` with 45° stripes (running bottom-left to top-right) alternating `a` and `b`.
    static func stripes(_ g: DVGraphics, _ rect: CGRect, _ a: DVPaint, _ b: DVPaint, width: CGFloat = 4) {
        guard rect.width > 0, rect.height > 0 else { return }
        g.withState {
            g.ctx.clip(to: rect)
            var even = true
            var x = rect.minX - rect.height
            while x < rect.maxX {
                let band = CGMutablePath()
                band.move(to: CGPoint(x: x, y: rect.maxY))
                band.addLine(to: CGPoint(x: x + width, y: rect.maxY))
                band.addLine(to: CGPoint(x: x + width + rect.height, y: rect.minY))
                band.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                band.closeSubpath()
                g.fillPath(band, even ? a : b)
                even.toggle()
                x += width
            }
        }
    }

    /// One month bar: its bands stacked top first in `paints`, a top-rounded column, each
    /// band's count inside it when there is room. `striped` alternates each band with the
    /// other year's paint for it (`altPaints`) in 45° stripes (the month in progress).
    private static func monthBar(_ g: DVGraphics, _ rect: CGRect, value: Int, bands: [Int],
                                 paints: [DVPaint], altPaints: [DVPaint], striped: Bool) {
        guard rect.height > 0, value > 0 else { return }
        // Band edges from the running total, each rounded once, so the bands tile the bar.
        var edges: [CGFloat] = [0]
        var running = 0
        for n in bands {
            running += n
            edges.append(min(rect.height, max(0, (rect.height * CGFloat(running) / CGFloat(value)).rounded())))
        }
        edges[edges.count - 1] = rect.height
        g.withState {
            g.ctx.addPath(DVShapes.topRounded(rect, 3)); g.ctx.clip()
            let label = DVFont.mono(8)
            for (i, n) in bands.enumerated() where n > 0 {
                let band = CGRect(x: rect.minX, y: rect.minY + edges[i], width: rect.width, height: edges[i + 1] - edges[i])
                let paint = paints[i % paints.count], alt = altPaints[i % altPaints.count]
                if striped { stripes(g, band, paint, alt) } else { g.fill(band, paint) }
                guard band.height >= 14 else { continue }
                let line = DVLine.plain(DVFormat.count(n), label)
                let w = min(rect.width, line.width(scale: g.scale))
                g.draw(line, at: CGPoint(x: g.snap(rect.midX - w / 2), y: band.minY + 2), width: w, paint: DVPaint(color: .white, opacity: 0.55))
            }
        }
    }

    /// Viewings per month: the year shown beside the comparison year (when there is one),
    /// each bar split into its bands (`paints`, the comparison year's in `priorPaints`) with
    /// their counts; the month in progress (`dimmed`) striped with both years' paints.
    static func monthColorBars(_ bars: [DVKMonthBar], paints: [DVPaint] = [monthBlue, monthGray],
                               priorPaints: [DVPaint] = [monthPriorBlue, monthPriorGray],
                               height: CGFloat = 150, spacing: CGFloat = 8) -> any DVNode {
        let peak = bars.reduce(0.0) { max($0, Double(max($1.value, $1.ghost ?? 0))) }
        let scale = peak > 0 ? peak : 1
        let lh = DVFont.mono(10).lineHeight
        func barHeight(_ v: Int) -> CGFloat { v > 0 ? max(2, CGFloat(Double(v) / scale) * (height - 16)) : 0 }
        func valueLabel(_ g: DVGraphics, _ text: String, x: CGFloat, width: CGFloat, top: CGFloat, paint: DVPaint) {
            let line = DVLine.plain(text, .mono(10))
            let w = min(width, line.width(scale: g.scale))
            g.draw(line, at: CGPoint(x: g.snap(x + width / 2 - w / 2), y: top - 3 - lh), width: w, paint: paint, scaleToFit: 0.6)
        }
        return DVColumns(count: bars.count, spacing: spacing, chartHeight: height, draw: { g, i, col in
            let bar = bars[i]
            let total = barHeight(bar.value)
            // The two years side by side, 3 pt apart, splitting the column equally; with no
            // comparison the year shown takes the whole column.
            let ghostH = bar.ghost.map(barHeight) ?? 0
            let hasGhost = bar.ghost != nil
            let half = (col.width - 3) / 2
            let filledW = hasGhost ? half : col.width
            let ghostX = col.minX + half + 3
            if total > 0 {
                monthBar(g, g.snap(CGRect(x: col.minX, y: col.maxY - total, width: filledW, height: total)),
                         value: bar.value, bands: bar.bands, paints: paints, altPaints: priorPaints, striped: bar.dimmed)
            }
            if let label = bar.valueLabel {
                valueLabel(g, label, x: col.minX, width: filledW, top: col.maxY - total, paint: .secondary)
            }
            if let ghost = bar.ghost, ghostH > 0 {
                monthBar(g, g.snap(CGRect(x: ghostX, y: col.maxY - ghostH, width: half, height: ghostH)),
                         value: ghost, bands: bar.ghostBands, paints: priorPaints, altPaints: paints, striped: bar.dimmed)
                valueLabel(g, DVFormat.count(ghost), x: ghostX, width: half, top: col.maxY - ghostH, paint: .tertiary)
            }
        }, labels: bars.map(\.label))
    }

    // MARK: Rows

    /// Label at the leading edge, value at the trailing edge. `year` follows the label in
    /// tertiary, as one line (a film's release year). With `popoverID`, an info glyph trails
    /// the value and a click opens that popover, as a Needs Attention row does;
    /// `reserveInfoSpace` keeps the glyph's room (unseen) so the value lines up with such rows.
    static func factRow(label: String, year: Int? = nil, value: String, valueColor: NSColor = .labelColor, indented: Bool = false,
                        indentWidth: CGFloat = 20, reserveChevronSpace: Bool = false, popoverID: String? = nil,
                        reserveInfoSpace: Bool = false, compactLabel: String? = nil, compactValue: String? = nil) -> any DVNode {
        // A compact wording swaps in only when the full row would truncate.
        if compactLabel != nil || compactValue != nil {
            func row(_ l: String, _ v: String) -> any DVNode {
                factRow(label: l, year: year, value: v, valueColor: valueColor, indented: indented, indentWidth: indentWidth,
                        reserveChevronSpace: reserveChevronSpace, popoverID: popoverID, reserveInfoSpace: reserveInfoSpace)
            }
            func needs(_ l: String, _ v: String, _ node: any DVNode) -> CGFloat {
                var w = node.sizing.min + DVText(runs: [DVRun(string: l + (year.map { " (\(String($0)))" } ?? ""), paint: .primary)],
                                                  .system(11)).idealWidth
                if !reserveChevronSpace { w += DVText(v, .mono(11)).idealWidth }
                return w
            }
            let full = row(label, value), compact = row(compactLabel ?? label, compactValue ?? value)
            return DVFirstFit([(needs(label, value, full), full), (needs(compactLabel ?? label, compactValue ?? value, compact), compact)])
        }
        let valueText = DVText(value, .mono(11), DVPaint(color: valueColor))
        var labelRuns = [DVRun(string: label, paint: indented ? .secondary : .primary)]
        if let year { labelRuns.append(DVRun(string: " (\(String(year)))", paint: .tertiary)) }
        let row = DVHStack(spacing: 8, [
            DVText(runs: labelRuns, .system(11)),
            DVSpacer(minLength: 8),
            reserveChevronSpace ? DVFrame(child: valueText, width: 32, hAlign: .trailing) : valueText,
            reserveChevronSpace ? DVBox(width: 18, height: 1) { _, _ in } : nil,
            popoverID != nil || reserveInfoSpace
                ? DVSymbol(name: "info.circle", pointSize: 11, weight: .semibold, paint: .secondary, opacity: popoverID != nil ? 1 : 0) : nil,
        ], priorities: [0, 0, 1, 0, 0])
        return DVDecorated(child: row, insets: NSEdgeInsets(top: 4, left: indented ? indentWidth : 8, bottom: 4, right: 8),
                           background: rowPaint, radius: 4, action: popoverID.map { .popover(id: $0) }, pointer: popoverID != nil)
    }

    /// "1. Name … value [extras]": a ranked row with optional fixed-width extra columns.
    static func rankRow(rank: Int? = nil, name: String, value: String, extras: [String] = [], extraWidth: CGFloat = 44,
                        compact: Bool = false, year: Int? = nil) -> any DVNode {
        var runs = [DVRun(string: name, paint: .primary)]
        if let year { runs.append(DVRun(string: " (\(String(year)))", paint: .tertiary)) }
        var children: [(any DVNode)?] = [
            rank.map { DVFrame(child: DVText("\($0).", .system(11), .secondary), width: 20, hAlign: .leading) },
            DVText(runs: runs, .system(12)),
            DVSpacer(minLength: 8),
            DVText(value, .mono(11, .semibold), .primary),
        ]
        var priorities: [Double] = [0, 0, 0, 1]
        for extra in extras {
            children.append(DVFrame(child: DVText(extra, .mono(11), .secondary), width: extraWidth, hAlign: .trailing))
            priorities.append(0)
        }
        return DVDecorated(child: DVHStack(spacing: 6, children, priorities: priorities),
                           insets: NSEdgeInsets(top: compact ? 2 : 4, left: 8, bottom: compact ? 2 : 4, right: 8),
                           background: rowPaint, radius: 4)
    }

    /// The Rotation Status card's rows: dot, label, count and (when actionable) a chevron.
    static func attentionRowCompact(label: String, count: Int, tint: NSColor, action: (() -> Void)? = nil) -> any DVNode {
        let row = DVHStack(spacing: 8, [
            DVBox(width: 8, height: 8) { g, r in g.ctx.setFillColor(DVPaint(color: tint).cgColor); g.ctx.fillEllipse(in: r) },
            DVText(label, .system(12), .primary),
            DVSpacer(minLength: 8),
            DVFrame(child: DVText(DVFormat.count(count), .mono(11, .semibold), .primary), width: 32, hAlign: .trailing),
            DVFrame(child: DVSymbol(name: "chevron.right", pointSize: 10, weight: .semibold, paint: .secondary,
                                    opacity: action != nil ? 1 : 0), width: 18, hAlign: .trailing),
        ], priorities: [0, 0, 0, 1, 0])
        return DVDecorated(child: row, insets: NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8),
                           background: rowPaint, radius: 4, action: action.map { .perform($0) }, pointer: action != nil)
    }

    /// A row of the Needs Attention card: dot, label (up to two lines), count and info glyph;
    /// a click opens the popover listing the films behind the count.
    static func attentionListRow(label: String, count: Int, tint: NSColor, popoverID: String) -> any DVNode {
        let row = DVHStack(spacing: 8, [
            DVBox(width: 8, height: 8) { g, r in g.ctx.setFillColor(DVPaint(color: tint).cgColor); g.ctx.fillEllipse(in: r) },
            DVFrame(child: DVText(label, .system(12), .primary, lineLimit: 2), maxInfinity: true, hAlign: .leading),
            DVText(DVFormat.count(count), .mono(11, .semibold), .primary),
            DVSymbol(name: "info.circle", pointSize: 11, weight: .semibold, paint: .secondary),
        ], priorities: [0, 0, 1, 0])
        return DVDecorated(child: row, insets: NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8),
                           background: rowPaint, radius: 4, action: .popover(id: popoverID), pointer: true)
    }

    // MARK: Highlights and lines

    /// A Spending Trends statement: kicker, headline and detail beside its small chart,
    /// bounded by a 1 pt quaternary outline.
    static func highlightRow(_ h: DVHighlight) -> any DVNode {
        let text = DVVStack(spacing: 3, [
            DVText(h.kicker, .system(10, .semibold), .secondary),
            DVText(h.headline, .system(13, .semibold), .primary, lineLimit: nil),
            DVText(h.detail, .system(11), .secondary, lineLimit: nil),
        ])
        let tint = h.tint.nsColor
        let chart: any DVNode
        switch h.chart {
        case .bars(let bars):
            chart = verticalBars(bars.map { DVKBar(label: $0.label, value: $0.value, color: tint, dimmed: !$0.highlighted,
                                                   valueLabel: $0.valueLabel) },
                                 height: DVStyle.highlightChartHeight, spacing: 4)
        case .line(let values, let first, let last):
            chart = lineChart(.sparkline(values, first: first, last: last, color: tint), height: DVStyle.highlightChartHeight + 4 + 13)
        case .share(let part, let whole, let caption):
            chart = DVVStack(spacing: 4, [
                fillBar(whole > 0 ? Double(part) / Double(whole) : 0, tint, height: 12),
                DVText(caption, .system(10), .secondary),
            ])
        case .none:
            chart = DVBox(height: 1) { _, _ in }
        }
        let row = DVHStack(spacing: 16, alignment: .center, [
            DVFrame(child: text, maxInfinity: true, hAlign: .leading),
            DVFrame(child: chart, width: DVStyle.highlightChartWidth),
        ])
        let padded = DVDecorated(child: row, insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        return DVOverlay(base: padded) { g, rect in
            // strokeBorder: a 1 pt line inside the rounded rect's edge.
            let radius = DVStyle.highlightOutlineRadius
            g.withState {
                g.ctx.setStrokeColor(DVPaint(color: .quaternaryLabelColor).cgColor)
                g.ctx.setLineWidth(1)
                g.ctx.addPath(DVShapes.rounded(rect.insetBy(dx: 0.5, dy: 0.5), radius - 0.5))
                g.ctx.strokePath()
            }
        }
    }

    /// A line chart: the spec's gridlines, areas, lines, end dots and labels.
    static func lineChart(_ spec: DVLineChartSpec, height: CGFloat) -> any DVNode {
        DVBox(height: height) { g, rect in
            let plot = spec.plot(in: rect)
            let tickFont = DVFont.mono(DVLineChartSpec.tickFontSize)
            for tick in spec.ticks {
                g.fill(spec.gridline(tick, in: plot, scale: g.scale), separator.opacity(tick == 0 ? 1 : 0.5))
                let line = DVLine.plain(spec.tickText(tick), tickFont)
                let w = line.width(scale: g.scale)
                g.draw(line, at: CGPoint(x: plot.minX - 6 - w, y: spec.y(tick, in: plot) - tickFont.lineHeight / 2),
                       width: w, paint: .secondary)
            }
            for s in spec.series where spec.areaOpacity > 0 {
                g.fillPath(spec.area(s, in: plot), DVPaint(color: s.color, opacity: spec.areaOpacity))
            }
            for s in spec.series {
                g.withState {
                    g.ctx.setStrokeColor(DVPaint(color: s.color).cgColor)
                    g.ctx.setLineWidth(spec.lineWidth)
                    g.ctx.setLineCap(.round)
                    g.ctx.setLineJoin(.round)
                    g.ctx.addPath(spec.line(s, in: plot))
                    g.ctx.strokePath()
                }
                if spec.showsEndDots, let last = s.values.last {
                    let p = CGPoint(x: spec.x(s.values.count - 1, in: plot), y: spec.y(last, in: plot))
                    g.ctx.setFillColor(DVPaint(color: s.color).cgColor)
                    g.ctx.fillEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
                }
            }
            for mark in spec.visibleMarks(plotWidth: plot.width) {
                let line = DVLine.plain(mark.text, .system(10))
                let w = line.width(scale: g.scale)
                g.draw(line, at: CGPoint(x: spec.markX(mark, width: w, in: rect, plot: plot), y: plot.maxY + DVLineChartSpec.markGap),
                       width: w, paint: .secondary)
            }
        }
    }
}

// MARK: - Wrap layout

/// Children at their natural size, flowed onto rows (a legend's items).
@MainActor
struct DVWrap: DVNode {
    let items: [any DVNode]
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    /// Never wider than its items on one line: in a card's title row a legend that took the
    /// whole offer would leave the Spacer nothing, and sit against the title.
    var sizing: DVSizing {
        let widths = items.map { $0.sizing.max == .infinity ? $0.sizing.min : $0.sizing.max }
        return DVSizing(min: 0, max: widths.reduce(0, +) + spacing * CGFloat(max(0, items.count - 1)))
    }

    private func place(_ width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for item in items {
            let w = item.sizing.max == .infinity ? item.sizing.min : item.sizing.max
            let h = item.height(w)
            if x > 0, x + w > width {
                x = 0; y += rowHeight + lineSpacing; rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: w, height: h))
            x += w + spacing
            rowHeight = max(rowHeight, h)
        }
        return (frames, items.isEmpty ? 0 : y + rowHeight)
    }

    func height(_ width: CGFloat) -> CGFloat { place(width).height }
    /// The first item's baseline, as a stack's.
    func firstBaseline(_ width: CGFloat) -> CGFloat? {
        guard let first = items.first, let f = place(width).frames.first else { return nil }
        return first.firstBaseline(f.width).map { f.minY + $0 }
    }
    func draw(_ g: DVGraphics, _ rect: CGRect) {
        guard rect.intersects(g.dirty) else { return }
        for (item, f) in zip(items, place(rect.width).frames) {
            item.draw(g, g.snap(f.offsetBy(dx: rect.minX, dy: rect.minY)))
        }
    }
}

// MARK: - Chart columns

/// The shared skeleton of the vertical charts: `count` equal columns `spacing` apart, a chart
/// area `chartHeight` tall with a 1 pt separator along its bottom, and a row of 10 pt
/// secondary labels 4 pt below it, each centered in its column.
@MainActor
struct DVColumns: DVNode {
    let count: Int
    let spacing: CGFloat
    let chartHeight: CGFloat
    let draw: (DVGraphics, Int, CGRect) -> Void
    let labels: [String]

    func height(_ width: CGFloat) -> CGFloat { chartHeight + 4 + DVFont.system(10).lineHeight }

    func draw(_ g: DVGraphics, _ rect: CGRect) {
        guard rect.intersects(g.dirty), count > 0 else { return }
        let colW = (rect.width - spacing * CGFloat(count - 1)) / CGFloat(count)
        for i in 0..<count {
            let x = rect.minX + CGFloat(i) * (colW + spacing)
            let col = g.snap(CGRect(x: x, y: rect.minY, width: colW, height: chartHeight))
            draw(g, i, col)
        }
        g.fill(g.snap(CGRect(x: rect.minX, y: rect.minY + chartHeight - 1, width: rect.width, height: 1)), DVK.separator)
        let labelY = rect.minY + chartHeight + 4
        for i in 0..<count {
            let x = rect.minX + CGFloat(i) * (colW + spacing)
            let col = g.snap(CGRect(x: x, y: labelY, width: colW, height: 13))
            let line = DVLine.plain(labels[i], .system(10))
            let w = min(col.width, line.width(scale: g.scale))
            g.draw(line, at: CGPoint(x: g.snap(col.midX - w / 2), y: col.minY), width: w, paint: .secondary, scaleToFit: 0.6)
        }
    }
}

// MARK: - Year bars

/// One bar per year across the whole span, fitted to the width at any size: no per-bar
/// labels (there can be a hundred), only the first and last years under the axis and the
/// decades between them that have room. Hovering a bar shows its year and count.
@MainActor
struct DVYearBars: DVNode {
    let values: [(year: Int, count: Int)]
    var color: NSColor = .systemBlue
    let chartHeight: CGFloat
    private static let label = DVFont.system(10)

    func height(_ width: CGFloat) -> CGFloat { chartHeight + 4 + Self.label.lineHeight }

    /// Bar `i`'s slot: equal slots tiling the width; the bar leaves a gap of a fifth of
    /// the slot (at most 2 pt, none once a slot is under 2 pt).
    private func slot(_ i: Int, _ rect: CGRect) -> CGRect {
        let w = rect.width / CGFloat(values.count)
        return CGRect(x: rect.minX + CGFloat(i) * w, y: rect.minY, width: w, height: chartHeight)
    }

    private func barRect(_ i: Int, _ rect: CGRect, peak: Int, scale: CGFloat) -> CGRect {
        let s = slot(i, rect)
        let gap = s.width < 2 ? 0 : min(2, s.width / 5)
        let n = values[i].count
        let h: CGFloat = n > 0 ? max(2, CGFloat(n) / CGFloat(max(peak, 1)) * (chartHeight - 4)) : 0
        // Snapped edge to edge so neighbors never overlap or leave a seam of uneven width.
        let x0 = (s.minX * scale).rounded() / scale, x1 = ((s.maxX - gap) * scale).rounded() / scale
        return CGRect(x: x0, y: s.maxY - h, width: max(1 / scale, x1 - x0), height: h)
    }

    func draw(_ g: DVGraphics, _ rect: CGRect) {
        guard rect.intersects(g.dirty), !values.isEmpty else { return }
        let peak = values.reduce(0) { max($0, $1.count) }
        let paint = DVPaint(color: color, opacity: DVStyle.fillOpacity)
        let radius: CGFloat = slot(0, rect).width >= 6 ? 2 : 0
        // In the PDF (vector, so a reader can zoom in) each count rides in its bar: a font
        // sized to the narrowest slot's widest count, inside the top of the bar, or just above
        // a bar too short to hold it.
        let countFont: DVFont? = g.vector ? {
            let digits = String(values.reduce(0) { max($0, $1.count) }).count
            return .mono(min(8, max(2, slot(0, rect).width * 0.8 / (0.62 * CGFloat(digits)))))
        }() : nil
        for i in values.indices where values[i].count > 0 {
            let r = barRect(i, rect, peak: peak, scale: g.scale)
            if radius > 0 { g.fillPath(DVShapes.topRounded(r, radius), paint) } else { g.fill(r, paint) }
            guard let countFont else { continue }
            let line = DVLine.plain(DVFormat.count(values[i].count), countFont)
            let w = line.width(scale: g.scale)
            let fits = r.height >= countFont.lineHeight + 2
            g.draw(line, at: CGPoint(x: r.midX - w / 2, y: fits ? r.minY + 1 : r.minY - countFont.lineHeight - 0.5),
                   width: w, paint: fits ? DVPaint(color: .white, opacity: 0.85) : .secondary)
        }
        g.fill(g.snap(CGRect(x: rect.minX, y: rect.minY + chartHeight - 1, width: rect.width, height: 1)), DVK.separator)
        // Axis years: the bookends first, then each decade that clears its neighbors by 8 pt.
        let y = rect.minY + chartHeight + 4
        var taken: [ClosedRange<CGFloat>] = []
        func place(_ i: Int, align: DVFrame.HAlign) {
            let line = DVLine.plain(String(values[i].year), Self.label)
            let w = line.width(scale: g.scale)
            let s = slot(i, rect)
            let x: CGFloat
            switch align {
            case .leading: x = rect.minX
            case .trailing: x = rect.maxX - w
            case .center: x = min(max(rect.minX, s.midX - w / 2), rect.maxX - w)
            }
            let span = (x - 8)...(x + w + 8)
            guard !taken.contains(where: { $0.overlaps(span) }) else { return }
            taken.append(x...(x + w))
            g.draw(line, at: CGPoint(x: g.snap(x), y: y), width: w, paint: .secondary)
        }
        place(0, align: .leading)
        if values.count > 1 { place(values.count - 1, align: .trailing) }
        for i in values.indices.dropFirst().dropLast() where values[i].year % 10 == 0 { place(i, align: .center) }
    }

    func hotspots(_ rect: CGRect, into: inout [DVHotspot]) {
        guard !values.isEmpty else { return }
        let values = values
        let plot = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: chartHeight)
        let peak = values.reduce(0) { max($0, $1.count) }
        let me = self
        into.append(DVHotspot(rect: plot, action: .hover { p in
            let i = min(values.count - 1, max(0, Int((p.x - plot.minX) / plot.width * CGFloat(values.count))))
            let v = values[i]
            var bar = me.barRect(i, rect, peak: peak, scale: 2)
            if bar.height == 0 { bar = CGRect(x: bar.minX, y: plot.maxY - 1, width: bar.width, height: 1) }
            return ("\(v.year): \(DVFormat.count(v.count)) film\(v.count == 1 ? "" : "s")", bar)
        }, pointer: false))
    }
}

// MARK: - Flow columns

/// Equal (or weighted, on one row) columns at `minColumnWidth`, rows balanced,
/// each child placed at the row's height when it fills (cards) or its own (tiles, attention
/// cards).
@MainActor
struct DVFlow: DVNode {
    let minColumnWidth: CGFloat
    var spacing: CGFloat = DVStyle.gap
    var maxColumns: Int = 8
    var weights: [CGFloat]? = nil
    let children: [any DVNode]
    private let memo = DVMemo<(frames: [CGRect], height: CGFloat)>()

    init(minColumnWidth: CGFloat, spacing: CGFloat = DVStyle.gap, maxColumns: Int = 8,
         weights: [CGFloat]? = nil, _ children: [any DVNode]) {
        self.minColumnWidth = minColumnWidth
        self.spacing = spacing
        self.maxColumns = maxColumns
        self.weights = weights
        self.children = children
    }

    private func columnCount(_ width: CGFloat) -> Int {
        let count = children.count
        let fit = Int(((width + spacing) / (minColumnWidth + spacing)).rounded(.down))
        let columns = max(1, min(count, maxColumns, fit))
        guard columns < count else { return columns }
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        return max(1, Int((Double(count) / Double(rows)).rounded(.up)))
    }

    private func columnWidths(_ width: CGFloat, _ columns: Int) -> [CGFloat] {
        let available = width - spacing * CGFloat(columns - 1)
        if let weights, columns == children.count, weights.count == children.count {
            let sum = weights.reduce(0, +)
            return weights.map { available * $0 / max(sum, 0.0001) }
        }
        return Array(repeating: available / CGFloat(columns), count: columns)
    }

    func frames(_ width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        memo.get(width) { computeFrames(width) }
    }

    private func computeFrames(_ width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        guard !children.isEmpty else { return ([], 0) }
        let columns = columnCount(width)
        let widths = columnWidths(width, columns)
        var frames: [CGRect] = []
        var y: CGFloat = 0
        var index = 0
        while index < children.count {
            let rowRange = index..<min(index + columns, children.count)
            let heights = rowRange.map { children[$0].height(widths[$0 - index]) }
            let rowHeight = heights.max() ?? 0
            var x: CGFloat = 0
            for i in rowRange {
                let w = widths[i - index]
                let h = children[i].fillsHeight ? rowHeight : heights[i - index]
                frames.append(CGRect(x: x, y: y, width: w, height: h))
                x += w + spacing
            }
            y += rowHeight
            index += columns
            if index < children.count { y += spacing }
        }
        return (frames, y)
    }

    func height(_ width: CGFloat) -> CGFloat { frames(width).height }

    func draw(_ g: DVGraphics, _ rect: CGRect) {
        guard rect.intersects(g.dirty) else { return }
        for (child, f) in zip(children, frames(rect.width).frames) {
            child.draw(g, g.snap(f.offsetBy(dx: rect.minX, dy: rect.minY)))
        }
    }
    func hotspots(_ rect: CGRect, into: inout [DVHotspot]) {
        for (child, f) in zip(children, frames(rect.width).frames) {
            child.hotspots(f.offsetBy(dx: rect.minX, dy: rect.minY), into: &into)
        }
    }
    func controls(_ rect: CGRect, into: inout [(any DVControl, CGRect)]) {
        for (child, f) in zip(children, frames(rect.width).frames) {
            child.controls(f.offsetBy(dx: rect.minX, dy: rect.minY), into: &into)
        }
    }
}
