// MARK: - DVComponents.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The Data Visualizations tab's shared pieces that are not drawing nodes: the style
// constants, the delta a stat tile shows, a line chart's geometry (drawn by DVK.lineChart,
// 27.44), and the SwiftUI popover a Needs Attention row opens. The page itself is drawn by
// the canvas (27.44 / 27.45), on screen and in the library PDF alike.

import SwiftUI

// MARK: - Style Constants

enum DVStyle {
    static let cardRadius: CGFloat = 8
    static let cardPadding: CGFloat = 12
    /// Gap between cards in a row and between rows of cards.
    static let gap: CGFloat = 16
    /// Gap between stat tiles, which sit tighter than cards.
    static let tileGap: CGFloat = 12
    /// Fill and track opacities of every horizontal and vertical bar — the same
    /// pairing the tab's previous PercentFillBar used, so the redesign keeps its tint.
    static let fillOpacity: CGFloat = 0.7
    static let trackOpacity: CGFloat = 0.1
    /// Narrowest a card may be laid out before its row sheds a column. Raised from 236 so
    /// a three- or four-column row drops to two columns earlier, before its cards get
    /// skinny enough to trigger their own internal layout shuffles.
    static let minCardWidth: CGFloat = 280
    /// For cards whose rows carry long labels or several fixed columns (ranked tables,
    /// source ladders, ten-bar charts): they shed a column sooner than a simple card.
    static let minTextCardWidth: CGFloat = 320
    static let minTileWidth: CGFloat = 144
    /// For a five-tile row (Library Overview, Purchases and Spending): wide enough that
    /// the row drops to two balanced rows of three before a tile's title or footnote
    /// truncates, the way the Viewing History tiles' six-across row already does at 144.
    static let minWideTileWidth: CGFloat = 190
    static let minWideCardWidth: CGFloat = 360
    /// Fixed content height for the Most Rewatched card's row list — ten compact
    /// rank rows plus their spacing — so the card's height is constant by construction
    /// regardless of the scope switch or how many rows a library actually has.
    static let mostRewatchedListHeight: CGFloat = 244

    /// The Spending Trends statements: chart column width, bar plot height, outline radius.
    static let highlightChartWidth: CGFloat = 240
    static let highlightChartHeight: CGFloat = 56
    static let highlightOutlineRadius: CGFloat = 6
}

// MARK: - Delta

/// A stat tile's change against the comparison span.
struct DVDelta: Equatable {
    enum Direction { case up, down, flat }
    let text: String
    let direction: Direction

    /// A count delta: current minus prior, "▲ 9" / "▼ 5" / "▬ 0".
    init(current: Int, prior: Int, suffix: String = "") {
        let diff = current - prior
        direction = diff > 0 ? .up : (diff < 0 ? .down : .flat)
        text = (diff > 0 ? "▲ " : (diff < 0 ? "▼ " : "▬ ")) + DVFormat.count(abs(diff)) + suffix
    }

    /// A preformatted delta, e.g. money.
    init(text: String, direction: Direction) {
        self.text = text
        self.direction = direction
    }

    static func money(current: Double, prior: Double) -> DVDelta {
        let diff = current - prior
        let dir: Direction = diff > 0.005 ? .up : (diff < -0.005 ? .down : .flat)
        let arrow = dir == .up ? "▲ " : (dir == .down ? "▼ " : "▬ ")
        return DVDelta(text: arrow + DVFormat.wholeMoney(abs(diff)), direction: dir)
    }

    static func decimal(current: Double?, prior: Double?) -> DVDelta? {
        guard let current, let prior else { return nil }
        let diff = current - prior
        let dir: Direction = diff > 0.05 ? .up : (diff < -0.05 ? .down : .flat)
        let arrow = dir == .up ? "▲ " : (dir == .down ? "▼ " : "▬ ")
        return DVDelta(text: arrow + Fmt.fixed(abs(diff), 1), direction: dir)
    }
}

// MARK: - Attention Popover

/// The popover a Needs Attention row opens: a fixed header — just the "Create New List
/// With These Items" button, centered — atop a divider, with the matching titles in a
/// scrollview below. The same fixed-header/scrolling-body composition and sizing as
/// ImportsView's per-session "Details" popover (SessionDetailsPopover); the row's own
/// label already reads as the popover's title by virtue of anchoring to it, so nothing
/// here restates it. Every row opens one, listing exactly the films its count was drawn
/// from, so no row merely displays a number with nothing behind it.
struct DVAttentionPopover: View {
    let label: String
    let items: [DVNamedFilm]
    let dismiss: () -> Void

