// MARK: - ImportsView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Displays import history and manages metadata/ratings imports. The scrollable
// session list is hosted by DataCoordinatorScrollView (27_40_RPTabDataViz.swift),
// the shared AppKitScrollView facade for consumers that need nothing re-injected
// into the hosted tree beyond DataCoordinator. The sessions themselves come from
// ImportHistory (28_20), an in-memory index of value records, not from a fetch.

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit

struct ImportsView: View {
    @Environment(DataCoordinator.self) private var dataCoordinator
    var importProgress = ImportProgress.shared
    var importsState = ImportsState.shared
    var importHistory = ImportHistory.shared

    // Session-box layout. Boxes grow with the view up to `importBoxMaxWidth`; past
    // that point the surrounding whitespace grows instead (mirroring the gallery
    // grid's centered max-width behavior). They never sit closer than
    // `importBoxEdgeInset` to the view's side edges.
    private let importBoxMaxWidth: CGFloat = 1000
    private let importBoxEdgeInset: CGFloat = 40

    // Incremented only when a session is inserted, never when one is deleted,
    // so the insertion spring inside ImportSessionList fires when new cards
    // appear but never for tab switches or deletions. Card-removal
    // animation is owned entirely by ImportSessionList — see its declaration
    // for why that state must live inside the hosted content tree.
    @State private var insertionCount: Int = 0

    // Every session on the tab is listed. There used to be a "Show More" window (ten,
    // then 500 more per press) that bounded how many cards were built; ImportSessionList
    // now builds only those on or near the screen (see "Windowed mounting" there), so
    // the length of the history no longer costs anything to show.

    // Lets ImportSessionList hold the scroll view's document height through a card's
    // removal animation, and tells it which part of the list is on screen (see
    // ImportSessionList). Anchors are never published.
    @State private var listScrollProxy = AppKitScrollProxy(tracksAnchors: false, tracksViewport: true)

