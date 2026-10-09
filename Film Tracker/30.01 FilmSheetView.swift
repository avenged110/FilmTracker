// MARK: - FilmSheetView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// SwiftUI view layer for the FilmSheet — top-level view, button bar,
// tab content switcher, and the FilmTab enum that drives them. Also contains
// FilmSheetScrollView and the FilmSheetScrollProxy typealias, the
// AppKitScrollView facade used by the sheet's three scrollable tabs.

import AppKit
import SwiftUI

// MARK: - Film Tabs Enum
// Declaration order is the tab strip's left-to-right order: the tab bar is built from
// `allCases`, and the Option-number shortcuts in FilmSheetTabContent's changeFilmSheetTab
// handler are numbered to match. Metadata precedes Releases so the sheet's ordering lines
// up with the right sidebar's, where Metadata is a Details module and Releases follows it.
enum FilmTab: String, CaseIterable, Identifiable, CustomTab {
    case details = "Details"
    case metadata = "Metadata"
    case releases = "Releases"
    case notes = "Notes"
    case poster = "Poster"

    var id: String { rawValue }
    var displayName: String { rawValue }
    var iconName: String {
        switch self {
        case .details: return "square.text.square"
        case .metadata: return "tag"
        case .releases: return "opticaldisc.fill"
        case .notes: return "square.and.pencil"
        case .poster: return "photo"
        }
    }
}

// MARK: - FilmSheetScrollProxy

/// Programmatic-scroll bridge for FilmSheet tabs.
/// Typealias for AppKitScrollProxy. FSTabDetailsView is the sole call site —
/// Notes and Metadata no longer take a proxy.
typealias FilmSheetScrollProxy = AppKitScrollProxy

// MARK: - FilmSheetScrollView

/// SwiftUI wrapper for the FilmSheet's scrollable tabs (Details, Metadata, Notes).
///
/// `isActive` controls whether the underlying NSScrollView participates in
/// AppKit's hit-test chain. When `false`, the scroll view's `hitTest(_:)` is
/// short-circuited to return `nil` (see `HitTestGatedScrollView` in
/// `92_00_AppKitScrollView.swift`), removing it and all of its AppKit subviews
/// from AppKit's hit-test traversal — without hiding it. This is a
/// defense-in-depth companion to the `TabEventShield` overlay applied at the
/// `tabLayer` level.
///
/// `scrollProxy` enables programmatic scroll-to-anchor for tabs that need it
/// (currently Details alone). Omit it — the parameter defaults to `nil` — for tabs
/// that never scroll programmatically, which is Metadata, Notes, and Releases.
struct FilmSheetScrollView<Content: View>: View {

    let content: Content
    var scrollProxy: FilmSheetScrollProxy?
    var isActive: Bool

    init(
        scrollProxy: FilmSheetScrollProxy? = nil,
        isActive: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.scrollProxy = scrollProxy
        self.isActive = isActive
        self.content = content()
    }

    var body: some View {
        AppKitScrollView(
            modifier: EmptyModifier(),
            scrollProxy: scrollProxy,
            isActive: isActive
        ) {
            content
        }
    }
}

// MARK: - FilmSheetView
struct FilmSheetView: View {
    @Bindable var owner: FilmSheet

    /// The sheet's key monitor: Tab (see `FilmSheetKeyLoop` for why the sheet handles Tab
    /// itself) and Return in a single-line field (see `endsFieldEditOnReturn`).
    ///
    /// No `FieldSubmitAction` is installed at this level any more. It made Return inside a
    /// multi-line field save the whole sheet; the sheet's rule is now that an active field
    /// takes Return first, and `FixedHeightScrollingTextView` finishes editing on Return
    /// when no action is installed. The sheet's popovers still install their own.
    @State private var tabMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            // Custom titlebar — windowTitle is resolved once in FilmSheet.init (from
            // isEditMode and, in edit mode, the film's name at open time), so it never
            // changes after init. The Text node is stable.
            ZStack {
                Text(owner.windowTitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(Divider(), alignment: .bottom)

            // Custom tab header — depends only on selectedTab.
            CustomTabHeader(
                selectedTab: owner.selectedTab,
                enabled: true,
                showIcons: true,
                onTabSelect: { owner.selectedTab = $0 }
            )
            .padding(.horizontal, 4)
            .padding(.top, -1)
            .padding(.bottom, 1)
            .background(Color(nsColor: .windowBackgroundColor))
            .focusEffectDisabled()
            .overlay(Divider(), alignment: .bottom)
            .zIndex(1)

            // Scrollable tab content.
            // Isolated in a child view that holds no reference to `owner` — only the
            // five stable tab view-model references and the current tab selection are
            // passed in. This means `owner`'s observation invalidations for hasChanges,
            // canConfirm, showingSaveError, etc. never reach the tab content area and
            // cannot cause it to be rebuilt. Only an actual selectedTab change causes
            // the content area to re-evaluate.
            //
            // The changeFilmSheetTab command listener lives inside FilmSheetTabContent
            // (via its onTabChange callback + internal FilmSheetTabSwitcher) rather than
            // here. Placing it here on a view that holds @Bindable owner would cause
            // SwiftUI to re-subscribe to the Combine publisher on every owner observation
            // hit — i.e., on every keystroke, every canConfirm toggle, etc.
            // FilmSheetTabContent holds no owner reference, so its onReceive subscription
            // remains stable across the lifetime of the sheet.
            FilmSheetTabContent(
                selectedTab: owner.selectedTab,
                appearedTabs: owner.appearedTabs,
                detailsTab:  owner.detailsTab,
                metadataTab: owner.metadataTab,
                releasesTab: owner.releasesTab,
                notesTab:    owner.notesTab,
                posterTab:   owner.posterTab,
                onTabChange: { owner.selectedTab = $0 }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Bottom buttons — isolated in its own struct so canConfirm / isConfirming
            // toggles only re-evaluate this subtree, not the titlebar or tab header.
            // The save-error alert is also hosted here: it needs $owner.showingSaveError
            // and only fires during a save operation, so binding it to the button bar
            // keeps it out of FilmSheetView's observation footprint entirely.
            FilmSheetButtonBar(owner: owner)
        }
        .onAppear { installTabMonitor() }
        .onDisappear { removeTabMonitor() }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: Preferences.sheetSize, maxWidth: Preferences.sheetSize, minHeight: Preferences.sheetSize, maxHeight: Preferences.sheetSize)
    }
}