    private static let popoverWidth: CGFloat = 300
    private static let popoverHeight: CGFloat = 400
    /// The popover's content size, for NSPopover.contentSize.
    static let size = NSSize(width: popoverWidth, height: popoverHeight)
    private static let headerHorizontalPadding: CGFloat = 10

    /// Same ordering as the gallery's title sort: article-stripped, numbers-last,
    /// `localizedStandardCompare`.
    private var sortedItems: [DVNamedFilm] {
        items.sorted(by: DVNamedFilm.compareTitles)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Fixed header: just the list-creation button, centered. Pre-fills the new
            // list's name with this row's own label, so the user can just press Return
            // to accept it or edit it first.
            Button("Create New List With These Items") {
                AppEventBus.shared.sendCommand(
                    .showListCreationFromSelection(filmIDs: Set(items.map(\.filmID)), prefillName: label))
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(items.isEmpty)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Self.headerHorizontalPadding)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, Self.headerHorizontalPadding)

            // Scrollable title list, exactly the films `count` was drawn from. A plain
            // VStack, not LazyVStack: with LazyVStack, the ScrollView cannot know the
            // list's true content height until each row has been laid out once, so it
            // estimates and corrects as rows scroll into view — visible as the scrollbar
            // (and content) subtly jumping mid-scroll, independent of frame rate. Every
            // row here is one Text at a fixed size, so eagerly laying out even the
            // largest list (low hundreds of films) is cheap, and doing so upfront gives
            // the ScrollView an exact content height from the first frame.
            if items.isEmpty {
                Text("No Items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(sortedItems.enumerated()), id: \.offset) { _, item in
                            // Name, then the release year (tertiary) and, where the list
                            // mixes purchased and unpurchased releases, "(purchased)" (secondary).
                            (Text(item.name)
                             + Text(item.year.map { " (\(String($0)))" } ?? "").foregroundStyle(.tertiary)
                             + Text(item.purchased ? " (purchased)" : "").foregroundStyle(.secondary))
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(width: Self.popoverWidth)
        .frame(height: Self.popoverHeight, alignment: .top)
    }
}

// MARK: - Highlights

extension DVHighlight.Tint {
    var nsColor: NSColor {
        switch self {
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .purple: return .systemPurple
        case .indigo: return .systemIndigo
        }
    }
}

// MARK: - Line Chart

/// A line chart's marks as numbers: where every line, area, gridline and label goes in a
/// rect. DVK.lineChart draws them; nothing here measures text or reads the appearance.
struct DVLineChartSpec {
    struct Series {
        let values: [Double]
        let color: NSColor
    }
    /// A label under the axis at a point's index. `value` orders thinning (years that are
    /// multiples of the step survive).
    struct Mark {
        let index: Int
        let value: Int
        let text: String
    }
    enum TickStyle { case count, money }

    let series: [Series]
    let marks: [Mark]
    /// Drop marks until neighbors are at least `minMarkSpacing` apart.
    var thinsMarks = true
    /// Gridlines at zero, half and the top of the scale, labeled in a gutter on the left.
    var showsGrid = true
    var tickStyle: TickStyle = .count
    /// A fixed gridline interval: the scale tops out at the next multiple above the peak and
    /// every multiple gets a gridline. Nil keeps zero / half / top.
    var tickStep: Double?
    var showsEndDots = false
    var lineWidth: CGFloat = 2
    var areaOpacity: CGFloat = 0.12

    static let markGap: CGFloat = 4
    /// A 10 pt Text's box (DVFont.system(10).lineHeight).
    static let markHeight: CGFloat = 13
    static let minMarkSpacing: CGFloat = 40
    static let tickFontSize: CGFloat = 9

    /// The Spending Trends long-term line: no grid, a light area, a dot at the end, and
    /// the first and last years under it.
    static func sparkline(_ values: [Double], first: String, last: String, color: NSColor) -> DVLineChartSpec {
        DVLineChartSpec(series: [Series(values: values, color: color)],
                        marks: [Mark(index: 0, value: 0, text: first), Mark(index: max(0, values.count - 1), value: 1, text: last)],
                        thinsMarks: false, showsGrid: false, showsEndDots: true, lineWidth: 1.5)
    }

    var pointCount: Int { series.map(\.values.count).max() ?? 0 }

