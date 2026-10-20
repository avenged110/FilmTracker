// MARK: - Harness.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Standalone release-year ordering harness — NOT part of the app target.
//
// Mirrors, verbatim, the two layers that keep `baseReleaseYear < releaseYear`:
//
//   • Model.enforceReleaseYearOrder()  ← 33.00 FSTabReleases.swift
//   • the Stepper ranges and the enable/disable gate computed in _ReleaseYearRow
//     ← 33.20 ReleaseCard.swift
//   • CustomDateStepper.steppedYear(from:by:) and its activation rule
//     ← 91.00 InputUtilities.swift
//
// The three sources are transcribed rather than imported, exactly as the
// ReleaseCardStateEquivalence harness carries its own ReleaseCardModel: the shipped code
// lives inside SwiftUI views and an @Observable app target that cannot be built with
// swiftc alone. Any edit to the originals must be mirrored here — the tests below are
// only evidence about the code they copy.
import Foundation

// MARK: - Model (the subset the ordering rule touches)

final class Model {
    var releaseYear: Int
    var hasReleaseYear: Bool
    var baseReleaseYear: Int
    var hasBaseReleaseYear: Bool
    var formatFloor: Int
    var filmReleaseYear: Int
    let currentYear: Int

    init(currentYear: Int = 2026, formatFloor: Int = 2006, filmReleaseYear: Int = 0) {
        self.currentYear        = currentYear
        self.formatFloor        = formatFloor
        self.filmReleaseYear    = filmReleaseYear
        self.releaseYear        = currentYear
        self.hasReleaseYear     = false
        self.baseReleaseYear    = currentYear
        self.hasBaseReleaseYear = false
    }

    var purchaseYearRange: ClosedRange<Int> {
        let rawLowerBound = filmReleaseYear > formatFloor ? filmReleaseYear : formatFloor
        let lowerBound    = rawLowerBound > currentYear ? currentYear : rawLowerBound
        return lowerBound...currentYear
    }

    func enforceReleaseYearOrder() {
        guard hasReleaseYear, hasBaseReleaseYear else { return }
        let range = purchaseYearRange
        let lower = range.lowerBound
        let upper = range.upperBound
        guard upper > lower else { hasBaseReleaseYear = false; return }
        guard releaseYear > lower else { hasBaseReleaseYear = false; return }
        guard baseReleaseYear >= releaseYear else { return }
        baseReleaseYear = min(releaseYear - 1, upper - 1)
    }
}

// MARK: - View layer (_ReleaseYearRow's computed ranges and gate)

struct RowState {
    let fullRange: ClosedRange<Int>
    let releaseRange: ClosedRange<Int>
    let baseRange: ClosedRange<Int>
    let baseYearAvailable: Bool
    /// What _ReleaseYearRow hands the base-year picker as `placeholderYear`.
    let basePlaceholderYear: Int?

    init(_ m: Model) {
        let full = m.purchaseYearRange
        fullRange         = full
        releaseRange      = full
        baseYearAvailable = m.hasReleaseYear && m.releaseYear > full.lowerBound
        let ceiling: Int = {
            guard m.hasReleaseYear else { return full.upperBound }
            return max(full.lowerBound, min(full.upperBound, m.releaseYear - 1))
        }()
        baseRange = full.lowerBound...ceiling
        basePlaceholderYear = m.hasReleaseYear ? ceiling : nil
    }
}

// MARK: - Placeholder display (CustomDateStepper.displayYear / yearDisplayText)
//
// What the base-year Stepper renders while un-activated: dashes when it is also disabled,
// otherwise the placeholder year — which is the value its activating click commits.
enum BaseYearLabel: Equatable {
    case dashes
    case year(Int)
}

extension Model {
    var baseYearLabel: BaseYearLabel {
        let row = RowState(self)
        if hasBaseReleaseYear { return .year(baseReleaseYear) }
        if !row.baseYearAvailable { return .dashes }   // un-activated AND disabled
        return .year(row.basePlaceholderYear ?? currentYear)
    }
}

// MARK: - Stepper (CustomDateStepper)

func steppedYear(from current: Int, by delta: Int, in yearRange: ClosedRange<Int>) -> Int {
    let lower = yearRange.lowerBound
    let upper = yearRange.upperBound
    guard upper > lower else { return lower }
    if current < lower { return delta > 0 ? lower : upper }
    if current > upper { return delta > 0 ? lower : upper }
    if delta > 0 { return current >= upper ? lower : current + 1 }
    return current <= lower ? upper : current - 1
}

// MARK: - User actions
//
// Each mirrors one click, routed through the same .onChange handlers the row installs:
// a value write is followed by enforceReleaseYearOrder(), and so is an activation.

extension Model {
    /// A click on the release-year Stepper. No-op while its Stepper would be disabled.
    func stepRelease(_ delta: Int, comboChild: Bool = false) {
        guard !comboChild else { return }
        if !hasReleaseYear {           // first click activates without changing the value
            hasReleaseYear = true
            enforceReleaseYearOrder()
            return
        }
        releaseYear = steppedYear(from: releaseYear, by: delta, in: RowState(self).releaseRange)
        enforceReleaseYearOrder()
    }

    /// A click on the base-year Stepper. No-op while the gate disables it.
    func stepBase(_ delta: Int) {
        guard RowState(self).baseYearAvailable else { return }
        if !hasBaseReleaseYear {
            // Activation commits the placeholder that was on screen, not the value the model
            // was still carrying behind it — see CustomDateStepper.shouldActivateInsteadOfIncrement.
            hasBaseReleaseYear = true
            if let placeholder = RowState(self).basePlaceholderYear { baseReleaseYear = placeholder }
            enforceReleaseYearOrder()
            return
        }
        baseReleaseYear = steppedYear(from: baseReleaseYear, by: delta, in: RowState(self).baseRange)
        enforceReleaseYearOrder()
    }

    /// Delete pressed with a Stepper focused.
    func clearRelease() {
        hasReleaseYear = false
        if hasBaseReleaseYear { hasBaseReleaseYear = false }
    }

    func clearBase() { hasBaseReleaseYear = false }

    /// The invariant every state must satisfy.
    var isLegal: Bool {
        guard hasBaseReleaseYear else { return true }
        guard hasReleaseYear else { return false }
        let r = purchaseYearRange
        return baseReleaseYear < releaseYear
            && r.contains(baseReleaseYear) && r.contains(releaseYear)
    }

    var describe: String {
        "release=\(hasReleaseYear ? String(releaseYear) : "—") base=\(hasBaseReleaseYear ? String(baseReleaseYear) : "—")"
    }
}