    var body: some View {
        // Compute once per render pass; used for both the empty-state check and
        // the ForEach/animation-value below, avoiding three separate filter passes.
        let sessions = filteredSessions
        let isActiveOnTab = isActiveImportOnSelectedTab
        VStack(spacing: 0) {
            // Title bar with tab picker and action button.
            GenericTitleBar(
                glyph: importsState.selectedCategory.glyph,
                leadingContent: {
                    ImportsTabPicker()
                        .frame(width: 220)
                        .padding(.leading, 12)
                },
                trailingButtons: {
                    HStack(spacing: 8) {
                        // "Import in Progress" label (only visible during import or linger).
                        if isImportBusy {
                            Text("Import in Progress…")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                                .transition(.opacity)
                        }
                        
                        // Both tabs' buttons share this spot; size the chrome to the
                        // widest title across categories so it never resizes when the
                        // tab (and thus the visible title) changes. The hidden Texts
                        // establish that max width; only the last Text is drawn.
                        Button { handleImportAction() } label: {
                            ZStack {
                                ForEach(ImportsCategory.allCases, id: \.self) { category in
                                    Text(category.buttonTitle).hidden()
                                }
                                Text(importsState.selectedCategory.buttonTitle)
                            }
                        }
                        .disabled(isImportBusy)
                    }
                    .padding(.trailing, 18)
                    .animation(.easeInOut(duration: 0.2),
                               value: isImportBusy)
                }
            )

            // Fixed, omnipresent header beneath the tab bar. While an import that
            // matches the selected tab is running it shows the live progress UI;
            // otherwise it shows a placeholder. It is always present so the tab/list
            // layout below it stays consistent regardless of import state.
            ImportHeaderBar(
                importProgress: importProgress,
                isActive: isActiveOnTab,
                category: importsState.selectedCategory,
                onCancel: { importProgress.cancelImport() },
                importBoxMaxWidth: importBoxMaxWidth,
                importBoxEdgeInset: importBoxEdgeInset)

            // Show the empty state only when there are no sessions for the selected tab
            // AND no active import is running on that tab.
            if sessions.isEmpty && !isActiveOnTab {
                // Empty state — no ScrollView; fills the remaining space.
                StandardPlaceholder(
                    glyph: importsState.selectedCategory.glyph,
                    title: "No Imports",
                    message: emptyStateMessage
                )
            } else {
                // Completed import sessions, each rendered as its own bounded box.
                // Boxes grow with the view up to `importBoxMaxWidth`; beyond that the
                // surrounding whitespace grows so the boxes stay centered, and they
                // remain at least `importBoxEdgeInset` from the view's side edges.
                //
                // The list itself is a dedicated struct (not built inline here)
                // because its removal-animation state must live inside the
                // NSHostingView created by AppKitScrollView — see ImportSessionList.
                DataCoordinatorScrollView(scrollProxy: listScrollProxy) {
                    ImportSessionList(
                        sessions: sessions,
                        scrollProxy: listScrollProxy,
                        insertionCount: insertionCount,
                        importBoxMaxWidth: importBoxMaxWidth,
                        importBoxEdgeInset: importBoxEdgeInset,
                        onDelete: { deleteSession($0) },
                        onDeleteAll: { deleteAllSessions() }
                    )
                }
                .background(Color(NSColor.underPageBackgroundColor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        // MARK: - Keyboard Shortcuts (Cmd+O, Shift+Cmd+I, Opt+Cmd+I)
        // Hidden buttons capture keyboard shortcuts only while ImportsView is active.
        // Cmd+O mirrors the "Select Files" / "Select HTML File" button action and is
        // reclaimed unconditionally — it has no MenuBar equivalent to conflict with.
        //
        // Shift+Cmd+I and Opt+Cmd+I are each the MenuBar's shortcut for "Import
        // Metadata…" and "Import Ratings…" respectively (MenuBar.swift). Each is
        // reclaimed here ONLY while its own tab is the one currently selected —
        // exactly mirroring the tab-specific condition those MenuBar items are
        // disabled under. This means whichever shortcut belongs to the tab NOT
        // currently selected is deliberately left unclaimed, so it falls through to
        // the responder chain and reaches the (enabled) MenuBar item instead, which
        // switches to that other tab. Reclaiming both regardless of tab would let
        // this view's "current tab" action silently shadow the other tab's MenuBar
        // item, since a local key equivalent always wins over a Commands-menu one.
        //
        // The two roles compose into a deliberate two-step: from the Ratings tab,
        // Shift+Cmd+I reaches the MenuBar item and only switches to Metadata; a
        // second press now lands on the button below and opens the picker. Nothing
        // in the app opens a file dialog as a side effect of navigation.
        .overlay(alignment: .topLeading) {
            Group {
                // Claimed only while no import is running. These three shortcuts are
                // stand-ins for the title bar's action button, so they are withheld
                // on exactly the condition that disables it — omitted from the view
                // tree rather than merely .disabled, so the key equivalent is left
                // genuinely unclaimed and continues down the responder chain instead
                // of being swallowed here.
                if !isImportBusy {
                    Button("") { handleImportAction() }
                        .keyboardShortcut("o", modifiers: .command)
                    if importsState.selectedCategory == .metadata {
                        Button("") { handleImportAction() }
                            .keyboardShortcut("i", modifiers: [.shift, .command])
                    }
                    if importsState.selectedCategory == .ratings {
                        Button("") { handleImportAction() }
                            .keyboardShortcut("i", modifiers: [.option, .command])
                    }
                }
            }
            .frame(width: 0, height: 0)
            .clipped()
        }
        .onAppear {
            // ImportProgress is already attached to the model context and coordinator
            // by MainView.onAppear (which fires before any child view appears).
            // No re-attachment is needed here.

            // Tell ImportsState (and MenuBar) we're viewing the Imports screen.
            // ImportProgress reads this same flag, so it must be set before the
            // notification below.
            importsState.isViewingImports = true
            importProgress.viewingImportsDidChange(true)
            
            // Ensure the view state reflects the currently selected category.
            importsState.ensureInitialViewLoad()
            
            // If currently on the default tab, auto-switch to the Ratings tab
            // when an active or recently completed import is of that type.
            //
            // Skipped when the arrival named a tab (a MenuBar item, the toolbar
            // menu, or their keyboard shortcuts): those must land where they say
            // they will, every time, or the shortcut stops being predictable.
            // Only a generic arrival — the sidebar's "Imports" row, which expresses
            // no preference — gets steered toward the live import.
            let arrivedByName = importsState.consumeCategoryRequest()
            if !arrivedByName, importsState.selectedCategory == .metadata {
                let activeIsRatings = importProgress.activeImportType == .ratings
                let lastWasRatings  = importProgress.lastCompletedImportType == .ratings
                if activeIsRatings || (importProgress.activeImportType == nil && lastWasRatings) {
                    importsState.selectCategory(.ratings)
                }
            }
        }
        .onDisappear {
            // Tell ImportsState (and MenuBar) we've left the Imports screen.
            importsState.isViewingImports = false
            importProgress.viewingImportsDidChange(false)
            // A by-name request only ever describes the appearance it immediately
            // precedes; drop any that was raised while this view was on screen.
            importsState.clearCategoryRequest()
        }
        // Increment insertionCount only when the session list grows. This is the
        // value driving the VStack's insertion animation, and keeping it stable
        // on deletions ensures the spring never fires when a record is removed.
        .onChange(of: sessions.count) { oldCount, newCount in
            if newCount > oldCount { insertionCount += 1 }
        }
    }

    // The selected tab's sessions, excluding the current active session while importing
    // or while the UI is lingering post-completion, so the new historical card
    // only appears once the linger clears and all controls unlock together.
    // Outside that window this is ImportHistory's own array, so the list receives the
    // same storage on every pass rather than a copy.
    private var filteredSessions: [ImportSessionRecord] {
        let records = importHistory.records(for: importsState.selectedCategory,
                                            in: dataCoordinator.modelContainer)
        guard isImportBusy, let currentID = importProgress.currentSessionID else { return records }
        return records.filter { $0.id != currentID } }

    // The single lock in the imports flow: true while an import is running or its
    // completion UI is still lingering. It gates the title bar's action button and
    // the keyboard shortcuts that stand in for it — the only two ways to open a
    // file picker. Navigation to and around this view is deliberately never gated
    // on it; see the MenuBar and toolbar-menu items.
    private var isImportBusy: Bool {
        importProgress.isImporting || importProgress.isUILingering }

    private var emptyStateMessage: String {
        switch importsState.selectedCategory {
        case .metadata:
            return "Import metadata from MP4/M4V files with iTunes-style metadata to add films to your library for tracking."
        case .ratings:
            return "Import ratings from Blu-ray.com HTML files to sync your online ratings with your library." } }

    // True while an import is running OR the UI is lingering post-completion,
    // and its type matches the selected tab. Drives the fixed header active UI
    // and keeps all import-related controls locked until the linger clears.
    private var isActiveImportOnSelectedTab: Bool {
        guard isImportBusy else { return false }
        return importProgress.activeImportType == importsState.selectedCategory }

    private func handleImportAction() {
        importProgress.beginImport(of: importsState.selectedCategory)
    }

    private func deleteSession(_ sessionID: UUID) {
        dataCoordinator.deleteImportSession(id: sessionID)
    }

    private func deleteAllSessions() {
        dataCoordinator.deleteAllImportSessions(ofType: importsState.selectedCategory.rawValue)
    }
}

private struct ImportsTabPicker: View {
    var importsState = ImportsState.shared

    var body: some View {
        SubcategoryPicker(
            label: "Imports Tab",
            style: .segmented,
            options: ImportsCategory.allCases,
            selection: importsState.selectedCategory,
            title: \.displayName,
            onSelect: { importsState.selectCategory($0) })
    }
}

// MARK: - Imports State

/// Manages the currently selected imports category.
@MainActor
@Observable
final class ImportsState {
    static let shared = ImportsState()
    
    var selectedCategory: ImportsCategory = .metadata
    var isViewingImports: Bool = false
    
    init() {
        // Restore the last-used category if the preference is enabled.
        if Preferences.rememberImportsTab,
           let savedRawValue = Preferences.lastImportsCategory,
           let saved = ImportsCategory(rawValue: savedRawValue) {
            selectedCategory = saved
        }
    }
    
    /// Triggers a view-state switch to the current category, ensuring the gallery
    /// and sidebar reflect the correct view. Called once each time ImportsView appears.
    func ensureInitialViewLoad() {
        ViewStateManager.shared.switchToViewSync(.imports(selectedCategory))
    }
    
    /// Set when the arrival at ImportsView named a tab outright — the "Import
    /// Metadata…"/"Import Ratings…" MenuBar items, the toolbar menu, and the
    /// keyboard shortcuts behind them all do. It exists so ImportsView's onAppear
    /// can tell those apart from a generic arrival (clicking "Imports" in the
    /// sidebar), which is the only kind its steer-me-to-the-live-import
    /// convenience should apply to. A shortcut whose label names a tab has to land
    /// on that tab every time, or it isn't a shortcut the user can build a habit
    /// around.
    private(set) var categoryRequestedByName = false

    /// Selects `category` on behalf of a caller that asked for it by name.
    /// The flag is raised BEFORE the selection: `selectCategory` drives
    /// ViewStateManager, and the flag must already be set for any appearance that
    /// could conceivably result from that, rather than arriving a line too late.
    func requestCategory(_ category: ImportsCategory) {
        categoryRequestedByName = true
        selectCategory(category)
    }

    /// Reads and clears the flag. Called once per appearance, whether or not the
    /// caller acts on the result, so a request raised while ImportsView was already
    /// on screen (pressing the other tab's shortcut from here) cannot survive to
    /// influence some later, unrelated appearance.
    func consumeCategoryRequest() -> Bool {
        defer { categoryRequestedByName = false }
        return categoryRequestedByName
    }

    /// Companion to the above for the leaving edge — see ImportsView.onDisappear.
    func clearCategoryRequest() { categoryRequestedByName = false }

    /// - Parameter persist: Whether this is a deliberate tab CHOICE by the user, and so
    ///   should be remembered across sessions. See RecentsState.selectCategory.
    func selectCategory(_ category: ImportsCategory, persist: Bool = true) {
        selectedCategory = category

        if persist && Preferences.rememberImportsTab {
            Preferences.lastImportsCategory = category.rawValue
        }
        
        ViewStateManager.shared.switchToViewSync(.imports(category))
    }
}

// MARK: - Import Header Bar
/// Fixed-height header pinned directly beneath the tab bar. It is always
/// present: while `isActive` is true (import running or UI lingering
/// post-completion) it hosts the live progress UI; otherwise it shows a
/// placeholder. The height is fixed to the fully-populated active-UI size
/// (ratings case, which has the most rows) so the list below never shifts
/// between states or between imports with different row counts.
///
/// `isActive` is derived from `(isImporting || isUILingering)` upstream,
/// so the linger timing is managed entirely by `ImportProgress` — this view
/// simply renders whatever `isActive` says.
///
/// Content is inset to match the max-width bounding used by the session cards
/// in the list below, so dates and stats stay visually left-aligned across
/// both areas regardless of window width.
private struct ImportHeaderBar: View {
    var importProgress: ImportProgress
    let isActive: Bool
    let category: ImportsCategory
    let onCancel: () -> Void
    let importBoxMaxWidth: CGFloat
    let importBoxEdgeInset: CGFloat

    // Fixed height sized to the fully-populated ratings-import UI (most rows).
    // Using a hard value (not minHeight) keeps the header and the list below it
    // perfectly stable regardless of which state or import type is showing.
    private let fixedHeight: CGFloat = 192

    // One-line, tab-specific blurb shown beneath the "No import session in
    // progress." placeholder. The Ratings variant carries a Markdown link that
    // opens in the system-default browser (see the .openURL override on `body`),
    // mirroring the RightSidebar's Web Query hand-off.
    @ViewBuilder
    private var placeholderDescription: some View {
        switch category {
        case .metadata:
            Text("Film Tracker is compatible with MP4/M4V files containing iTunes-style metadata.")
        case .ratings:
            Text("Film Tracker is compatible with HTML-based user ratings from [Blu-ray.com](https://www.blu-ray.com/community/ratings.php).")
        }
    }

    var body: some View {
        Group {
            if isActive {
                // Bound the content to the same max-width as the session cards
                // below, with matching edge insets, so they stay visually aligned.
                HStack(spacing: 0) {
                    Spacer(minLength: importBoxEdgeInset)
                    ActiveImportRow(importProgress: importProgress, onCancel: onCancel)
                        .frame(maxWidth: importBoxMaxWidth, alignment: .leading)
                    Spacer(minLength: importBoxEdgeInset)
                }
            } else {
                VStack(spacing: 0) {
                    Text("No import session in progress.")
                    // Empty lines between the placeholder and the tab-specific description.
                    Text(" ")
                    Text(" ")
                    // Tertiary tint keeps the blurb a step below the placeholder
                    // line in visual priority (the .ratings link keeps its own tint).
                    placeholderDescription
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .frame(height: fixedHeight)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
        // Route the description's Markdown link through NSWorkspace so it opens
        // in the system-default browser, matching the Web Query button.
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
    }
}

// MARK: - Active Import Row

private struct ActiveImportRow: View {
    var importProgress: ImportProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header — use the captured start date rather than Date() so the string
            // is stable for the entire import and never re-formatted on each re-render.
            HStack {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text((importProgress.importStartDate ?? Date()).formatted(Date.FormatStyle(date: .complete, time: .omitted, calendar: AppCalendar.current)))
                        .font(.headline)
                    Text("In Progress")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer() }

            // Progress bar.
            HStack(spacing: 12) {
                ProgressView(value: Double(importProgress.currentFile),
                           total: Double(importProgress.totalFiles))
                    .progressViewStyle(.linear)
                Button { onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("Cancel import") }

            // Stats.
            VStack(alignment: .leading, spacing: 4) {
                StatRow(
                    label: "Processing…",
                    value: "\(importProgress.currentFile) of \(importProgress.totalFiles)")
                Divider()
                    .padding(.vertical, 2)
                StatRow(
                    label: "New Items Added",
                    value: "\(importProgress.successCount)")
                StatRow(
                    label: "Existing Items Updated",
                    value: "\(importProgress.updatedCount)")
                StatRow(
                    label: "Errors",
                    value: "\(importProgress.errorFiles.count)",
                    isError: importProgress.errorFiles.count > 0)
                StatRow(
                    label: "Duplicates Skipped",
                    value: "\(importProgress.duplicateCount)")
                // "Not Found" is only meaningful for ratings imports.
                if importProgress.activeImportType == .ratings {
                    StatRow(
                        label: "Skipped Due to Film Not Found in Library",
                        value: "\(importProgress.notFoundCount)") } }
            .font(.caption) }
        .padding(16) }
}

// MARK: - Import Session List

// Card removal works by structural exclusion, not by height manipulation.
//
// Every prior approach animated the removed card's own layout (frame collapse,
// maxHeight, measured-height interpolation) and failed in one of two ways:
// sibling cards were sheared/jumped as the collapsing frame fought the VStack's
// layout, or the collapse silently never animated and the remaining cards
// snapped into place when the record left the store. The root architectural
// cause: this list lives inside an NSHostingView (AppKitScrollView), whose
// updateNSView pushes refreshed content via a bare `rootView` assignment that
// carries no animation transaction — so withAnimation calls from the outer
// SwiftUI tree (ImportsView) can never animate the hosted layout.
//
// The mechanism below sidesteps all of that:
//
//   1. "Clear This Item" inserts the session's ID into `removingIDs` — @State
//      that lives INSIDE the hosted tree, so the mutation runs within the
//      NSHostingView's own SwiftUI render loop where the withAnimation
//      transaction survives intact. `remaining` excludes the ID, so the
//      row leaves the ForEach as a single animated structural change: its
//      .opacity removal transition fades the card out (at full, untouched
//      height — no card's height ever changes) while the VStack reflow slides
//      every card below it up into the vacated space, both in the same spring.
//      Because the entire row — including its 12-pt VStack spacing
//      contribution — leaves layout in that one change, no residual gap is
//      left behind to close later.
//   2. After the spring has visually settled (400 ms), the database delete
//      fires. When ImportHistory subsequently drops the record, `remaining` is
//      unchanged (the ID was already filtered out), so that structural
//      removal produces zero visual delta — no second animation, no jump.
//   3. Once the record is confirmed gone from `sessions`, the ID is dropped
//      from `removingIDs` (pure hygiene; an absent ID filters nothing).
//
// Two more pieces make it work wherever the card sits:
//
//   • The scroll view holds the document's height through the spring
//     (`holdForAnimatedShrink`, "Animated shrink" in 92_00). Without it, a
//     removal while scrolled to (or near) the bottom of a list taller than the
//     window shortened the document in one step, NSClipView clamped the offset
//     in that same frame, every card leapt down by the shortfall, and a removed
//     bottom card faded entirely out of sight — it "simply disappeared". The
//     hold's anchor places the list in the held frame (ShrinkAnchoredLayout) so
//     that the cards above the removal slide down instead, on the same spring;
//     when the hold ends, the offset follows and nothing moves.
//   • Only cards near the screen exist (see "Windowed mounting" below); the rest
//     are spacer. The window reaches far enough that every card a spring moves
//     on screen is already built.
//
// The `imports-removal` harness scenario (99.54) films every case of this —
// top, middle and bottom cards; short and long lists; scrolled to the bottom,
// near it, and at the top; long lists that are mostly spacer; overlapping removals; and
// clearing the bottom card repeatedly until the list is empty — and checks each
// frame for jumps, reversals, snaps, and a visible fade.
//
// As defense in depth, the VStack also carries .animation(value: removingIDs),
// which injects the spring at the modifier level in the exact update that
// removes the row — independent of whatever transaction reaches the hosted
// tree. This is the same transaction-independent mechanism that lets the
// existing insertion spring (keyed to insertionCount) animate correctly
// through AppKitScrollView's bare rootView pushes today. It is also the
// sole animation source for removals: a bare removingIDs.insert(id) in
// beginRemoval() — without any wrapping withAnimation — is all that is
// needed, mirroring how insertionCount increments drive the insertion spring.
//
// Windowed mounting
// ─────────────────
// The list is still one plain VStack, so every animation above runs exactly as it
// always has — but it only mounts the cards on or near the screen. Each run of cards
// above or below that window is stood in for by a single clear spacer exactly as tall
// as the cards and gaps it replaces (`CardColumn`), so every mounted card sits where it
// would sit in the full stack, the document is exactly as tall, and the scroller is
// unchanged. What it costs to show, switch tabs or leave no longer depends on how many
// sessions there are. `imports-switch-perf` (99.55), 1,000 sessions: leaving after
// revealing 900 cards took 1,342 ms before this (when a "Show More" button bounded the
// list; each press took 3,614 ms), against ~95 ms for a gallery switch.
//
//   • Heights. A card's height depends only on its `ImportCardShape` (canceled or
//     not, ratings or not, failures or not): every line in it is a single line at
//     any width the window allows. ImportCardMetrics remembers each shape's height,
//     measured from the real card in this tree — from mounted cards, and from
//     hidden template cards for shapes not yet seen. Until a shape is measured (a
//     launch's first visit), its height as measured on macOS 15 stands in; the first
//     visit opens at the top, so that can only touch the spacer below the screen, and
//     the measurement replaces it a frame later.
//   • The window is ImportsListViewport's, fed by the clip view
//     (AppKitScrollProxy.viewportHandler / liveScrollHandler). Changing it mid-scroll is
//     what costs — every change, however small, re-lays out the list and builds cards,
//     20 ms and more (`imports-scroll`, 99.55, on a copy of a real library) — so the
//     window grows while the list is at rest: after a visit's first frame (which builds
//     only what it shows) and after each scroll, a step per run-loop turn. A list up to
//     `ImportsListViewport.wholeListHeight` tall (a few dozen sessions) grows to all of
//     it, and then scrolls exactly as the full stack did; a longer one to
//     `ImportsListViewport.lead` beyond the viewport each way, letting go of cards
//     beyond that. Mid-scroll, a long list's window moves only when the viewport reaches
//     its edge, and then only that edge, a full lead ahead: a live scroll synchronizes
//     with the main thread every frame, so that costs a few dropped frames, never a gap.
//   • Edges are invisible. The window always reaches at least one card pitch (the
//     tallest card plus a gap) beyond the viewport on both sides — farther than any
//     card moves in one removal or insertion spring, the shrink hold's lowering
//     included. So every card that is on screen at any moment of a spring is already
//     mounted when it starts, and moves exactly as in the full stack. A card that joins
//     the window only because the layout moved (not a session that is new) takes no
//     insertion transition: it appears at its place, out of sight. One that leaves
//     fades where it was, also out of sight.
//   • Only the cards that can be on screen during a spring — within two card pitches of
//     the viewport — animate in it; the others move to their new places in one step,
//     unseen. Every card that moves is redrawn every frame of a spring, so with the
//     whole of a long list mounted, animating them all made each removal stall the main
//     thread for 100–400 ms (the `imports-removal` `windowed-*` cases).
//
// `imports-window` (99.55) checks that a windowed list is pixel-identical to the full
// stack at offsets throughout a long history (`window-identical`).

private struct ImportSessionList: View {
    /// Every session on the current tab, newest first. Those not being removed are
    /// listed, and of those only the ones near the viewport are mounted (see
    /// "Windowed mounting").
    let sessions: [ImportSessionRecord]
    /// Holds the scroll view's document height through each removal, and reports
    /// what part of the list is on screen.
    let scrollProxy: AppKitScrollProxy
    /// Incremented by ImportsView only when the session list grows; keys the
    /// insertion spring. Tab switches and deletions never change it.
    let insertionCount: Int
    let importBoxMaxWidth: CGFloat
    let importBoxEdgeInset: CGFloat
    let onDelete: (UUID) -> Void
    let onDeleteAll: () -> Void

    /// IDs of sessions whose removal animation is running or whose database
    /// delete is still in flight. Rows with these IDs are excluded from the
    /// ForEach. Must remain @State on this struct — inside the hosted tree —
    /// for the animation transaction to survive (see comment above).
    @State private var removingIDs: Set<UUID> = []

    /// Where the list sits within the scroll view's held frame during a removal
    /// (see `ShrinkAnchoredLayout`). Inert outside a hold, when the frame is exactly
    /// the list's height; never reset, because a reset during a hold would move it.
    @State private var removalAnchor = ShrinkAnchor.top

    /// The part of the list on screen and the window of cards mounted around it.
    @State private var viewport = ImportsListViewport()

    /// The sessions in `sessions` as of the last update. A card for a session not in it
    /// is a new one, and slides in; any other card joining the window is only being
    /// mounted, and appears in place (see "Windowed mounting").
    @State private var presentIDs: Set<UUID> = []

    /// The removal spring. Shared with the scroll view's hold so the clip view's
    /// travel (see `beginRemoval`) moves in step with the cards.
    private static let removalResponse = 0.35
    private static let removalDampingFraction = 0.85

    private var remaining: [ImportSessionRecord] {
        sessions.filter { !removingIDs.contains($0.id) }
    }

    var body: some View {
        let revealed = remaining
        let heights = ImportCardMetrics.shared.heights
        let column = ImportsListDebug.windows ? CardColumn(revealed, metrics: ImportCardMetrics.shared) : nil
        let mounted = column.map {
            $0.cards(in: viewport.window(margin: $0.maxPitch, contentHeight: $0.height))
        } ?? revealed.indices
        // The cards that can be on screen at some moment of a spring starting now. Only
        // they animate; see "Windowed mounting".
        let animating = column.flatMap { column in
            viewport.visible.map { column.cards(in: ($0.minY - 2 * column.maxPitch)...($0.maxY + 2 * column.maxPitch)) }
        }
        let unmeasured = ImportCardShape.allCases.filter { heights[$0] == nil }
        ShrinkAnchoredLayout(anchor: removalAnchor) {
        VStack(spacing: CardColumn.spacing) {
            if let column, mounted.lowerBound > 0 {
                Color.clear.frame(height: column.extent(of: 0..<mounted.lowerBound))
            }
            ForEach(Array(zip(mounted, revealed[mounted])), id: \.1.id) { index, session in
                row(for: session)
                    .transaction { transaction in
                        if let animating, !animating.contains(index) { transaction.animation = nil }
                    }
                    // Insertion: new cards slide in from the top and fade in,
                    // pushing existing cards downward. A card that is only being
                    // mounted, as the window moves, appears in place.
                    // Removal: the card fades out in place while the animated
                    // VStack reflow slides the cards below up through the vacated
                    // space. Structural removals that carry no animation (e.g.
                    // Clear All) resolve the .opacity removal transition instantly.
                    //
                    // Spelled with the Transition types rather than AnyTransition's
                    // `.identity`/`.opacity` statics, which the SDK declares
                    // nonisolated(unsafe); the transitions are the same ones.
                    .transition(.asymmetric(
                        insertion: presentIDs.contains(session.id)
                            ? AnyTransition(IdentityTransition())
                            : AnyTransition(MoveTransition(edge: .top).combined(with: OpacityTransition())),
                        removal: AnyTransition(OpacityTransition())))
            }
            if let column, mounted.upperBound < revealed.count {
                Color.clear.frame(height: column.extent(of: mounted.upperBound..<revealed.count))
            }
        }
        // Insertion spring. Keyed to insertionCount so it fires only when the
        // list grows — never for deletions or tab switches.
        // A plain VStack (not LazyVStack) is required: LazyVStack recycles
        // views and cannot animate structural changes.
        .animation(.spring(response: 0.35, dampingFraction: 0.85),
                   value: insertionCount)
        // Shapes whose height is not yet known, measured once per app run from
        // the real card, laid out and never drawn. See "Windowed mounting".
        .background(alignment: .top) {
            if !unmeasured.isEmpty {
                ZStack(alignment: .top) {
                    ForEach(unmeasured, id: \.self) { shape in
                        row(for: shape.template)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .hidden()
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, CardColumn.padding)
        }
        // Removal spring. Keyed to removingIDs so it fires at the exact update
        // that removes a row from the ForEach — the same transaction-independent
        // mechanism that drives the insertion spring via insertionCount. This is
        // the sole animation source for removals (see comment block above). It
        // sits outside ShrinkAnchoredLayout so the same spring also carries the
        // list's placement within the held frame (`removalAnchor`).
        // Also fires at the hygiene cleanup below, where the listed sessions are
        // provably unchanged, so there is nothing for it to animate there.
        .animation(.spring(response: Self.removalResponse,
                           dampingFraction: Self.removalDampingFraction),
                   value: removingIDs)
        // Hygiene: once ImportHistory confirms a deletion — or the session set is
        // swapped wholesale by a tab switch — drop any IDs that no longer
        // exist in `sessions`. An absent ID filters nothing, so this can never
        // change the listed sessions, and therefore can never cause a visual
        // change, an animation, or a jump.
        .onChange(of: sessions.map(\.id)) { _, newIDs in
            let ids = Set(newIDs)
            removingIDs.formIntersection(ids)
            presentIDs = ids
            #if DEBUG
            installRemovalProbe()
            #endif
        }
        // This update is the one that starts the removal spring; the scroll view
        // times the end of its hold from it.
        .onChange(of: removingIDs) { old, new in
            if new.count > old.count { scrollProxy.shrinkDidBegin() }
        }
        // Not cleared on disappearance: the scroll view reporting to it goes away with
        // this list, and a list that replaces this one installs its own.
        .onAppear {
            presentIDs = Set(sessions.map(\.id))
            scrollProxy.viewportHandler = { [viewport] rect in viewport.update(rect) }
            scrollProxy.liveScrollHandler = { [viewport] isLive in viewport.setLiveScrolling(isLive) }
            scrollProxy.requestViewport()
            #if DEBUG
            installRemovalProbe()
            #endif
        }
        #if DEBUG
        .onDisappear {
            ImportsRemovalProbe.beginRemoval = nil
            ImportsSwitchProbe.visibleCount = nil
            ImportsSwitchProbe.mountedCount = nil
        }
        #endif
    }

    /// One card in its row (see SessionCardRow).
    private func row(for session: ImportSessionRecord) -> some View {
        SessionCardRow(
            session: session,
            importBoxMaxWidth: importBoxMaxWidth,
            importBoxEdgeInset: importBoxEdgeInset,
            onClearThis: { beginRemoval(of: session.id) },
            onClearAll: onDeleteAll
        )
        .equatable()
    }

    #if DEBUG
    /// The `imports-removal` harness scenario (99.54) clears cards through the same
    /// call the context menu's "Clear This Item" makes; the 99.55 scenarios count
    /// cards. Re-installed whenever the sessions change, so no closure reads a stale
    /// `sessions`.
    private func installRemovalProbe() {
        ImportsRemovalProbe.beginRemoval = { sessionID in
            beginRemoval(of: sessionID)
        }
        ImportsSwitchProbe.visibleCount = { remaining.count }
        ImportsSwitchProbe.mountedCount = { [viewport] in
            guard ImportsListDebug.windows else { return remaining.count }
            let column = CardColumn(remaining, metrics: ImportCardMetrics.shared)
            return column.cards(in: viewport.window(margin: column.maxPitch, contentHeight: column.height)).count
        }
    }
    #endif

    /// Starts the removal of the session with `sessionID`, which must be on screen.
    private func beginRemoval(of sessionID: UUID) {
        // Ignore re-entry (e.g. invoking the context menu again on a card
        // whose fade-out is already running) so the delayed delete below can
        // never be scheduled twice for the same session.
        guard !removingIDs.contains(sessionID) else { return }
        // BEFORE the state change, so the scroll view holds the document at its
        // current height through the spring instead of clamping the scroll offset
        // to the shorter list in one frame (see "Animated shrink" in 92_00). The
        // anchor it reports places the list within the held frame, in this same
        // animated update, so a removal near the bottom brings the cards above
        // down rather than leaving the viewport past the list's end.
        removalAnchor = scrollProxy.holdForAnimatedShrink(
            response: Self.removalResponse, dampingFraction: Self.removalDampingFraction)
        // Structural removal from the ForEach, animated. The bare mutation is
        // picked up by the .animation(value: removingIDs) modifier on the VStack,
        // which injects the spring at the exact update that removes the row —
        // the same transaction-independent mechanism that drives the insertion
        // spring via insertionCount. withAnimation is unnecessary here and
        // would produce a "result unused" warning in Swift 6.
        removingIDs.insert(sessionID)
        // Defer the database delete until the animation has visually settled
        // so the record never leaves `sessions` mid-animation. When the deletion
        // lands, the listed sessions are unchanged — zero visual delta.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            onDelete(sessionID)
        }
    }
}

// MARK: - Session Card Row

/// One card in its row: centered, at most `importBoxMaxWidth` wide, never closer than
/// `importBoxEdgeInset` to the sides.
///
/// Equatable on what it draws — the session and the two lengths — and compared that way
/// (`.equatable()`), because its two closures never compare equal: without it, every
/// update of the list (a deletion landing, an import's progress) re-ran every mounted
/// card's body and threw away its measured size, and the list re-measured all of them —
/// 130–390 ms with sixty cards mounted (`imports-removal`, the `windowed-*` cases). The
/// closures a reused row keeps act exactly as new ones would: `onClearThis` reaches the
/// list's state through its @State storage, and `onClearAll` reads the tab when called.
private struct SessionCardRow: View, Equatable {
    let session: ImportSessionRecord
    let importBoxMaxWidth: CGFloat
    let importBoxEdgeInset: CGFloat
    let onClearThis: () -> Void
    let onClearAll: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session == rhs.session
            && lhs.importBoxMaxWidth == rhs.importBoxMaxWidth
            && lhs.importBoxEdgeInset == rhs.importBoxEdgeInset
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: importBoxEdgeInset)
            SessionCardContent(session: session, onClearThis: onClearThis, onClearAll: onClearAll)
                .frame(maxWidth: importBoxMaxWidth)
            Spacer(minLength: importBoxEdgeInset)
        }
        // A card is always its ideal height (see "Card Shapes and Heights"); saying so
        // spares the VStack probing it at other heights on every layout.
        .fixedSize(horizontal: false, vertical: true)
        // Shadow on the outer HStack so it is never clipped by the
        // card's own clip shape.
        .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
        // Every mounted card keeps its shape's height current (see "Windowed
        // mounting"); a template does the same for a shape no card has shown yet.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            ImportCardMetrics.shared.record(height, for: ImportCardShape(session))
        }
    }
}

// MARK: - Card Shapes and Heights

/// What decides a session card's height: the stat rows it shows (one for a canceled
/// session; five, or six for ratings, otherwise) and whether its header carries a
/// failure notice. Every line on a card is a single line at any width the window
/// allows (the Imports view is at least 820 pt wide, so a card is at least 740), so two
/// cards of one shape are always the same height.
enum ImportCardShape: CaseIterable, Hashable {
    case canceled
    case metadata, metadataWithFailures
    case ratings, ratingsWithFailures

    init(_ session: ImportSessionRecord) {
        if session.isCanceled {
            self = .canceled
        } else if session.importType == ImportsCategory.ratings.rawValue {
            self = session.errorCount > 0 ? .ratingsWithFailures : .ratings
        } else {
            self = session.errorCount > 0 ? .metadataWithFailures : .metadata
        }
    }

    /// A session of this shape, for measuring one (never shown, never stored).
    fileprivate var template: ImportSessionRecord {
        let ratings = self == .ratings || self == .ratingsWithFailures
        let failures = self == .metadataWithFailures || self == .ratingsWithFailures
        return ImportSessionRecord(
            id: UUID(), persistentID: nil, sessionDate: Date(timeIntervalSinceReferenceDate: 0),
            importType: (ratings ? ImportsCategory.ratings : .metadata).rawValue,
            totalItems: 2, successCount: 1, errorCount: failures ? 1 : 0, duplicateCount: 0,
            updatedCount: 0, notFoundCount: 0, errorFileNames: [], addedTitles: [], updatedTitles: [],
            duplicateTitles: [], isCompleted: self != .canceled, isCanceled: self == .canceled)
    }
}

/// Each card shape's height, measured from real cards (see ImportSessionList,
/// "Windowed mounting"). Kept for the app's lifetime: a shape's height never changes.
@MainActor
@Observable
final class ImportCardMetrics {
    static let shared = ImportCardMetrics()

    private(set) var heights: [ImportCardShape: CGFloat] = [:]

    /// A shape's height: measured, or until it has been, what it measured on macOS 15
    /// (`imports-window` reports the measurements).
    func height(of shape: ImportCardShape) -> CGFloat {
        if let measured = heights[shape] { return measured }
        switch shape {
        case .canceled: return 73
        case .metadata, .metadataWithFailures: return 150
        case .ratings, .ratingsWithFailures: return 167
        }
    }

    func record(_ height: CGFloat, for shape: ImportCardShape) {
        guard height > 0, heights[shape] != height else { return }
        heights[shape] = height
    }
}

/// The vertical layout of the revealed cards, computed from their shapes' heights
/// exactly as the list's VStack lays them out: `padding` above the first, `spacing`
/// between each.
private struct CardColumn {
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 16

    /// The top of each card in list coordinates, then one more entry: where a card
    /// after the last would start.
    private let tops: [CGFloat]

    /// The tallest card plus a gap: the farthest any card moves in one removal or
    /// insertion spring, and so how far beyond the viewport the window reaches.
    let maxPitch: CGFloat

    /// The whole list's height, padding included.
    var height: CGFloat { tops[tops.count - 1] - Self.spacing + Self.padding }

    @MainActor
    init(_ sessions: [ImportSessionRecord], metrics: ImportCardMetrics) {
        let heights = Dictionary(uniqueKeysWithValues: ImportCardShape.allCases.map { ($0, metrics.height(of: $0)) })
        var tops: [CGFloat] = []
        tops.reserveCapacity(sessions.count + 1)
        var y = Self.padding
        for session in sessions {
            tops.append(y)
            y += heights[ImportCardShape(session)]! + Self.spacing
        }
        tops.append(y)
        self.tops = tops
        maxPitch = (heights.values.max() ?? 0) + Self.spacing
    }

    /// How tall a spacer standing in for the cards in `range` must be: their heights
    /// and the gaps between them, but not the gaps either side, which the VStack
    /// puts around the spacer itself.
    func extent(of range: Range<Int>) -> CGFloat {
        tops[range.upperBound] - tops[range.lowerBound] - Self.spacing
    }

    /// The cards any part of which lies within `span`.
    func cards(in span: ClosedRange<CGFloat>) -> Range<Int> {
        let count = tops.count - 1
        // First card whose bottom reaches the span's top.
        let first = Self.partition(count) { tops[$0 + 1] - Self.spacing >= span.lowerBound }
        // First card whose top lies past the span's bottom.
        let end = Self.partition(count) { tops[$0] > span.upperBound }
        return first..<max(first, end)
    }

    /// The first index in 0..<count for which `isPast` holds (count if none), where
    /// `isPast` is false then true along the column.
    private static func partition(_ count: Int, _ isPast: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if isPast(mid) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}

/// Which part of ImportSessionList is on screen, fed by the scroll view
/// (`AppKitScrollProxy.viewportHandler` and `liveScrollHandler`), and the window of it
/// whose cards are mounted. Publishes a change only when that window moves — never on
/// an ordinary scroll frame. See "Windowed mounting".
@MainActor
@Observable
final class ImportsListViewport {
    /// Steps the window's edges are rounded out to, so a scroll that stops a few points
    /// from the last one re-renders nothing.
    static let quantum: CGFloat = 200

    /// A list no taller than this is mounted whole at rest, so nothing at all is built
    /// while it scrolls. About sixty cards; each mounted card adds about a millisecond to
    /// leaving the view (`imports-switch-perf`).
    static let wholeListHeight: CGFloat = 10_000

    /// The mounted span, in list coordinates; nil until the scroll view first reports.
    private var mounted: ClosedRange<CGFloat>?

    @ObservationIgnored private var rect: CGRect?
    @ObservationIgnored private var isLiveScrolling = false

    /// The visible rectangle as last reported, read without subscribing to it.
    var visible: CGRect? { rect }
    @ObservationIgnored private var growthScheduled = false
    /// The least the window may reach beyond the viewport: one card pitch.
    @ObservationIgnored private var margin: CGFloat = 0
    /// The list's height, as of the last render.
    @ObservationIgnored private var contentHeight: CGFloat = .infinity
    /// The viewport height the last list reported, for the next visit's first frame.
    @ObservationIgnored private static var lastHeight: CGFloat?

    /// How far beyond the viewport, each way, a long list's window grows at rest: farther
    /// than most single scrolls carry, since one that reaches the edge costs frames.
    private static func lead(for height: CGFloat) -> CGFloat { max(1_500, height * 2.5) }

    /// The span whose cards are mounted, given the least `margin` it must reach beyond the
    /// viewport and the list's height. Before the first report: from the top down as far
    /// as the last visit's viewport reached (the screen's height, the very first time) —
    /// what the first frame shows, and no more.
    func window(margin: CGFloat, contentHeight: CGFloat) -> ClosedRange<CGFloat> {
        self.margin = margin
        if self.contentHeight != contentHeight {
            self.contentHeight = contentHeight
            if mounted != nil, !isLiveScrolling { scheduleGrowth() }
        }
        if let mounted { return mounted }
        return -margin...((Self.lastHeight ?? NSScreen.main?.frame.height ?? 1200) + margin)
    }

    func update(_ rect: CGRect) {
        self.rect = rect
        Self.lastHeight = rect.height
        if let mounted {
            // Only once the viewport needs it. (Reaching ahead earlier buys nothing: a live
            // scroll waits on the main thread every frame, so a late window costs dropped
            // frames, never a gap — and an early one costs them more often.)
            if mounted.lowerBound > rect.minY - margin || mounted.upperBound < rect.maxY + margin {
                let ahead = target(rect)
                // Mid-scroll, only the edge the viewport reached moves — a lead ahead — and
                // nothing is let go: as little as can be built inside the scroll. At rest (a
                // programmatic scroll, a resize), the window is simply what it should be.
                if isLiveScrolling {
                    let lower = mounted.lowerBound > rect.minY - margin ? ahead.lowerBound : mounted.lowerBound
                    let upper = mounted.upperBound < rect.maxY + margin ? ahead.upperBound : mounted.upperBound
                    self.mounted = min(lower, mounted.lowerBound)...max(upper, mounted.upperBound)
                } else {
                    self.mounted = ahead
                }
            }
        } else {
            // The first report: the window the first frame used, now from the real viewport.
            mounted = (rect.minY - margin)...(rect.maxY + margin)
        }
        if !isLiveScrolling { scheduleGrowth() }
    }

    func setLiveScrolling(_ live: Bool) {
        isLiveScrolling = live
        if !live { scheduleGrowth() }
    }

    /// The window at rest: the whole of a short list; for a long one, `lead` beyond the
    /// viewport each way, rounded out to steps.
    private func target(_ rect: CGRect) -> ClosedRange<CGFloat> {
        if contentHeight <= Self.wholeListHeight { return 0...contentHeight }
        let lead = Self.lead(for: rect.height), q = Self.quantum
        return (floor((rect.minY - lead) / q) * q)...(ceil((rect.maxY + lead) / q) * q)
    }

    /// Moves the window toward `target` while nothing scrolls, one step per run-loop turn
    /// (on the turn after the one that asked, so never inside the frame being drawn):
    /// cards beyond it are let go at once, cards within it built up to a viewport's height
    /// of them at a time.
    private func scheduleGrowth() {
        guard !growthScheduled else { return }
        growthScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.growthScheduled = false
                guard !self.isLiveScrolling, let rect = self.rect, let mounted = self.mounted else { return }
                let goal = self.target(rect)
                guard goal != mounted else { return }
                let step = max(rect.height, Self.quantum)
                let lower = mounted.lowerBound < goal.lowerBound
                    ? goal.lowerBound : max(goal.lowerBound, mounted.lowerBound - step)
                let upper = mounted.upperBound > goal.upperBound
                    ? goal.upperBound : min(goal.upperBound, mounted.upperBound + step)
                self.mounted = lower...upper
                if self.mounted != goal { self.scheduleGrowth() }
            }
        }
    }
}

#if DEBUG
/// `imports-switch-perf` turns windowing off to prove the windowed list draws exactly
/// what the full stack draws.
@MainActor
enum ImportsListDebug {
    static var windows = true
}
#else
enum ImportsListDebug {
    static let windows = true
}
#endif

// MARK: - Shrink Anchored Layout

/// Places its one subview at the top of the proposed frame, lowered by the anchor's
/// `lowering(frameHeight:contentHeight:)` (92_00) when the subview is shorter.
///
/// The frame is only ever taller than the list while the scroll view holds the
/// document's height through a removal (`AppKitScrollProxy.holdForAnimatedShrink`).
/// Whatever height a removal takes away that the space below the viewport cannot
/// absorb — height whose loss would otherwise clamp the scroll offset in one frame —
/// comes off the TOP instead: the cards above the removal slide down by exactly the
/// amount the offset must later come back, on the same spring as the rest of the
/// removal, and when the hold is released the offset follows the list back to the
/// top of the frame without anything moving. Otherwise this is plain top alignment.
///
/// Top alignment itself is load-bearing (it was `.frame(maxHeight: .infinity,
/// alignment: .top)`): SwiftUI's default for content shorter than its frame is to
/// center it, which once shifted the whole list up by half a removed card while the
/// spring ran. Under the unspecified proposal NSHostingView uses to measure natural
/// height, the subview's ideal height passes through unchanged.
private struct ShrinkAnchoredLayout: Layout {
    var anchor: ShrinkAnchor

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        let height = proposal.height.flatMap { $0.isFinite ? max($0, ideal.height) : nil } ?? ideal.height
        return CGSize(width: proposal.width ?? ideal.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let ideal = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let lowered = anchor.lowering(frameHeight: bounds.height, contentHeight: ideal.height)
        // Placed with the same unspecified height it was measured at, which it then takes
        // exactly. A concrete height would be the identical size, but makes the VStack
        // probe every card at several heights to share it out — on every layout, which
        // windowed mounting brings about each time the window moves during a scroll.
        subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + lowered), anchor: .topLeading,
                      proposal: ProposedViewSize(width: bounds.width, height: nil))
    }

    // No alignment guides of its own. The default merges its subview's, which asks the
    // VStack, which asks every card, down to each Details button, on every layout. Nothing
    // aligns this view by a guide: its container is a fixed-width frame, centered, that
    // takes exactly its height.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

// MARK: - Session Card Content

// SessionCardContent renders a completed-import card at its natural, immutable
// size. No height-related modifiers may ever be added to this view: card
// heights never change, including during removal — the removal animation is a
// structural exclusion handled entirely by ImportSessionList above.
//
// A card also has no interactive state of its own that could change its height.
// It once carried a disclosure triangle that expanded an inline "Failed Files:"
// list, which made a card's height depend on whether the user had clicked it;
// the Details popover supersedes that list (its Errors tab shows the same
// `errorFileNames`, alongside the other four categories), so the expander and
// its @State are gone. Nothing here should reintroduce per-card view state.

private struct SessionCardContent: View {
    let session: ImportSessionRecord
    let onClearThis: () -> Void
    let onClearAll: () -> Void
    @State private var isShowingDetailsPopover = false

    // Distinguishes a partial failure from a total one. Every processed item failing
    // means the session accomplished nothing, which is worth saying plainly rather
    // than filing under "some". Duplicates and in-place updates count as processed
    // and NOT as errors, so a session that skipped duplicates and failed the rest
    // correctly reads as partial. `>=` rather than `==` so an unforeseen count skew
    // can never leave the message understating the outcome.
    private var failureMessage: String {
        session.errorCount >= session.totalItems
            ? "Import session failed."
            : "Some files failed to import."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header.
            HStack {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.dateFormatted)
                        .font(.headline)
                    if session.isCanceled {
                        Text("Import Canceled")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("at \(session.timeFormatted)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Failure notice, sitting immediately left of the "Details" button it
                // is telling the user to press. Canceled sessions are excluded: their
                // unprocessed remainder isn't a failure, and they show no Details
                // button for this line to point at.
                if !session.isCanceled, session.errorCount > 0 {
                    HStack(spacing: 5) {
                        // Palette rendering paints the two layers separately: the
                        // first color is the exclamation mark, the second the
                        // triangle it sits in — so this is a white mark punched out
                        // of a red triangle, in both light and dark appearances.
                        // (Reversing the pair silently yields a red mark on a white
                        // triangle, which all but vanishes on a light card.)
                        Image(systemName: ViewGlyphs.importsFailure.outline)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                        // The glyph alone carries the alarm; the sentence stays in
                        // the same secondary tone as the rest of the card header so
                        // the notice reads as information rather than shouting.
                        Text(failureMessage)
                            // Never wrap. Card height must not vary (see the note
                            // above the struct), and a message that wrapped to two
                            // lines at narrow window widths would make this card's
                            // height depend on the window's.
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .help("Click \"Details\" for specific titles.")
                }

                // "Details" button — surfaces the specific titles involved in this
                // session via a popover (SessionDetailsPopover). Hidden for canceled
                // sessions, which have no per-category title breakdown to show.
                if !session.isCanceled {
                    Button("Details") {
                        isShowingDetailsPopover.toggle()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("View the specific titles involved")
                    .popover(isPresented: $isShowingDetailsPopover, arrowEdge: .leading) {
                        SessionDetailsPopover(session: session)
                    }
                    // Scroll-dismiss: closes the popover whenever this button's vertical
                    // position in global coordinates changes — i.e., the session list
                    // (an AppKitScrollView-backed NSScrollView) was scrolled. This is the
                    // same onGeometryChange(for:of:action:) pattern HelpPopoverButton
                    // uses (GlobalUtilities.swift) rather than a background
                    // GeometryReader: onGeometryChange computes only the reduced minY
                    // value and fires its action solely when that value actually
                    // changes, with no extra layout node and no per-frame view-tree
                    // work — the same efficiency rationale documented there applies
                    // here, where this button is mounted once per session card in a
                    // potentially long scrolling list.
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .global).minY
                    } action: { _ in
                        if isShowingDetailsPopover {
                            isShowingDetailsPopover = false
                        }
                    }
                }

            }

            // Stats (showing progress for canceled imports, full stats otherwise).
            if session.isCanceled {
                VStack(alignment: .leading, spacing: 4) {
                    StatRow(
                        label: "Items Selected for Import",
                        value: "\(session.totalItems)")
                }
                .font(.caption)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    StatRow(
                        label: "Total Items Processed",
                        value: "\(session.totalItems)")
                    Divider()
                        .padding(.vertical, 2)
                    StatRow(
                        label: "New Items Added",
                        value: "\(session.successCount)")
                    StatRow(
                        label: "Existing Items Updated",
                        value: "\(session.updatedCount)")
                    StatRow(
                        label: "Errors",
                        value: "\(session.errorCount)",
                        isError: session.errorCount > 0)
                    StatRow(
                        label: "Duplicates Skipped",
                        value: "\(session.duplicateCount)")
                    if session.importType == ImportsCategory.ratings.rawValue {
                        StatRow(
                            label: "Skipped Due to Film Not Found in Library",
                            value: "\(session.notFoundCount)")
                    }
                }
                .font(.caption)
            }
        }
        // Box chrome.
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Preferences.cornerRadius))
        // Context menu lives here so it targets the visible card surface.
        // Shadow is on the outer HStack in ForEach — not here — so it renders
        // in an unclipped layer and can extend freely in all directions.
        .contextMenu {
            Button("Clear This Item", action: onClearThis)
            Button("Clear All",       action: onClearAll)
        }
    }
}