    /// The scale's top: the largest value rounded up to 1, 2, 2.5 or 5 of its power of ten.
    var top: Double {
        let peak = series.flatMap(\.values).max() ?? 0
        if let step = tickStep, step > 0 { return max(1, (peak / step).rounded(.up)) * step }
        guard peak > 0 else { return 1 }
        let power = pow(10, floor(log10(peak)))
        let f = peak / power
        return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10) * power
    }

    /// Zero, the top, and half the top when that is a whole number.
    var ticks: [Double] {
        guard showsGrid else { return [] }
        if let step = tickStep, step > 0 { return Array(stride(from: 0, through: top, by: step)) }
        let half = top / 2
        return half == half.rounded() ? [0, half, top] : [0, top]
    }

    func tickText(_ value: Double) -> String {
        tickStyle == .money ? DVFormat.wholeMoney(value) : DVFormat.count(Int(value.rounded()))
    }

    /// The tick labels' column: monospaced digits, so its width follows from the longest.
    var gutter: CGFloat {
        guard showsGrid else { return 0 }
        let chars = ticks.map { tickText($0).count }.max() ?? 1
        return (CGFloat(chars) * 5.5 + 6).rounded(.up)
    }

    /// The plotting area inside the chart's rect: the gutter on the left, the marks below,
    /// headroom above for the top tick label (or the end dot).
    func plot(in rect: CGRect) -> CGRect {
        let bottom = marks.isEmpty ? 0 : Self.markGap + Self.markHeight
        let head: CGFloat = showsGrid ? 6 : 4
        let trail: CGFloat = showsEndDots ? 4 : 0
        return CGRect(x: rect.minX + gutter, y: rect.minY + head,
                      width: max(0, rect.width - gutter - trail), height: max(0, rect.height - head - bottom))
    }

    func x(_ index: Int, in plot: CGRect) -> CGFloat {
        pointCount > 1 ? plot.minX + plot.width * CGFloat(index) / CGFloat(pointCount - 1) : plot.midX
    }

    func y(_ value: Double, in plot: CGRect) -> CGFloat {
        plot.maxY - plot.height * CGFloat(max(0, value) / top)
    }

    func line(_ s: Series, in plot: CGRect) -> CGPath {
        let path = CGMutablePath()
        for (i, v) in s.values.enumerated() {
            let p = CGPoint(x: x(i, in: plot), y: y(v, in: plot))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    func area(_ s: Series, in plot: CGRect) -> CGPath {
        let path = CGMutablePath()
        guard !s.values.isEmpty else { return path }
        path.move(to: CGPoint(x: x(0, in: plot), y: plot.maxY))
        for (i, v) in s.values.enumerated() { path.addLine(to: CGPoint(x: x(i, in: plot), y: y(v, in: plot))) }
        path.addLine(to: CGPoint(x: x(s.values.count - 1, in: plot), y: plot.maxY))
        path.closeSubpath()
        return path
    }

    /// A gridline's rect: the baseline is the bar charts' 1 pt rule along the bottom; the
    /// others are 1 pt lines on their value, snapped to the pixel grid at `scale`.
    func gridline(_ tick: Double, in plot: CGRect, scale: CGFloat) -> CGRect {
        let y = tick == 0 ? plot.maxY - 1 : (self.y(tick, in: plot) * scale).rounded() / scale
        return CGRect(x: plot.minX, y: y, width: plot.width, height: 1)
    }

    /// The marks drawn at this plot width: all of them, or those whose value is a multiple
    /// of the smallest step (1, 2, 5, 10…) that spaces them `minMarkSpacing` apart.
    func visibleMarks(plotWidth: CGFloat) -> [Mark] {
        guard thinsMarks, marks.count > 1, pointCount > 1 else { return marks }
        let spacing = plotWidth * CGFloat(marks[1].index - marks[0].index) / CGFloat(pointCount - 1)
        for step in [1, 2, 5, 10, 20, 50, 100] where spacing * CGFloat(step) >= Self.minMarkSpacing {
            return marks.filter { $0.value % step == 0 }
        }
        return [marks[0]]
    }

    /// A mark's box left edge: centered on its point, kept inside the chart's rect.
    func markX(_ mark: Mark, width: CGFloat, in rect: CGRect, plot: CGRect) -> CGFloat {
        min(max(rect.minX, x(mark.index, in: plot) - width / 2), rect.maxX - width)
    }
}
