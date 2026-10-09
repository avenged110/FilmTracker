// MARK: - SettingsSheet.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// SwiftUI-based settings sheet coordinator for FilmTracker.app

import SwiftUI
import SwiftData
import Combine

struct SettingsSheet: View, Loggable {
    nonisolated static let logTag = "[SettingsSheet]"
    
    @Environment(AppState.self) private var appState
    @Environment(SheetCoordinator.self) private var sheetCoordinator
    @Environment(DataCoordinator.self) private var dataCoordinator
    /// The tab to select when the sheet first appears. Read once in onAppear; all
    /// subsequent tab navigation is driven by SettingsCoordinator.
    let initialTab: SettingsTab
    /// When true, the sheet opens on the Restore tab and the tab bar + Close button
    /// are disabled until the sheet is dismissed — used by the database-error recovery
    /// flow so the user cannot navigate away before addressing the restore decision.
    var lockedToRestore: Bool = false
    /// A backup file URL to load automatically when the sheet appears on the Restore tab.
    /// Set by the Finder double-click / "Open Settings" flow so the file is pre-loaded
    /// and the user only needs to confirm via "Restore Database".
    var backupURL: URL? = nil
    @State private var coordinator = SettingsCoordinator()
    @State private var hostingWindow: NSWindow?
    @State private var returnKeyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            // Custom titlebar.
            ZStack {
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10) }
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(Divider(), alignment: .bottom)

            // Custom tab header.
            tabsHeader
                .padding(.horizontal, 4)
                .padding(.top, -1)
                .padding(.bottom, 1)
                .background(Color(nsColor: .windowBackgroundColor))
                .focusEffectDisabled()
                .overlay(Divider(), alignment: .bottom)
                .zIndex(1)

            // Tab view content - using lazy evaluation with view identity.
            // The if statements ensure only the selected view is in the hierarchy and the
            // .id() modifier gives each view a stable identity so SwiftUI can cache them.
            //
            // Each branch is wrapped in SettingsFocusSinkWrapper (SettingsKit), which puts
            // a zero-height SettingsFocusSink ahead of the tab content. The sink absorbs
            // AppKit's automatic first-responder assignment, which matters here beyond the
            // focus ring: with a real control focused, Return would activate that control
            // instead of reaching the sheet's window-level Return monitor. Because each
            // branch is a distinct structural identity, switching tabs builds a fresh sink
            // that claims focus for the new tab.
            ZStack {
                if coordinator.selectedTab == .general {
                    SettingsFocusSinkWrapper {
                        DataCoordinatorScrollView {
                            GeneralSettingsView()
                                .id(SettingsTab.general)
                                .padding(26) } } }
                if coordinator.selectedTab == .import_ {
                    SettingsFocusSinkWrapper {
                        ImportSettingsView()
                            .id(SettingsTab.import_)
                            .padding(10) } }
                if coordinator.selectedTab == .export {
                    SettingsFocusSinkWrapper {
                        ExportSettingsView(viewModel: coordinator.exportViewModel)
                            .id(SettingsTab.export)
                            .padding(10) } }
                if coordinator.selectedTab == .restore {
                    SettingsFocusSinkWrapper {
                        RestoreSettingsView(viewModel: coordinator.restoreViewModel)
                            .id(SettingsTab.restore)
                            .padding(10) } }
                if coordinator.selectedTab == .advanced {
                    SettingsFocusSinkWrapper {
                        DataCoordinatorScrollView {
                            AdvancedSettingsView()
                                .id(SettingsTab.advanced)
                                .padding(26) } } } }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Bottom section with close button.
            //
            // Right-aligned in the button gutter.
            HStack {
                Spacer()
                Button {
                    // Dismiss the sheet through coordinator
                    sheetCoordinator.dismissSheet()
                } label: {
                    Text("Close")
                        .padding(4)
                        .font(.system(size: 12))
                }
                .disabled(coordinator.isSheetDismissBlocked)
                // Attach the Escape keyboard shortcut only when the sheet is not blocked.
                // When blocked, .onKeyPress(.escape) already returns .handled to consume
                // the event — removing the shortcut here closes any residual shortcut-
                // activation path as a belt-and-suspenders guard.
                .keyboardShortcut(coordinator.isSheetDismissBlocked ? nil : .cancelAction)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: Preferences.sheetSize, height: Preferences.sheetSize)
        .onKeyPress(.escape) {
            // Block Esc key if the sheet is dismiss-blocked (blocking operation in
            // progress, or locked to the Restore tab for database-error recovery).
            if coordinator.isSheetDismissBlocked {
                return .handled
            }
            // Allow default behavior (close sheet)
            return .ignored
        }
        .onAppear {
            // Configure coordinator with app state and dependencies.
            coordinator.configure(appState: appState, dataCoordinator: dataCoordinator)
            // Seed coordinator from the initial tab value once on appear.
            // All subsequent tab changes are driven by coordinator.selectedTab only.
            coordinator.selectedTab = initialTab
            // Activate locked-to-restore mode if requested by the caller.
            // This must be set after selectedTab so the tab is correct before the lock
            // prevents any further tab navigation.
            if lockedToRestore {
                coordinator.selectedTab = .restore
                coordinator.isLockedToRestoreTab = true
                // Mirror the locked state onto AppState so MenuBar can detect it and
                // route "Quit Film Tracker" through the dismiss-then-terminate path.
                appState.isLockedToRestoreTab = true
            }
            // If a backup URL was supplied (Finder double-click / "Open Settings" flow),
            // navigate to the Restore tab and begin loading the file automatically.
            // This runs after the tab and lock setup above so the tab is correct before
            // loadBackupFile(_:) begins its async validation work.
            if let url = backupURL {
                coordinator.selectedTab = .restore
                coordinator.restoreViewModel.loadBackupFile(url)
            }
            installReturnKeyMonitor()
        }
        .onReceive(AppEventBus.shared.viewEvents) { event in
            // Handle in-place backup URL delivery when Settings is already open.
            // SheetHostView broadcasts .loadBackupFile when an .openSettingsWithBackup
            // command arrives but the Settings sheet is already active and cannot be
            // re-presented without a dismiss/reshow cycle.
            if case .loadBackupFile(let url) = event {
                guard !coordinator.isSheetDismissBlocked else { return }
                coordinator.selectedTab = .restore
                coordinator.restoreViewModel.loadBackupFile(url)
            }
        }
        .onDisappear {
            removeReturnKeyMonitor()
            // Clear the AppState mirror when the sheet leaves the hierarchy.
            // NOTE: pendingTerminationAfterSheetDismiss is NOT acted upon here.
            // onDisappear on a sheet's content view is not reliably called in all
            // programmatic dismissal paths. The termination observer lives in
            // SheetHostView, which watches sheetCoordinator.activeSheet becoming nil
            // via onChange — a guaranteed, stable signal that the sheet binding
            // has been cleared.
            appState.isLockedToRestoreTab = false
        }
        .background(WindowAccessor(window: $hostingWindow))
        .onChange(of: hostingWindow) { _, newWindow in
            // Pass the hosting window to the coordinator so it can provide it to view models
            coordinator.updateHostingWindow(newWindow)
        }
        .onReceive(AppEventBus.shared.uiCommands) { command in
            switch command {
            case .changeSettingsSheetTab(let tabNumber):
                // Tab number (1-5) → SettingsTab, in declaration order.
                let tabs = SettingsTab.allCases
                guard (1...tabs.count).contains(tabNumber) else { return }
                let newTab = tabs[tabNumber - 1]
                // Only change tab if not blocked by operations or tab lock
                guard !coordinator.isSheetDismissBlocked else { return }
                coordinator.selectedTab = newTab
            case .cycleSettingsSheetTab(let forward):
                guard !coordinator.isSheetDismissBlocked else { return }
                let tabs = SettingsTab.allCases
                let index = tabs.firstIndex(of: coordinator.selectedTab) ?? 0
                coordinator.selectedTab = tabs[(index + (forward ? 1 : -1) + tabs.count) % tabs.count]
            default:
                break
            }
        }
    }

    // MARK: - Return Key Monitor
    //
    // Uses a window-level NSEvent local monitor so Return dismisses the sheet
    // regardless of which control currently holds focus — .onKeyPress on the
    // outer VStack is only delivered when that view or a descendant has focus,
    // which breaks after any tab switch that hands focus to a tab-content control.
    //
    // The monitor is scoped exclusively to the settings sheet's own NSWindow via
    // the `event.window === hostingWindow` guard. Events arriving from any other
    // window (the main window, other sheets, panels) are passed through unchanged,
    // so this monitor has zero side effects outside the settings sheet.

    private func installReturnKeyMonitor() {
        guard returnKeyMonitor == nil else { return }
        returnKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            // Only act on events that originated in the settings sheet's own window.
            // This prevents the monitor from interfering with any other sheet or window.
            guard let sheetWindow = hostingWindow, event.window === sheetWindow else {
                return event
            }

            // MARK: Cmd+Q intercept — locked-restore flow only
            // When the sheet is locked to the Restore tab (database-error recovery) and
            // no restore operation is actively in progress, intercept Cmd+Q before it
            // reaches AppKit's window/menu system. Set a pending-termination flag on
            // AppState, then dismiss the sheet. SettingsSheet.onDisappear observes the
            // flag and calls NSApp.terminate(nil) once the sheet has fully left the view
            // hierarchy — the earliest moment at which AppKit will no longer block
            // termination due to an attached sheet.
            //
            // A fixed asyncAfter delay was previously used here but proved unreliable:
            // AppKit silently rejects NSApp.terminate(nil) while a sheet is still
            // attached, so timing-based approaches are inherently fragile. The
            // onDisappear callback is the authoritative signal that the sheet is gone.
            //
            // The key code for Q is 12; the guard checks for Cmd with no other modifiers.
            if event.keyCode == 12,
               event.normalizedModifiers == .command,
               coordinator.isLockedToRestoreTab,
               !coordinator.isBlockingOperationInProgress {
                appState.pendingTerminationAfterSheetDismiss = true
                sheetCoordinator.dismissSheet()
                return nil  // Consume the event — do not let it reach the menu system.
            }

            // MARK: Return key — normal dismiss
            // Only intercept a bare Return (keyCode 36) with no modifier keys.
            guard event.keyCode == 36,
                  event.normalizedModifiers.isEmpty else {
                return event
            }
            // Don't steal Return while the sheet is dismiss-blocked (blocking operation
            // in progress, or locked to the Restore tab for database-error recovery).
            guard !coordinator.isSheetDismissBlocked else { return event }
            // Don't steal Return when a text-entry control is the first responder.
            //
            // Routed through `TextInputFocus` (InputUtilities.swift) rather than an
            // inline copy of the rule. The copy that stood here recognized only
            // "TextField", "TextEditor" and "SearchField" — it was missing the
            // "EditableText" keyword and the generic Text + Field/Editor/Input clause
            // that KeyboardManager and MenuBar both apply — so a responder those two
            // classify as text was invisible here and Return dismissed the sheet out
            // from under a live edit.
            if TextInputFocus.isActive(in: sheetWindow) { return event }
            sheetCoordinator.dismissSheet()
            return nil  // Consume the event.
        }
    }

    private func removeReturnKeyMonitor() {
        if let monitor = returnKeyMonitor {
            NSEvent.removeMonitor(monitor)
            returnKeyMonitor = nil
        }
    }

    // MARK: - Tabs Header
    @ViewBuilder
    private var tabsHeader: some View {
        // CustomTabHeader applies visual fade when disabled.
        // Tabs are locked when a blocking operation is in progress OR when the sheet
        // is locked to the Restore tab for database-error recovery.
        CustomTabHeader(
            selectedTab: coordinator.selectedTab,
            enabled: !coordinator.isSheetDismissBlocked,
            showIcons: true,
            onTabSelect: { coordinator.selectedTab = $0 }
        )
    }
}