// MARK: - FilmSheetButtonBar
/// Isolated child view for the FilmSheet's bottom button row.
///
/// Extracted from FilmSheetView so that `canConfirm` / `isConfirming` / `isValid`
/// toggles only re-evaluate this subtree. Without this separation, every
/// observation invalidation on `owner` — including frequent canConfirm flips
/// caused by keystroke-driven validation — would force SwiftUI to re-evaluate the
/// entire FilmSheetView.body, rebuilding the titlebar Text, CustomTabHeader, and
/// FilmSheetTabContent bindings on every pass even though none of their inputs
/// changed. With this struct, the titlebar and tab header are stable nodes that
/// SwiftUI can skip entirely during a canConfirm/isConfirming toggle.
///
/// The save-error alert is also hosted here so its binding
/// ($owner.showingSaveError) lives in this subtree rather than in FilmSheetView.
/// This prevents the alert binding from contributing to FilmSheetView.body
/// re-evaluations during normal editing activity.
private struct FilmSheetButtonBar: View {
    @Bindable var owner: FilmSheet
    @AppStorage(preference: Preferences.loggingEnabledKey) private var loggingEnabled: Bool

    var body: some View {
        HStack {
            Button {
                owner.cancel()
            } label: {
                Text("Cancel")
                    .padding(4)
                    .font(.system(size: 12))
            }
            .keyboardShortcut(.cancelAction)
            .disabled(owner.isConfirming)
            // Exclude from the Tab-key focus ring — activated via Escape
            // (keyboardShortcut .cancelAction), not Tab navigation.
            .focusable(false)

            Spacer()

            // Validation message - shows in both add and edit modes when fields are missing
            if !owner.canConfirm && !owner.detailsTab.isValid {
                Text("The \"Name\" and \"Release Date\" fields are required.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Button {
                owner.confirm()
            } label: {
                Text(owner.confirmButtonTitle)
                    .padding(4)
                    .font(.system(size: 12))
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!owner.canConfirm || owner.isConfirming)
            // Exclude from the Tab-key focus ring — activated via Return
            // (keyboardShortcut .defaultAction), not Tab navigation.
            .focusable(false)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .animation(.easeInOut(duration: 0.2), value: owner.canConfirm)
        .animation(.easeInOut(duration: 0.2), value: owner.isConfirming)
        // With debug logging ON, "check the log" is sound advice and the user — who turned
        // it on deliberately — knows where to look, so the message stays as it was. With
        // logging OFF, no log exists to consult, so the fault text travels in the alert.
        .alert("Save Error", isPresented: $owner.showingSaveError) {
            // Button order is deliberate and counterintuitive: the alert panel lays
            // buttons out RIGHT to LEFT in declaration order, so OK is declared first
            // to sit rightmost as the highlighted default, leaving Copy Error to its
            // left. Reversing these two swaps their positions on screen.
            Button("OK") { }
                .keyboardShortcut(.defaultAction)
            if let detail = owner.saveErrorDetail, !loggingEnabled {
                Button("Copy Error") { AlertErrorDetail.copyToPasteboard(detail) }
            }
        } message: {
            if loggingEnabled {
                Text("An error occurred while saving. The film may be in an unexpected state. Check the log for more information.")
            } else if let detail = owner.saveErrorDetail {
                Text("An error occurred while saving. The film may be in an unexpected state.\n\n\(AlertErrorDetail.cap(detail))")
            } else {
                Text("An error occurred while saving. The film may be in an unexpected state.")
            }
        }
    }
}

extension FilmSheetView {
    // MARK: Key monitor
    //
    // RETURN. The sheet's Return rule: an active text field takes Return first, and only
    // a Return with no field active (and changes to save) saves the sheet — the latter is
    // KeyboardManager's intercept. Three kinds of field, one rule:
    //   • a table row's editor commits its row itself (it opts out below, via
    //     FilmSheetReturnHandlingField), and the row editor closes;
    //   • a multi-line FixedHeightScrollingTextView finishes editing itself (its
    //     doCommandBy, 30_10);
    //   • every other single-line field — Name, Sort Name, Release, a card's Notes and
    //     currency fields — has Return taken here and editing ended.
    // Without that last arm Return in a single-line field did nothing at all: the field
    // kept focus, KeyboardManager passes Return through while any text is being edited,
    // and so no number of presses could reach Update. Ending editing is also what commits
    // a digit field's own end-of-edit work (cents padding, time-code completion).
    //
    // TAB.
    // One monitor for the whole sheet. On every tab it takes Tab and Shift-Tab away from
    // AppKit's key view loop and hands them to FilmSheetKeyLoop, which walks the active
    // tab's controls — or, on the Releases tab, the current card's — by what is actually
    // on screen. Only the bare key and Shift-Tab: Ctrl-Tab and the like keep whatever
    // meaning the responder chain gives them. Falls through, leaving the event to AppKit,
    // whenever the loop has nothing to walk — never swallowed silently.
    //
    // Scoped to this sheet's own window: the loop is asked whether the key window holds a
    // region it registered, so a Tab in the main window, in another sheet, or in an alert
    // over this one is left alone. And not while a menu is tracking — a pop-up's menu
    // takes Tab for its own type-select.
    private func installTabMonitor() {
        let sheet = owner
        let tracking = FilmSheetKeyLoop.MenuTrackingState.shared
        tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 36, event.normalizedModifiers.isEmpty {
                if Self.endsFieldEditOnReturn(event, sheet: sheet) { return nil }
                // A popover over the sheet owns Return while it is up. Its window is a child
                // of the sheet's and may not be key (after its field gave up focus the sheet
                // is still the key window), so a bare Return would otherwise reach the
                // sheet's default button and save the whole sheet. Make the popover key and
                // let its own default button take the key; consume it either way.
                if let window = NSApp.keyWindow, event.window === window,
                   !tracking.isActive, !Self.isPopoverWindow(window),
                   let popover = window.childWindows?.first(where: { $0.isVisible && Self.isPopoverWindow($0) }) {
                    if !popover.isKeyWindow { popover.makeKey() }
                    _ = popover.performKeyEquivalent(with: event)
                    return nil
                }
                return event
            }
            guard event.keyCode == 48, event.normalizedModifiers.isSubset(of: [.shift]) else { return event }
            guard !tracking.isActive else { return event }
            guard let window = NSApp.keyWindow, event.window === window else { return event }
            let forward = !event.normalizedModifiers.contains(.shift)
            // A popover over the sheet owns Tab while it is up: its controls are what the
            // user is looking at, and they are not in any registered region. Its window is
            // a child of the sheet's and may or may not be key yet (a freshly opened one is
            // not — the sheet's window still gets the key events). Either way the walk is
            // the same one the tabs get, over the popover's content, because SwiftUI does
            // not assemble a usable key-view chain there any more than it does here.
            let popover = Self.isPopoverWindow(window)
                ? window
                : window.childWindows?.first { $0.isVisible && Self.isPopoverWindow($0) }
            if let popover {
                if !popover.isKeyWindow { popover.makeKey() }
                return FilmSheetKeyLoop.shared.advance(inWindow: popover, forward: forward) ? nil : event
            }
            let moved: Bool
            switch sheet.selectedTab {
            case .releases:
                guard let vm = sheet.releasesTab else { return event }
                let entries = vm.carouselEntries
                let idx = vm.currentCardIndex
                guard entries.indices.contains(idx) else { return event }
                moved = FilmSheetKeyLoop.shared.advance(inCard: entries[idx].id, in: window, forward: forward)
            default:
                moved = FilmSheetKeyLoop.shared.advance(inTab: sheet.selectedTab, in: window, forward: forward)
            }
            return moved ? nil : event
        }
    }

    /// Ends editing of the single-line field Return was pressed in, and reports whether it
    /// did (the event is then consumed). See RETURN above.
    ///
    /// Declines — leaving the event to everything else — unless ALL hold: the key window
    /// is this sheet's own (not a popover, whose default button owns Return, and not an
    /// alert); no menu is tracking; the responder is a shared field editor, i.e. a
    /// single-line field is being edited (a multi-line text view handles Return itself);
    /// no input-method composition is on screen (Return commits it); and the field does
    /// not handle Return itself (a table row's editor).
    private static func endsFieldEditOnReturn(_ event: NSEvent, sheet: FilmSheet) -> Bool {
        guard !FilmSheetKeyLoop.MenuTrackingState.shared.isActive,
              let window = NSApp.keyWindow, event.window === window,
              !isPopoverWindow(window),
              FilmSheetKeyLoop.shared.hosts(sheet.selectedTab, in: window),
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              !editor.hasMarkedText(),
              !(editor.delegate is any FilmSheetReturnHandlingField) else { return false }
        window.makeFirstResponder(nil)
        return true
    }

    /// `NSPopover` hosts its content in a private window class; the name is the only
    /// public signal that a child window is one.
    private static func isPopoverWindow(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("Popover")
    }

    private func removeTabMonitor() {
        if let tabMonitor { NSEvent.removeMonitor(tabMonitor) }
        tabMonitor = nil
    }
}

// MARK: - FilmSheetReturnHandlingField

/// A single-line field that gives Return a meaning of its own — the string list's row
/// editor, where Return commits the row. The sheet's key monitor leaves Return to such a
/// field instead of simply ending its editing; see `FilmSheetView.endsFieldEditOnReturn`.
@MainActor
protocol FilmSheetReturnHandlingField: NSTextField {}

// MARK: - FilmSheetKeyLoop
//
// Keyboard focus traversal for the sheet: Tab and Shift-Tab walk the ACTIVE TAB's controls
// — on the Releases tab, the CURRENT CARD's — in reading order, wrapping at either end, and
// never leave it.
//
// WHY NOT APPKIT'S OWN KEY VIEW LOOP
//
// AppKit's Tab walks the window's `nextValidKeyView` chain, which SwiftUI assembles over
// every NSView it hosts. In this sheet that chain is wrong for the user in four separate
// ways, each of which shows up as "Tab does nothing" or "focus vanished":
//
//   1. THE OTHER TABS ARE IN IT. The sheet keeps every visited tab ALIVE behind the active
//      one, hidden with `.opacity(0)` rather than `isHidden` (FilmSheetTabContent). Neither
//      opacity nor SwiftUI's `.allowsHitTesting(false)` takes a control out of the key view
//      loop, so Tab walks through a hidden Details field, or fifty hidden card controls,
//      between two visible stops. That is the "dead space" between a tab's controls.
//   2. THE CAROUSEL'S NEIGHBORS ARE IN IT. The Releases tab keeps the cards on either side
//      of the current one mounted so a step can animate, dimmed and hit-disabled rather
//      than `.disabled` (see the carousel body for why) — the same failure within one tab.
//   3. THE CHAIN GOES STALE. The carousel mounts and unmounts cards without rebuilding the
//      view tree around them, and SwiftUI does not always recompute the chain when it does.
//      A control that exists, draws and clicks can then be absent from the chain entirely,
//      and Tab cannot reach what is not in it — the sporadically unreachable date Stepper.
//   4. THE ORDER IS THE TREE'S, NOT THE EYE'S. The chain follows SwiftUI's view tree, which
//      mostly reads correctly — but a control hosted through a container that SwiftUI
//      orders differently lands out of sequence, and the user cannot predict where the
//      next press goes.
//
// So Tab is taken off AppKit's hands. The sheet's key monitor (FilmSheetView) consumes it
// and hands it here, which computes the loop from what is actually on screen and moves
// first responder itself. None of the four failures can occur: a hidden tab's controls are
// recognizably hidden, an off-screen card is not inside the current card's frame, a
// control's presence in the loop is decided by its geometry rather than by a chain that may
// not have been rebuilt, and the order is the visual one by construction.
//
// TWO KINDS OF DOMAIN
//
// A CARD domain (Releases) is a frame: the controls whose centers lie inside the current
// card's region, which `ReleaseCardFocusRegion` registers from a view sized to the card.
// The card step is wider than a card, so a neighbor's controls never satisfy that test. A
// card is never scrolled, so a control clipped away is one the user cannot see, and a hit
// test at the control's center — could the user click it? — is what keeps a covered
// control out.
//
// A TAB domain (Details, Metadata, Notes) is a frame too — `FilmSheetTabFocusRegion`,
// registered from a view sized to the tab's area — but its content SCROLLS, so a control
// scrolled out of view must still be a stop, and Tab must scroll it in. A control inside a
// scroll view is therefore located by its outermost enclosing scroll view rather than by
// its own frame, and no clipping or hit test is applied to it: what keeps the other tabs'
// controls out is the visibility test below.
//
// WHAT COUNTS AS A CONTROL
//
// `canBecomeKeyView` is AppKit's own answer — it folds together `acceptsFirstResponder`,
// hidden-ness and, for an NSControl, `isEnabled` — and it is what honors the user's Full
// Keyboard Access setting: with "keyboard navigation" off, buttons, pop-ups and steppers
// refuse first responder and only the text fields remain, exactly as they would under
// AppKit's loop. A disabled control drops out the same way. Then:
//
//   • VISIBLE: no ancestor with `alphaValue` 0. SwiftUI realizes `.opacity(0)` on hosted
//     views as a zero-alpha container view (`_NSInheritedView`), so this is exactly the
//     hidden-tab test, and unlike a hit test it also holds for a control scrolled out of
//     view.
//   • A STOP, NOT A CONTAINER: scroll views, clip views, scrollers and hosting views are
//     never stops, whatever `canBecomeKeyView` says of them (a text view's scroll view
//     forwards its first-responder acceptance; a hosting view accepts it on behalf of
//     SwiftUI's own focus engine). The window's shared field editor — an NSTextView
//     installed INSIDE the field being edited — is the field's editing surface, not a
//     second stop. And SwiftUI's `KeyViewProxy` stand-ins, through which AppKit's loop
//     would hand focus to a SwiftUI-native control, are skipped: focus given to one is
//     immediately taken over by the hosting view, after which nothing in AppKit says which
//     control has it. SwiftUI-native controls the user should reach by Tab are therefore
//     built as AppKit ones (SheetCheckbox, ReleasePopUpButton, ClearableStepperView).
//   • ONE STOP PER CONTROL: a candidate nested inside another candidate is that control's
//     own machinery and is dropped in favor of its ancestor.
//
// The current control is the window's first responder, or the control whose field editor
// it is — during text entry the responder is the shared NSTextView, not the field.
@MainActor
final class FilmSheetKeyLoop {
    static let shared = FilmSheetKeyLoop()
    private init() {}

