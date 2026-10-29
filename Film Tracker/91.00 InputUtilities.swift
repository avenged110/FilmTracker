// MARK: - InputUtilities.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Reusable utilities for collecting and parsing user input, guaranteeing safe, validated data.

import SwiftUI

// MARK: - Shared Color Constants
// Constructed once at process launch — avoids repeated bridging allocations on every
// render of TimeStepper, DurationStepper and CustomDateStepper.
private let tertiaryLabelColor   = Color(NSColor.tertiaryLabelColor)
// The Steppers' fill and border are `stepperChrome(filled:)` (90.00 GlobalUtilities.swift),
// shared with FSControlHelpers.swift's so the two files' Steppers cannot drift.

// MARK: - Digit Test
extension Character {
    /// True for the ten ASCII digits "0"–"9" and nothing else.
    ///
    /// The one test every digit-only input in the app uses. Not `isNumber`, which is true
    /// for any Unicode numeric character — "½", "Ⅻ", Arabic-Indic "٣", CJK "三" — all of
    /// which it let through into fields meant for US-style digits (currency, time codes,
    /// frame numbers, external IDs), where they then failed to parse or produced broken
    /// links. The app targets a US, English-language audience; these are the only digits
    /// it accepts.
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

// MARK: - Modifier-Key Normalization
extension NSEvent {
    /// The event's modifier flags reduced to actual modifier-key *intent*.
    ///
    /// Two reductions, and the second is the one that matters:
    ///   1. Intersect with `.deviceIndependentFlagsMask`, dropping the device-specific
    ///      hardware bits in the lower 16 bits (mouse buttons, JIS keys) that carry no
    ///      modifier-key meaning.
    ///   2. Subtract `.capsLock`. CapsLock IS part of `.deviceIndependentFlagsMask`
    ///      (0x10000), so any exact test — `== .command`, `== [.command, .shift]`,
    ///      `.isEmpty` — silently stops matching the moment CapsLock is engaged.
    ///
    /// CapsLock is a toggle state, not a held modifier. No macOS key equivalent can
    /// include it, and a user with it switched on is not asking for different
    /// shortcuts — so letting it gate a shortcut only ever produces the bug where
    /// "the keyboard shortcuts randomly stopped working."
    ///
    /// Use this anywhere an exact comparison against a modifier set is made.
    /// `.contains(…)` tests are already tolerant of extra flags and do not need it.
    ///
    /// Character matching is unaffected and needs no parallel treatment:
    /// `charactersIgnoringModifiers` reports "D" rather than "d" while CapsLock is on,
    /// which callers already fold away with `.lowercased()`; digit keys are not
    /// case-mapped at all.
    var normalizedModifiers: NSEvent.ModifierFlags {
        modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
    }
}

// MARK: - Clearable NSStepper Infrastructure
//
// SwiftUI's .onKeyPress modifier only fires when SwiftUI itself owns the focus state
// for the view. When AppKit's Tab-navigation focus ring lands on a NSStepper, AppKit
// owns first-responder status and SwiftUI never receives key events for that stepper.
// NSEvent local monitors see the event, but identifying *which* stepper is focused
// via type names or accessibility identifiers is fragile and unreliable.
//
// The correct solution: subclass NSStepper and override keyDown(with:) directly.
// ClearableNSStepper intercepts keyCode 51 (the Delete/Backspace key, no modifiers)
// before the event reaches the AppKit responder chain, calls the registered onDelete
// closure, and marks the event handled. Everything else — arrows, space, etc. — is
// forwarded to super so NSStepper's native increment/decrement behavior is preserved.
//
// ClearableStepperView bridges this into SwiftUI as an NSViewRepresentable. It
// replaces SwiftUI's Stepper only at call sites that need Delete-clear behavior;
// every other stepper in the codebase continues using the standard Stepper view.

// MARK: ClearableNSStepper
/// NSStepper subclass that intercepts the Delete key (keyCode 51) and calls onDelete.
/// All other key events are forwarded to super unchanged.
final class ClearableNSStepper: NSStepper {
    /// Called when the Delete key is pressed with no modifier keys while this stepper
    /// holds the AppKit focus ring. Set by ClearableStepperView's Coordinator.
    var onDelete: (() -> Void)?

    /// AppKit's intrinsic size per control size and appearance, shared by every stepper.
    ///
    /// Auto Layout asks each stepper for its intrinsic size on every constraint pass, and
    /// NSStepper answers with a CoreUI metrics query rather than a stored value. The FilmSheet
    /// carries several (Release Date, User Rating, Duration, and more on every release card),
    /// so the `filmsheet-perf` harness scenario's open loop sampled that query as one of the
    /// largest AppKit costs in the Details tab's first layout. The answer depends only on
    /// what the key holds, so it is measured once per key.
    private struct IntrinsicSizeKey: Hashable {
        let controlSize: UInt
        let appearance: NSAppearance.Name
    }
    private static var intrinsicSizes: [IntrinsicSizeKey: NSSize] = [:]

    override var intrinsicContentSize: NSSize {
        let key = IntrinsicSizeKey(controlSize: controlSize.rawValue,
                                   appearance: effectiveAppearance.name)
        if let size = Self.intrinsicSizes[key] { return size }
        let size = super.intrinsicContentSize
        Self.intrinsicSizes[key] = size
        return size
    }

    override func keyDown(with event: NSEvent) {
        // keyCode 51 is the Delete (Backspace) key on all standard Mac keyboards.
        // Only intercept when no intentional modifier keys are held — plain Delete only.
        //
        // `normalizedModifiers` (above) is what makes the isEmpty test honest: it drops
        // the device-specific hardware bits and, critically, CapsLock — which would
        // otherwise leave this non-empty and silently block Delete-clear for anyone with
        // CapsLock toggled on. This file's local copy of that reduction was the original
        // of the shared definition, which KeyboardManager and SettingsSheet now use too.
        if event.keyCode == 51 && event.normalizedModifiers.isEmpty, let onDelete {
            onDelete()
            return  // Event handled — do NOT call super, which would produce the beep.
        }
        super.keyDown(with: event)
    }
}

// MARK: ClearableStepperView
/// NSViewRepresentable wrapping ClearableNSStepper. Exposes the same increment /
/// decrement callbacks and value/range binding as the portions of SwiftUI's Stepper
/// that DurationStepper and CustomDateStepper use internally. The label content
/// (Text views) is kept as SwiftUI views in the parent HStack; only the stepper
/// control (the +/− button pair) is bridged here.
struct ClearableStepperView: NSViewRepresentable {
    /// The caller's live value. Retained as part of the call-site API (and as the
    /// natural place for a future value-driven behavior), but no longer pushed into
    /// the NSStepper: the control's own number is a step delta, not the value.
    @Binding var value: Int
    /// The caller's logical range. Likewise NOT handed to AppKit — every caller wraps
    /// within this range inside its own step closures, and giving the control the same
    /// bounds is precisely what stopped a click on a bound from wrapping.
    let range: ClosedRange<Int>
    let onIncrement: () -> Void
    let onDecrement: () -> Void
    /// Called when the Delete key is pressed with no modifier while this stepper
    /// holds the AppKit focus ring. Pass nil for steppers that do not need clearing.
    let onDelete: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ClearableNSStepper {
        let stepper = ClearableNSStepper()
        // MARK: Neutral-centered range — NOT the logical range
        //
        // The control is deliberately given a huge symmetric range centered on zero
        // rather than `range`, and its doubleValue is parked back at the center after
        // every click (see stepperChanged). Every caller of this view wraps its own
        // value in the onIncrement / onDecrement closures, so the NSStepper is used
        // purely as a direction-reporting device — its own number is never displayed.
        //
        // Handing AppKit the logical range instead is what broke wrapping at a bound.
        // NSStepper clamps doubleValue to min/max, and with valueWraps == false a click
        // that cannot change the value may send no action at all — so a Stepper sitting
        // ON its ceiling (a base-release-year field whose range is capped by a locked
        // release year, or any single-year range) could not be stepped forward to wrap
        // around to its floor. The boundary-equality branch below was an attempt to
        // recover the intent after the fact; with a range the value can never reach,
        // the action always fires and the direction is always unambiguous.
        stepper.minValue  = -1_000_000
        stepper.maxValue  =  1_000_000
        stepper.doubleValue = 0
        stepper.increment = 1
        stepper.isContinuous = false
        stepper.autorepeat   = true
        stepper.valueWraps   = false
        stepper.target = context.coordinator
        stepper.action = #selector(Coordinator.stepperChanged(_:))
        stepper.onDelete = onDelete
        // Constrain the stepper to its natural size — the same intrinsic size AppKit
        // assigns to NSStepper controls rendered by SwiftUI's own Stepper bridge.
        stepper.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        stepper.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return stepper
    }

    func updateNSView(_ stepper: ClearableNSStepper, context: Context) {
        // MARK: Re-point the coordinator at the CURRENT representable
        //
        // This is the first thing the method does, and it is not bookkeeping — it is what
        // makes every other value here reachable from the click handler.
        //
        // `makeCoordinator()` captures the representable struct as it existed when the
        // NSView was first created, and the coordinator is what AppKit calls back into.
        // Without this line the coordinator keeps invoking the `onIncrement`/`onDecrement`
        // closures from that FIRST construction — closures which have captured, by value,
        // the `yearRange` and the `@Binding`s of whatever the parent view was showing at
        // the time. Everything downstream of a click therefore froze at first mount:
        //
        //   • the wrap bounds. A release card's base-year Stepper caps its range at the
        //     release year, and a merged combo pack re-points ONE card at
        //     a different release (a 4K parent, floor 2016, and its bundled Blu-ray, floor
        //     2006) without rebuilding the view tree. The stale closure kept applying the
        //     range it was born with, which is why a bundled Blu-ray's base-release-year
        //     Stepper refused to go below the 4K parent's floor.
        //   • the bindings. `hasValue` and the year binding still addressed the PREVIOUS
        //     release, so the first click on a swapped-in card activated the other release's
        //     field: the visible Stepper's own `hasValue` stayed false — it rendered as an
        //     un-activated placeholder while its number moved — and because
        //     `enforceReleaseYearOrder` returns early unless BOTH of a release's year flags
        //     are set, the ordering rule never engaged and a base year could be walked past
        //     the release year it qualifies.
        //
        // SwiftUI reconstructs the representable on every parent body pass and calls this
        // method with it, so assigning here keeps the callbacks exactly as current as the
        // view that declared them.
        context.coordinator.parent = self

        stepper.onDelete = onDelete

        // MARK: Mirror SwiftUI's isEnabled onto the AppKit control
        //
        // SwiftUI's `.disabled(...)` writes an ENVIRONMENT value. It reaches the SwiftUI views
        // in this picker — which is why a combo-pack child's date field draws gray — and it does
        // not reach the NSStepper at all, because nothing was reading it here. So the control
        // stayed enabled in AppKit: it accepted clicks (stepping a field the card is not allowed
        // to edit) and, being an enabled NSControl, it stayed a legal Tab stop.
        //
        // Both halves of the treatment match DigitTextField's, in this same file, which hit the
        // identical problem: `isEnabled` for hit-testing and drawing, and `refusesFirstResponder`
        // as the AppKit-level backstop so the Tab-key responder chain SKIPS the control outright
        // rather than merely landing on something that will not respond. The second is the one
        // that matters for keyboard navigation — `isEnabled == false` alone does not always take
        // a control out of the key view loop, and a dead Tab stop is indistinguishable, to the
        // person pressing Tab, from focus having vanished.
        //
        // Read from `context.environment` rather than an `@Environment` property: a
        // representable has no view body, and this method is called on every SwiftUI update
        // pass, so the environment here is always current.
        let enabled = context.environment.isEnabled
        stepper.isEnabled = enabled
        stepper.refusesFirstResponder = !enabled

        // The control's own number carries no meaning (see makeNSView) — it is only ever
        // read as a delta from the neutral center, so it is re-parked here as well as in
        // the action handler. min/max are fixed and are deliberately NOT re-derived from
        // `range`: the logical range lives entirely in the caller's step closures.
        stepper.doubleValue = 0
    }

    // MARK: Coordinator
    @MainActor
    final class Coordinator: NSObject {
        var parent: ClearableStepperView

        init(_ parent: ClearableStepperView) {
            self.parent = parent
        }

        @objc func stepperChanged(_ sender: ClearableNSStepper) {
            // The control is parked at zero between clicks and its range is far wider
            // than any click can travel (see makeNSView), so the value AppKit reports
            // here is exactly the signed step the user asked for: +1 for the up button,
            // −1 for the down button, and never zero. No boundary case exists, which is
            // what lets a Stepper sitting on either end of its logical range still wrap
            // around to the other end — the caller's closure does the wrapping.
            //
            // Re-parked immediately rather than waiting for updateNSView: an autorepeat
            // burst can deliver several actions before SwiftUI runs another update pass,
            // and each of them must read as a fresh single step from zero.
            let delta = sender.doubleValue
            sender.doubleValue = 0
            if delta > 0 {
                parent.onIncrement()
            } else if delta < 0 {
                parent.onDecrement()
            }
        }
    }
}

// MARK: - Time Stepper Component
struct TimeStepper: View {
    @Binding var hour: Int
    @Binding var minute: Int
    @Binding var isAM: Bool

