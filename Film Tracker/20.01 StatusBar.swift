// MARK: - StatusBar.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// The status bar at the foot of GalleryView. It is built from up to two rows, each a style a view can choose:
///  • CLASSIC: the live count of films (or releases) and of selected items. Most views use it alone.
///  • SUMMARY: a row of labeled figures a view supplies (StatusBarSummary), in a style it picks
///    (StatusBarSummaryStyle).
/// A view may show either row alone (one row high) or both stacked (two rows high), and the summary row is
/// always on top. The Reports Purchase Tracker tab shows both.
///
/// Everything about the bar lives in this file: its rows, metrics, chrome (background and top divider; stacked
/// rows have no divider between them), the summary contents and styles, and how much room content leaves for it.
///
/// ONE RULE, ONE CALL. `StatusBarLayout.resolve(for:showStatusBar:)` decides, for a sidebar item, whether the bar
/// shows and which rows it has. Views read it through `@CurrentStatusBar`, which observes the preference and the
/// selection, and never compute it themselves:
///  • MainView mounts `StatusBar(layout:)` when `isVisible`, and passes `height` to GalleryView, which hands it to
///    the grid, list, and Recents summary as their AppKit bottom insets. GalleryView must not resolve it itself:
///    see GalleryView.statusBarHeight.
///  • SwiftUI content (the Reports tables and lists) applies `.statusBarInset()`.
/// `height` is 0 when the bar is hidden and grows by one row per row shown, so no site counts rows itself.
///
/// CHOOSING ROWS: a view sets ViewCapabilities.statusBar (ViewState.swift) to `.classic` (the default),
/// `.summary(_:)`, or `.summaryAndClassic(_:)`.
/// ADDING A SUMMARY: add a StatusBarSummary case and give it a `style` and `items`. Every inset follows.

import SwiftUI

// MARK: - Status Bar Rows
/// One row of the bar.
enum StatusBarRow: Hashable, Sendable {
    /// The film or release count, with the selection count.
    case classic
    /// A view-supplied row of labeled figures.
    case summary(StatusBarSummary)
}

/// The rows a view asks for: ViewCapabilities.statusBar. Build it with one of the presets, so the summary row,
/// when there is one, always sits above the classic row.
struct StatusBarContent: Equatable, Sendable {
    let summary: StatusBarSummary?
    let showsClassic: Bool

    private init(summary: StatusBarSummary?, showsClassic: Bool) {
        self.summary = summary
        self.showsClassic = showsClassic
    }

    /// The count row alone: one row high.
    static let classic = StatusBarContent(summary: nil, showsClassic: true)
    /// A summary row alone: one row high.
    static func summary(_ summary: StatusBarSummary) -> StatusBarContent {
        StatusBarContent(summary: summary, showsClassic: false)
    }
    /// A summary row above the count row: two rows high.
    static func summaryAndClassic(_ summary: StatusBarSummary) -> StatusBarContent {
        StatusBarContent(summary: summary, showsClassic: true)
    }

    /// The rows top to bottom. The summary always comes first.
    var rows: [StatusBarRow] {
        var rows: [StatusBarRow] = []
        if let summary { rows.append(.summary(summary)) }
        if showsClassic { rows.append(.classic) }
        return rows
    }
}

// MARK: - Status Bar Layout
/// The bar as the selected view shows it: its rows, top to bottom, or none when hidden. Its `height` is the room
/// content must leave at the bottom.
struct StatusBarLayout: Equatable, Sendable {
    let rows: [StatusBarRow]

    /// No bar: the Show Status Bar setting is off, or the view has no gallery chrome (Imports, Insights).
    static let hidden = StatusBarLayout(rows: [])