    /// Tracks whether ANY NSMenu is open and tracking, app-wide — shared by this file's tab
    /// monitor and FSTabReleasesView's swipe/key monitors, both of which need to leave Tab
    /// and arrow/scroll events to an open menu's own tracking loop rather than stealing them
    /// (a `.pickerStyle(.menu)` Picker or a Menu-based control in ReleaseCardView reassigning
    /// carouselEntries/currentIndex out from under an open menu would orphan it on screen).
    /// NSMenu posts its tracking notifications for every menu app-wide, so one singleton,
    /// installed once, covers both consumers — they used to each keep their own @State copy
    /// with their own pair of NotificationCenter observers doing the identical subscription.
    ///
    /// Main-actor isolated: every reader is main-actor code, and the observers are delivered
    /// on `.main`, so their @Sendable closures assert that isolation rather than hop to it —
    /// the flag flips in the same turn the notification is posted, as it always has.
    @MainActor
    final class MenuTrackingState {
        static let shared = MenuTrackingState()

        var isActive = false

        private init() {
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                    object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isActive = true }
            }
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification,
                                                    object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isActive = false }
            }
        }
    }

    /// The registered regions: one per mounted card, one per built tab. Weak so a view that
    /// goes away with its card or tab drops out without a dismantle call having to run.
    private let cardRegions = NSMapTable<NSUUID, NSView>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    private let tabRegions  = NSMapTable<NSString, NSView>(keyOptions: .strongMemory, valueOptions: .weakMemory)

    /// Controls sit exactly at a row's edges only by coincidence, so two frames whose
    /// vertical centers are within this distance are read as one row and ordered by x.
    /// A row's controls (a 22pt text field beside a 20pt pop-up) differ by a point or two;
    /// adjacent rows are a full row height apart.
    private static let rowTolerance: CGFloat = 8

    /// The backing view of every region: invisible, never hit, never a stop itself.
    final class RegionView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isOpaque: Bool { false }
        override var acceptsFirstResponder: Bool { false }
    }

    func register(_ view: NSView, forCard id: UUID) {
        cardRegions.setObject(view, forKey: id as NSUUID)
    }

    func register(_ view: NSView, forTab tab: FilmTab) {
        tabRegions.setObject(view, forKey: String(describing: tab) as NSString)
    }

    /// Whether `tab` is built in `window` — i.e. `window` is a FilmSheet's own window.
    /// The Releases tab's card regions and its tab region are both registered, so this
    /// holds on every tab.
    func hosts(_ tab: FilmTab, in window: NSWindow) -> Bool {
        region(forTab: tab, in: window) != nil
    }

    private func region(forCard id: UUID, in window: NSWindow) -> NSView? {
        guard let view = cardRegions.object(forKey: id as NSUUID), unsafe view.window === window else { return nil }
        return view
    }

    private func region(forTab tab: FilmTab, in window: NSWindow) -> NSView? {
        guard let view = tabRegions.object(forKey: String(describing: tab) as NSString),
              unsafe view.window === window else { return nil }
        return view
    }

    /// The card region whose frame contains `view`'s center — the card `view` is on.
    private func cardRegion(containing view: NSView) -> NSView? {
        guard let window = unsafe view.window else { return nil }
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard let candidates = cardRegions.objectEnumerator()?.allObjects as? [NSView] else { return nil }
        return candidates.first { region in
            unsafe region.window === window && region.convert(region.bounds, to: nil).contains(center)
        }
    }

    // MARK: Census

    /// True when some ancestor of `view` (or `view` itself) is drawn at zero alpha — the
    /// hidden-tab test; see WHAT COUNTS AS A CONTROL.
    private static func isDrawnInvisible(_ view: NSView) -> Bool {
        var v: NSView? = view
        while let x = v {
            if x.alphaValue == 0 || (x.layer?.opacity ?? 1) == 0 { return true }
            v = unsafe x.superview
        }
        return false
    }

    /// The outermost scroll view enclosing `view` below the window's content view, if any:
    /// what a scrolled control is located by in a tab domain.
    private static func outermostScrollView(of view: NSView) -> NSScrollView? {
        var found: NSScrollView?
        var v: NSView? = unsafe view.superview
        while let x = v {
            if let scroll = x as? NSScrollView { found = scroll }
            v = unsafe x.superview
        }
        return found
    }

    private static func isContainer(_ view: NSView) -> Bool {
        if view is NSScrollView || view is NSClipView || view is NSScroller { return true }
        let name = String(describing: type(of: view))
        return name.hasPrefix("NSHostingView") || name.contains("KeyViewProxy")
    }

    /// The key-view candidates in `region`'s domain, in reading order: top to bottom, and
    /// left to right within a row. Window coordinates put y upward, so "top" is the larger
    /// midY. `scrolls` selects the tab-domain rules (see TWO KINDS OF DOMAIN).
    private func controls(in region: NSView, scrolls: Bool) -> [NSView] {
        guard let window = unsafe region.window, let root = window.contentView else { return [] }
        let domain = region.convert(region.bounds, to: nil)

        var found: [(view: NSView, frame: NSRect)] = []
        var stack: [NSView] = [root]
        while let v = stack.popLast() {
            stack.append(contentsOf: v.subviews)
            guard v !== region, v.canBecomeKeyView, !Self.isContainer(v) else { continue }
            // The region's own ancestors are containers the tab sits in, not controls on it.
            if region.isDescendant(of: v) { continue }
            if let text = v as? NSTextView, text.isFieldEditor { continue }
            if Self.isDrawnInvisible(v) { continue }

            let frame = v.convert(v.bounds, to: nil)
            guard !frame.isEmpty else { continue }
            // Where the control counts as being: itself, or — in a tab domain — the scroll
            // view it lives in, so that a control scrolled out of the tab's area still
            // belongs to the tab.
            let anchor = (scrolls ? Self.outermostScrollView(of: v) : nil)
                .map { $0.convert($0.bounds, to: nil) } ?? frame
            guard domain.contains(NSPoint(x: anchor.midX, y: anchor.midY)) else { continue }

            if !scrolls {
                // A card is never scrolled: a control clipped away, or covered by something
                // else at its own center, is one the user cannot see focus land on. hitTest
                // takes the point in the receiver's SUPERVIEW's coordinates.
                guard !v.visibleRect.isEmpty else { continue }
                let center = NSPoint(x: frame.midX, y: frame.midY)
                let hitPoint = unsafe root.superview?.convert(center, from: nil) ?? center
                guard let hit = root.hitTest(hitPoint), hit === v || hit.isDescendant(of: v) else { continue }
            }
            found.append((v, frame))
        }
        // One stop per control — see WHAT COUNTS AS A CONTROL.
        let candidates = found.map(\.view)
        found.removeAll { entry in
            var ancestor = unsafe entry.view.superview
            while let a = ancestor {
                if candidates.contains(where: { $0 === a }) { return true }
                ancestor = unsafe a.superview
            }
            return false
        }

        // Rows first: sort by descending center y, then walk once assigning a row index
        // that advances whenever the center drops by more than the tolerance from the
        // row's anchor. Then order within rows by x. Both sorts are stable, so two controls
        // that tie exactly keep tree order.
        found.sort { $0.frame.midY > $1.frame.midY }
        var rows: [Int] = []
        var rowAnchorY: CGFloat = .infinity
        var row = -1
        for entry in found {
            if rowAnchorY - entry.frame.midY > Self.rowTolerance {
                row += 1
                rowAnchorY = entry.frame.midY
            }
            rows.append(row)
        }
        let ordered = zip(found, rows).sorted { a, b in
            a.1 != b.1 ? a.1 < b.1 : a.0.frame.minX < b.0.frame.minX
        }
        return ordered.map(\.0.view)
    }

    /// The controls of card `id`, in Tab order. Empty when the card is not mounted in
    /// `window` or has no eligible controls (Full Keyboard Access off and no text field, say).
    func controls(inCard id: UUID, in window: NSWindow) -> [NSView] {
        guard let region = region(forCard: id, in: window) else { return [] }
        return controls(in: region, scrolls: false)
    }

    /// The controls of `tab`, in Tab order; empty when the tab has not been built in `window`.
    func controls(inTab tab: FilmTab, in window: NSWindow) -> [NSView] {
        guard let region = region(forTab: tab, in: window) else { return [] }
        return controls(in: region, scrolls: true)
    }

    /// The control that currently holds focus in `window`: the first responder, or the
    /// field whose editor it is.
    static func focusedControl(in window: NSWindow) -> NSView? {
        guard let responder = window.firstResponder else { return nil }
        if let editor = responder as? NSTextView, editor.isFieldEditor {
            return editor.delegate as? NSView
        }
        return responder as? NSView
    }

    // MARK: Advancing

    /// Moves focus one step through card `id`'s controls, wrapping at either end. When focus
    /// is not on one of those controls — it is on the tab's focus sink, or nowhere — the
    /// step lands on the first (or, backward, the last) control, which is what makes a
    /// single Tab press from a freshly opened tab reach the Purchased checkbox. Returns
    /// false, moving nothing, when the card has no controls to walk.
    @discardableResult
    func advance(inCard id: UUID, in window: NSWindow, forward: Bool) -> Bool {
        guard let region = region(forCard: id, in: window) else { return false }
        return advance(within: region, scrolls: false, in: window, forward: forward)
    }

    /// The popover counterpart: walks every control in `window`'s content view. For the
    /// sheet's popovers, whose windows register no region of their own.
    @discardableResult
    func advance(inWindow window: NSWindow, forward: Bool) -> Bool {
        guard let region = window.contentView else { return false }
        return advance(within: region, scrolls: true, in: window, forward: forward)
    }

    /// The tab-domain counterpart of `advance(inCard:in:forward:)`.
    @discardableResult
    func advance(inTab tab: FilmTab, in window: NSWindow, forward: Bool) -> Bool {
        guard let region = region(forTab: tab, in: window) else { return false }
        return advance(within: region, scrolls: true, in: window, forward: forward)
    }

    /// Moves focus one step forward from `view`, through the controls of whichever card
    /// `view` is on. For callers that advance on their own — a field that auto-advances
    /// when filled — so their step obeys the same loop as a Tab press. Returns false,
    /// moving nothing, when `view` is not on a registered card; the caller then falls back
    /// to AppKit's chain.
    @discardableResult
    func advance(from view: NSView) -> Bool {
        guard let region = cardRegion(containing: view), let window = unsafe view.window else { return false }
        return advance(within: region, scrolls: false, in: window, forward: true)
    }

    private func advance(within region: NSView, scrolls: Bool, in window: NSWindow, forward: Bool) -> Bool {
        let loop = controls(in: region, scrolls: scrolls)
        guard !loop.isEmpty else { return false }

        let current = Self.focusedControl(in: window)
        let currentIndex = current.flatMap { c in loop.firstIndex { $0 === c } }
        let next: NSView
        if let currentIndex {
            next = loop[(currentIndex + (forward ? 1 : loop.count - 1)) % loop.count]
        } else {
            next = forward ? loop[0] : loop[loop.count - 1]
        }
        focus(next, in: window)
        return true
    }

    /// Gives `control` first responder the way a Tab press would: scrolled into view
    /// first, and a text field also gets its contents selected, which is what AppKit's own
    /// traversal does and what lets the user type over a value they tabbed onto.
    private func focus(_ control: NSView, in window: NSWindow) {
        // `scrollToVisible` reaches only the NEAREST clip view, and a text view or a list
        // is itself inside one — so scroll every enclosing scroll view, innermost first,
        // each asked from its own document view so its own clip is the one that answers.
        var ancestor = unsafe control.superview
        while let a = ancestor {
            if let scroll = a as? NSScrollView, let document = scroll.documentView {
                document.scrollToVisible(control.convert(control.bounds, to: document))
            }
            ancestor = unsafe a.superview
        }
        // A text field gets its contents selected, through makeFirstResponder + the field
        // editor — the path AppKit's own Tab takes. Moving first responder makes the outgoing
        // field editor run its pending text checking synchronously, which needs AppKit's
        // data-detector scanner; TextCheckingPrewarm (91.00) loads that at launch, so this
        // never waits on AppKit's default-QoS loader thread (the priority inversion Xcode
        // reported here, and through `selectText(nil)` before that).
        window.makeFirstResponder(control)
        if control is NSTextField, let editor = window.fieldEditor(false, for: control) as? NSTextView,
           window.firstResponder === editor {
            editor.selectAll(nil)
        }
    }
}