    // @State mirror of the SwiftUI isEnabled environment value.
    //
    // WHY NOT @Environment(\.isEnabled) directly in the background modifier:
    // Reading @Environment(\.isEnabled) in a view body modifier registers isEnabled
    // as a live SwiftUI dependency of the view. If TimeStepper is ever placed inside
    // an animated context where .disabled() flips mid-animation (e.g. a carousel
    // applying .disabled(index != idx) per card), that flip triggers a body
    // re-evaluation inside the active animation transaction, causing the background
    // fill change to be picked up by — and animated along with — the surrounding
    // transition. The @State mirror pattern breaks this dependency: the background
    // modifier reads isEnabledState (@State), whose transitions are explicitly
    // instant via withAnimation(nil), and isEnabledEnv (@Environment) is only
    // read in onAppear and onChange — neither of which participates in animation
    // dependency tracking. Matches the identical pattern in CustomDateStepper.
    @Environment(\.isEnabled) private var isEnabledEnv
    @State private var isEnabledState: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            // Time input container (hours:minutes with border)
            HStack(spacing: 4) {
                // Hour stepper (no range - we handle wrapping manually)
                Stepper(
                    onIncrement: {
                        hour = hour >= 12 ? 1 : hour + 1
                    },
                    onDecrement: {
                        hour = hour <= 1 ? 12 : hour - 1
                    }
                ) {
                    Text(Fmt.padded(hour, 2))
                        .font(.system(size: 14))
                        .frame(width: 20, alignment: .trailing)
                }

                Text(":")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                // Minute stepper (no range - we handle wrapping manually, 5-minute increments)
                Stepper(
                    onIncrement: {
                        minute = minute >= 55 ? 0 : minute + 5
                    },
                    onDecrement: {
                        minute = minute <= 0 ? 55 : minute - 5
                    }
                ) {
                    Text(Fmt.padded(minute, 2))
                        .font(.system(size: 14))
                        .frame(width: 18, alignment: .trailing)
                }
            }
            // 1 pt tighter a side than the original 8 / 4 / 4, matching CustomDateStepper.
            .padding(.leading, 7)
            .padding(.trailing, 3)
            .padding(.vertical, 3)
            // isEnabledState is the @State mirror of isEnabledEnv (see declaration
            // above). Using it here — rather than the live @Environment value —
            // prevents the background fill from being registered as an animation
            // dependency of isEnabled, keeping fill transitions instant and isolated
            // from any ambient transaction that may be active in the parent.
            .stepperChrome(filled: isEnabledState)

            // AM/PM picker
            Picker("", selection: $isAM) {
                Text("AM").tag(true)
                Text("PM").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 80)
            .foregroundStyle(.primary)
        }
        .onAppear {
            // Seed the mirror from the live environment value on first mount so
            // the initial fill is correct before any onChange fires.
            isEnabledState = isEnabledEnv
        }
        // Mirror isEnabledEnv into isEnabledState with an explicit nil animation
        // so the fill transition is instant and never picked up by an ambient
        // spring or ease transaction active in the parent hierarchy.
        .onChange(of: isEnabledEnv) { _, newValue in
            withAnimation(nil) { isEnabledState = newValue }
        }
    }
}

// MARK: - Duration Stepper Component
struct DurationStepper: View {
    @Binding var hours: Int
    @Binding var minutes: Int
    @Binding var hasValue: Bool
    /// Optional closure called when the Delete key is pressed while either
    /// sub-stepper holds the AppKit focus ring. When provided, the stepper
    /// is bridged through ClearableStepperView so the key event is intercepted
    /// at the NSStepper level before it reaches the responder chain.
    var onDelete: (() -> Void)? = nil

    // @State mirror of the SwiftUI isEnabled environment value — see TimeStepper
    // and CustomDateStepper for the full rationale. Reading @Environment(\.isEnabled)
    // directly in the background modifier registers isEnabled as a live animation
    // dependency, which causes fill changes to be swept into any ambient transaction
    // active in the parent (e.g. a card carousel spring). The mirror pattern breaks
    // that dependency: the background reads isEnabledState (@State) whose transitions
    // are forced instant via withAnimation(nil), while isEnabledEnv is only consumed
    // in onAppear and onChange — safe, non-animation-tracked contexts.
    @Environment(\.isEnabled) private var isEnabledEnv
    @State private var isEnabledState: Bool = true
    @State private var isInteracting: Bool = false

    /// True when the hours stepper holds a non-zero value that the user has
    /// deliberately set. Specifically, it is set to `hours > 0` after every
    /// hours-stepper step, meaning:
    ///
    /// - It becomes `true` only when the resulting hours value is greater than 0.
    /// - It reverts to `false` if the user steps hours back down to 0.
    ///
    /// While `false` (hours is 0, whether untouched or user-zeroed), the minute
    /// stepper is permitted to auto-manage the hours value — setting 1h when
    /// minutes reach 0, clearing it when minutes move away from 0. While `true`
    /// (hours is a non-zero user-committed value), the auto-hour rule is suppressed
    /// so that a deliberately set hour value is never silently overwritten.
    /// Reset to `false` when the field is cleared via Delete.
    @State private var hoursSetByUser: Bool = false

    /// Mirror of `hoursSetByUser` for the minutes component. True when the minutes
    /// stepper holds a non-zero value the user has deliberately set (`minutes > 0`
    /// after a minute-stepper step). While `false`, the hours stepper is permitted
    /// to auto-manage the minutes value — setting 1m when hours reach 0, clearing
    /// it when hours move away from 0. While `true`, the auto-minute rule is
    /// suppressed so a deliberately set minute value is never silently overwritten.
    /// Reset to `false` when the field is cleared via Delete.
    @State private var minutesSetByUser: Bool = false
    
    var body: some View {
        HStack(spacing: 4) {
            // Hours stepper (0-9)
            if let onDelete {
                // ClearableStepperView intercepts Delete at the NSStepper level.
                // The label Text views are kept as SwiftUI siblings in the HStack,
                // matching the visual layout of the standard Stepper alternative below.
                HStack(spacing: 4) {
                    Text("\(hours)")
                        .font(.system(size: 14))
                        .foregroundStyle(textColor)
                        .frame(width: 10, alignment: .trailing)
                        .monospacedDigit()
                    Text(hours == 1 ? "hour" : "hours")
                        .font(.system(size: 14))
                        .foregroundStyle(textColor)
                        .frame(width: 38, alignment: .leading)
                    ClearableStepperView(
                        value: $hours,
                        range: 0...9,
                        onIncrement: {
                            if shouldActivateInsteadOfIncrement(isHoursComponent: true) { return }
                            hours = hours >= 9 ? 0 : hours + 1
                            hoursSetByUser = hours > 0
                            applyAutoMinuteRule()
                        },
                        onDecrement: {
                            if shouldActivateInsteadOfIncrement(isHoursComponent: true) { return }
                            hours = hours <= 0 ? 9 : hours - 1
                            hoursSetByUser = hours > 0
                            applyAutoMinuteRule()
                        },
                        onDelete: onDelete
                    )
                }
            } else {
                Stepper(
                    onIncrement: {
                        if shouldActivateInsteadOfIncrement(isHoursComponent: true) { return }
                        hours = hours >= 9 ? 0 : hours + 1
                        hoursSetByUser = hours > 0
                        applyAutoMinuteRule()
                    },
                    onDecrement: {
                        if shouldActivateInsteadOfIncrement(isHoursComponent: true) { return }
                        hours = hours <= 0 ? 9 : hours - 1
                        hoursSetByUser = hours > 0
                        applyAutoMinuteRule()
                    }
                ) {
                    HStack(spacing: 4) {
                        Text("\(hours)")
                            .font(.system(size: 14))
                            .foregroundStyle(textColor)
                            .frame(width: 10, alignment: .trailing)
                            .monospacedDigit()
                        Text(hours == 1 ? "hour" : "hours")
                            .font(.system(size: 14))
                            .foregroundStyle(textColor)
                            .frame(width: 38, alignment: .leading)
                    }
                }
            }
            
            // Minutes stepper (0-59)
            if let onDelete {
                HStack(spacing: 4) {
                    Text("\(minutes)")
                        .font(.system(size: 14))
                        .foregroundStyle(textColor)
                        .frame(width: 20, alignment: .trailing)
                        .monospacedDigit()
                    Text(minutes == 1 ? "minute" : "minutes")
                        .font(.system(size: 14))
                        .foregroundStyle(textColor)
                        .frame(width: 52, alignment: .leading)
                    ClearableStepperView(
                        value: $minutes,
                        range: 0...59,
                        onIncrement: {
                            if shouldActivateInsteadOfIncrement(isHoursComponent: false) { return }
                            minutes = minutes >= 59 ? 0 : minutes + 1
                            minutesSetByUser = minutes > 0
                            applyAutoHourRule()
                        },
                        onDecrement: {
                            if shouldActivateInsteadOfIncrement(isHoursComponent: false) { return }
                            minutes = minutes <= 0 ? 59 : minutes - 1
                            minutesSetByUser = minutes > 0
                            applyAutoHourRule()
                        },
                        onDelete: onDelete
                    )
                }
            } else {
                Stepper(
                    onIncrement: {
                        if shouldActivateInsteadOfIncrement(isHoursComponent: false) { return }
                        minutes = minutes >= 59 ? 0 : minutes + 1
                        minutesSetByUser = minutes > 0
                        applyAutoHourRule()
                    },
                    onDecrement: {
                        if shouldActivateInsteadOfIncrement(isHoursComponent: false) { return }
                        minutes = minutes <= 0 ? 59 : minutes - 1
                        minutesSetByUser = minutes > 0
                        applyAutoHourRule()
                    }
                ) {
                    HStack(spacing: 4) {
                        Text("\(minutes)")
                            .font(.system(size: 14))
                            .foregroundStyle(textColor)
                            .frame(width: 20, alignment: .trailing)
                            .monospacedDigit()
                        Text(minutes == 1 ? "minute" : "minutes")
                            .font(.system(size: 14))
                            .foregroundStyle(textColor)
                            .frame(width: 52, alignment: .leading)
                    }
                }
            }
        }
        // 1 pt tighter a side than the original 8 / 4 / 4, matching CustomDateStepper.
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .padding(.vertical, 3)
        // isEnabledState is the @State mirror of isEnabledEnv (see declaration
        // above). Using it here — rather than the live @Environment value —
        // prevents the background fill from being registered as an animation
        // dependency of isEnabled, keeping fill transitions instant and isolated
        // from any ambient transaction that may be active in the parent.
        .stepperChrome(filled: isEnabledState)
        .onAppear {
            // Seed the isEnabled mirror from the live environment value on first
            // mount so the initial fill is correct before any onChange fires.
            isEnabledState = isEnabledEnv
            // Reset interaction state when view appears.
            isInteracting = false
            // Seed the "set by user" flags from the incoming binding values so
            // that a pre-populated duration (e.g. loaded from import data) is
            // treated as if the user had deliberately entered both components.
            // Without this, hoursSetByUser and minutesSetByUser both default to
            // false regardless of the binding values, causing applyAutoHourRule /
            // applyAutoMinuteRule to incorrectly zero out the pre-loaded component
            // the first time the other stepper is stepped (e.g. incrementing
            // minutes from 50 to 51 on a "1 hour 50 minutes" value would clear
            // hours back to 0 via the `else if hours == 1` auto-correction branch).
            if hasValue {
                hoursSetByUser   = hours > 0
                minutesSetByUser = minutes > 0
            }
        }
        // Mirror isEnabledEnv into isEnabledState with an explicit nil animation
        // so the fill transition is instant and never picked up by an ambient
        // spring or ease transaction active in the parent hierarchy.
        .onChange(of: isEnabledEnv) { _, newValue in
            withAnimation(nil) { isEnabledState = newValue }
        }
        .onChange(of: hasValue) { _, newValue in
            // When the field is externally cleared via the Delete key: reset all
            // local state so the placeholder color and display values are restored,
            // and the auto-hour rule is eligible to fire again on the next session.
            if !newValue {
                isInteracting    = false
                hoursSetByUser   = false
                minutesSetByUser = false
                hours            = 0
                minutes          = 0
            }
        }
    }
    
    // MARK: - Computed Properties
    
    /// Determines the text color based on whether the field has a value and if user is interacting
    private var textColor: Color {
        (hasValue || isInteracting) ? .primary : tertiaryLabelColor
    }
    
    // MARK: - Helpers

    /// Checks if this is the first interaction and should only activate (not change value).
    ///
    /// On activation the field seeds an initial live state that reflects which component
    /// was clicked, guaranteeing the picker never enters the invalid 0h 0m position:
    /// - Hours stepper click  → 1 hour  / 0 minutes  (`isHoursComponent: true`)
    /// - Minutes stepper click → 0 hours / 1 minute  (`isHoursComponent: false`)
    ///
    /// Returns true if the click should be consumed (field was just activated).
    private func shouldActivateInsteadOfIncrement(isHoursComponent: Bool) -> Bool {
        if !hasValue && !isInteracting {
            isInteracting = true
            hasValue      = true
            if isHoursComponent {
                hours            = 1
                minutes          = 0
                // The seeded hour is a deliberate user value — the user clicked
                // the hours stepper to activate the field. Mark it user-committed
                // so applyAutoHourRule() does not later treat it as a disposable
                // auto-promoted hour and zero it out when minutes is stepped.
                hoursSetByUser   = true
                minutesSetByUser = false
            } else {
                hours            = 0
                minutes          = 1
                // Symmetric to the hours branch: the seeded minute is a deliberate
                // user value (the user clicked the minutes stepper), so mark it
                // user-committed to protect it from applyAutoMinuteRule() when the
                // hours stepper is later stepped.
                minutesSetByUser = true
                hoursSetByUser   = false
            }
            return true
        }
        return false
    }

    /// Applies the auto-hour rule after a minute stepper step.
    ///
    /// While `hoursSetByUser` is false (hours is 0, untouched or user-zeroed),
    /// the rule manages the hours value on behalf of the user:
    /// - minutes → 0: hours promoted to 1 so the total remains non-zero.
    /// - minutes → non-zero while hours == 1: the auto-promoted hour is cleared
    ///   back to 0, restoring the pure-minute representation.
    ///
    /// Suppressed when `hoursSetByUser` is true (hours holds a non-zero
    /// user-committed value that must not be silently overwritten).
    /// See `applyAutoMinuteRule()` for the symmetric counterpart.
    private func applyAutoHourRule() {
        guard !hoursSetByUser else { return }
        if minutes == 0 {
            hours = 1
        } else if hours == 1 {
            hours = 0
        }
    }