// MARK: - Stat Row
/// Displays a label-value pair with stable layout.
/// Uses monospaced digits and minimum width to prevent layout jiggling as numbers change.
private struct StatRow: View {
    let label: String
    let value: String
    var isError: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit() // Prevents layout shifts as numbers change.
                .fontWeight(.medium)
                .foregroundStyle(isError ? .red : .primary)
                .frame(minWidth: 40, alignment: .trailing) // Prevents jiggling.
        }
    }
}

// MARK: - Session Details Popover Category
/// The five tabs of the Details popover, mirroring the five per-category stat rows
/// shown on each completed-import card.
private enum SessionDetailsCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case added = "Added"
    case updated = "Updated"
    case errors = "Errors"
    case duplicates = "Duplicates"

    var id: String { rawValue }
}

// MARK: - Session Details Popover
// Presented from SessionCardContent's "Details" button. This deliberately does not
// reuse HelpPopoverButton (GlobalUtilities.swift): that utility renders a single block
// of static help text, while this popover needs an internal segmented-Picker header
// and a separately-scrolling title list — different enough content shape that bolting
// it onto the shared single-purpose utility would complicate that call site for
// every other consumer.
//
// The header is a SheetSegmentedControl (30_20) — an NSSegmentedControl driven
// directly — rather than SwiftUI's segmented Picker, because it disables the
// categories with nothing to list: AppKit's per-segment
// `setEnabled(_:forSegment:)` is the native way to gray one out, and the SwiftUI
// Picker has no reliable per-segment equivalent. "All" always stays enabled, as the
// landing tab, and shows "No Items" for a session that touched nothing. The auto-dismiss/position-tracking behavior of
// HelpPopoverButton isn't reproduced here since a Details popover is deliberately
// left open while the user browses between tabs.
private struct SessionDetailsPopover: View {
    let session: ImportSessionRecord
    @State private var selectedCategory: SessionDetailsCategory = .all

