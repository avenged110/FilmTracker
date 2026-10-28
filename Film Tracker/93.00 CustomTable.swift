// MARK: - CustomTable.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// A custom table that mimics the macOS-standard table appearance, but
// provides more flexibility for content presentation.

import SwiftUI

// MARK: - Animated Expansion Opt-In

private struct CustomTableAnimatesExpansionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// When true, "Show All" flips `isExpanded` without suppressing animation, so an
    /// ancestor's `.animation(_:value:)` keyed to the expansion state animates it. Set only
    /// by the right sidebar's Details tab (RTabDetails), which owns that animation and the
    /// layout that keeps it from jumping; every other table expands in one step as before.
    var customTableAnimatesExpansion: Bool {
        get { self[CustomTableAnimatesExpansionKey.self] }
        set { self[CustomTableAnimatesExpansionKey.self] = newValue }
    }
}

struct CustomTable<Data: RandomAccessCollection,
    Content: View>: View where Data.Element: Identifiable {
    let data: Data
    let columns: [CustomTableColumn]
    let content: (Data.Element) -> Content
    let showHeader: Bool
    let allowHorizontalScroll: Bool
    let allowSelection: Bool
    let contentPadding: CGFloat
    /// Optional explicit leading/trailing insets for the header row, overriding the
    /// computed ones below. The computed values exist to reconcile the three
    /// horizontal-scroll layout paths against one another; a caller that turns
    /// horizontal scrolling off but still wants the header to line up with the
    /// scrolling layout's geometry (DiscReleasesTable's `.releaseCard` mode) has no
    /// way to express that through `contentPadding`, which reaches the data rows only.
    /// Nil everywhere else, and therefore a no-op.
    let headerLeadingPadding: CGFloat?
    let headerTrailingPadding: CGFloat?
    let onRowTap: ((Data.Element.ID) -> Void)?
    @Binding var isExpanded: Bool
    /// Nil for a table without selection. Held as a plain optional rather than an
    /// `@Binding` with a `.constant(nil)` default: SwiftUI reports a binding input as
    /// changed on every re-init — a shared constant included — so every time a parent
    /// re-ran its body this table re-ran its own with identical data, three times per
    /// mount in the right sidebar. `selectedIDValue` carries the selection as a plain
    /// value instead, which is what makes a real selection change re-render the table.
    private let selectedIDBinding: Binding<Data.Element.ID?>?
    private let selectedIDValue: Data.Element.ID?
    private var selectedID: Data.Element.ID? {
        get { selectedIDBinding?.wrappedValue }
        nonmutating set { selectedIDBinding?.wrappedValue = newValue } }
    @State private var fadeOut = false
    // Ambient registrar (non-nil only inside RightSidebar) used to exclude this
    // table's on-screen area from the sidebar's tab-swipe hit testing while its
    // horizontal scroll is actually active, driven by `.onHover` below. Always
    // nil, and therefore a no-op, everywhere else CustomTable is used.
    @Environment(\.horizontalScrollZoneRegistrar) private var horizontalScrollZoneRegistrar
    @Environment(\.customTableAnimatesExpansion) private var animatesExpansion
    // Stable identity for this table instance's zone registration; a plain
    // per-instance constant is sufficient since CustomTable never needs more than
    // one zone of its own.
    @State private var horizontalScrollZoneID = UUID()
    /// Drives the animated clipping region for the data rows. Separated from
    /// `tableHeight` so the outer frame (which NSHostingView reports to Auto
    /// Layout) can jump to its final value instantly while the visible content
    /// reveals smoothly via animation. This decoupling prevents the "expand
    /// upward" artifact that occurs when the outer frame animates inside an
    /// NSHostingView, because the parent VStack allocates the full expanded
    /// height in one layout pass rather than interpolating it frame-by-frame.
    ///
    /// NOTE: clipHeight is intentionally never set to a non-nil value during
    /// expansion. In NSScrollView-hosted contexts the animated clip reveal
    /// produced a gap (space reserved, rows filling it slowly); suppressing it
    /// means the rows become visible in the same single frame that tableHeight
    /// jumps, matching the RSB single-frame behavior. The variable is kept so
    /// the collapse reset path (onChange) compiles unchanged.
    @State private var clipHeight: CGFloat?

    init(
        _ data: Data,
        columns: [CustomTableColumn],
        isExpanded: Binding<Bool>,
        selectedID: Binding<Data.Element.ID?>? = nil,
        showHeader: Bool = true,
        allowHorizontalScroll: Bool = false,
        allowSelection: Bool = false,
        contentPadding: CGFloat = 10,
        headerLeadingPadding: CGFloat? = nil,
        headerTrailingPadding: CGFloat? = nil,
        onRowTap: ((Data.Element.ID) -> Void)? = nil,
        @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.columns = columns
        self._isExpanded = isExpanded
        self.selectedIDBinding = selectedID
        self.selectedIDValue = selectedID?.wrappedValue
        self.showHeader = showHeader
        self.allowHorizontalScroll = allowHorizontalScroll
        self.allowSelection = allowSelection
        self.contentPadding = contentPadding
        self.headerLeadingPadding = headerLeadingPadding
        self.headerTrailingPadding = headerTrailingPadding
        self.onRowTap = onRowTap
        self.content = content }

    private let collapsedRowCount = 6
    private let rowHeight: CGFloat = 22
    // Header + divider height (if enabled).
    private let baseHeaderHeight: CGFloat = 24

    // Alternating row color (matches macOS-standard table style).
    private var alternatingRowColor: Color {
        Color(nsColor: NSColor.unemphasizedSelectedContentBackgroundColor).opacity(0.3) }

    // Selection highlight color (system accent color).
    private var selectionColor: Color {
        Color(nsColor: NSColor.selectedContentBackgroundColor) }

    private var shouldShowExpandButton: Bool { data.count > collapsedRowCount }

    // Adjust effective header height based on showHeader flag.
    private var headerHeight: CGFloat { showHeader ? baseHeaderHeight : 0 }

    // Calculate the actual table height based on content and expansion state.
    private var tableHeight: CGFloat {
        if shouldShowExpandButton {
            // Table overflows (more than 6 rows).
            if isExpanded {
                // When expanded, show all rows (minimum 6.5 rows) + 12 for bottom padding.
                return headerHeight + max(CGFloat(data.count), 6.5) * rowHeight + 12
            } else {
                // When collapsed, show 6.5 rows.
                return headerHeight + (6.5 * rowHeight)
            }
        } else {
            // Table doesn't overflow (6 or fewer rows) - always show 6.5 rows.
            return headerHeight + (6.5 * rowHeight) } }

    // Determine whether or not horizontal scrolling should be active.
    private var enableHorizontalScroll: Bool {
        guard allowHorizontalScroll else { return false }
        return data.count <= collapsedRowCount || isExpanded }

    // When the table is not wrapped in a horizontal ScrollView, macOS shifts
    // content 1 pt to the left compared to the ScrollView-wrapped layout.
    // This offset compensates for that platform-level discrepancy.
    private var scrollCompensation: CGFloat { allowHorizontalScroll ? 0 : 2 }

    // The scroll-disabled ScrollView used for collapsed overflowing tables introduces
    // a leading offset relative to the active-scroll path. This compensation applies
    // exclusively to that state and must be added to all content leading padding
    // in that path to realign rows with the expanded (active-scroll) layout.
    // Tied to contentPadding so customized call sites remain aligned automatically.
    private var collapsedScrollOffset: CGFloat { (allowHorizontalScroll && !enableHorizontalScroll) ? contentPadding : 0 }

    var body: some View {
        ZStack(alignment: .top) {
            contentContainer
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                // Applied to the clipped content rather than the outer frame: the visible
                // plate runs past `tableHeight` (collapsed, 7 rows sit in a 6.5-row frame),
                // so chrome sized to the frame had its bottom edge covered by the overflow.
                .sidebarFieldEdgeChrome()
            // Gradient overlay and "Show All" button.
            if shouldShowExpandButton && !isExpanded {
                ZStack(alignment: .bottom) {
                    // Shadow gradient covers bottom half of visible row area.
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(nsColor: .controlBackgroundColor).opacity(0.00),
                            Color(nsColor: .controlBackgroundColor).opacity(0.40),
                            Color(nsColor: .controlBackgroundColor).opacity(0.70),
                            Color(nsColor: .controlBackgroundColor).opacity(0.85),
                            Color(nsColor: .controlBackgroundColor).opacity(1.00) ]),
                        startPoint: .top,
                        endPoint: .bottom)
                    .frame(height: (6.5 * rowHeight) / 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .opacity(fadeOut ? 0 : 1)
                    .animation(.easeInOut(duration: 0.15), value: fadeOut)
                    .allowsHitTesting(false)

                    Spacer()

                    // Standard macOS button with rounded corners.
                    Button(action: {
                        // 1. Fade both elements.
                        withAnimation(.easeInOut(duration: 0.12)) { fadeOut = true }
                        // 2. Expand table after fade completes.
                        // Task { @MainActor in } is the Swift-concurrency-correct
                        // replacement for DispatchQueue.main.asyncAfter. It enters
                        // MainActor isolation without a GCD hop, satisfying Xcode 16
                        // strict concurrency checking while preserving the identical
                        // 0.1-second delay needed for the fade animation to settle
                        // before the frame jump occurs.
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(0.1))
                            // Flip isExpanded WITHOUT animation so the outer
                            // .frame(height: tableHeight) jumps to its final value
                            // instantly. NSHostingView reports the full expanded
                            // height to Auto Layout in one pass, and the parent
                            // container allocates space immediately — no frame-by-frame
                            // interpolation that NSScrollView could misinterpret.
                            // The rows become visible in the same frame (clipHeight
                            // is never set, so no animated reveal gap is produced).
                            //
                            // Unless an ancestor has opted in to animating it (see
                            // `customTableAnimatesExpansion`): then the flip is plain, and
                            // that ancestor's `.animation(_:value:)` supplies the animation.
                            if animatesExpansion {
                                isExpanded = true
                            } else {
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) { isExpanded = true }
                            }
                        } }) {
                        Text("Show All")
                            .font(.system(size: 11))
                            .frame(width: 90, height: 18) }
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .padding(.bottom, 6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .opacity(fadeOut ? 0 : 1)
                    .animation(.easeInOut(duration: 0.1), value: fadeOut) } } }
        .frame(height: tableHeight, alignment: .top)
        // Reset fade and clip state when the table collapses again.
        .onChange(of: isExpanded) { _, newValue in
            if newValue == false {
                fadeOut = false
                clipHeight = nil
            } } }

    // MARK: - Content Container
    // A single unified layout for all modes. The inner content (header + divider +
    // rows) is built once via tableContent and then optionally wrapped in a ScrollView.
    @ViewBuilder
    private var contentContainer: some View {
        if enableHorizontalScroll {
            // Expanded: full horizontal scrolling active. While the cursor is over
            // this ScrollView, register it as a swipe-exclusion zone (see
            // HorizontalScrollZoneRegistrar) so RightSidebar's tab-swipe monitor
            // lets horizontal-dominant gestures here reach this ScrollView instead
            // of switching tabs. onDisappear guards against this table being
            // removed (collapse, film change) while still marked hovered; a tab
            // switch usually leaves it mounted, so RightSidebar clears the
            // registrar itself on every switch.
            ScrollView(.horizontal, showsIndicators: true) { tableContent }
                .frame(maxWidth: .infinity)
                .onHover { hovering in
                    horizontalScrollZoneRegistrar?.setActive(horizontalScrollZoneID, active: hovering)
                }
                .onDisappear {
                    horizontalScrollZoneRegistrar?.setActive(horizontalScrollZoneID, active: false)
                }
        } else if allowHorizontalScroll {
            // Collapsed: wide content must stay clipped within table bounds.
            // A scroll-disabled ScrollView constrains children to its viewport.
            ScrollView(.horizontal, showsIndicators: false) { tableContent }
                .scrollDisabled(true)
                .frame(maxWidth: .infinity)
        } else {
            // No horizontal scrolling — identical inner structure, no wrapper.
            tableContent
                .frame(maxWidth: .infinity) } }

    // MARK: - Table Content
    // The single source of truth for the table's inner view hierarchy.
    // Every code path (scroll-enabled, scroll-disabled, and no-scroll) uses
    // this exact same structure so the content's coordinate space is consistent.
    private var tableContent: some View {
        VStack(spacing: 0) {
            if showHeader {
                headerRow
                Divider() }
            dataRows } }

    // MARK: - Header Row
    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                Group {
                    if let symbolName = column.systemImage {
                        Image(systemName: symbolName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    } else {
                        Text(column.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                }
                .frame(minWidth: column.minWidth, maxWidth: column.maxWidth ?? .infinity,
                    alignment: column.alignment)
                .padding(.horizontal, column.cellPadding)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .allowsHitTesting(false) } }
        .padding(.leading, headerLeadingPadding
            ?? (enableHorizontalScroll ? 10 : scrollCompensation + collapsedScrollOffset))
        .padding(.trailing, headerTrailingPadding
            ?? (enableHorizontalScroll ? 10 : 0))
        .background(Color(nsColor: .controlBackgroundColor)) }

    // MARK: - Data Rows
    // While collapsed, the clip shows 6.5 rows, so only the first 7 can ever be on
    // screen; building the rest (a long viewing history runs to hundreds) cost a
    // full second render of the sidebar on every selection. Expanding swaps in the
    // whole collection; the prefix keeps its rows' identities, so they carry over.
    private var renderedRows: Data.SubSequence {
        shouldShowExpandButton && !isExpanded
            ? data.prefix(collapsedRowCount + 1)
            : data[...] }

    private var dataRows: some View {
        LazyVStack(spacing: 0, pinnedViews: []) {
            if data.isEmpty {
                placeholderRow
                ForEach(1..<7, id: \.self) { index in
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: rowHeight)
                        .background(rowBackground(for: index)) }
            } else {
                ForEach(Array(renderedRows.enumerated()), id: \.element.id) { index, item in
                    // Use Color.clear as the layout base — identical to filler rows — so the
                    // row's frame is always determined purely by .frame(maxWidth: .infinity)
                    // rather than by the HStack's natural content width. Content is rendered
                    // via .overlay so it doesn't participate in frame measurement.
                    Group {
                        if allowSelection {
                            // contentShape + onTapGesture install a row-wide gesture
                            // recognizer. That recognizer claims the row's hit-testing
                            // region for itself, which silently swallows the hover
                            // events that nested cells rely on for their .help()
                            // tooltips (e.g. Notes / Versions Included in ReleasesTable).
                            // Selection-driven tables need the gesture, so it's only
                            // attached here — non-selecting tables skip it entirely,
                            // leaving hover free to reach inner tooltip overlays.
                            rowBase(index: index, item: item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    // Allow selection when expanded or when expansion isn't needed.
                                    if isExpanded || !shouldShowExpandButton {
                                        // Toggle selection: deselect if already selected, select otherwise.
                                        if selectedID == item.id {
                                            selectedID = nil
                                        } else {
                                            selectedID = item.id
                                            onRowTap?(item.id) } } }
                        } else {
                            rowBase(index: index, item: item)
                        }
                    } }

                if data.count < 7 {
                    ForEach(data.count..<7, id: \.self) { index in
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: rowHeight)
                            .background(rowBackground(for: index)) } }

                // Add 12pt padding only when expanded and table has >6 rows.
                if shouldShowExpandButton && isExpanded {
                    Spacer(minLength: 12) } } }
        .frame(
            height: clipHeight ?? (isExpanded && shouldShowExpandButton
                ? max(CGFloat(data.count), 6.5) * rowHeight + 12
                : 6.5 * rowHeight),
            alignment: .top)
        .clipped()
        .allowsHitTesting(true) }

    // MARK: - Row Base
    // Shared visual structure for a single data row: a Color.clear layout base
    // (so the row's width always tracks .frame(maxWidth: .infinity) rather than
    // the HStack's natural content width) with the row's actual content rendered
    // via .overlay so it doesn't participate in frame measurement. Deliberately
    // carries no gesture or contentShape of its own — that is layered on by the
    // caller only when allowSelection is true, keeping non-selecting tables free
    // of any row-wide hit-testing claim that would block nested tooltip hover.
    @ViewBuilder
    private func rowBase(index: Int, item: Data.Element) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: rowHeight)
            .background(rowBackground(for: index, itemID: item.id))
            .overlay(
                HStack(spacing: 0) { content(item) }
                    .padding(.leading, contentPadding + scrollCompensation + collapsedScrollOffset)
                    .padding(.trailing, contentPadding))
    }

    // MARK: - Placeholder Row
    private var placeholderRow: some View {
        HStack(spacing: 0) {
            Text("None")
                .font(.system(size: 12))
                .italic()
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 2) }
        // Always apply extra horizontal padding to match content positioning in all scenarios.
        .padding(.leading, contentPadding + scrollCompensation + collapsedScrollOffset)
        .padding(.trailing, contentPadding)
        .frame(maxWidth: .infinity)
        .frame(height: rowHeight)
        .background(rowBackground(for: 0)) }

    // MARK: - Row Backgrounds
    @ViewBuilder
    private func rowBackground(for index: Int, itemID: Data.Element.ID? = nil) -> some View {
        ZStack {
            // Alternating row color.
            if index % 2 != 0 {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(alternatingRowColor)
                    .padding(.horizontal, 10) }

            // Selection highlight (only when selection is enabled and row is selected).
            if allowSelection, let itemID = itemID, itemID == selectedIDValue {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selectionColor)
                    .padding(.horizontal, 10) } } }
}