// MARK: - FilmSheetTabFocusRegion
// An invisible AppKit view sized to a tab's content area, registered with FilmSheetKeyLoop
// so Tab traversal on that tab can be scoped to it. The card-level counterpart is
// ReleaseCardFocusRegion (33_10).
private struct FilmSheetTabFocusRegion: NSViewRepresentable {
    let tab: FilmTab

    func makeNSView(context: Context) -> NSView {
        let view = FilmSheetKeyLoop.RegionView()
        FilmSheetKeyLoop.shared.register(view, forTab: tab)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        FilmSheetKeyLoop.shared.register(nsView, forTab: tab)
    }
}

// MARK: - FilmSheetTabContent
/// Isolated child view for the FilmSheet's scrollable tab body. Uses a lazy-persistent
/// rendering strategy: on first activation each tab is built once and stays in the
/// `ZStack` for the sheet's lifetime, hidden via `.opacity(0)` + `.allowsHitTesting(false)`
/// rather than destroyed, so returning to it costs only `updateNSView`, not a full AppKit
/// rebuild. Unvisited tabs are zero-cost `Color.clear` placeholders, so sheet open time
/// matches the original `switch` approach.
///
/// Holds no `@Bindable var owner: FilmSheet` reference: `FilmSheet`'s tracked properties
/// (hasChanges, canConfirm, showingSaveError) flip on every keystroke, and those
/// invalidations must not reach this subtree and trigger spurious updateNSView calls on
/// the active tab's AppKit stack. This also keeps `changeFilmSheetTab`'s `onReceive`
/// subscription (handled here rather than in FilmSheetView) stable instead of being torn
/// down and rebuilt on every owner observation hit, and keeps `detailsScrollProxy` (below)
/// from being recreated by FilmSheetView's own invalidation cycles.
private struct FilmSheetTabContent: View {
    let selectedTab:  FilmTab
    /// Tabs that have been selected at least once, and are therefore built and kept
    /// alive (hidden) rather than collapsed to a placeholder. Owned by `FilmSheet` and
    /// updated from `selectedTab`'s didSet, not tracked here as @State: see the note on
    /// `FilmSheet.selectedTab` for why. The short version is that recording the tab from
    /// an `onChange` inside this view forced a second render pass immediately after a
    /// tab was first built, and that pass reassigns NSHostingView.rootView and re-measures
    /// the whole freshly built tab through Auto Layout for no change in content.
    let appearedTabs: Set<FilmTab>
    let detailsTab:   FSTabDetails
    let metadataTab:  FSTabMetadata
    let releasesTab:  FSTabReleases
    let notesTab:     FSTabNotes
    let posterTab:    FSTabPoster
    /// Callback invoked when a `changeFilmSheetTab` command requests a new tab.
    /// Writes back to `owner.selectedTab` via the closure provided by FilmSheetView,
    /// without this struct needing to hold an owner reference.
    let onTabChange: (FilmTab) -> Void