    /// The single source of truth for the bar's presence and rows. The per-view inputs are ViewCapabilities'
    /// `showsGalleryChrome` (shared with the right sidebar) and `statusBar`.
    @MainActor
    static func resolve(for item: SidebarItem, showStatusBar: Bool) -> StatusBarLayout {
        guard showStatusBar else { return .hidden }
        let capabilities = item.capabilities
        guard capabilities.showsGalleryChrome else { return .hidden }
        return StatusBarLayout(rows: capabilities.statusBar.rows)
    }

    var isVisible: Bool { !rows.isEmpty }

    /// The bar's height, and so the bottom inset content reserves: one row height per row, 0 when hidden.
    var height: CGFloat { CGFloat(rows.count) * StatusBar.rowHeight }
}

/// The selected view's StatusBarLayout, kept current. It observes the Show Status Bar setting and the sidebar
/// selection (and, through ViewCapabilities, the Reports tab), so a view that reads it updates when any of them changes.
@MainActor
@propertyWrapper
struct CurrentStatusBar: DynamicProperty {
    @AppStorage(preference: Preferences.showStatusBarKey) private var showStatusBar: Bool
    @Environment(AppState.self) private var appState

    init() {}

    var wrappedValue: StatusBarLayout {
        StatusBarLayout.resolve(for: appState.selectedSidebarItem, showStatusBar: showStatusBar)
    }
}

// MARK: - Status Bar Summary
/// The contents of a summary row. Each case supplies its items and picks its style.
enum StatusBarSummary: Hashable, Sendable {
    /// The Purchase Tracker's Cost and Spent totals, spent-to-cost percentage, and average cost.
    case purchaseTotals

    /// How the row sets its items apart.
    var style: StatusBarSummaryStyle {
        switch self {
        case .purchaseTotals: return .chips
        }
    }

    /// The row's items, left to right.
    @MainActor
    func items(reportsState: ReportsState) -> [StatusBarItem] {
        switch self {
        case .purchaseTotals:
            let totals = reportsState.purchaseTotals
            /// "—" where there is nothing to divide, as the Cost column shows "—" for a release with no cost.
            let percent = totals.spentToCostPercent.map { Fmt.percentText($0 / 100) } ?? "—"
            let average = totals.averageCost.map(Fmt.dollars) ?? "—"
            return [StatusBarItem(label: "Total Cost", value: Fmt.dollars(totals.totalCost)),
                    StatusBarItem(label: "Total Spent", value: Fmt.dollars(totals.totalSpent)),
                    StatusBarItem(label: "Percentage Spent", value: percent),
                    StatusBarItem(label: "Average Cost", value: average)]
        }
    }
}

/// One labeled figure in a summary row, shown as "Label: value".
struct StatusBarItem: Hashable {
    let label: String
    let value: String

    var text: String { "\(label): \(value)" }
}

/// How a summary row sets its items apart. Each summary picks one (StatusBarSummary.style).
enum StatusBarSummaryStyle {
    /// Plain text joined by centered dots.
    case separated
    /// Each item on its own tight, subtle rounded fill, like the Insights tab's cards.
    case chips
}

// MARK: - Status Bar
struct StatusBar: View {
    // MARK: Metrics
    /// The height of one row. StatusBarLayout.height builds the bar's height from it; nothing else should read it.
    nonisolated static let rowHeight: CGFloat = 29

    /// A scrolling chips row's inset from the bar's edges once its chips overflow.
    fileprivate static let chipEdgeInset: CGFloat = 10
    /// The text's distance from the bar's edges.
    fileprivate static let textInset: CGFloat = 8
    /// The text font for every row.
    fileprivate static let font: Font = .caption