// MARK: - Column and Cell Definitions
struct CustomTableColumn: Identifiable {
    // Stable identity derived from column definition so ForEach doesn't treat
    // columns as new on every render when the column list is rebuilt in body.
    let id: String
    let title: String
    let systemImage: String?   // Optional SF Symbol name for the header
    let minWidth: CGFloat?
    let maxWidth: CGFloat?
    let alignment: Alignment
    let cellPadding: CGFloat   // Horizontal padding applied to both header and data cells

    init(_ title: String, systemImage: String? = nil, minWidth: CGFloat? = nil,
        maxWidth: CGFloat? = nil, alignment: Alignment = .leading, cellPadding: CGFloat = 8) {
        self.title = title
        self.systemImage = systemImage
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.alignment = alignment
        self.cellPadding = cellPadding
        // Stable ID: combines all defining properties so two logically identical
        // columns always produce the same ID, preventing unnecessary ForEach diffs.
        self.id = "\(title)|\(systemImage ?? "")|\(minWidth ?? 0)|\(maxWidth ?? 0)|\(cellPadding)|\(alignment)"
    }
}

// MARK: - CustomTableCell
// Generic over its content type to avoid AnyView type erasure, preserving
// SwiftUI's structural identity for efficient diffing and eliminating the
// per-cell heap allocation that AnyView would otherwise require.
//
// Both initializers resolve Content == Text, which covers all current call sites:
// plain strings (wrapped automatically) and styled Text values (italic, secondary
// color, etc. — Text modifiers always return Text, not an opaque view type).
//
// `tooltip`: when non-empty, a native macOS hover tooltip is shown via .help().
// Pass the full untruncated string at call sites where the fixed cell width may
// clip content. An empty string (the default) suppresses the tooltip entirely,
// so all existing call sites remain unaffected without any modification.
struct CustomTableCell: View {
    let content: Text
    let minWidth: CGFloat?
    let maxWidth: CGFloat?
    let alignment: Alignment
    let cellPadding: CGFloat
    let tooltip: String

