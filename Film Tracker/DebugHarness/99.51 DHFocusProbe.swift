// MARK: - DHFocusProbe.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// DEBUG-only, opt-in probe for the reported bug where a ReleaseCard date Stepper stops being
// reachable by keyboard while remaining clickable. Armed with `-FTDebugFocus`; observes and
// prints, and changes nothing about how the app behaves.
//
// WHY A PROBE AND NOT A HARNESS SCENARIO
//
// The DebugHarness scenarios are headless: build a corpus, drive production code, assert, exit.
// This bug is not reachable that way. It is a property of AppKit's KEY VIEW LOOP — the chain
// `nextValidKeyView` walks when Tab is pressed — and of which window is active, neither of which
// a headless run has. Worse, the report is that the bug appears and clears on its own across
// application activations, so the thing that has to be captured is a real window in the moment
// it misbehaves, next to the same window in the moment it does not.
//
// WHAT IT ANSWERS
//
// Four hypotheses explain "clicks work, Tab does not". A click goes through hitTest and never
// consults the key view loop, so every one of these is invisible to the mouse:
//
//   1. FULL KEYBOARD ACCESS IS OFF. `NSControl.acceptsFirstResponder` is false for a stepper
//      unless `NSApp.isFullKeyboardAccessEnabled` is true, so with it off no stepper in the app
//      is ever Tab-reachable. Reported as `fka` on every line, because if this is the answer
//      then nothing in the app is at fault and the fix is a Settings toggle.
//
//   2. THE STEPPER IS NOT IN THE LOOP. SwiftUI maintains its own `nextKeyView` chain over the
//      NSViews it hosts. If the chain is stale — the carousel mounts and unmounts cards without
//      rebuilding the view tree around them — a stepper that exists, draws, and clicks can be
//      absent from the chain entirely, and Tab cannot reach what is not in it. `inLoop: no` on
//      a visible, enabled stepper is this case, and `recalculateKeyViewLoop()` is the fix.
//
//   3. THE STEPPER IS IN THE LOOP, BUT SO ARE THE OFF-SCREEN CARDS'. The carousel dims distant
//      cards with `.opacity` and blocks them with `.allowsHitTesting(false)` rather than
//      `.disabled` — a deliberate choice documented at that call site, whose stated known
//      consequence is that their controls stay in the key view loop. Neither opacity nor
//      hit-testing removes a view from it. Tab then walks into invisible cards, and to the
//      person pressing it the visible field simply refuses focus. `offscreen: yes` rows with
//      `inLoop: yes` are this case.
//
//   4. THE STEPPER IS DISABLED IN SWIFTUI ONLY. `ClearableStepperView` never pushes the
//      `isEnabled` environment value onto its NSStepper, so a combo-pack child's date field is
//      gray in SwiftUI and enabled in AppKit. That is reported as `swiftUIDisabled` vs
//      `nsEnabled` disagreeing on the same row.
//
// HOW TO USE IT
//
//   1. Run with `-FTDebugFocus` (it does not need the sandbox — the bug wants a real library).
//   2. Open a film, go to Releases, and press Ctrl+Opt+F. That is the healthy baseline.
//   3. Reproduce: switch to another app and back, however you normally trigger it, and press
//      Ctrl+Opt+F again the moment the Stepper refuses focus.
//   4. Press Tab a few times while it is broken. Every Tab is logged with the first responder
//      before and after, which shows where focus actually goes when it does not go here.
//
// Activation and key-window changes print a one-line summary on their own, so the transitions
// between steps 2 and 3 are in the log without anyone having to press anything.
//
// SINCE THEN: the FilmSheet no longer lets AppKit walk the key view loop at all. Its key
// monitor consumes Tab and FilmSheetKeyLoop (30.01) moves first responder itself — over the
// current card's controls on the Releases tab, over the active tab's elsewhere — by geometry — so hypotheses 2 and 3 cannot produce the symptom any
// more, and the `inLoop` column describes a chain that Tab no longer follows there. The TAB
// lines still show where focus actually lands, which is the probe's remaining use.

#if DEBUG

import AppKit
import Foundation

@MainActor
final class DebugFocusProbe {
    static let shared = DebugFocusProbe()