    /// `.separated` style: the joiner between items.
    fileprivate static let separator = "  ·  "
    /// `.chips` style: the gap between chips, each chip's padding around its text, its corner radius, and its fill.
    fileprivate static let chipSpacing: CGFloat = 10
    fileprivate static let chipPadding = EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)
    fileprivate static let chipRadius: CGFloat = 5
    fileprivate static let chipFill = Color.primary.opacity(0.06)

    /// The bar's rows. MainView mounts the bar only when it is visible, and passes its `@CurrentStatusBar` value.
    let layout: StatusBarLayout

    // MARK: - View
    /// Each row is its own view, so each observes only its own inputs: a selection click redraws the classic row, and
    /// a data reload redraws the summary row.
    var body: some View {
        VStack(spacing: 0) {
            ForEach(layout.rows, id: \.self) { row in
                StatusBarRowFrame(insetsContent: !row.scrollsHorizontally) {
                    switch row {
                    case .classic: StatusBarClassicRow()
                    case .summary(let summary): StatusBarSummaryRow(summary: summary)
                    }
                }
            } }
        .font(Self.font)
        /// One line per row, always. Text that does not fit truncates rather than wrapping out of the row.
        .lineLimit(1)
        .frame(height: layout.height)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(alignment: .top) { Divider() } }
}

private extension StatusBarRow {
    /// A chips summary row scrolls on overflow and applies its own edge inset (chipEdgeInset) inside its own scroll content, so chips
    /// scroll out to the bar's edge instead of clipping at the inset.
    var scrollsHorizontally: Bool {
        if case .summary(let summary) = self { return summary.style == .chips }
        return false
    }
}

/// One centered row. The rows split the bar's height evenly.
private struct StatusBarRowFrame<Content: View>: View {
    /// False for a row that places itself and applies its own edge inset (a scrolling chips row).
    var insetsContent = true
    @ViewBuilder let content: Content

    var body: some View {
        if insetsContent {
            HStack {
                Spacer(minLength: 0)
                content
                Spacer(minLength: 0) }
            .padding(.horizontal, StatusBar.textInset)
            .frame(maxHeight: .infinity)
        } else {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } }
}

// MARK: - Summary Row
private struct StatusBarSummaryRow: View {
    let summary: StatusBarSummary
    var reportsState = ReportsState.shared

    var body: some View {
        let items = summary.items(reportsState: reportsState)
        switch summary.style {
        case .separated:
            Text(items.map(\.text).joined(separator: StatusBar.separator))
        case .chips:
            /// Centered while the chips fit; past that, a native scroll view (see StatusBarChipScroller).
            StatusBarChipScroller(items: items)
        }
    }
}

// MARK: - Chip Scroller
/// The chips row's content at its natural width: full-width chips with chipEdgeInset on both ends.
/// It sets its own font and line limit, since an NSHostingView does not inherit the bar's environment.
private struct StatusBarChips: View {
    let items: [StatusBarItem]

    var body: some View {
        HStack(spacing: StatusBar.chipSpacing) {
            ForEach(items, id: \.label) { item in
                Text(item.text)
                    .fixedSize()
                    .padding(StatusBar.chipPadding)
                    .background(StatusBar.chipFill,
                                in: RoundedRectangle(cornerRadius: StatusBar.chipRadius, style: .continuous))
            }
        }
        .font(StatusBar.font)
        .lineLimit(1)
        .padding(.horizontal, StatusBar.chipEdgeInset)
        .frame(maxHeight: .infinity)
    }
}

/// Hosts the chips in a plain horizontal NSScrollView, for native momentum and rubber-band scrolling. A SwiftUI
/// ScrollView here scrolled with neither. The document is as wide as the chips, or the visible width if that is wider,
/// and the chips sit centered in it, so they stay centered until they overflow, then start at chipEdgeInset and
/// scroll. There is no scroller, and while the chips fit the row does not scroll or rubber-band at all.
private struct StatusBarChipScroller: NSViewRepresentable {
    let items: [StatusBarItem]

    func makeNSView(context: Context) -> ChipScrollView {
        ChipScrollView(host: NSHostingView(rootView: StatusBarChips(items: items)))
    }

    func updateNSView(_ scrollView: ChipScrollView, context: Context) {
        scrollView.host.rootView = StatusBarChips(items: items)
        scrollView.sizeDocument()
    }