    // String convenience initializer — wraps the string in a plain Text.
    init(_ text: String, minWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
        alignment: Alignment = .leading, cellPadding: CGFloat = 8, tooltip: String = "") {
        self.content = Text(text)
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.alignment = alignment
        self.cellPadding = cellPadding
        self.tooltip = tooltip }

    // Text initializer — accepts pre-styled Text values (italic, foregroundStyle, etc.).
    // Text modifiers such as .italic(), .bold(), and .foregroundStyle(_:) all return
    // Text, so this init covers any chain of Text-only modifiers without type erasure.
    init(_ text: Text, minWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
        alignment: Alignment = .leading, cellPadding: CGFloat = 8, tooltip: String = "") {
        self.content = text
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.alignment = alignment
        self.cellPadding = cellPadding
        self.tooltip = tooltip }

    var body: some View {
        // The Text itself remains non-interactive (.allowsHitTesting(false)) so it
        // does not consume row tap gestures. When a tooltip is requested, a
        // Color.clear overlay — which does receive hover events — carries .help()
        // on top of the text. Without this layer the tooltip modifier is unreachable
        // because the disabled hit-testing on Text prevents hover delivery entirely.
        let textView = content
            .allowsHitTesting(false)
            .font(.system(size: 12))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: minWidth, maxWidth: maxWidth ?? .infinity, alignment: alignment)
            .padding(.horizontal, cellPadding)
            .padding(.vertical, 2)

        if tooltip.isEmpty {
            textView
        } else {
            textView.overlay(
                Color.clear
                    .contentShape(Rectangle())
                    .help(tooltip)
            )
        }
    }
}