// MARK: - Settings Tabs Enum
/// The Settings sheet's tabs, in tab-bar order — the one identifier every path that opens
/// or switches a tab uses (Cmd+1–5 map onto this order).
enum SettingsTab: String, CaseIterable, Identifiable, CustomTab {
    case general = "General"
    case import_ = "Import"
    case export = "Export"
    case restore = "Restore"
    case advanced = "Advanced"
    
    var id: String { rawValue }
    var displayName: String { rawValue }
    var iconName: String {
        switch self {
        case .general: return "gearshape"
        case .import_: return "arrow.down.doc"
        case .export: return "arrow.up.doc"
        case .restore: return "doc.badge.clock"
        case .advanced: return "gearshape.2" } }
}

// MARK: - Settings Coordinator
// ObservableObject to hold lazy tab instances.
@MainActor
@Observable
final class SettingsCoordinator {
    fileprivate var selectedTab: SettingsTab = .general

    // @Observable is incompatible with 'lazy var'. Private optional backing stores
    // give the same deferred-initialization semantics without using the lazy keyword.
    private var _exportViewModel: ExportViewModel?
    var exportViewModel: ExportViewModel {
        if let e = _exportViewModel { return e }
        let e = ExportViewModel(); _exportViewModel = e; return e
    }
    private var _restoreViewModel: RestoreViewModel?
    var restoreViewModel: RestoreViewModel {
        if let r = _restoreViewModel { return r }
        let r = RestoreViewModel(); _restoreViewModel = r; return r
    }