    /// Applies the auto-minute rule after an hours stepper step.
    ///
    /// Symmetric counterpart to `applyAutoHourRule()`. While `minutesSetByUser`
    /// is false (minutes is 0, untouched or user-zeroed), the rule manages the
    /// minutes value on behalf of the user:
    /// - hours → 0: minutes promoted to 1 so the total remains non-zero.
    /// - hours → non-zero while minutes == 1: the auto-promoted minute is cleared
    ///   back to 0, restoring the pure-hour representation.
    ///
    /// Suppressed when `minutesSetByUser` is true (minutes holds a non-zero
    /// user-committed value that must not be silently overwritten).
    private func applyAutoMinuteRule() {
        guard !minutesSetByUser else { return }
        if hours == 0 {
            minutes = 1
        } else if minutes == 1 {
            minutes = 0
        }
    }
}

// MARK: - Custom Date Stepper Component
struct CustomDateStepper: View {
    private enum Mode {
        case fullDate
        case yearOnly
    }
    
    private let mode: Mode
    @Binding private var date: Date
    @Binding private var hasValue: Bool
    private let yearRange: ClosedRange<Int>
    /// Optional lower-bound clamp (full-date mode only). When set, any stepper action
    /// (month, day, or year) that would otherwise produce a date earlier than minDate
    /// is clamped to minDate instead. `nil` — the default — applies no clamp. Existing,
    /// already-stored values below minDate are left untouched on load/sync; the clamp
    /// only engages as a consequence of the user actively stepping a field, mirroring
    /// how yearRange only constrains stepper wrap-around rather than rewriting the
    /// initial display value.
    private let minDate: Date?
    /// Optional upper bound (full-date mode only). When set, the range loops: each field
    /// steps independently through its own values, skipping any that would carry the date
    /// past this ceiling or the floor — minDate, or January 1 of yearRange's lower bound when
    /// there is none — and wrapping from one end to the other. See loopStep.
    /// `nil` — the default — applies no ceiling and leaves minDate's hard clamp unchanged.
    private let maxDate: Date?
    /// Optional closure called when the Delete key is pressed while any sub-stepper
    /// holds the AppKit focus ring. When provided, steppers are bridged through
    /// ClearableStepperView so the key event is intercepted at the NSStepper level.
    private let onDelete: (() -> Void)?
    /// Year the un-activated placeholder displays, and the year the activating click
    /// commits (year-only mode). `nil` — the default, and what every call site but one
    /// passes — keeps the original behavior: the placeholder shows the current calendar
    /// year, and activation commits whatever the bound value already held.
    ///
    /// The placeholder is a promise: it shows the value the first click is about to
    /// produce, which is why an *enabled* placeholder shows a year rather than dashes
    /// (see `yearDisplayText`). One field cannot keep that promise on its own. A release
    /// card's base release year is capped at `releaseYear - 1` and can only be activated
    /// while a release year exists, so it activates at that cap, never at the current
    /// year — the generic placeholder named a year the click could not deliver.
    ///
    /// Passing the cap here makes the promise true at both ends: the placeholder tracks
    /// the release-year Stepper live, and the activating click commits exactly the year
    /// it was showing rather than leaving the value the ordering rule happened to find.
    /// That second half matters on a field the user has cleared and is re-activating,
    /// where the model still carries the year it last held — a year the placeholder was
    /// not showing and, being already below the release year, one no correction moves.
    ///
    /// Ignored in full-date mode, which has no single-value placeholder to speak of.
    private let placeholderYear: Int?

    /// Full-date mode only: true while the bound value is a date known only by its YEAR — a
    /// compatibility state for values stored before the field held full dates. `date`
    /// carries the year; its month and day are ignored and drawn as dashes.
    ///
    /// The user cannot produce this state, only display it. The first click on ANY of the
    /// three steppers activates the field the way a blank field's first click does — it
    /// steps nothing — filling the month and day from today and keeping the year, and
    /// writes false here. Delete clears the field whole (`onDelete`), from this state as
    /// from any other.
    ///
    /// `nil` — the default, and every year-only-mode instance — means the value is never
    /// year-only.
    private let yearOnlyValue: Binding<Bool>?

    // In full-date mode the live date value is decomposed into these three @State
    // fields on first onAppear rather than in init. SwiftUI calls init on every
    // parent body pass even when the node is already in the hierarchy (discarding
    // the new State initialValues for existing nodes), so doing Calendar work in
    // init paid that cost on every parent render — typically 3× per ReleaseFormView
    // pass in the Releases carousel. Deferring to onAppear means the Calendar query
    // runs exactly once per view lifetime, when the node is actually mounted.
    //
    // Sentinel defaults (1, 1, currentYear) are cheap constant assignments that
    // are replaced before the first user-visible frame by the onAppear sync.
    @State private var month: Int = 1
    @State private var day:   Int = 1
    @State private var year:  Int = CustomDateStepper.currentYear
    @State private var isInteracting: Bool = false

    // Set to true after the first onAppear sync so a rapid re-appear (e.g. tab
    // switch) does not reset user-edited fields back to the binding value.
    @State private var didSync: Bool = false