    /// Opt-in, and deliberately NOT gated on `DebugSandbox.isActive`: the bug is reported against
    /// a real library, and this type only reads AppKit state and prints. It never touches the
    /// store, the caches, or any view state — and in particular it never calls
    /// `makeFirstResponder` or `recalculateKeyViewLoop`, either of which would repair the very
    /// condition it exists to observe.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-FTDebugFocus")
    }

    private init() {}

    private var installed = false
    private var keyMonitor: Any?
    private var observers: [any NSObjectProtocol] = []

    // MARK: - Install

    func installIfNeeded() {
        guard Self.isEnabled, !installed else { return }
        installed = true

        // Ctrl+Opt+F dumps a report; Tab is logged as it passes through. The monitor always
        // returns the event — nothing here consumes a key, so arming the probe cannot change
        // which control ends up focused.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // keyCode 3 = F, keyCode 48 = Tab.
            if event.keyCode == 3, event.normalizedModifiers == [.control, .option] {
                self.report("MANUAL (Ctrl+Opt+F)")
                return event
            }
            if event.keyCode == 48 {
                let before = Self.describe(NSApp.keyWindow?.firstResponder)
                // Read the destination on the next run-loop pass: AppKit has not moved first
                // responder yet at keyDown time, and the whole question is where it lands.
                Task { @MainActor in
                    let after = Self.describe(NSApp.keyWindow?.firstResponder)
                    Self.emit("TAB  \(before)  ->  \(after)")
                }
            }
            return event
        }

        for name: Notification.Name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.willResignActiveNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                // The notification's own object is deliberately not read: passing it into the
                // main-actor context is a Sendable violation, and the question these lines
                // answer — which window is key at each transition — is answered by asking
                // NSApp on the main actor, which is where the answer has to come from anyway.
                MainActor.assumeIsolated {
                    let label = name.rawValue
                        .replacingOccurrences(of: "NSApplication", with: "app.")
                        .replacingOccurrences(of: "NSWindow", with: "win.")
                    Self.emit("EVENT \(label) | key: \(Self.summary(of: NSApp.keyWindow))"
                              + " | fr: \(Self.describe(NSApp.keyWindow?.firstResponder))")
                }
            }
            observers.append(token)
        }

        Self.emit("armed — Ctrl+Opt+F for a report")
    }

    // MARK: - Report

    /// Full census of the key window's steppers and key view loop.
    func report(_ label: String) {
        guard let window = NSApp.keyWindow else {
            Self.emit("\(label): no key window")
            return
        }
        guard let content = window.contentView else {
            Self.emit("\(label): key window has no content view")
            return
        }

        // The key view loop, in order. Cycle-guarded (it is circular by design) and capped, so a
        // malformed chain reports a number rather than hanging the main thread. Membership is
        // taken from THIS set rather than from `acceptsFirstResponder`, because the two can
        // disagree and that disagreement is hypothesis 2.
        var loop: [NSView] = []
        var seen = Set<ObjectIdentifier>()
        var node = unsafe content.nextValidKeyView
        while let current = node, loop.count < 10_000 {
            guard seen.insert(ObjectIdentifier(current)).inserted else { break }
            loop.append(current)
            node = unsafe current.nextValidKeyView
        }
        let loopMembers = Set(loop.map(ObjectIdentifier.init))

        // Every stepper in the window, in tree order, whether or not the loop knows about it.
        var steppers: [NSStepper] = []
        var stack: [NSView] = [content]
        while let view = stack.popLast() {
            if let stepper = view as? NSStepper { steppers.append(stepper) }
            stack.append(contentsOf: view.subviews.reversed())
        }

        var out = "\n===FOCUS-REPORT: \(label)===\n"
        unsafe out += String(format: "fka %@ | active %@ | keyWindow %@\n",
                      NSApp.isFullKeyboardAccessEnabled ? "ON" : "OFF",
                      NSApp.isActive ? "yes" : "no",
                      Self.summary(of: window))
        out += "firstResponder: \(Self.describe(window.firstResponder))\n"
        unsafe out += String(format: "keyViewLoop: %d entries | autorecalculates %@\n",
                      loop.count, window.autorecalculatesKeyViewLoop ? "yes" : "no")
        out += "steppers in window: \(Fmt.int(steppers.count)) (\(Fmt.int(steppers.filter { loopMembers.contains(ObjectIdentifier($0)) }.count)) of them in the loop)\n"

        let visible = content.bounds
        for (i, stepper) in steppers.enumerated() {
            let frame = stepper.convert(stepper.bounds, to: content)
            // Off-screen in the sense that matters here: the carousel parks distant cards
            // outside the content view's bounds and fades them to nothing. Either alone is
            // enough to make a focused control invisible to the person who focused it.
            let offscreen = !visible.intersects(frame) || Self.effectiveAlpha(of: stepper) < 0.01
            unsafe out += String(
                format: "  [%02d] %@ inLoop %-3@ accepts %-3@ nsEnabled %-3@ hidden %-3@ "
                      + "alpha %.2f offscreen %-3@ frame %.0f,%.0f %.0fx%.0f\n",
                i,
                stepper is ClearableNSStepper ? "clearable" : "plain    ",
                loopMembers.contains(ObjectIdentifier(stepper)) ? "yes" : "NO",
                stepper.acceptsFirstResponder ? "yes" : "NO",
                stepper.isEnabled ? "yes" : "no",
                stepper.isHiddenOrHasHiddenAncestor ? "yes" : "no",
                Self.effectiveAlpha(of: stepper),
                offscreen ? "yes" : "no",
                frame.origin.x, frame.origin.y, frame.width, frame.height)
        }
        out += "===FOCUS-REPORT-END===\n"
        printToStandardError(out)
    }

    // MARK: - Formatting

    /// Product of `alphaValue` up the superview chain. A single view's own alpha says nothing —
    /// the carousel fades a whole card, not the stepper inside it.
    private static func effectiveAlpha(of view: NSView) -> CGFloat {
        var alpha: CGFloat = 1
        var node: NSView? = view
        while let current = node {
            alpha *= current.alphaValue
            node = unsafe current.superview
        }
        return alpha
    }

    private static func describe(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        let name = String(describing: type(of: responder))
        guard let view = responder as? NSView else { return name }
        let frame = view.convert(view.bounds, to: nil)
        return unsafe String(format: "%@(%.0f,%.0f %.0fx%.0f a%.2f)",
                      name, frame.origin.x, frame.origin.y, frame.width, frame.height,
                      effectiveAlpha(of: view))
    }

    private static func summary(of window: NSWindow?) -> String {
        guard let window else { return "nil" }
        return String(describing: type(of: window))
            + (window.isSheet ? " [sheet]" : "")
            + (window.attachedSheet != nil ? " [has sheet]" : "")
    }

    private static func emit(_ message: String) {
        printToStandardError("[DebugFocus] \(message)\n")
    }
}

#endif
