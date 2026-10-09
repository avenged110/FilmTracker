// MARK: - STabAdvanced.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// FilmTracker.app settings window: "Advanced" tab.
//
// Rows are built on SettingsKit's row factory (SettingsRow / SettingsDescribedToggle /
// SettingsControlStrip) and the Debug Logging block is the kit's SettingsLoggingSection,
// so this tab lays out and behaves the same as the corresponding tab in every sibling
// project. The section's own LogFileMonitor watches the log directory and gates the
// Reveal/Clear buttons, replacing the one-second polling view model that stood here.

import SwiftUI

struct AdvancedSettingsView: View, Loggable {
    nonisolated static let logTag = "[STabAdvanced]"

    @Environment(DataCoordinator.self) private var dataCoordinator
    @AppStorage(preference: Preferences.showInfoCompleteKey) private var showInfoComplete: Bool
    @AppStorage(preference: Preferences.prunePosterImagesKey) private var prunePosterImages: Bool
    @AppStorage(preference: Preferences.showWatchDetailsAnnotationGlyphsKey)
        private var showWatchDetailsAnnotationGlyphs: Bool
    @AppStorage(preference: Preferences.overrideDateClampKey) private var overrideDateClamp: Bool
    @AppStorage(preference: Preferences.strictFramesTableCheckingKey)
        private var strictFramesTableChecking: Bool

    @State private var showResetInfoCompleteAlert = false
    @State private var showResetIgnoredPairsAlert = false

    var body: some View {
        // SettingsPage with no padding: the inset is applied at the call site in
        // SettingsSheet, which also supplies the scroll container. This tab outgrew the
        // sheet's height, so it moved into DataCoordinatorScrollView alongside the General
        // tab; the `maxHeight: .infinity` that used to pin a non-scrolling tab to the top of
        // SettingsSheet's centered ZStack went with it, since a scroll view's content is
        // top-anchored by nature and stretching it to infinity would give the scroll view
        // nothing to scroll.
        SettingsPage(padding: 0) {
            SettingsRow("Show \"Complete Data\" components",
                        description: "Manually flag films as being complete and filter the gallery using this trait.",
                        leading: .checkbox($showInfoComplete)) {
            } accessory: {
                SettingsControlStrip {
                    Button("Reset All Flags") { showResetInfoCompleteAlert = true } } }

            Divider()

            SettingsRow("Ignored duplicate pairs",
                        description: "When scanning for duplicates, film pairs you've previously ignored will be excluded from results.") {
            } accessory: {
                SettingsControlStrip {
                    Button("Reset All Ignored Pairs") { showResetIgnoredPairsAlert = true } } }

            Divider()

            // The caveat appears only when there is a caveat to state. With
            // purchasedDiscGlyphVisibilityOverride off, every glyph answers to this
            // checkbox and the row needs no explanation; with it on, one glyph visibly
            // does not, and a user toggling this off would otherwise be left wondering
            // why the disc stayed behind.
            SettingsRow("Show glyphs in contextual sidebar fields",
                        description: Preferences.purchasedDiscGlyphVisibilityOverride
                            ? "This does not apply to the glyph used to denote a purchased release in the \"Source for Viewing\" field, which is always present."
                            : nil,
                        leading: .checkbox($showWatchDetailsAnnotationGlyphs))

            SettingsDescribedToggle("Override date clamp for viewing events",
                description: "The floor of the permissible date range for entering viewing events is automatically clamped to a film's release date. You may temporarily override this guard to add viewing events that occurred prior to a film's release date, but this preference will always be automatically reset upon quit.",
                isOn: $overrideDateClamp)

            Toggle(isOn: $strictFramesTableChecking) {
                Text("Strict user-facing input validation for HandBrake frame data") }

            SettingsDescribedToggle("Prune orphaned poster images",
                description: "Periodically check for orphaned poster images and automatically remove any which are found.",
                isOn: $prunePosterImages)

            // MARK: - Logging Section
            // The forced log line on disable and shutdownLogging() are the section's own;
            // this closure adds only Film Tracker's side effects. `Preferences.loggingEnabled`
            // is already committed by the section's @AppStorage binding — writing it again
            // through the setter is what routes the "loggingEnabled set to …" log line
            // through Preferences' deduplicated write.
            SettingsLoggingSection(loggingEnabledKey: Preferences.loggingEnabledKey,
                                   title: "Debug logging") { newValue in
                Preferences.loggingEnabled = newValue
                AppEventBus.shared.send(.view(.preferencesChanged)) } }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .alert("Reset All \"Complete Data\" Flags",
            isPresented: $showResetInfoCompleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                // resetAllInfoCompleteFlags() is fire-and-forget:
                // optimistic MemoryStore update is applied synchronously; background
                // persistence is dispatched via trackOperation, which handles rollback
                // and user alerting on failure internally.
                dataCoordinator.resetAllInfoCompleteFlags()
            }
        } message: {
            Text("Are you sure you want to reset all \"Complete Data\" flags? This will clear the flag on every film in your library, resetting them all to false. This action cannot be undone.") }
        .alert("Reset All Ignored Duplicate Pairs",
            isPresented: $showResetIgnoredPairsAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                Preferences.resetIgnoredDuplicatePairs()
                log("User reset all ignored duplicate pairs") }
        } message: {
            Text("Are you sure you want to reset all ignored duplicate pairs? The next duplicate scan will include these pairs again if they still match as duplicates. This action cannot be undone.") } }
}