    // Mirrors the SwiftUI environment's isEnabled flag for use inside textColor.
    //
    // WHY NOT @Environment(\.isEnabled) directly in textColor:
    // Reading @Environment(\.isEnabled) in a computed property that feeds
    // .foregroundStyle(textColor) on every Text node causes SwiftUI to register
    // isEnabled as a live dependency of each of those Text nodes. The carousel
    // applies .disabled(index != idx) on each card, so isEnabled flips for
    // off-screen cards during every spring animation. That flip triggers a
    // re-evaluation of textColor on the Text nodes mid-spring — in a new implicit
    // animation transaction — which conflicts with the parent spring and causes the
    // label text to translate at a different rate than the card, producing the
    // observed "detached number" artifact.
    //
    // Using a @State mirror updated via .onChange(of: isEnabledEnv) with an
    // explicit .animation(nil) transaction breaks this dependency: the Text nodes
    // subscribe only to isEnabledState (a stable @State Bool), and the transition
    // between enabled/disabled color is applied instantly rather than being picked
    // up by whatever ambient animation transaction happens to be active.
    @Environment(\.isEnabled) private var isEnabledEnv
    @State private var isEnabledState: Bool = true
    
    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December"
    ]

    // Delegates to the shared cache rather than querying Calendar itself.
    //
    // The new-year-boundary guarantee this accessor was written for is unchanged — see
    // CurrentYear (90_00_GlobalUtilities) — but the query is no longer paid per access.
    // That matters most for the `year` @State default below, which Swift evaluates on
    // EVERY construction of this view, including the year-only init that overwrites it.
    private static var currentYear: Int { CurrentYear.value }

    /// The years a year Stepper steps through when its caller gives no range. Also the
    /// range the saved-search builder clamps a typed year to (SavedSearchSheet), so a
    /// year typed there is one a Stepper could reach.
    static var defaultYearRange: ClosedRange<Int> { 1910...currentYear }

    /// Every month/day/year decomposition and composition in this view goes through the
    /// app's pinned Gregorian calendar — the one the stored-date formatters use — never
    /// `Calendar.current`.
    ///
    /// The fields are Gregorian by construction: `monthNames`, `daysInMonth`'s leap rule,
    /// `yearRange`, and every value the callers persist through `StorageDateFormatters`.
    /// `Calendar.current` is whatever the Mac is set to, so under a Japanese or Buddhist
    /// system calendar it decomposed a 2014 date as year 26 or 2557, and composed a stepped
    /// year back into the wrong era. Pinning also makes the time zone the formatters'
    /// (fixed at first use) rather than one that can change under a running session.
    private static var calendar: Calendar { StorageDateFormatters.calendar }

    // Maximum days per month for non-leap years.
    // February (index 1) is handled separately with leap-year logic.
    private static let maxDaysInMonth: [Int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    
    // MARK: - Initializers
    
    /// Full date mode - displays month, day, and year steppers
    /// - Parameters:
    ///   - date: Binding to the date value
    ///   - hasValue: Optional binding to track whether field has a stored value (for placeholder behavior)
    ///   - yearRange: Optional range for year values (defaults to 1910...current year)
    ///   - minDate: Optional lower-bound clamp applied when the user steps a field to a
    ///     date earlier than this value. `nil` (the default) applies no clamp.
    ///   - maxDate: Optional ceiling; stepping past it loops to the floor (see `maxDate`).
    ///   - yearOnlyValue: Optional binding that is true while the value is known only by
    ///     its year, drawn with dashed month and day (see `yearOnlyValue`).
    ///   - onDelete: Optional closure called when Delete is pressed with focus on any sub-stepper
    init(date: Binding<Date>, hasValue: Binding<Bool>? = nil, yearRange: ClosedRange<Int>? = nil,
         minDate: Date? = nil, maxDate: Date? = nil, yearOnlyValue: Binding<Bool>? = nil,
         onDelete: (() -> Void)? = nil) {
        self.mode = .fullDate
        self._date = date
        self._hasValue = hasValue ?? .constant(true)
        self.yearOnlyValue = yearOnlyValue
        self.yearRange = yearRange ?? Self.defaultYearRange
        self.minDate = minDate
        self.maxDate = maxDate
        self.onDelete = onDelete
        // Full-date mode has no single-value placeholder — see placeholderYear.
        self.placeholderYear = nil
        // @State fields (month, day, year, isInteracting, didSync) use their
        // stored-property default values. SwiftUI ignores the init-time value for
        // nodes already in the hierarchy, so these literals are only used on first
        // instantiation — the real values are synced from the binding in onAppear.
    }
    
    /// Year-only mode - displays only the year stepper
    /// - Parameters:
    ///   - year: Binding to the year value
    ///   - hasValue: Optional binding to track whether field has a stored value (for placeholder behavior)
    ///   - yearRange: Optional range for year values (defaults to 1910...current year)
    ///   - placeholderYear: Optional year the un-activated placeholder shows and the
    ///     activating click commits, for a field whose activation value is dictated by
    ///     another field. Defaults to `nil` — the current year, as before.
    ///   - onDelete: Optional closure called when Delete is pressed with focus on the year stepper
    init(year: Binding<Int>, hasValue: Binding<Bool>? = nil, yearRange: ClosedRange<Int>? = nil,
         placeholderYear: Int? = nil, onDelete: (() -> Void)? = nil) {
        self.mode = .yearOnly
        self.placeholderYear = placeholderYear
        
        // Left inside the `??` autoclosure rather than hoisted into a `let`, so the
        // Calendar query is paid only when no range was supplied. Every release-card
        // call site passes one (see _ReleaseYearRow), and SwiftUI re-runs this init on
        // every parent body pass — so a hoisted read was a Calendar.component() per
        // construction whose result was then discarded. Matches the full-date init above.
        self.yearRange = yearRange ?? Self.defaultYearRange
        // Year-only mode has no full-date minDate concept — the year stepper's own
        // yearRange already governs its bounds.
        self.minDate = nil
        self.maxDate = nil
        self.yearOnlyValue = nil
        self.onDelete = onDelete
        
        // Create a date binding that only uses/updates the year
        self._date = Binding(
            get: {
                var components = DateComponents()
                components.year = year.wrappedValue
                components.month = 1
                components.day = 1
                return Self.calendar.date(from: components) ?? Date()
            },
            set: { newDate in
                year.wrappedValue = Self.calendar.component(.year, from: newDate)
            }
        )
        
        self._hasValue = hasValue ?? .constant(true)
        // Year-only mode: seed the year @State directly from the Int value —
        // no Calendar query needed. month and day use sentinel defaults (1, 1)
        // and are never read in year-only mode.
        //
        // An un-activated field with a placeholder year seeds from THAT instead, so a card
        // mounted with the field already blank renders the promised year on its first frame
        // rather than the stale value the model is carrying behind it.
        let isActive = hasValue?.wrappedValue ?? true
        self._year = State(initialValue: (!isActive ? placeholderYear : nil) ?? year.wrappedValue)
        // didSync starts true in year-only mode: the year is already correct from
        // the direct assignment above, so the onAppear sync path is skipped.
        self._didSync = State(initialValue: true)
    }
    
    // MARK: - Body
    
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if mode == .fullDate {
                    // Month stepper — clearable variant when onDelete is provided.
                    if let onDelete {
                        // spacing: 8 matches SwiftUI's default HStack spacing — the
                        // same gap Stepper { label } places between its label content
                        // and the NSStepper buttons. Without it, the raw NSStepper
                        // control sits flush against the label text with no gap.
                        HStack(spacing: 8) {
                            monthLabel
                            ClearableStepperView(
                                value: $month,
                                range: 1...12,
                                onIncrement: {
                                    step(.month, by: 1)
                                },
                                onDecrement: {
                                    step(.month, by: -1)
                                },
                                onDelete: onDelete
                            )
                        }
                    } else {
                        Stepper(
                            onIncrement: {
                                step(.month, by: 1)
                            },
                            onDecrement: {
                                step(.month, by: -1)
                            }
                        ) {
                            monthLabel
                        }
                    }
                    
                    // Day stepper — clearable variant when onDelete is provided.
                    if let onDelete {
                        HStack(spacing: 8) {
                            dayLabel
                            ClearableStepperView(
                                value: $day,
                                range: 1...31,
                                onIncrement: {
                                    step(.day, by: 1)
                                },
                                onDecrement: {
                                    step(.day, by: -1)
                                },
                                onDelete: onDelete
                            )
                        }
                    } else {
                        Stepper(
                            onIncrement: {
                                step(.day, by: 1)
                            },
                            onDecrement: {
                                step(.day, by: -1)
                            }
                        ) {
                            dayLabel
                        }
                    }
                }
                
                // Year stepper — clearable variant when onDelete is provided.
                if let onDelete {
                    HStack(spacing: 8) {
                        Text(yearDisplayText)
                            .font(.system(size: Self.labelFontSize))
                            .tracking(showsPlaceholderDashes ? Self.placeholderTracking : 0)
                            .foregroundStyle(textColor)
                            .padding(.trailing, placeholderTrailingInset)
                            .frame(width: 37, alignment: .trailing)
                        ClearableStepperView(
                            value: $year,
                            range: yearRange,
                            onIncrement: {
                                step(.year, by: 1)
                            },
                            onDecrement: {
                                step(.year, by: -1)
                            },
                            onDelete: onDelete
                        )
                    }
                } else {
                    Stepper(
                        onIncrement: {
                            step(.year, by: 1)
                        },
                        onDecrement: {
                            step(.year, by: -1)
                        }
                    ) {
                        Text(yearDisplayText)
                            .font(.system(size: Self.labelFontSize))
                            .tracking(showsPlaceholderDashes ? Self.placeholderTracking : 0)
                            .foregroundStyle(textColor)
                            .padding(.trailing, placeholderTrailingInset)
                            .frame(width: 37, alignment: .trailing)
                    }
                }
            }
            // 1 pt inside the chrome's outline on every side less than the Stepper family's
            // usual 8 / 4 / 4, for an outline that sits a little tighter on the fields and
            // the arrows (StandardStepper takes the same 1 pt).
            .padding(.leading, 7)
            .padding(.trailing, 3)
            .padding(.vertical, 3)
            // isEnabledState is the @State mirror of the SwiftUI isEnabled environment
            // value (see its declaration above). Using it here — rather than the live
            // @Environment(\.isEnabled) — avoids registering isEnabled as a dependency
            // of the background modifier, which would cause it to re-evaluate mid-spring
            // during card carousel transitions and produce visual artifacts.
            .stepperChrome(filled: isEnabledState)
        }
        .onAppear {
            // Sync @State fields from the binding on first mount.
            // didSync gates subsequent re-appears so user edits are not clobbered
            // (e.g. when the carousel reveals this card after another format visit).
            if !didSync {
                syncFromBinding()
                didSync = true
            }
            isInteracting = false
            // Seed the isEnabled mirror from the live environment value on first
            // mount so the initial text color is correct before any onChange fires.
            isEnabledState = isEnabledEnv
        }
        // Mirror isEnabledEnv into isEnabledState with an explicit nil animation so
        // the color transition is instant and never picked up by an ambient spring
        // (e.g. the carousel slide animation) as a co-occurring animated mutation.
        .onChange(of: isEnabledEnv) { _, newValue in
            withAnimation(nil) { isEnabledState = newValue }
        }
        .onChange(of: date) { _, newDate in
            // Keep the local @State display value in sync when the underlying binding
            // is updated externally — e.g. syncComboChildFields pushing a new
            // releaseYear or purchaseDate value onto a combo-pack child card.
            //
            // Without this, the local @State (year / month / day) retains the value
            // from its initial onAppear sync and never reflects subsequent external
            // writes to the binding. The user would see a stale value on the child
            // card until the view is fully re-mounted.
            //
            // Guard: in full-date mode, skip this update when the user is actively
            // interacting to avoid overwriting a value the user is currently stepping.
            //
            // The guard is deliberately NOT applied in year-only mode. There, `date`
            // is synthesized directly from the caller's Int binding, and every local
            // step writes straight through to that Int via validateAndUpdateDate()
            // before this handler can run — so the local @State can never be ahead of
            // the binding, and an external write is always authoritative. Applying the
            // guard there would permanently freeze the display of any field the user
            // has activated (isInteracting latches to true on the activation click and
            // is only reset when the field is cleared), which would leave a stale year
            // on screen whenever another field's validation rule corrects this one —
            // e.g. the mutual release-year / base-release-year ordering rule on a
            // release card, where stepping one field must visibly move the other.
            let cal = Self.calendar
            switch mode {
            case .yearOnly:
                let newYear = cal.component(.year, from: newDate)
                if newYear != year { year = newYear }
            case .fullDate:
                guard !isInteracting else { return }
                let comps = cal.dateComponents([.year, .month, .day], from: newDate)
                let newYear  = comps.year  ?? year
                let newMonth = comps.month ?? month
                let newDay   = comps.day   ?? day
                if newYear != year || newMonth != month || newDay != day {
                    year  = newYear
                    month = newMonth
                    day   = newDay
                }
            }
        }
        .onChange(of: hasValue) { oldValue, newValue in
            // When hasValue changes from false to true externally (data loaded),
            // update the year display if needed
            if !oldValue && newValue && mode == .yearOnly {
                let components = Self.calendar.dateComponents([.year], from: date)
                if let loadedYear = components.year {
                    year = loadedYear
                }
            }
            // When the field is cleared via the Delete key (true → false): reset
            // isInteracting so the placeholder color restores immediately, and reset
            // the @State display values to their defaults so the grayed-out placeholder
            // shows the correct initial value rather than the last user-edited value.
            if oldValue && !newValue {
                isInteracting = false
                switch mode {
                case .yearOnly:
                    year = placeholderYear ?? Self.currentYear
                case .fullDate:
                    let comps = Self.calendar.dateComponents([.year, .month, .day], from: Date())
                    month = comps.month ?? 1
                    day   = comps.day   ?? 1
                    year  = comps.year  ?? Self.currentYear
                }
            }
        }
    }
    
    // MARK: - Computed Properties
    
    /// Determines the text color based on whether the field has a value, if the user
    /// is interacting, and — critically — whether the control is enabled. When disabled
    /// (e.g. locked on a combo-pack child), the label always renders in the tertiary
    /// label color regardless of whether a value is present, signaling read-only state.
    /// Uses isEnabledState (a @State mirror of isEnabledEnv) rather than the live
    /// @Environment value to avoid animation-transaction conflicts — see declaration above.
    private var textColor: Color {
        guard isEnabledState else { return tertiaryLabelColor }
        return (hasValue || isInteracting) ? .primary : tertiaryLabelColor
    }

    // MARK: Year-only display

    /// True while the field shows a year-only value: dashed month and day beside a real
    /// year. Requires `hasValue`, so a blank field never shows it, whatever `yearOnlyValue` holds.
    private var showsYearOnly: Bool {
        mode == .fullDate && hasValue && (yearOnlyValue?.wrappedValue ?? false)
    }

    /// The month label: the month's name, or seven dashes for a year-only value.
    ///
    /// The dashes are drawn as the base-release-year Stepper draws its blank state — en
    /// dashes, spread by `placeholderTracking`, with the trailing gap `.tracking` leaves
    /// after the last glyph taken back by a negative inset — so the two dashed states read
    /// as one style. The inset is applied inside the frame, which centers what is left.
    private var monthLabel: some View {
        Text(showsYearOnly ? Self.monthPlaceholderDashes : Self.monthNames[month - 1])
            .font(.system(size: Self.labelFontSize))
            .tracking(showsYearOnly ? Self.placeholderTracking : 0)
            .foregroundStyle(textColor)
            .padding(.trailing, showsYearOnly ? -Self.placeholderTracking : 0)
            .frame(minWidth: 72, alignment: .center)
    }

    /// The day label: the two-digit day, or two dashes for a year-only value. Styled as
    /// `monthLabel` describes.
    private var dayLabel: some View {
        Text(showsYearOnly ? Self.dayPlaceholderDashes : Fmt.padded(day, 2))
            .font(.system(size: Self.labelFontSize))
            .tracking(showsYearOnly ? Self.placeholderTracking : 0)
            .foregroundStyle(textColor)
            .padding(.trailing, showsYearOnly ? -Self.placeholderTracking : 0)
            .frame(width: 20, alignment: .trailing)
    }

    /// Seven and two en dashes — the year-only month and day. See `placeholderDashes`.
    private static let monthPlaceholderDashes = String(repeating: "\u{2013}", count: 7)
    private static let dayPlaceholderDashes = String(repeating: "\u{2013}", count: 2)

    /// The year stepper's label text.
    ///
    /// An un-activated field normally shows the current year as a placeholder, and
    /// `textColor` is what distinguishes it from a committed value — placeholder in
    /// tertiary, committed in primary. That signal is the *only* one, and it collapses
    /// the moment the control is disabled: `textColor` returns tertiary unconditionally
    /// when disabled, so a locked field holding a real year and a locked field holding
    /// nothing render identically. Two such steppers sitting side by side (the release
    /// year / base release year pair on a combo-pack child card, where the release year
    /// is locked to the 4K parent) then give the user no way to tell an input from a
    /// placeholder. Substituting dashes states the empty case outright rather than
    /// asking one more shade of gray to carry it.
    ///
    /// Deliberately narrow: it applies only when the field is BOTH un-activated and
    /// disabled. An enabled placeholder keeps showing the current year, because there
    /// the color difference still reads and because that year is the value the first
    /// click commits — showing dashes would hide what activation is about to produce.
    ///
    /// `isInteracting` is included for the same reason `textColor` includes it: a field
    /// activated during this view's lifetime is holding a real value even before
    /// `hasValue` has propagated, and must not flash dashes if it is disabled in the
    /// same pass.
    ///
    /// Scoped to `.yearOnly` so the full-date instances (purchase date, date last seen,
    /// the Notes and Details date fields) are untouched.
    private var yearDisplayText: String {
        showsPlaceholderDashes ? Self.placeholderDashes : Fmt.padded(displayYear, 4)
    }

    /// The year the label renders: the placeholder while the field is un-activated, the
    /// live value once it holds one.
    ///
    /// Read straight off `placeholderYear` rather than mirrored into the `year` @State, so
    /// it tracks the field it is derived from in real time — the parent re-renders this view
    /// on every step of the release-year Stepper, and the new value is in place for the same
    /// frame. Mirroring would need an onChange and would land a frame late.
    ///
    /// `isInteracting` is included for the same reason `textColor` and
    /// `showsPlaceholderDashes` include it: a field activated during this view's lifetime is
    /// already holding its committed value, and must not fall back to the placeholder in the
    /// pass before `hasValue` propagates.
    private var displayYear: Int {
        guard mode == .yearOnly, !hasValue, !isInteracting, let placeholderYear else { return year }
        return placeholderYear
    }

    /// True when the year stepper should render dashes rather than a number: the field
    /// is un-activated AND disabled, in year-only mode. Factored out of
    /// `yearDisplayText` because the tracking and trailing-inset modifiers below are
    /// gated on the same condition and must not disagree with the string.
    private var showsPlaceholderDashes: Bool {
        mode == .yearOnly && !hasValue && !isInteracting && !isEnabledState
    }

    /// The label point size shared by every stepper `Text` in this view. Named so the
    /// metrics computed against it below cannot silently drift from what is rendered.
    private static let labelFontSize: CGFloat = 14

    /// En dashes (U+2013) rather than hyphens. A hyphen is the narrowest dash SF Pro
    /// draws — four of them span barely three-fifths of a four-digit year — so the
    /// placeholder read as a small mark floating in an empty cell instead of as
    /// something occupying the field. The em dash overshoots in the other direction and
    /// its four glyphs run together into one unbroken rule; the en dash is the one that
    /// reads as four distinct marks at this size.
    private static let placeholderDashes = "\u{2013}\u{2013}\u{2013}\u{2013}"

    /// Extra spacing inserted between the dashes so the placeholder spans the same
    /// width as a four-digit year.
    ///
    /// Measured rather than hard-coded: the deficit depends on SF Pro's dash and digit
    /// advances at `labelFontSize`, which are the system's to change across macOS
    /// releases and are not worth pinning a magic number to. NSFont is the right ruler
    /// here because `Font.system(size:)` resolves to exactly `NSFont.systemFont(ofSize:)`
    /// on this platform.
    ///
    /// Divided by 3, not 4, because the value is being used to widen the *ink* span:
    /// four glyphs have three gaps between them, so three insertions of this amount
    /// bring the first dash's left edge and the last dash's right edge to the same
    /// separation as a year's. SwiftUI's `.tracking` applies the value after every
    /// character including the last, which adds a fourth, trailing gap — that surplus
    /// is canceled by the negative trailing inset below rather than by under-tracking,
    /// so the spacing between the dashes stays even.
    ///
    /// Computed once, lazily, on first access. `max(0, …)` is a floor for the
    /// hypothetical future font whose dashes are already wide enough, where negative
    /// tracking would crush them together.
    ///
    /// `@MainActor` because the initializer touches AppKit type-metrics APIs, and
    /// because every read of it happens from `body`, which is main-actor isolated
    /// already — so the annotation costs nothing and keeps the property correct under
    /// strict concurrency regardless of how AppKit's own isolation is declared.
    @MainActor
    private static let placeholderTracking: CGFloat = {
        let font = NSFont.systemFont(ofSize: labelFontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        // "0000" as the reference: the placeholder stands in for a four-digit year, and
        // zero is representative of SF Pro's digit advance.
        let digitWidth = ("0000" as NSString).size(withAttributes: attributes).width
        let dashWidth  = (placeholderDashes as NSString).size(withAttributes: attributes).width
        return max(0, (digitWidth - dashWidth) / 3)
    }()

    /// Applied as negative trailing padding to absorb the trailing gap `.tracking` adds
    /// after the final dash. Without it the dashes' right edge would sit one gap short
    /// of where a year's last digit lands, and the placeholder would look nudged left
    /// inside its trailing-aligned frame. Zero whenever dashes are not being shown, so
    /// a real year's layout is bit-for-bit what it was before.
    private var placeholderTrailingInset: CGFloat {
        showsPlaceholderDashes ? -Self.placeholderTracking : 0
    }
    
    /// Checks if this is the first interaction and should only activate (not change value)
    /// Returns true if the click should be "thrown away" (only activates field)
    ///
    /// MARK: Activation commits what is on screen
    ///
    /// The click steps nothing, but it does write the DISPLAYED value into the binding. The
    /// two are the same on a field mounted blank — its display is synced from the binding —
    /// but they part the moment the field is cleared: the Delete key's closure only lowers
    /// `hasValue`, and the `hasValue` observer below resets the display (to today, or to the
    /// current or placeholder year) without touching the binding, which keeps the value the
    /// field held before. Activating then showed today while committing that old value, and
    /// every caller saved what it had not shown. Committing the display here keeps the
    /// promise the placeholder makes, whatever the caller's Delete closure does.
    ///
    /// MARK: Gated on `hasValue` alone
    ///
    /// `isInteracting` is view-local @State and `hasValue` is the committed model flag, so
    /// the two can separate — and when they do, `hasValue` is the one that is right.
    /// Requiring BOTH to be false (the previous condition) meant a picker holding a stale
    /// `isInteracting == true` treated the first click on an UNCOMMITTED field as an
    /// ordinary step: the value moved while the field was never activated, leaving a
    /// number on screen that the model considered absent and that no validation rule
    /// applied to, since every rule that pairs the two year fields is gated on their
    /// committed flags.
    ///
    /// The separation is reachable whenever the field is deactivated by something other
    /// than this view — the release card's ordering rule clears an un-orderable base year,
    /// and a merged combo pack re-points the whole picker at a different release without
    /// remounting it. The `hasValue` observer below resets `isInteracting` on the
    /// transitions it can see; this makes the activation decision independent of whether
    /// it did.
    ///
    /// Dropping `isInteracting` from the test costs nothing in the normal case: once a
    /// field is activated `hasValue` is true, so this returns false and clicks step the
    /// value exactly as before.
    private func shouldActivateInsteadOfIncrement() -> Bool {
        // A year-only value activates like a blank field: the click fills in the month and
        // day rather than stepping anything. See `yearOnlyValue`.
        if showsYearOnly {
            activateFromYearOnly()
            return true
        }
        if !hasValue {
            // Read before the flags change: it is the year the placeholder was showing.
            let shownYear = displayYear
            // First click - activate the field but don't change the value
            isInteracting = true
            hasValue = true
            // A blank field activates as a full date. A stale flag left behind by a caller
            // that cleared the field without resetting it must not dash the fresh value.
            if yearOnlyValue?.wrappedValue == true { yearOnlyValue?.wrappedValue = false }
            // Commit what was on screen (see "Activation commits what is on screen" above).
            switch mode {
            case .yearOnly:
                // The placeholder year when one was supplied (see placeholderYear), else the
                // year on display. Compared against the BINDING, which is what may be stale.
                if year != shownYear || Self.calendar.component(.year, from: date) != shownYear {
                    year = shownYear
                    validateAndUpdateDate(direction: 0)
                }
            case .fullDate:
                commitActivatedDay()
            }
            return true
        }
        return false
    }

    /// Turns a year-only value into a full date: the stored year with today's month and
    /// day, the day pulled back into a shorter month (February 29 in a year without one
    /// becomes the 28th).
    ///
    /// The year is read from the binding, not the `year` @State: the external-sync
    /// observer is suspended once the field has been interacted with, so the @State may
    /// trail a year the caller has since written.
    ///
    /// Bounds clamp rather than loop — see `commitActivatedDay`.
    private func activateFromYearOnly() {
        isInteracting = true
        let cal = Self.calendar
        let today = cal.dateComponents([.month, .day], from: Date())
        year  = cal.component(.year, from: date)
        month = today.month ?? 1
        day   = min(today.day ?? 1, daysInMonth(month: month, year: year))
        yearOnlyValue?.wrappedValue = false
        commitActivatedDay()
    }

    /// Writes the day the month, day and year fields show into the binding, as part of an
    /// activation (a blank field's first click, or a year-only value's).
    ///
    /// Bounds clamp rather than loop. A step in a looping range skips past the limits
    /// (see `loopStep`), but an activation is not a step: the user asked for nothing but
    /// "fill this in", and the nearest legal day is the honest answer.
    ///
    /// The binding is left alone when it already holds the shown day. That is the ordinary
    /// first activation of a field mounted blank, whose display was synced from the binding;
    /// keeping its instant (callers seed it with `Date()`, time of day included) rather
    /// than replacing it with that day's midnight means the activation writes nothing it
    /// did not have to.
    private func commitActivatedDay() {
        let cal = Self.calendar
        guard let candidate = cal.date(from: DateComponents(year: year, month: month, day: day)) else { return }
        // The same floor loopBounds uses: minDate, or — in a looping range — January 1 of
        // the year range's floor.
        let floor = minDate ?? (maxDate == nil ? nil
            : cal.date(from: DateComponents(year: yearRange.lowerBound, month: 1, day: 1)))
        let target: Date
        if let maxDate, candidate > cal.startOfDay(for: maxDate) {
            target = cal.startOfDay(for: maxDate)
        } else if let floor, candidate < floor {
            target = floor
        } else {
            target = candidate
        }
        if target != candidate {
            apply(target)
        } else if !cal.isDate(date, inSameDayAs: target) {
            date = target
        }
    }

    /// The three fields a stepper can move.
    private enum DateField { case month, day, year }

    /// One click of a field's stepper: `delta` is +1 for an increment, -1 for a decrement.
    ///
    /// Outside a looping range each field wraps within its own domain — month 12 → 1, the
    /// last day → 1, the year within `yearRange` (`steppedYear`) — and validateAndUpdateDate
    /// applies minDate's hard floor. In a looping range (`maxDate` set) see `loopStep`.
    private func step(_ field: DateField, by delta: Int) {
        if shouldActivateInsteadOfIncrement() { return }
        guard maxDate == nil else {
            loopStep(field, by: delta)
            return
        }
        switch field {
        case .month:
            month = delta > 0 ? (month >= 12 ? 1 : month + 1) : (month <= 1 ? 12 : month - 1)
        case .day:
            let maxDay = daysInMonth(month: month, year: year)
            day = delta > 0 ? (day >= maxDay ? 1 : day + 1) : (day <= 1 ? maxDay : day - 1)
        case .year:
            year = steppedYear(from: year, by: delta)
        }
        validateAndUpdateDate(direction: delta)
    }

    /// One step of a field in a looping range (`maxDate` set).
    ///
    /// Each field loops through its own domain independently — months 1–12, the days of the
    /// shown month, the years from the floor's to the ceiling's — skipping every value that
    /// would put the date outside the floor…ceiling range, and wrapping from one end of the
    /// domain to the other. The other two fields are left as they are; a day the new month
    /// or year lacks is pulled back to its last day (January 31 → February 28), as
    /// everywhere else in this picker.
    ///
    /// With today 2026.10.19, so a 2027.10.18 ceiling and a 2006.01.01 floor: year up from
    /// 2026.10.02 lands on 2027.10.02, and up again loops to 2006.10.02 — the first year in
    /// which October 2 is in range. It never stops on a limit along the way: a date is only
    /// ever moved to the floor or the ceiling when no value of the stepped field puts it in
    /// range, which can only happen to a value that was already out of range before the step.
    private func loopStep(_ field: DateField, by delta: Int) {
        let (floor, ceiling) = loopBounds()
        let cal = Self.calendar

        let current: Int
        let domain: [Int]
        switch field {
        case .month:
            current = month
            domain = Array(1...12)
        case .day:
            current = day
            domain = Array(1...daysInMonth(month: month, year: year))
        case .year:
            current = year
            let low = cal.component(.year, from: floor)
            let high = max(low, cal.component(.year, from: ceiling))
            domain = Array(low...high)
        }
        // The domain in step order, starting just past `current` and wrapping, with
        // `current` itself last — the answer when no other value is in range.
        let ordered: [Int] = delta > 0
            ? domain.filter { $0 > current } + domain.filter { $0 <= current }
            : Array(domain.filter { $0 < current }.reversed()) + Array(domain.filter { $0 >= current }.reversed())

        func composed(_ value: Int) -> Date? {
            var (y, m, d) = (year, month, day)
            switch field {
            case .month: m = value
            case .day:   d = value
            case .year:  y = value
            }
            return cal.date(from: DateComponents(year: y, month: m,
                                                 day: min(d, daysInMonth(month: m, year: y))))
        }

        for value in ordered {
            if let candidate = composed(value), candidate >= floor, candidate <= ceiling {
                apply(candidate)
                return
            }
        }
        // Nothing in range: the value was out of range before the step (e.g. a stored date
        // below a floor that has since risen). The nearest limit is the honest answer.
        guard let fallback = composed(current) else { return }
        apply(fallback > ceiling ? ceiling : floor)
    }

    /// A looping range's limits as calendar days: minDate, or January 1 of yearRange's lower
    /// bound when there is none, up to maxDate. Only meaningful while `maxDate` is set.
    private func loopBounds() -> (floor: Date, ceiling: Date) {
        let cal = Self.calendar
        let ceiling = cal.startOfDay(for: maxDate ?? Date())
        let floor = minDate.map { cal.startOfDay(for: $0) }
            ?? cal.date(from: DateComponents(year: yearRange.lowerBound, month: 1, day: 1))
            ?? ceiling
        return (floor, ceiling)
    }

    /// One step of the year Stepper, wrapping at both ends of `yearRange`.
    ///
    /// The wrap used to be written inline at each of the four call sites as
    /// `year >= upperBound ? lowerBound : year + 1` and its mirror. That is correct only
    /// while `year` is already inside the range, and the release card routinely produces a
    /// year that is not: the base-year Stepper's ceiling moves with the release year that
    /// caps it, the film's own release year raises the floor under an
    /// already-stored value when the Details tab is edited, and a restored record can
    /// carry a year from below a format floor that has since risen. In those states the
    /// inline form stepped *toward* the range one year at a time from outside it —
    /// silently, with no wrap — instead of entering it.
    ///
    /// Handled here as three cases so the behavior is the same no matter how the bounds
    /// came to be where they are:
    ///   • below the range — increment enters at the floor, decrement wraps to the ceiling;
    ///   • above the range — decrement enters at the ceiling, increment wraps to the floor;
    ///   • inside — step, wrapping at whichever bound is reached.
    /// A degenerate (single-year) range has exactly one legal answer and returns it.
    private func steppedYear(from current: Int, by delta: Int) -> Int {
        let lower = yearRange.lowerBound
        let upper = yearRange.upperBound
        guard upper > lower else { return lower }
        if current < lower { return delta > 0 ? lower : upper }
        if current > upper { return delta > 0 ? lower : upper }
        if delta > 0 { return current >= upper ? lower : current + 1 }
        return current <= lower ? upper : current - 1
    }
    
    // MARK: - Helper Methods

    /// Decomposes the current binding value into the local @State fields.
    /// Called once from onAppear (gated by didSync) so the Calendar query runs
    /// exactly once per view lifetime rather than once per parent render pass.
    /// Only called in full-date mode — year-only mode seeds its year @State
    /// directly in init and sets didSync = true to bypass this path entirely.
    private func syncFromBinding() {
        let cal = Self.calendar
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        month = comps.month ?? 1
        day   = comps.day   ?? 1
        year  = comps.year  ?? Self.currentYear
    }

    /// Calculate the number of days in a given month/year (handles leap years).
    ///
    /// Uses a static lookup table for all twelve months and applies a lightweight
    /// leap-year formula for February, avoiding the two Calendar.current calls
    /// (date(from:) + range(of:in:for:)) that were fired on every stepper click.
    private func daysInMonth(month: Int, year: Int) -> Int {
        guard month >= 1 && month <= 12 else { return 31 }
        // February: apply Gregorian leap-year rule directly.
        if month == 2 {
            let isLeap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
            return isLeap ? 29 : 28
        }
        return Self.maxDaysInMonth[month - 1]
    }
    
    /// Ensure the selected day is valid for the current month/year and update the bound date.
    /// If minDate is set and the resulting date falls before it, the month/day/year fields
    /// are clamped to minDate's own components instead — a hard floor rather than a
    /// wrap-around, since "earlier than the film's release date" is never a valid viewing
    /// date regardless of which stepper produced the out-of-range value.
    ///
    /// `direction` is the step that produced the fields: +1 for an increment, -1 for a
    /// decrement, 0 for anything else.
    private func validateAndUpdateDate(direction: Int) {
        // Ensure day is valid for the selected month/year
        let maxDay = daysInMonth(month: month, year: year)
        if day > maxDay {
            day = maxDay
        }
        
        // Update the bound date
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        
        guard let candidateDate = Self.calendar.date(from: components) else { return }

        if maxDate != nil {
            // A looping range's steps go through loopStep and never reach here; what does
            // is a non-step update (`direction` 0), which clamps to the nearest limit.
            let (floor, ceiling) = loopBounds()
            if candidateDate > ceiling {
                apply(ceiling)
            } else if candidateDate < floor {
                apply(floor)
            } else {
                date = candidateDate
            }
            return
        }

        if let minDate, candidateDate < minDate {
            let minComponents = Self.calendar.dateComponents([.year, .month, .day], from: minDate)
            year  = minComponents.year  ?? year
            month = minComponents.month ?? month
            day   = minComponents.day   ?? day
            date = minDate
        } else {
            date = candidateDate
        }
    }

    /// Moves the stepper fields and the bound date to `target` (a looping-range bound).
    private func apply(_ target: Date) {
        let comps = Self.calendar.dateComponents([.year, .month, .day], from: target)
        year  = comps.year  ?? year
        month = comps.month ?? month
        day   = comps.day   ?? day
        date = target
    }
}