    final class ChipScrollView: NSScrollView {
        let host: NSHostingView<StatusBarChips>
        /// The scrolled document. The chips are centered in it, so it can be wider than they are.
        private let document = NSView()

        init(host: NSHostingView<StatusBarChips>) {
            self.host = host
            super.init(frame: .zero)
            /// The chips' natural width (padding included) is read from the intrinsic size; sizeDocument sets every frame.
            host.sizingOptions = [.intrinsicContentSize]
            hasHorizontalScroller = false
            hasVerticalScroller = false
            borderType = .noBorder
            drawsBackground = false
            horizontalScrollElasticity = .allowed
            verticalScrollElasticity = .none
            usesPredominantAxisScrolling = true
            documentView = document
            document.addSubview(host)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func tile() {
            super.tile()
            sizeDocument()
        }

        /// Sizes the document to the chips' natural width, or the visible width if that is wider, and centers the
        /// chips in it. While they fit, scrolling and rubber-banding are off and the row is held at its origin.
        func sizeDocument() {
            let visible = contentView.bounds.size
            let chipsWidth = host.intrinsicContentSize.width.rounded(.up)
            let fits = chipsWidth <= visible.width
            let documentFrame = NSRect(x: 0, y: 0, width: max(chipsWidth, visible.width), height: visible.height)
            let chipsFrame = NSRect(x: ((documentFrame.width - chipsWidth) / 2).rounded(.down), y: 0,
                                    width: chipsWidth, height: visible.height)
            if document.frame != documentFrame { document.frame = documentFrame }
            if host.frame != chipsFrame { host.frame = chipsFrame }
            let elasticity: NSScrollView.Elasticity = fits ? .none : .allowed
            if horizontalScrollElasticity != elasticity { horizontalScrollElasticity = elasticity }
            if fits, contentView.bounds.origin != .zero {
                contentView.scroll(to: .zero)
                reflectScrolledClipView(contentView)
            }
        }
    }
}

// MARK: - Classic Row
/// The count and selection. Derived inline rather than cached in @State, since a cache would add a body pass per change.
/// MainView mounts the bar only while it is visible, so a hidden bar does not exist to read these inputs.
private struct StatusBarClassicRow: View {
    @Environment(AppState.self) private var appState
    @Environment(SelectionState.self) private var selectionState
    @Environment(DataCoordinator.self) private var dataCoordinator
    var reportsState = ReportsState.shared

    var body: some View {
        Text(text)
    }

    private var text: String {
        let isReportsView = appState.selectedSidebarItem == .libraryItem(.reports)
        let total = isReportsView ? reportsState.visibleItemCount : dataCoordinator.filmCount
        let selected = selectionState.selectedFilmIDs.count

        /// The Hall of Fame tab lists films, so it uses the film label. The Purchase Tracker, Price Tracker, and
        /// Release Wishlist tabs list releases. The tab is the displayed one, which visibleItemCount follows, so the
        /// label and count change together. The selected tab leads it by two run-loop cycles on a picker switch.
        let listsReleases = isReportsView && reportsState.displayedCategory != .hallOfFame
        let label = Fmt.noun(total, listsReleases ? "release" : "film")

        switch selected {
        case 0: return "\(Fmt.count(total)) \(label)"
        default: return "\(Fmt.count(selected)) of \(Fmt.count(total)) \(label)" }
    }
}

// MARK: - Status Bar Inset
/// Applies a `.safeAreaInset(edge: .bottom)` spacer, so SwiftUI content does not scroll under the StatusBar. The
/// spacer is the selected view's bar height: none when hidden, otherwise one row height per row.
struct StatusBarInset: ViewModifier {
    @CurrentStatusBar private var statusBar

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                /// 0 high when the bar is hidden.
                Color.clear.frame(height: statusBar.height)
            }
    }
}

extension View {
    /// Reserves space at the bottom for the StatusBar when it is visible.
    func statusBarInset() -> some View {
        modifier(StatusBarInset())
    }
}