    // When true (set by the database-error recovery flow), the sheet is locked to
    // the Restore tab. The tab bar, Close button, Escape key, and Return key are all
    // disabled until the user either completes the restore workflow or the sheet is
    // dismissed programmatically after an error. This state is orthogonal to
    // isBlockingOperationInProgress — it persists between blocking phases (e.g., the
    // user selects a file but hasn't hit Restore yet) and can only be cleared by
    // dismissing the sheet, not by an operation completing.
    var isLockedToRestoreTab: Bool = false
    
    // Computed property to check if any blocking operation is in progress
    // (prevents sheet closure and tab switching)
    var isBlockingOperationInProgress: Bool {
        exportViewModel.isExporting || restoreViewModel.isRestoring
    }
    
    // True when the sheet cannot be closed or the tab bar used — either because a
    // blocking operation is running OR because the tab is locked for recovery.
    var isSheetDismissBlocked: Bool {
        isBlockingOperationInProgress || isLockedToRestoreTab
    }

    func configure(appState: AppState, dataCoordinator: DataCoordinator) {
        // Pre-configure export view model to avoid lag on first tab switch.
        exportViewModel.configure(modelContainer: appState.modelContainer,
            dataCoordinator: dataCoordinator)
        exportViewModel.loadSavedBookmarkIfNeeded()
        
        // Pre-configure restore view model with necessary dependencies.
        restoreViewModel.configure(dataCoordinator: dataCoordinator,
            modelContainer: appState.modelContainer)
        
        // With @Observable, isBlockingOperationInProgress is a computed property that
        // reads exportViewModel.isExporting and restoreViewModel.isRestoring directly.
        // SwiftUI's observation graph tracks these accesses automatically — no manual
        // objectWillChange forwarding is needed.
    }
    
    func updateHostingWindow(_ window: NSWindow?) {
        // Pass the hosting window to view models that need it for NSOpenPanel attachment
        exportViewModel.hostingWindow = window
        restoreViewModel.hostingWindow = window
    }
}