// MARK: - Currency Input Field Component
/// A split dollar/cents input field (format: $ [000] . [00]) backed by a Double binding.
/// Each sub-field attaches a DigitOnlyFormatter whose isPartialStringValid method is
/// AppKit's authoritative pre-storage intercept point — it fires before any character
/// reaches text storage, making non-digit rejection and length enforcement both silent
/// and lag-free regardless of input speed or input method (typing, paste, IME, etc.).
struct CurrencyInputField: View {
    @Binding var value: Double
    var isDisabled: Bool = false

    @State private var dollars: String = ""
    @State private var cents:   String = ""

    /// Armed when the dollars field is exited by a forward Tab while holding a value;
    /// cleared when the cents field's editing session ends. Read by the cents field's
    /// autoFillOnTabThrough closure to decide whether a tab-through fill is warranted.
    ///
    /// Written only from AppKit's end-editing callback, which is already main-actor
    /// bound. Reads inside these closures resolve through the @State property wrapper's
    /// storage box rather than the captured view snapshot, so they always observe the
    /// current value — the same mechanism the pre-existing `dollars.isEmpty` check
    /// below already depends on. Each CurrencyInputField owns its own copy, so the
    /// three fields on a ReleaseCard cannot contaminate one another.
    @State private var pendingTabFromDollars = false

