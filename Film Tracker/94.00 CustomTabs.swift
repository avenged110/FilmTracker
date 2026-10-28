// MARK: - CustomTabs.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Reusable custom tab header component for SwiftUI sheets and views.

import SwiftUI

// MARK: - Tab Protocol
// Protocol that any tab enum must conform to for use with CustomTabHeader.
protocol CustomTab: CaseIterable, Identifiable, Hashable, Sendable {
    var id: String { get }
    var displayName: String { get }
    var iconName: String { get }
}

// MARK: - Custom Tab Header View
struct CustomTabHeader<Tab: CustomTab>: View {
    let selectedTab: Tab
    let enabled: Bool
    let showIcons: Bool
    let onTabSelect: (Tab) -> Void
    /// Individual tabs that should be disabled regardless of `enabled`.
    /// Only meaningful when `enabled` is true; when `enabled` is false, all tabs
    /// are already disabled and this set is ignored.
    let disabledTabs: Set<Tab>

    init(selectedTab: Tab, enabled: Bool = true, showIcons: Bool = true,
         disabledTabs: Set<Tab> = [],
         onTabSelect: @escaping (Tab) -> Void) {
        self.selectedTab = selectedTab
        self.enabled = enabled
        self.showIcons = showIcons
        self.disabledTabs = disabledTabs
        self.onTabSelect = onTabSelect
    }

    var body: some View {
        // Compared by value, closure excluded: see `TabHeaderContent`.
        let content = TabHeaderContent(selectedTab: selectedTab, enabled: enabled, showIcons: showIcons,
                                       disabledTabs: disabledTabs, onTabSelect: onTabSelect)
        if RSBProfileFlags.tabBarNoEquatable {
            content
        } else {
            content.equatable()
        }
    }
}

// MARK: - Tab Header Content
/// The header's actual layout, equatable on everything except `onTabSelect`.
///
/// Every caller passes a fresh closure on each body pass, and SwiftUI cannot compare
/// closures, so without this the whole header was re-diffed whenever its parent updated
/// (for RightSidebar, on every film change) even though nothing it draws had changed.
/// Ignoring the closure is safe because every caller's closure only forwards to a
/// reference with a stable identity (a coordinator, sheet owner, or view-state manager),
/// so a retained older closure behaves exactly like the newest one.
private struct TabHeaderContent<Tab: CustomTab>: View, Equatable {
    // Nonisolated so the nonisolated `==` SwiftUI calls can read them.
    nonisolated let selectedTab: Tab
    nonisolated let enabled: Bool
    nonisolated let showIcons: Bool
    nonisolated let disabledTabs: Set<Tab>
    let onTabSelect: (Tab) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectedTab == rhs.selectedTab && lhs.enabled == rhs.enabled
            && lhs.showIcons == rhs.showIcons && lhs.disabledTabs == rhs.disabledTabs
    }

    var body: some View {
        // Enumerate Tab.allCases into a single Array once per body evaluation.
        // This is the only allocation needed: it provides stable indices for the
        // O(1) divider-visibility check and drives the ForEach, with no second
        // intermediate array required.
        let tabs = Array(Tab.allCases.enumerated())
        let lastIndex = tabs.count - 1

        // Pre-compute selected index once so divider visibility is a simple integer
        // comparison rather than two O(n) firstIndex(of:) searches per divider.
        let selectedIndex = tabs.firstIndex(where: { $0.element == selectedTab })

        HStack(spacing: 0) {
            ForEach(tabs, id: \.element.id) { index, tab in
                // A tab is enabled only when the header is globally enabled AND the
                // tab is not individually disabled.
                let tabEnabled = enabled && !disabledTabs.contains(tab)
                CustomTabButton(
                    tab: tab,
                    isSelected: tab == selectedTab,
                    enabled: tabEnabled,
                    showIcon: showIcons,
                    onSelect: { onTabSelect(tab) }
                )
                .frame(maxWidth: .infinity)

                // Vertical dividers between tabs; hidden when adjacent to the selected tab.
                if index < lastIndex {
                    // Divider is visible unless it directly borders the selected tab.
                    // Using a conditional branch rather than opacity(0) eliminates the
                    // transparent-layer compositor pass for every hidden divider.
                    let dividerVisible: Bool = {
                        guard enabled, let si = selectedIndex else { return false }
                        return index != si && index != si - 1
                    }()
                    VerticalDivider(isVisible: dividerVisible)
                }
            }
        }
        .frame(height: 28)
    }
}

// MARK: - Custom Tab Button
private struct CustomTabButton<Tab: CustomTab>: View {
    let tab: Tab
    let isSelected: Bool
    let enabled: Bool
    let showIcon: Bool
    let onSelect: () -> Void

    var body: some View {
        // `.disabled(!enabled)` already prevents this action from firing when
        // the header is disabled; the guard inside the closure is redundant.
        Button(action: onSelect) {
            // Both branches share identical layout modifiers (.frame, .contentShape)
            // and the same foreground color expression. These are factored out to
            // the Group level to eliminate duplication and reduce the view node count.
            // The icon branch adds no horizontal padding (content fills the cell
            // naturally); the text-only branch retains its .padding(.horizontal, 8).
            Group {
                if showIcon && Preferences.showCustomTabIcons && !tab.iconName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 11))
                        Text(tab.displayName)
                            .font(.system(size: 13))
                            .fontWeight(.medium)
                    }
                } else {
                    Text(tab.displayName)
                        .font(.system(size: 13))
                        .fontWeight(.medium)
                        .padding(.horizontal, 8)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(CustomTabButtonStyle(isSelected: isSelected))
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.45)
        // Exclude tab-header buttons from the Tab-key focus ring. Tab switching is
        // a pointer / keyboard-shortcut operation (Cmd+1–5); including these buttons
        // in Tab traversal inserts five invisible stops before the first card field,
        // forcing the user to press Tab five times before reaching any form control.
        .focusable(false)
    }
}

// MARK: - Custom Button Style
private struct CustomTabButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            // Selected tab accent highlight.
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
            }

            // Press overlay: active for the full click-hold duration, dismissed
            // as soon as the cursor leaves the hit-target.
            if configuration.isPressed {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.12))
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
            }

            configuration.label
        }
    }
}

// MARK: - Vertical Tab Button Divider
private struct VerticalDivider: View {
    let isVisible: Bool

    var body: some View {
        // When not visible, render Color.clear instead of a transparent Rectangle.
        // This eliminates the compositor pass for the separator layer entirely,
        // whereas opacity(0) keeps the draw call but makes the result invisible.
        if isVisible {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .padding(.vertical, 6)
        } else {
            Color.clear
                .frame(width: 1)
        }
    }
}