    /// Proxy that bridges the Details tab's programmatic scroll requests to the
    /// underlying NSScrollView managed by FilmSheetScrollView. Created once for
    /// the lifetime of this view; its scrollHandler is wired in
    /// AppKitScrollNSView.makeNSView.
    ///
    /// Details is the only tab that holds one — Notes and Metadata never call
    /// `scroll(to:)`, so `AppKitScrollView` documents `nil` as the value for
    /// consumers that never scroll programmatically, which is what they pass.
    @State private var detailsScrollProxy = FilmSheetScrollProxy()

    var body: some View {
        // Compute the effective "appeared" set once. FilmSheet seeds the set with the
        // initial tab and inserts each subsequent selection from selectedTab's didSet,
        // so the fast path (identity return, zero allocation) is taken on every render.
        // The union branch is a safety net: if selectedTab is ever a value not yet
        // recorded, it is included in the set used for this frame so the active tab
        // always renders.
        let appeared = appearedTabs.contains(selectedTab)
            ? appearedTabs
            : appearedTabs.union([selectedTab])

        // Hoist per-tab state into five Bool pairs so each Set.contains runs exactly
        // once per tab per body evaluation, instead of being repeated inside tabView.
        let sel = selectedTab
        let dLoaded = appeared.contains(.details),  dActive = sel == .details
        let mLoaded = appeared.contains(.metadata), mActive = sel == .metadata
        let rLoaded = appeared.contains(.releases), rActive = sel == .releases
        let nLoaded = appeared.contains(.notes),    nActive = sel == .notes
        let pLoaded = appeared.contains(.poster),   pActive = sel == .poster

        ZStack {
            tabLayer(.details, loaded: dLoaded, active: dActive) { content(for: .details) }
            tabLayer(.metadata, loaded: mLoaded, active: mActive) { content(for: .metadata) }
            tabLayer(.releases, loaded: rLoaded, active: rActive) { content(for: .releases) }
            tabLayer(.notes, loaded: nLoaded, active: nActive) { content(for: .notes) }
            tabLayer(.poster, loaded: pLoaded, active: pActive) { content(for: .poster) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Tab-switching keyboard command. Hosted here rather than in FilmSheetView so
        // the Combine subscription is stable — this struct's body only re-evaluates on
        // selectedTab changes, not on every owner observation hit.
        .onReceive(AppEventBus.shared.uiCommands) { command in
            if case .cycleFilmSheetTab(let forward) = command {
                let tabs = FilmTab.allCases
                let index = tabs.firstIndex(of: selectedTab) ?? 0
                onTabChange(tabs[(index + (forward ? 1 : -1) + tabs.count) % tabs.count])
                return
            }
            guard case .changeFilmSheetTab(let tabNumber) = command else { return }
            let newTab: FilmTab
            switch tabNumber {
            case 1: newTab = .details
            case 2: newTab = .metadata
            case 3: newTab = .releases
            case 4: newTab = .notes
            case 5: newTab = .poster
            default: return
            }
            onTabChange(newTab)
        }
    }

    /// Returns the content view for a tab slot, or a `Color.clear` placeholder if the
    /// tab has not yet been activated. Active tabs are fully visible and interactive;
    /// inactive-but-loaded tabs are hidden and protected against stray input.
    ///
    /// Two layered protections are both needed:
    ///   • `.allowsHitTesting(false)` suppresses SwiftUI gesture recognizers, but AppKit
    ///     native controls (NSPopUpButton, NSTextField, etc.) respond to clicks through
    ///     the AppKit event chain regardless, since `NSView.hitTest(_:)` operates
    ///     independently of SwiftUI's gesture routing.
    ///   • `TabEventShield` closes that gap: it returns `self` (a plain inert NSView)
    ///     from hitTest when shielded, consuming the event before any underlying
    ///     control sees it.
    ///
    /// `FilmSheetScrollView` (Details, Metadata, Notes) additionally receives `isActive`
    /// and short-circuits its NSScrollView's own `hitTest(_:)` to `nil` — defense in
    /// depth alongside the shield, independently excluding the whole scroll subtree.
    @ViewBuilder
    private func tabLayer<C: View>(_ tab: FilmTab, loaded: Bool, active: Bool,
                                   @ViewBuilder content: () -> C) -> some View {
        if loaded {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Sized to the tab's area, for FilmSheetKeyLoop's Tab traversal. Inside
                // the opacity, so it is hidden with the tab (the loop only ever asks for
                // the active tab's region anyway).
                .background(FilmSheetTabFocusRegion(tab: tab))
                .opacity(active ? 1 : 0)
                .allowsHitTesting(active)
                .overlay(TabEventShield(isShielded: !active))
                .zIndex(active ? 1 : 0)
        } else {
            Color.clear
        }
    }

    /// Builds the concrete content view for each tab. Called at most once per tab
    /// per sheet presentation; subsequent renders reuse the existing node.
    @ViewBuilder
    private func content(for tab: FilmTab) -> some View {
        switch tab {
        case .details:
            // FilmSheetFocusSink must be the first NSView child of this branch so
            // AppKit's automatic first-responder assignment lands on the sink rather
            // than on the "Name" TextField when the Details tab is first built.
            // See MARK: - FilmSheetFocusSink below for the full rationale.
            // swallowReturn: false — on Details, Return is forwarded so AppKit's
            // responder chain can dispatch it to the window's default-action button.
            VStack(spacing: 0) {
                FilmSheetFocusSink(swallowReturn: false, reclaimWhenActive: selectedTab == .details)
                    .frame(height: 0)
                    .clipped()
                FilmSheetScrollView(scrollProxy: detailsScrollProxy,
                                    isActive: selectedTab == .details) {
                    FSTabDetailsView(viewModel: detailsTab,
                                     scrollProxy: detailsScrollProxy)
                        .padding(26)
                        .coordinateSpace(name: "filmSheetScrollContent")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .metadata:
            // No scroll proxy and no named coordinate space: this tab publishes no
            // anchor and targets none. Its lists pull a newly committed row back into
            // view through ListAddRowRevealer, which finds its own enclosing scroll
            // view and needs no cooperation from this call site. See the Notes case.
            // swallowReturn: true — an inert Return is consumed; Return saves exactly when
            // Update is enabled, on every tab. See MARK: - FilmSheetFocusSink below.
            VStack(spacing: 0) {
                FilmSheetFocusSink(swallowReturn: true, reclaimWhenActive: selectedTab == .metadata)
                    .frame(height: 0)
                    .clipped()
                FilmSheetScrollView(isActive: selectedTab == .metadata) {
                    FSTabMetadataView(viewModel: metadataTab)
                        .padding(26)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .releases:
            // FilmSheetFocusSink mirrors the Details usage. The Releases tab
            // is only built the first time the user activates it, but at that moment
            // AppKit auto-assigns focus to the first focusable NSView it finds in
            // the fresh hierarchy — the "Studio" TextField in ReleaseFormView.
            // The sink intercepts that assignment exactly once per session.
            // swallowReturn: true — as on Metadata. See MARK: - FilmSheetFocusSink below.
            VStack(spacing: 0) {
                // Re-claims on EVERY activation of this tab, not only its first build — as
                // every tab's sink now does; see RE-CLAIM ON ACTIVATION on FilmSheetFocusSink.
                FilmSheetFocusSink(swallowReturn: true, reclaimWhenActive: selectedTab == .releases)
                    .frame(height: 0)
                    .clipped()
                FSTabReleasesView(viewModel: releasesTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .notes:
            // No scroll proxy and no named coordinate space, for the same reason as
            // Metadata. This tab's only anchor moved into FilmSheetListRow and
            // was then retired with the shortcut that targeted it, and its only
            // remaining scroll behavior — revealing a freshly added list row — is
            // handled by ListAddRowRevealer, which measures against whatever scroll
            // view it happens to sit inside.
            //
            // Details is the sole tab that still needs either: it publishes the
            // viewingDatesSection anchor and targets it from the
            // .openViewingDatesAddPopover command, so the space is established there,
            // outside FSTabDetailsView, where the measured origin includes the
            // surrounding padding and aligns with the y values
            // NSScrollView.contentView.scroll(to:) expects.
            // swallowReturn: true — as on Metadata/Releases above.
            VStack(spacing: 0) {
                FilmSheetFocusSink(swallowReturn: true, reclaimWhenActive: selectedTab == .notes)
                    .frame(height: 0)
                    .clipped()
                FilmSheetScrollView(isActive: selectedTab == .notes) {
                    FSTabNotesView(viewModel: notesTab)
                        .padding(26)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .poster:
            // swallowReturn: true — same reasoning as Metadata/Releases/Notes above.
            VStack(spacing: 0) {
                FilmSheetFocusSink(swallowReturn: true, reclaimWhenActive: selectedTab == .poster)
                    .frame(height: 0)
                    .clipped()
                FSTabPosterView(viewModel: posterTab)
                    .padding(26)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - TabEventShield
/// An invisible full-size AppKit overlay that blocks native NSView hit-testing on
/// inactive FilmSheet tabs.
///
/// PROBLEM:
/// SwiftUI's `.allowsHitTesting(false)` only suppresses SwiftUI gesture recognizers.
/// It does not affect AppKit's `NSView.hitTest(_:)` method, which native controls such
/// as NSPopUpButton-backed Pickers use to receive mouse events through the AppKit event
/// delivery chain. As a result, controls on a hidden tab — one with `.opacity(0)` and
/// `.allowsHitTesting(false)` applied — can still respond to clicks if the user's mouse
/// position happens to coincide with one of those controls' frames.
///
/// SOLUTION:
/// `TabEventShield` is an `NSViewRepresentable` placed as a full-size `.overlay` on
/// every tab layer. Its backing `NSView` subclass (`_ShieldView`) overrides `hitTest(_:)`
/// to return `self` when `isShielded = true`, consuming the event without dispatching it
/// to any control, and to return `nil` when `isShielded = false`, becoming invisible to
/// AppKit's event routing so the active tab's controls work normally.
///
/// The shield is always `Color.clear`-equivalent visually (no drawing) and contributes
/// no intrinsic size. It is active (shielded) when the tab is not currently selected,
/// and inactive (transparent to events) when the tab is selected.
@MainActor
private struct TabEventShield: NSViewRepresentable {
    let isShielded: Bool

    func makeNSView(context: Context) -> _ShieldView {
        let view = _ShieldView()
        view.isShielded = isShielded
        return view
    }

    func updateNSView(_ nsView: _ShieldView, context: Context) {
        // Apply the shielded state immediately. No animation deferral is needed:
        // the shield must be in the correct state before any mouse event can arrive,
        // and SwiftUI delivers updateNSView synchronously during the layout pass that
        // also applies the `.opacity` change to the tab's content.
        nsView.isShielded = isShielded
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: _ShieldView,
                      context: Context) -> CGSize? {
        // Inherit the proposed size so the overlay fills the full tab frame.
        return CGSize(
            width:  proposal.width  ?? 0,
            height: proposal.height ?? 0
        )
    }

    /// Transparent NSView that overrides hitTest to either absorb all mouse events
    /// (when shielded) or pass through invisibly (when not shielded). No drawing.
    @MainActor
    final class _ShieldView: NSView {
        var isShielded: Bool = false

        override func draw(_ dirtyRect: NSRect) {
            // Intentionally empty — the shield is always visually transparent.
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // When shielded: return self to consume the hit event, preventing AppKit
            // from routing it to any control in the same NSHostingView subtree that
            // falls at this coordinate. Returning self (rather than nil) is required;
            // returning nil means "not me — keep looking," which is the pass-through
            // behavior. Returning self means "I own this point," and since _ShieldView
            // has no action targets or recognizers, the event is silently discarded.
            //
            // When not shielded: return nil so AppKit continues its normal hitTest
            // traversal to the controls on the active tab below this overlay.
            guard isShielded else { return nil }
            // Only claim the hit if the point is within our bounds, matching the
            // standard NSView hitTest contract.
            return unsafe bounds.contains(convert(point, from: superview)) ? self : nil
        }

        // Refuse first-responder status so the shield never acquires keyboard focus.
        override var acceptsFirstResponder: Bool { false }
    }
}

// MARK: - FilmSheetFocusSink
// An invisible, zero-height focus trap placed as the first child of a tab's VStack in
// FilmSheetTabContent.content(for:). One parameterized type backs all five tabs' sinks,
// differing only in whether Return is forwarded to AppKit.
//
// PURPOSE: When a tab is first built, AppKit assigns first-responder status to the
// first focusable NSView it finds — normally the tab's first TextField — showing a
// focus ring before the user has pressed Tab. This sink sits first so AppKit's
// assignment lands on it instead.
//
// RETURN-KEY HANDLING:
//   THE POLICY is one rule on every tab: an active text field takes Return first (see
//   the key monitor's RETURN note in FilmSheetView), and with no field active Return
//   saves exactly when the Update/Add button is enabled. KeyboardManager's Return
//   intercept enforces the second half — it runs as a local event monitor, ahead of this
//   sink, and confirms whenever `canConfirm` is true (the same stored value the button's
//   `.disabled` reads). So a Return that reaches this sink at all is one the button would
//   have refused, and `swallowReturn` only decides what an inert Return does:
//   • Details (swallowReturn = false): forwarded to super, reaching the window's
//     default-action button — disabled in this state, so nothing happens.
//   • Metadata, Releases, Notes, Poster (swallowReturn = true): consumed outright.
//   Neither can save a sheet the button would not.
//
// SCOPE: every tab carries one. Details and Releases were the two that showed the
// auto-focus issue; the others gained theirs for the re-claim below, so that every tab
// starts its keyboard traversal from the same "nothing focused" state.
//
// SINGLE-FIRE, THEN RE-CLAIMED ON ACTIVATION: makeNSView runs exactly once per FilmSheet
// session per tab (the keep-alive architecture never destroys these views); its Task hop
// fires after AppKit's automatic assignment and claims focus for the sink. Every tab passes
// `reclaimWhenActive: selectedTab == <itself>`,
// and the sink claims focus again on each false→true transition — i.e. every time the
// user switches to the tab. The sheet's keyboard traversal begins from "nothing on this
// tab is focused" (a single Tab press lands on the first control; see FilmSheetKeyLoop),
// and that premise has to hold on every visit, not only the first: a control that held
// focus when the user left would otherwise come back with its ring, and a text field
// that held it on another tab would go on taking keystrokes from behind this one. Only
// the transition re-claims, so an update pass with the tab already active — every
// keystroke causes several — never steals focus from the control the user is on.
//
// LAYOUT / KEY-VIEW ORDER: Collapsed to zero height via .frame(height:0).clipped(),
// with zero-size Auto Layout constraints on the NSButton as a belt-and-suspenders
// guarantee it contributes no intrinsic size. Being first in the VStack places it
// first in AppKit's key-view loop, so Tab from the sink advances to the first real
// control in natural top-to-bottom order.
@MainActor
private struct FilmSheetFocusSink: NSViewRepresentable {
    let swallowReturn: Bool
    /// Also claims focus whenever this flips from false to true — see RE-CLAIM ON
    /// ACTIVATION above. Every call site passes `selectedTab == <its own tab>`.
    var reclaimWhenActive: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FilmSheetSinkButton {
        let button = FilmSheetSinkButton(swallowReturn: swallowReturn)
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.title = ""
        button.focusRingType = .none
        button.translatesAutoresizingMaskIntoConstraints = false
        let zeroWidth  = button.widthAnchor.constraint(equalToConstant: 0)
        let zeroHeight = button.heightAnchor.constraint(equalToConstant: 0)
        zeroWidth.priority  = .required
        zeroHeight.priority = .required
        NSLayoutConstraint.activate([zeroWidth, zeroHeight])
        // Claim focus on the next run-loop pass, after the view is in the hierarchy.
        Task { @MainActor in
            unsafe button.window?.makeFirstResponder(button)
        }
        return button
    }

    func updateNSView(_ nsView: FilmSheetSinkButton, context: Context) {
        let wasActive = context.coordinator.wasActive
        context.coordinator.wasActive = reclaimWhenActive
        guard reclaimWhenActive, wasActive == false else { return }
        // Same hop as makeNSView: after the pass that made the tab visible has finished.
        Task { @MainActor in
            unsafe nsView.window?.makeFirstResponder(nsView)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FilmSheetSinkButton,
                      context: Context) -> CGSize? {
        return .zero
    }

    /// The last `reclaimWhenActive` seen, so only a transition re-claims. Starts nil so the
    /// very first update — which follows makeNSView's own claim — is not read as one.
    final class Coordinator {
        var wasActive: Bool? = nil
    }
}

// Custom NSButton used by FilmSheetFocusSink. Always absorbs Space (keyCode 49)
// to prevent a spurious click on the sink itself; optionally absorbs Return
// (keyCode 36) depending on `swallowReturn`. When `swallowReturn` is false,
// Return is forwarded to super so AppKit's responder chain can dispatch it to
// the window's default-action button; when true, Return is silently consumed.
// Tab navigation (keyCode 48) is always handled by super.
private final class FilmSheetSinkButton: NSButton {
    private let swallowReturn: Bool

    init(swallowReturn: Bool) {
        self.swallowReturn = swallowReturn
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // keyCode 49 = Space. keyCode 36 = Return.
        if event.keyCode == 49 { return }
        if swallowReturn, event.keyCode == 36 { return }
        super.keyDown(with: event)
    }

    override func performClick(_ sender: Any?) {}
}