    var body: some View {
        HStack(spacing: 1) {
            Text("$")
                .foregroundStyle(isDisabled ? tertiaryLabelColor : .primary)

            DigitTextField(text: $dollars, maxLength: 3,
                           onEndEditing: { committedDollars, advancedByTab in
                // Arm the cents field only when the dollars field is left by a forward
                // Tab and actually holds a value. Tabbing through an empty dollars field,
                // clicking away, Shift-Tabbing, and Return all leave the flag clear.
                // This is a plain assignment, so it also disarms on every non-qualifying
                // exit — no separate reset path is required.
                pendingTabFromDollars = advancedByTab && !committedDollars.isEmpty
            })
                // See comment in following DigitTextField declaration.
                .padding(.trailing, 1)
                .frame(width: 48, height: 22)
                .onChange(of: dollars) { _, _ in commitValue() }

            Text(".")
                .foregroundStyle(isDisabled ? tertiaryLabelColor : .primary)

            DigitTextField(text: $cents, maxLength: 2, alignment: .natural, padsSingleDigit: true,
                           onEndEditing: { committedCents, _ in
                // Auto-fill the dollars field with "0" when the user commits a
                // non-zero cents value without entering a dollars amount.
                //
                // Rationale: a cents entry like "05" with an empty dollars field
                // represents $0.05, but the dollars placeholder ("000") stays blank,
                // which is visually ambiguous. Filling it with "0" makes the full
                // value legible and mirrors how the cents field pads a single digit.
                //
                // Guard conditions:
                //  • committedCents is non-empty (user entered something, not just
                //    focused and blurred without typing)
                //  • The integer value of the committed cents string is > 0
                //    (avoids writing "0" when the user entered "00")
                //  • dollars is currently empty (no overwrite of an explicit entry)
                //
                // The arming flag is cleared unconditionally first: this closure is the
                // final callback of every cents editing session (it runs after
                // autoFillOnTabThrough has already been consulted), so the flag can never
                // survive into an unrelated one regardless of which guard exits below.
                pendingTabFromDollars = false

                guard !committedCents.isEmpty,
                      (Int(committedCents) ?? 0) > 0,
                      dollars.isEmpty else { return }
                // The onChange(of: dollars) handler on the dollars DigitTextField
                // calls commitValue(), so no explicit call is needed here.
                dollars = "0"
            },
                           autoFillOnTabThrough: {
                // Consulted only when the cents field is empty, was not edited during
                // this session, and is being left by a forward Tab. The remaining
                // question — did focus arrive here from a populated dollars field? — is
                // answered by the arming flag.
                //
                // The dollars check is deliberately re-evaluated now rather than trusted
                // from arming time: an external reset of the bound value (e.g. the
                // purchased toggle zeroing cost) can clear the dollars field mid-session,
                // and in that case no fill should occur.
                guard pendingTabFromDollars, !dollars.isEmpty else { return nil }
                return "00"
            })
                // The field is intentionally sized to 40 pt rather than 38 pt.
                // At 38 pt, AppKit's roundedBezel cell assigns slightly different
                // interior padding to the live field-editor overlay vs. the inactive
                // drawing pass, causing a 1-2 pt horizontal shift on focus change.
                // 40 pt provides enough slack to absorb that discrepancy entirely.
                //
                // .padding(.leading, 1) shifts the NSTextField's SwiftUI origin
                // 1 pt rightward, visually centering(ish) the two-character monospaced
                // content in the available space. This is a pure SwiftUI layout
                // offset — it does not touch AppKit cell geometry, formatter state,
                // or focus-ring logic, leaving AppKit's field-editor behavior intact.
                .padding(.leading, 1)
                .frame(width: 40, height: 22)
                .onChange(of: cents) { _, _ in commitValue() }
        }
        .onAppear { syncFromBinding() }
        .onChange(of: value) { _, newValue in
            // Convert the incoming value to integer cents for an exact, branch-free
            // comparison — no floating-point tolerance fudge needed.
            let incomingCents = lround(newValue * 100)
            let displayedCents = (Int(dollars) ?? 0) * 100 + (Int(cents) ?? 0)
            guard incomingCents != displayedCents else { return }

            if newValue == 0 {
                // External reset to zero — clear both fields.
                dollars = ""
                cents   = ""
            } else {
                // External change to a non-zero amount — sync display.
                syncFromBinding()
            }
        }
        .disabled(isDisabled)
    }

    private func syncFromBinding() {
        guard value > 0 else { return }
        // lround avoids a .rounded() Swift method dispatch; % 100 isolates the
        // cents portion directly from the total integer-cents representation.
        let totalCents = lround(value * 100)
        dollars = "\(totalCents / 100)"
        cents   = Fmt.padded(totalCents % 100, 2)
    }

    private func commitValue() {
        let d = Int(dollars) ?? 0
        let c = Int(cents)   ?? 0
        value = Double(d) + Double(c) / 100.0
    }
}

// MARK: - Right-Aligned Bezel Cell
/// Custom NSTextFieldCell used exclusively for right-aligned DigitTextFields.
///
/// Problem: when AppKit activates its shared field editor overlay on a right-aligned
/// roundedBezel cell, it reserves trailing interior space for the text cursor,
/// compressing the drawable rect and pushing right-aligned content (including the
/// placeholder) toward the trailing edge — occasionally clipping the placeholder's
/// leading character(s). The effect is intermittent, depending on whether the field
/// editor geometry is computed before or after AppKit's first layout pass for that
/// activation cycle. For a two-character placeholder ("00") the reservation is ~1 pt;
/// for three characters ("000") it can reach ~2 pt, particularly on first activation
/// in a given edit session.
///
/// Fix: override `drawingRect(forBounds:)` to extend the trailing edge by 2 pt while
/// this field's own field editor is active, absorbing AppKit's cursor-space
/// reservation for both cases without visible overdraw.
///
/// Two things that didn't work, worth recording: gating the extension on
/// `isHighlighted` (assumed to reflect field-editor activity) never fired, since that
/// flag reflects cell-highlighted state for buttons/selected table rows, not
/// first-responder/editing state on a standalone `NSTextField`. Applying the
/// extension unconditionally stopped the on-focus shift but broke horizontal
/// centering while unfocused, since the same 2 pt shifts a right-aligned glyph
/// regardless of whether AppKit is actually reserving cursor space.
///
/// The correct signal is `NSTextField.currentEditor() != nil` on the cell's
/// `controlView` — non-nil only while that exact field is being edited — which
/// restores centering while unfocused and eliminates the shift while editing.
///
/// Only `drawingRect` is overridden — all drawing, editing geometry (`editingRect`,
/// `titleRect`) and focus-ring behavior remain untouched, preserving the native chrome.
private final class RightAlignedBezelCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var r = super.drawingRect(forBounds: rect)
        if let textField = unsafe controlView as? NSTextField, textField.currentEditor() != nil {
            // Extend trailing edge by 2 pt to absorb AppKit's cursor-space reservation
            // for both two-character ("00") and three-character ("000") placeholders,
            // preventing any right-aligned placeholder character from being pushed into clip.
            r.size.width += 2
        }
        return r
    }
}

// MARK: - Digit field
/// The NSTextField the bridge below creates. It exists so a DEBUG build can log what the
/// field editor is doing the moment a right-aligned digit field takes focus — the
/// currency placeholder is reported to jump right, sometimes out of view, on the first
/// cost field of a freshly purchased ReleaseCard, intermittently and only against the
/// real library. The line goes to the ordinary application log at focus, 100 ms and
/// 500 ms later, so a reproduction needs nothing more than running the app.
final class DigitField: NSTextField, Loggable {
    nonisolated static let logTag = "[DigitField]"

    #if DEBUG
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        guard became, alignment == .right else { return became }
        for ms in [0, 100, 500] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in
                guard let self else { return }
                Self.log("digit-field +\(ms)ms " + self.editorGeometry)
            }
        }
        return became
    }

    /// One line: the field, its cell's drawing rect, and — while editing — the shared
    /// field editor's frame, its clip view, its text container and the laid-out text.
    private var editorGeometry: String {
        let b = bounds
        var s = "'\(placeholderString ?? "-")' bounds=\(Fmt.fixed(b.width, 0))x\(Fmt.fixed(b.height, 0))"
        if let cell = cell as? NSTextFieldCell {
            let d = cell.drawingRect(forBounds: b)
            s += " drawing x=\(Fmt.fixed(d.minX, 1)) w=\(Fmt.fixed(d.width, 1))"
        }
        let fw = convert(b, to: nil)
        s += " inWindow x=\(Fmt.fixed(fw.minX, 1)) y=\(Fmt.fixed(fw.minY, 1))"
        guard let ed = currentEditor() as? NSTextView else { return s + " | no editor" }
        let ef = ed.convert(ed.bounds, to: self)
        let cf = unsafe ed.superview.map { $0.convert($0.bounds, to: self) } ?? .zero
        let used = unsafe ed.layoutManager.map { unsafe $0.usedRect(for: ed.textContainer!) } ?? .zero
        let container = unsafe ed.textContainer
        s += " | editor x=\(Fmt.fixed(ef.minX, 1)) w=\(Fmt.fixed(ef.width, 1))"
        s += " clip x=\(Fmt.fixed(cf.minX, 1)) w=\(Fmt.fixed(cf.width, 1))"
        s += " container w=\(Fmt.fixed(Double(container?.containerSize.width ?? -1), 0))"
        s += " used x=\(Fmt.fixed(used.minX, 1)) w=\(Fmt.fixed(used.width, 1))"
        s += " origin x=\(Fmt.fixed(ed.textContainerOrigin.x, 1))"
        s += " pad=\(Fmt.fixed(Double(container?.lineFragmentPadding ?? -1), 1))"
        s += " hres=\(ed.isHorizontallyResizable ? 1 : 0) align=\(ed.alignment.rawValue)"
        s += " min=\(Fmt.fixed(ed.minSize.width, 0)) max=\(Fmt.fixed(ed.maxSize.width, 0))"
        s += " text='\(ed.string)'"
        return s
    }
    #endif
}

// MARK: - Digit-Only NSTextField bridge
//
// Internal rather than fileprivate: the FilmSheet Notes tab's frames table
// (30_40_FSFramesList.swift) collects validated frame numbers and time codes
// through this same bridge when Preferences.strictFramesTableChecking is on.
// Sharing the control is the point — a second copy of the formatter intercept,
// the field-editor guard, and the Tab-exit detection below would be two
// implementations of one behavior, free to diverge.
struct DigitTextField: NSViewRepresentable {
    /// What the attached formatter enforces.
    enum Style {
        /// Digits only, capped at `maxLength` characters.
        case digits
        /// Digits only, capped at `maxLength` DIGITS, re-punctuated as pairs
        /// separated by colons (##:##:##). See `TimeCodeText`.
        case timeCode
    }

    @Binding var text: String
    /// For `.digits`, the maximum number of characters. For `.timeCode`, the
    /// maximum number of digits — the colons the formatter inserts are not
    /// counted against it.
    let maxLength: Int
    var style: Style = .digits
    var alignment: NSTextAlignment = .right
    var padsSingleDigit: Bool = false
    /// Shown when the field is empty. Defaults to `maxLength` zeros, which is the
    /// self-documenting placeholder the currency fields want; callers whose field
    /// is not a fixed-width numeral run supply their own.
    var placeholder: String? = nil
    /// Called after all end-of-editing processing (including single-digit padding and
    /// tab-through auto-fill) is complete. The closure receives the final committed
    /// string value and a flag that is true only when the session ended because the user
    /// pressed Tab to advance forward, letting the owning view distinguish that from a
    /// click-away, Return, Escape, or Shift-Tab.
    var onEndEditing: ((String, Bool) -> Void)? = nil
    /// Consulted during end-of-editing when this field is empty, was not edited during
    /// the session, and is being left by a forward Tab. Returning a non-nil, non-empty
    /// string fills the field with that value; returning nil leaves it empty. Owning
    /// views use this to supply context the field itself cannot know — for example
    /// whether focus arrived from a populated sibling field.
    var autoFillOnTabThrough: (() -> String?)? = nil
    /// When true, this field hands focus to the next control in the key view loop
    /// the moment its content reaches `maxLength`.
    ///
    /// Opt-in, and off by default, because it is only ever correct for the LEADING
    /// half of a two-field pair: the frames table's strict rows, where filling the
    /// six-digit frame number or the six digits of a time code means the user's next
    /// keystroke belongs in the field beside it. A trailing half that advanced on
    /// fill would throw focus out of the row entirely, and a standalone field —
    /// every currency field in the app — would fight the user for the cursor the
    /// instant a value was complete.
    ///
    /// Measured in DIGITS for both styles, which is what `maxLength` already means
    /// for `.timeCode`; the colons the formatter inserts are not counted, exactly as
    /// they are not counted against the cap.
    var advancesOnFill: Bool = false