    // MARK: Layout Constants
    private static let popoverWidth: CGFloat = 300
    // Fixed total popover height, regardless of content. Previously this scaled
    // between a minimum and maximum based on row count; a single fixed height
    // is simpler and avoids any size differences between the popover's internal
    // tabs (All/Added/Updated/Errors/Duplicates).
    private static let popoverHeight: CGFloat = 400
    // Horizontal padding applied to the picker (i.e. the header buttons) on each
    // side, measured from the popover's edges. The divider below is inset by this
    // same amount on both sides so its ends line up with the picker's edges
    // rather than running the full popover width.
    private static let headerHorizontalPadding: CGFloat = 10

    var body: some View {
        // Computed once per render — reused both to decide the branch below and to
        // size the overall popover so the header never has to recompute this twice.
        let titles = titles(for: selectedCategory)

        VStack(spacing: 0) {
            // Fixed header: segmented category picker atop a divider. The control
            // refuses first responder, so it is never a Tab stop and never draws the
            // native focus ring — the AppKit equivalent of the .focusable(false) the
            // SwiftUI Picker used to carry.
            SheetSegmentedControl(selection: $selectedCategory, segments: segments,
                                  refusesFirstResponder: true)
                .padding(.horizontal, Self.headerHorizontalPadding)
                .padding(.top, 10)
                .padding(.bottom, 8)

            // Divider is inset by the same horizontal padding as the picker above,
            // so its ends align with the picker's edges rather than the popover's.
            Divider()
                .padding(.horizontal, Self.headerHorizontalPadding)

            // Scrollable title list for the currently selected category. maxHeight:
            // .infinity on both branches below means this always extends to fill
            // 100% of the space between the divider and the popover's bottom edge —
            // the actual popover height is fixed by the .frame(height:) below, not
            // estimated independently here, so there is never a gap between this
            // view's own bounds and the popover's true bottom edge.
            if titles.isEmpty {
                Text("No Items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // LazyVStack defers row creation until scrolled into view, keeping
                    // both initial popover presentation and scrolling responsive even
                    // for sessions with large title counts.
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                            Text(title)
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
        // A single fixed total height, regardless of content. Because the
        // ScrollView/placeholder above both use maxHeight: .infinity, they always
        // expand to consume every point of vertical space this frame allots below
        // the divider; alignment: .top additionally guarantees the header itself
        // never shifts, matching the fix already applied for the header-sinking
        // issue.
        .frame(height: Self.popoverHeight, alignment: .top)
    }

    // One segment per category; a category with no titles is disabled, except "All".
    private var segments: [SheetSegmentedControl<SessionDetailsCategory>.Segment] {
        SessionDetailsCategory.allCases.map { category in
            .init(category, category.rawValue,
                  isEnabled: category == .all || !titles(for: category).isEmpty)
        }
    }

    // Returns the titles for the given category. "All" concatenates every category
    // in the same order their counts appear among the card's stat rows.
    private func titles(for category: SessionDetailsCategory) -> [String] {
        switch category {
        case .all:
            return session.addedTitles + session.updatedTitles + session.errorFileNames + session.duplicateTitles
        case .added: return session.addedTitles
        case .updated: return session.updatedTitles
        case .errors: return session.errorFileNames
        case .duplicates: return session.duplicateTitles
        }
    }

}

#if DEBUG
// MARK: - Harness Hook
extension DebugHarness {
    /// The real Details popover for `session`, for the `import-details-segments` scenario.
    static func sessionDetailsPopover(_ session: ImportSession) -> AnyView {
        AnyView(SessionDetailsPopover(session: ImportSessionRecord(session)))
    }
}
#endif