    /// The field's point size.
    var fontSize: CGFloat = 13

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// The caller's placeholder, or the historical default of `maxLength` zeros.
    private var resolvedPlaceholder: String {
        placeholder ?? String(repeating: "0", count: maxLength)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = DigitField()
        // Each NSTextField receives its own DigitOnlyFormatter instance.
        //
        // Why not shared statics? NSFormatter is not thread-safe, and AppKit
        // reads/writes formatter display state (attributed placeholder, cell
        // attributes) when a field gains or loses first-responder status. With
        // a shared instance, concurrent focus changes across the multiple
        // CurrencyInputField instances in a ReleaseCard corrupt that state —
        // causing the placeholder text to shift dramatically (sometimes clipping
        // one or all characters) when a currency field is focused, and restoring
        // only when focus leaves. One instance per field eliminates the race.
        //
        // Right-aligned fields receive a RightAlignedBezelCell to counteract
        // AppKit's 1 pt cursor-space reservation that shifts the placeholder on
        // focus. Left-aligned (natural) fields use the default NSTextFieldCell.
        if alignment == .right {
            let cell = RightAlignedBezelCell()
            cell.bezelStyle     = .roundedBezel
            cell.isEditable     = true
            cell.isSelectable   = true
            // NOT scrollable — this is the placeholder fix, so it gets the long comment.
            //
            // A scrollable cell hands the window's shared field editor over as a
            // horizontally resizable NSTextView, whose frame is only reconciled with the
            // cell's rect lazily, at its next layout. Logged against the real library
            // (2026-09-19): one run-loop turn after a cost field took focus its editor was
            // 57, 90 or 92 pt wide inside a 29 pt clip, and 29 pt again 100 ms later. A
            // right-aligned placeholder is drawn at the editor's trailing edge, so for that
            // first frame it sat 28–63 pt to the right of the visible interior — partly or
            // wholly clipped, by an amount that depended on whatever the editor had been
            // doing before, which is the "random" shift reported against the first
            // currency field of a freshly purchased card since the fields were introduced.
            // A natural-aligned placeholder sits at the leading edge, which a stale width
            // never moves; that is why the cents field beside it was never affected.
            //
            // With the cell not scrollable the editor is not horizontally resizable and
            // its width tracks the clip's, so there is no stale width to draw against.
            // Nothing is lost: the formatter caps the field at `maxLength` digits, which
            // fit the interior with room to spare, so there is never anything to scroll
            // to. Natural-aligned fields keep `isScrollable` (set below) because the
            // frames table relies on it as a safety margin for a rare long value.
            cell.isScrollable   = false
            cell.font           = .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
            cell.placeholderString = resolvedPlaceholder
            cell.alignment      = alignment
            field.cell          = cell
        }
        // One formatter instance per field, for the reason set out above. Which
        // formatter is the only thing the style selects: both are pre-storage
        // intercepts, so neither can produce a visible artifact.
        switch style {
        case .digits:   field.formatter = DigitOnlyFormatter(maxLength: maxLength)
        case .timeCode: field.formatter = TimeCodeFormatter(maxDigits: maxLength)
        }
        field.delegate          = context.coordinator
        // isBezeled + roundedBezel gives rounded native chrome matching
        // SwiftUI's .roundedBorder style; focusRingType = .default gives
        // the standard blue focus ring automatically when the field is active.
        field.isBordered        = false
        field.isBezeled         = true
        if alignment != .right {
            (field.cell as? NSTextFieldCell)?.bezelStyle = .roundedBezel
        }
        field.drawsBackground   = true
        field.focusRingType     = .default
        field.font              = .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        field.placeholderString = resolvedPlaceholder
        field.alignment         = alignment
        // Seed isEnabled from the SwiftUI environment at creation time.
        // The outer .disabled(isDisabled) modifier on CurrencyInputField's HStack
        // propagates the disabled state here; no separate isDisabled parameter needed.
        field.isEnabled         = context.environment.isEnabled
        // Natural-aligned fields only; a right-aligned cell must stay non-scrollable —
        // see RightAlignedBezelCell's configuration above.
        if alignment != .right {
            field.cell?.wraps        = false
            field.cell?.isScrollable = true
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Keep the coordinator's parent current. SwiftUI rebuilds this representable
        // struct on every update but REUSES the coordinator, so without this the
        // delegate goes on writing through the `text` binding — and calling the
        // `onEndEditing` / `autoFillOnTabThrough` closures — captured when the
        // coordinator was made, and goes on reading `style`, `maxLength`,
        // `padsSingleDigit` and `advancesOnFill` from that same first snapshot.
        //
        // Today's call sites are safe by construction rather than by design: each hands
        // over a `@State` projection, or a closure that reads through a `@State` storage
        // box, both of which survive a stale snapshot. Refreshing the reference costs one
        // assignment per update and removes the dependence on what callers happen to
        // capture — the same reasoning, and the same one-line fix, already applied to
        // `ExternalIDField` and `ScrollingTextViewRepresentable`.
        context.coordinator.parent = self
        // Guard against interrupting an active edit.
        //
        // When this field is the current first responder, AppKit routes all
        // keystrokes through a shared NSTextView (the "field editor") overlaid
        // on the cell. Writing nsView.stringValue while the field editor is live
        // causes AppKit to flush and reset it synchronously — which discards any
        // in-progress input and restarts the cursor, producing the "characters
        // stream in after the user finishes typing" symptom. Skipping the push
        // while focused is safe because the Coordinator's controlTextDidChange
        // already keeps parent.text in sync with every keystroke; the external
        // value can only be stale if a different path (e.g. the purchased toggle
        // resetting cost to 0.0) changed the binding from outside. That external
        // reset produces a genuinely different value in a render pass that
        // happens after the field loses focus, so the guard never suppresses a
        // legitimate external update.
        //
        // The field editor's delegate is the NSTextField it is editing — not the field's
        // cell. This compared against `nsView.cell`, which never matched, so the guard
        // never engaged and a mid-edit push could reach the live editor after all.
        let isFieldEditor: Bool
        if let fr = unsafe nsView.window?.firstResponder as? NSTextView,
           fr.isFieldEditor, fr.delegate === nsView {
            isFieldEditor = true
        } else {
            isFieldEditor = unsafe nsView.window?.firstResponder === nsView
        }
        if !isFieldEditor && nsView.stringValue != text {
            nsView.stringValue = text
        }
        // The SwiftUI environment's isEnabled flag carries both the outer
        // .disabled(isDisabled) from CurrencyInputField and the .disabled(index != idx)
        // applied to off-screen carousel cards in FSTabReleasesView.
        let enabled = context.environment.isEnabled
        nsView.isEnabled = enabled
        // refusesFirstResponder is the AppKit-level backstop: even if SwiftUI's
        // .focusable(false) on the card wrapper removes the subtree from the SwiftUI
        // focus engine, AppKit can still attempt to Tab into an NSTextField that is
        // merely isEnabled == false. Setting refusesFirstResponder = true when disabled
        // guarantees the AppKit Tab-key responder chain skips this field entirely,
        // preventing any lingering dead Tab stops on off-screen or combo-disabled fields.
        nsView.refusesFirstResponder = !enabled
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DigitTextField
        init(_ parent: DigitTextField) { self.parent = parent }

        /// True once the user has changed this field's text during the current editing
        /// session; reset when that session ends.
        ///
        /// This is deliberately derived from controlTextDidChange rather than from
        /// controlTextDidBeginEditing. The latter is NOT a focus-acquisition
        /// notification: AppKit posts it when the text object begins an operation that
        /// changes characters, i.e. on the first keystroke. A field that gains focus and
        /// is tabbed straight through without typing never posts it at all — which is
        /// exactly the case the tab-through auto-fill below has to recognize, so it
        /// cannot be built on that notification. controlTextDidChange, by contrast,
        /// fires on every user edit and never on a programmatic stringValue write, which
        /// makes "did the user touch this field?" reliably answerable here.
        private var sessionHadEdits = false

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            sessionHadEdits = true
            parent.text = field.stringValue

            // Auto-advance on fill, for the fields that asked for it.
            //
            // Gated on `advancesOnFill` so this is the leading half of a pair and
            // nothing else — see that property. Counted in digits so the two styles
            // are measured the same way: `.digits` holds nothing but digits anyway,
            // and `.timeCode`'s colons are punctuation the formatter inserts rather
            // than characters the user typed.
            //
            // Deferred one hop rather than run inline. This is a text-DID-change
            // notification, which AppKit posts from inside the field editor's own
            // processing of the keystroke; moving first responder there would tear
            // that editor down mid-edit, and the character just typed is not
            // guaranteed to have been flushed to the cell yet. A single main-queue
            // hop lands after AppKit has finished with the event, at which point
            // ending the session is the ordinary, supported thing to do.
            // `DispatchQueue.main.async` rather than a `Task`, per the rule for
            // synchronous AppKit callbacks — it inherits this event's QoS instead of
            // hopping through a new priority.
            if parent.advancesOnFill,
               field.stringValue.filter(\.isASCIIDigit).count >= parent.maxLength {
                DispatchQueue.main.async { [weak field] in
                    guard let field else { return }
                    // Only if this field is still the one being edited. Between the
                    // keystroke and this hop the user may have clicked elsewhere,
                    // and stealing focus back to advance out of a field they have
                    // already left would be worse than not advancing at all.
                    guard field.currentEditor() != nil else { return }
                    // On a ReleaseCard the step goes through the card's own key loop, so
                    // it lands where a Tab press would and can never walk into a
                    // neighboring card (see FilmSheetKeyLoop, 30_01); the loop declines,
                    // moving nothing, for a field that is not on a card. Elsewhere,
                    // `nextValidKeyView` when AppKit has a loop to walk, which is the
                    // ordinary case and lands on the sibling field directly. The
                    // window's own traversal is the fallback for a loop that has not
                    // been computed, and is the exact path a Tab key press takes.
                    if FilmSheetKeyLoop.shared.advance(from: field) {
                        return
                    }
                    if let next = unsafe field.nextValidKeyView {
                        unsafe field.window?.makeFirstResponder(next)
                    } else {
                        unsafe field.window?.selectNextKeyView(field)
                    }
                }
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            let advancedByTab = Self.isForwardTabExit(obj)
            let hadEdits = sessionHadEdits
            sessionHadEdits = false

            // Zero-pad a single-digit entry to two digits (e.g. "5" → "05").
            // Only runs when the parent has opted in (cents field), and only
            // when the value is exactly one character — empty fields are left
            // alone so the placeholder remains visible.
            if parent.padsSingleDigit, parent.text.count == 1 {
                parent.text = "0" + parent.text
                if let field = obj.object as? NSTextField {
                    field.stringValue = parent.text
                }
            }

            // Complete a partially entered time code (e.g. "01:2" → "01:20:00").
            //
            // Applied on end-of-editing rather than while typing, because filling
            // the remaining pairs mid-entry would fight the user for the cursor on
            // every keystroke. An EMPTY field is deliberately left empty: zero
            // characters means the user never entered a time code here, which is a
            // legitimate state, and filling it would invent a value of 00:00:00.
            //
            // Mutually exclusive with the padding block above by construction —
            // that path is opt-in via padsSingleDigit, which the time-code style's
            // callers do not set — and with the tab-through fill below, which
            // requires the field to be empty.
            if parent.style == .timeCode, !parent.text.isEmpty {
                let completed = TimeCodeText.completed(parent.text)
                if completed != parent.text {
                    parent.text = completed
                    if let field = obj.object as? NSTextField {
                        field.stringValue = completed
                    }
                }
            }

            // Tab-through auto-fill: the field is empty, the user never typed in it
            // during this session, and the session is ending because they pressed Tab to
            // advance to the next control. The owning view decides, via the closure,
            // whether this particular transition qualifies.
            //
            // The !hadEdits test is what distinguishes "focused and passed through" from
            // "deliberately cleared an existing value and moved on"; only the former
            // should be filled.
            //
            // Mutually exclusive with the padding block above: that path requires exactly
            // one character, this one requires zero.
            //
            // Applied here rather than from a key-command intercept because AppKit
            // flushes the live field editor back into the cell as part of ending editing;
            // a stringValue write made before that flush would be discarded. By this
            // point the flush has completed — the same reason the padding above is
            // applied here.
            if parent.text.isEmpty,
               advancedByTab,
               !hadEdits,
               let fillValue = parent.autoFillOnTabThrough?(),
               !fillValue.isEmpty {
                parent.text = fillValue
                if let field = obj.object as? NSTextField {
                    field.stringValue = fillValue
                }
            }

            // Notify the parent after all in-place mutations are complete.
            // CurrencyInputField uses this to auto-fill the sibling dollars field when a
            // non-zero cents value was committed without entering a dollars amount, to
            // arm the cents field's tab-through fill when the dollars field is exited by
            // a forward Tab, and to clear that arming flag when the cents session ends
            // (see the closures on each DigitTextField in CurrencyInputField).
            parent.onEndEditing?(parent.text, advancedByTab)
        }

        /// Reports whether this editing session ended because the user pressed Tab to
        /// advance forward to the next control.
        ///
        /// The primary signal is NSTextMovement from the end-editing notification's
        /// userInfo, which AppKit sets when its own key view loop performed the
        /// traversal; it cleanly separates a forward Tab from Shift-Tab, Return, Escape,
        /// and the arrow keys. NSTextMovementOther (raw value 0) means AppKit attributed
        /// the responder change to nothing in particular — which is what a
        /// makeFirstResponder call from outside the key view loop produces — so in that
        /// one ambiguous case the live NSApp.currentEvent is consulted instead.
        ///
        /// The userInfo key is spelled literally rather than via a Swift constant: the
        /// "NSTextMovement" string is the documented, ABI-stable key for this entry.
        private static func isForwardTabExit(_ notification: Notification) -> Bool {
            guard let raw = notification.userInfo?["NSTextMovement"] as? Int else {
                return isForwardTabKeyEvent()
            }
            if let movement = NSTextMovement(rawValue: raw), movement == .tab { return true }
            // Any other attributed movement is a definite non-advance.
            if raw != 0 { return false }
            return isForwardTabKeyEvent()
        }

        /// True when the event currently being dispatched is an unshifted Tab key press.
        /// 48 is kVK_Tab. Shift-Tab is excluded so backward traversal never qualifies.
        private static func isForwardTabKeyEvent() -> Bool {
            guard let event = NSApp.currentEvent,
                  event.type == .keyDown,
                  event.keyCode == 48 else { return false }
            return !event.modifierFlags.contains(.shift)
        }
    }
}

// MARK: - Digit-Only Formatter
/// NSFormatter subclass attached to each DigitTextField.
/// isPartialStringValid is called by AppKit for every proposed text change — typing,
/// paste, autocorrect, drag-drop — before it touches storage. Returning false with a
/// modified partialStringPtr causes AppKit to silently apply the cleaned value instead,
/// with no visual glitch of any kind.
// MARK: - Time-Code Text Rules
/// The punctuation rules for an `##:##:##` time code, in one place.
///
/// Both the live formatter below and the callers that seed a field from stored
/// text go through these, so what the user sees while typing, what is shown when
/// an existing value is loaded for editing, and what is finally committed are all
/// produced by the same rules rather than by three that happen to agree.
enum TimeCodeText {
    /// Hours, minutes, seconds.
    static let pairCount = 3
    /// The digits a complete time code holds, colons excluded.
    static let digitCount = pairCount * 2

    /// The digits of `raw`, capped at `digitCount`.
    static func digits(_ raw: String) -> String {
        String(raw.filter(\.isASCIIDigit).prefix(digitCount))
    }

    /// `digits` re-punctuated: a colon after every completed pair, and never a
    /// trailing one.
    ///
    /// The absence of a trailing colon is what makes deletion behave as it must.
    /// A colon is not a character the user can put there or take away — it exists
    /// only BETWEEN two pairs — so deleting the first digit of a pair takes the
    /// colon before it with it ("01:23:4" backspaced twice → "01:23" → "01:2"),
    /// and a backspace aimed at a colon itself removes nothing, because the
    /// re-punctuated result is identical to what was already displayed.
    static func punctuated(_ digits: String) -> String {
        var out = ""
        out.reserveCapacity(digitCount + pairCount - 1)
        for (offset, character) in digits.enumerated() {
            if offset > 0, offset % 2 == 0 { out.append(":") }
            out.append(character)
        }
        return out
    }

    /// `raw` reduced to digits and re-punctuated — the canonical display form of
    /// whatever the user or the stored record supplied.
    static func formatted(_ raw: String) -> String {
        punctuated(digits(raw))
    }

    /// A partial entry filled out to a full `##:##:##`, zero-filling to the right.
    ///
    /// Right-filling matches the order the pairs are typed in: a user who typed
    /// "1" meant one hour, not one second. An empty string is returned unchanged —
    /// see the caller in `DigitTextField.Coordinator`.
    static func completed(_ raw: String) -> String {
        let d = digits(raw)
        guard !d.isEmpty else { return "" }
        return punctuated(d + String(repeating: "0", count: digitCount - d.count))
    }

    /// A stored value normalized for display in a strict-mode field.
    ///
    /// Distinct from `formatted` because a legacy record may already carry
    /// colons in positions a straight digit run would not reproduce: "1:23:45"
    /// holds five digits, so `formatted` would render it "12:34:5" — the digits
    /// preserved, their meaning destroyed. Splitting on the colons first and
    /// padding each component to two digits reads it as the human-written time
    /// code it is, giving "01:23:45".
    ///
    /// A value with no colons is a bare digit run and is handled by `formatted`.
    /// Nothing here is written back to storage; this only decides what a field is
    /// seeded with, and the seeded text is committed only if the user saves.
    static func normalizedForDisplay(_ raw: String) -> String {
        guard raw.contains(":") else { return formatted(raw) }
        let components = raw.split(separator: ":", omittingEmptySubsequences: false)
            .prefix(pairCount)
            .map { component -> String in
                let d = String(component.filter(\.isASCIIDigit))
                switch d.count {
                case 0:  return "00"
                case 1:  return "0" + d
                default: return String(d.prefix(2))
                }
            }
        return components.joined(separator: ":")
    }
}

// MARK: - String Formatter
/// The base of the app's input-filtering formatters (`TimeCodeFormatter` and
/// `DigitOnlyFormatter` here, `ExternalIDFormatter` in 30.10 FSTextHelpers.swift). Their
/// "object value" is the string itself, so the conversions are identities; a subclass
/// only overrides `isPartialStringValid`, AppKit's pre-storage intercept, to decide what
/// may be typed. The three used to carry their own copies of these overrides.
class StringFormatter: Formatter {
    override init() { super.init() }

    required init?(coder: NSCoder) { nil }

    override func string(for obj: Any?) -> String? { obj as? String }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
        for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        unsafe obj?.pointee = string as AnyObject
        return true
    }
}

// MARK: - Time-Code Formatter
/// Enforces `##:##:##` on every proposed change, on the same pre-storage
/// intercept `DigitOnlyFormatter` uses — so non-digits are dropped and colons are
/// inserted before the text ever reaches storage, with no flicker and no
/// re-entrant edit of the field's own value.
private final class TimeCodeFormatter: StringFormatter, @unchecked Sendable {
    let maxDigits: Int

    init(maxDigits: Int) {
        self.maxDigits = maxDigits
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func isPartialStringValid(
        _ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
        proposedSelectedRange proposedSelRangePtr: NSRangePointer?,
        originalString origString: String,
        originalSelectedRange origSelRange: NSRange,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        let proposed = unsafe partialStringPtr.pointee as String
        let digits = String(proposed.filter(\.isASCIIDigit).prefix(maxDigits))
        let formatted = TimeCodeText.punctuated(digits)

        if formatted == proposed { return true }

        unsafe partialStringPtr.pointee = formatted as NSString

        // The cursor is re-derived rather than clamped, because the rewrite can
        // both remove characters (a rejected letter) and add them (an inserted
        // colon), so its position in the proposed string does not survive.
        //
        // Count the digits the user's cursor stood after, then place it after that
        // many digits in the formatted string — which means adding back the colons
        // that precede it. A cursor sitting after exactly one completed pair goes
        // BEFORE that pair's trailing colon, since no colon is drawn until the
        // next pair begins.
        if let ptr = unsafe proposedSelRangePtr {
            let location = unsafe min(ptr.pointee.location, proposed.count)
            let index = proposed.index(proposed.startIndex, offsetBy: location)
            let digitsBefore = min(proposed[..<index].filter(\.isASCIIDigit).count, digits.count)
            let colonsBefore = max(0, (digitsBefore - 1) / 2)
            unsafe ptr.pointee = NSRange(location: digitsBefore + colonsBefore, length: 0)
        }
        return false
    }
}

private final class DigitOnlyFormatter: StringFormatter, @unchecked Sendable {
    let maxLength: Int

    init(maxLength: Int) {
        self.maxLength = maxLength
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    /// Strip non-digits and truncate to maxLength before the change reaches storage.
    /// Returning true = accept as-is. Returning false = apply the modified partialStringPtr.
    override func isPartialStringValid(
        _ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
        proposedSelectedRange proposedSelRangePtr: NSRangePointer?,
        originalString origString: String,
        originalSelectedRange origSelRange: NSRange,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        let proposed = unsafe partialStringPtr.pointee as String
        let filtered = String(proposed.filter(\.isASCIIDigit).prefix(maxLength))

        // Proposed string is already clean — accept without touching anything.
        if filtered == proposed { return true }

        // Apply the cleaned string and clamp the cursor position.
        unsafe partialStringPtr.pointee = filtered as NSString
        if let ptr = unsafe proposedSelRangePtr {
            unsafe ptr.pointee = unsafe NSRange(location: min(ptr.pointee.location, filtered.count), length: 0)
        }
        return false
    }
}

// MARK: - Text-Input Focus
/// The one definition of "is a text-entry control currently holding first responder."
///
/// Three copies of this heuristic previously lived in the app — `KeyboardManager`'s
/// `isTextInputActive(in:)`, `MenuBar`'s `isTextFieldFocusedInWindow` /
/// `isTextRelatedClassName`, and an inline block in `SettingsSheet`'s Return-key
/// monitor — and they had already drifted: the Settings copy recognized only
/// `TextField`, `TextEditor` and `SearchField`, so a responder that the other two
/// classified as text (a `…EditableText…` wrapper, or any class matching the generic
/// `Text` + `Field`/`Editor`/`Input` rule) was invisible to it and Return dismissed the
/// sheet out from under a live edit.
///
/// The three call sites decide different things — whether to consume a shortcut,
/// whether to enable Cut/Copy/Paste, whether Return dismisses — but they are all asking
/// the identical question, and they must never disagree about the answer. One definition
/// is what guarantees that.
///
/// **Why the type-name test exists at all.** The fast path covers the AppKit classes
/// directly. What it cannot cover is SwiftUI's own text plumbing: `TextField` and
/// `TextEditor` are backed by private wrapper classes (`SwiftUI.SearchTextField` and
/// friends) that are not `NSTextField`/`NSTextView` subclasses, and there is no public
/// protocol to test for. Matching identifying keywords in the class name is a heuristic,
/// and deliberately a permissive one: a false positive costs a shortcut passed through to
/// a control that ignores it, while a false negative eats the user's keystroke or their
/// in-progress edit.
enum TextInputFocus {

    /// True when `window`'s first responder is a text-entry control.
    ///
    /// Note this asks about the window's *retained* first responder, which a window keeps
    /// while it is not key. Callers that care only about where typing would actually land
    /// should ask the key window, not every window in the app.
    @MainActor
    static func isActive(in window: NSWindow) -> Bool {
        guard let firstResponder = window.firstResponder else { return false }

        // Fast path: the AppKit text classes, by type.
        if firstResponder is NSTextField || firstResponder is NSTextView { return true }

        // `String(describing: type(of:))` and `NSObject.className` produce the same string
        // for NSView subclasses, so the type name alone is sufficient.
        return matchesTextClassName(String(describing: type(of: firstResponder)))
    }

    /// True when `name` reads as the class name of a text-entry control.
    /// Exposed separately only so the rule can be exercised without a live window.
    static func matchesTextClassName(_ name: String) -> Bool {
        if name.contains("TextField") || name.contains("TextEditor")
            || name.contains("SearchField") || name.contains("EditableText") {
            return true
        }
        return name.contains("Text")
            && (name.contains("Field") || name.contains("Editor") || name.contains("Input"))
    }
}

// MARK: - Text-Checking Prewarm
/// Loads AppKit's data-detector scanner on a utility thread at launch, so that no text
/// field ever waits for it on the main thread.
///
/// **The wait this removes.** Whenever a field editor or text view resigns first responder
/// — Tab moving focus (`FilmSheetKeyLoop.focus`, 30.01), Return ending an edit, a click
/// elsewhere — AppKit runs its pending text checking synchronously, and that pass asks for
/// a DataDetectors scanner (private `_getDataDetectorsScanner`). The process's first request
/// detaches an `NSThread` to load one, at Default QoS, and blocks the asking thread on a
/// condition lock until the load finishes. On the main thread, inside a key event, that is
/// a user-interactive thread waiting on a default one: Xcode's Thread Performance Checker
/// reported it at the Tab loop's `window.makeFirstResponder(control)`. A loaded scanner is
/// kept for the life of the process, so once this has run every later request returns
/// without waiting.
///
/// **Why a utility thread, and why synchronous.** The thread that makes the first request
/// is the one that waits, so it must not outrank the Default-QoS loader. `check` is the
/// call AppKit itself makes off the main thread, and run from a utility task it waits at a
/// lower QoS than the loader — no inversion anywhere. `requestChecking`, the asynchronous
/// form, would not do: AppKit runs it on its own queue at user-interactive QoS whatever the
/// caller's, which only moves the same inversion off the main thread. `shared` is still
/// taken on the main thread, since creating it builds UI.
///
/// **Why this request loads the right scanner.** AppKit keeps one scanner per kind and
/// picks the kind from the checking types: date, address, phone-number or transit checking
/// selects one kind, every other set of types the other. Nothing in the app changes a text
/// view's checking types, so the defaults asked for here — a text view's, which select the
/// same kind as the shared field editor's — load the scanner every field and text view in
/// the app uses. (Turning on Edit ▸ Substitutions ▸ Data Detectors in a text view switches
/// that view to the other kind, which then loads on first use as before.)
@MainActor
enum TextCheckingPrewarm: Loggable {
    nonisolated static let logTag = "[TextCheckingPrewarm]"
    private static var done = false

    /// Called once at launch, after the first render.
    static func run() {
        guard !done else { return }
        done = true
        let checker = NSSpellChecker.shared
        let types = NSTextView().enabledTextCheckingTypes
        Task.detached(priority: .utility) {
            let start = CACurrentMediaTime()
            let text = "Film Tracker"
            // `unsafe` only for the signature's two out-pointers, both passed nil.
            _ = unsafe checker.check(text, range: NSRange(location: 0, length: (text as NSString).length), types: types,
                                     options: nil, inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil)
            log("Scanner ready in \(Fmt.fixed((CACurrentMediaTime() - start) * 1000, 1)) ms")
        }
    }
}
