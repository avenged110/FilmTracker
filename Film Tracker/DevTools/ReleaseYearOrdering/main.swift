// MARK: - main.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
import Foundation

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { print("  ✅ \(label)") }
    else { failures += 1; print("  ❌ \(label)\(detail().isEmpty ? "" : " — \(detail())")") }
}

// A Blu-ray (floor 2006) for a 1980 film — the scenario in the change request.
func bluRay1980() -> Model { Model(currentYear: 2026, formatFloor: 2006, filmReleaseYear: 1980) }

print("Test 1 — base-year Stepper is capped at releaseYear - 1 and wraps to the floor")
do {
    let m = bluRay1980()
    m.hasReleaseYear = true
    m.releaseYear    = 2010
    m.stepBase(+1)                                   // activation
    check("activates at 2009", m.baseReleaseYear == 2009 && m.hasBaseReleaseYear, m.describe)
    m.stepBase(+1)                                   // at the cap → wraps
    check("increment at the cap wraps to the 2006 floor", m.baseReleaseYear == 2006, m.describe)
    check("release year untouched by the wrap", m.releaseYear == 2010, m.describe)
    for _ in 0..<3 { m.stepBase(+1) }
    check("cycles 2006→2009 without touching the release year",
          m.baseReleaseYear == 2009 && m.releaseYear == 2010, m.describe)
    m.stepBase(-1)
    check("decrement steps down normally", m.baseReleaseYear == 2008, m.describe)
    m.stepBase(-1); m.stepBase(-1)
    check("reaches the floor", m.baseReleaseYear == 2006, m.describe)
    m.stepBase(-1)
    check("decrement at the floor wraps to the cap, not past the release year",
          m.baseReleaseYear == 2009 && m.releaseYear == 2010, m.describe)
}

print("Test 2 — decrementing the release year drags the base year down")
do {
    let m = bluRay1980()
    m.hasReleaseYear = true; m.releaseYear = 2010
    m.stepBase(+1)                                   // base = 2009
    m.stepRelease(-1); m.stepRelease(-1)             // release 2010 → 2008
    check("release 2008 pushes base to 2007",
          m.releaseYear == 2008 && m.baseReleaseYear == 2007, m.describe)
    m.stepRelease(-1)                                // 2007
    check("release 2007 pushes base to 2006",
          m.releaseYear == 2007 && m.baseReleaseYear == 2006, m.describe)
    m.stepRelease(-1)                                // 2006 — the floor
    check("release on the floor clears the base year",
          m.releaseYear == 2006 && !m.hasBaseReleaseYear, m.describe)
    check("base-year Stepper is disabled on the floor", !RowState(m).baseYearAvailable)
    check("release year survives, exactly as entered", m.releaseYear == 2006, m.describe)
}

print("Test 3 — the release year is NEVER written by the ordering rule")
do {
    // Every reachable click sequence of length ≤ 7 over four card shapes, checking that the
    // release year only ever changes as the direct result of a release-year click.
    let shapes: [(String, () -> Model)] = [
        ("Blu-ray / 1980 film", { Model(currentYear: 2026, formatFloor: 2006, filmReleaseYear: 1980) }),
        ("4K / 2016 film",      { Model(currentYear: 2026, formatFloor: 2016, filmReleaseYear: 2016) }),
        ("DVD / no film year",  { Model(currentYear: 2026, formatFloor: 1997, filmReleaseYear: 0) }),
        ("degenerate range",    { Model(currentYear: 2026, formatFloor: 2006, filmReleaseYear: 2026) }),
    ]
    enum Click: CaseIterable { case relUp, relDown, baseUp, baseDown, clearRel, clearBase }
    var illegal = 0, clobbered = 0, states = 0

    func walk(_ m: Model, _ depth: Int) {
        states += 1
        if !m.isLegal { illegal += 1; print("     illegal state: \(m.describe)") }
        guard depth > 0 else { return }
        for c in Click.allCases {
            let n = Model(currentYear: m.currentYear, formatFloor: m.formatFloor,
                          filmReleaseYear: m.filmReleaseYear)
            n.releaseYear = m.releaseYear; n.hasReleaseYear = m.hasReleaseYear
            n.baseReleaseYear = m.baseReleaseYear; n.hasBaseReleaseYear = m.hasBaseReleaseYear
            let before = (n.releaseYear, n.hasReleaseYear)
            switch c {
            case .relUp:     n.stepRelease(+1)
            case .relDown:   n.stepRelease(-1)
            case .baseUp:    n.stepBase(+1)
            case .baseDown:  n.stepBase(-1)
            case .clearRel:  n.clearRelease()
            case .clearBase: n.clearBase()
            }
            let touchedRelease = (n.releaseYear, n.hasReleaseYear) != before
            let mayTouch = (c == .relUp || c == .relDown || c == .clearRel)
            if touchedRelease && !mayTouch {
                clobbered += 1
                print("     \(c) rewrote the release year: \(m.describe) → \(n.describe)")
            }
            walk(n, depth - 1)
        }
    }
    for (name, make) in shapes {
        let before = (illegal, clobbered)
        walk(make(), 7)
        check("\(name): no illegal state, no clobbered release year",
              (illegal, clobbered) == before)
    }
    print("     \(states) states explored")
}

print("Test 4 — combo-pack child (release year locked) behaves identically")
do {
    let m = Model(currentYear: 2026, formatFloor: 2006, filmReleaseYear: 2016)
    m.hasReleaseYear = true; m.releaseYear = 2020      // inherited from the 4K parent
    m.stepBase(+1)
    check("activates at 2019", m.baseReleaseYear == 2019, m.describe)
    m.stepBase(+1)
    check("wraps to the 2016 floor rather than sticking at 2019",
          m.baseReleaseYear == 2016, m.describe)
    m.stepRelease(+1, comboChild: true)
    check("the child's own release-year Stepper is inert",
          m.releaseYear == 2020, m.describe)

    // Parent's release year drops onto the child's floor → the base year is cleared.
    let c = Model(currentYear: 2026, formatFloor: 2006, filmReleaseYear: 2016)
    c.hasReleaseYear = true; c.releaseYear = 2018
    c.stepBase(+1)
    c.releaseYear = 2016; c.enforceReleaseYearOrder()  // syncComboChildFields
    check("a parent sync onto the floor clears the child's base year",
          c.releaseYear == 2016 && !c.hasBaseReleaseYear, c.describe)
}

print("Test 5 — repair paths a Stepper range cannot reach (load, restore, a rising floor)")
do {
    let m = bluRay1980()                                // stored: base ≥ release
    m.hasReleaseYear = true; m.hasBaseReleaseYear = true
    m.releaseYear = 2010; m.baseReleaseYear = 2015
    m.enforceReleaseYearOrder()
    check("inverted stored pair repairs to 2009, release intact",
          m.releaseYear == 2010 && m.baseReleaseYear == 2009, m.describe)

    m.filmReleaseYear = 2010                            // Details tab raises the floor onto it
    m.enforceReleaseYearOrder()
    check("a floor risen to the release year clears the base year",
          m.releaseYear == 2010 && !m.hasBaseReleaseYear, m.describe)

    let d = Model(currentYear: 2026, formatFloor: 2006, filmReleaseYear: 2026)  // one-year range
    d.hasReleaseYear = true; d.hasBaseReleaseYear = true
    d.enforceReleaseYearOrder()
    check("degenerate range clears the base year", !d.hasBaseReleaseYear, d.describe)

    let f = bluRay1980()                                // future film year → clamped range
    f.filmReleaseYear = 2099
    check("a future film year still yields a constructible range",
          f.purchaseYearRange == 2026...2026)
}

print("Test 6 — the placeholder tells the truth about what activation will commit")
do {
    let m = bluRay1980()
    check("no release year: the base-year Stepper is disabled and shows dashes",
          !RowState(m).baseYearAvailable && m.baseYearLabel == .dashes)

    m.hasReleaseYear = true; m.releaseYear = 2010
    check("placeholder reads 2009 under a 2010 release year", m.baseYearLabel == .year(2009))
    m.stepRelease(+1)
    check("placeholder tracks the release-year Stepper live (2011 → 2010)",
          m.releaseYear == 2011 && m.baseYearLabel == .year(2010))
    m.stepRelease(-1); m.stepRelease(-1); m.stepRelease(-1); m.stepRelease(-1)
    check("placeholder follows it back down (2007 → 2006)",
          m.releaseYear == 2007 && m.baseYearLabel == .year(2006))
    m.stepRelease(-1)
    check("release year on the floor: the Stepper disables and reverts to dashes",
          m.releaseYear == 2006 && m.baseYearLabel == .dashes)

    // The promise itself: whatever the placeholder shows is what the first click commits.
    for releaseYear in 2007...2026 {
        let c = bluRay1980()
        c.hasReleaseYear = true; c.releaseYear = releaseYear
        guard case .year(let shown) = c.baseYearLabel else {
            check("placeholder is a year at release year \(releaseYear)", false); continue
        }
        c.stepBase(+1)
        if !(c.hasBaseReleaseYear && c.baseReleaseYear == shown) {
            check("activation commits the placeholder at release year \(releaseYear)", false,
                  "showed \(shown), committed \(c.describe)")
        }
    }
    check("activation commits exactly the placeholder, for every release year 2007…2026", true)
}

print("Test 7 — a stale model value behind a cleared field cannot leak through activation")
do {
    // Clearing the base year leaves the model still carrying the year it held (the Delete
    // path writes only the has-flag). With the release year at the range ceiling, that stale
    // year is already legal, so the ordering rule would NOT correct it — the placeholder
    // would have promised one year and the click delivered another.
    let m = bluRay1980()
    m.hasReleaseYear = true; m.releaseYear = 2010
    m.stepBase(+1)                                   // base = 2009
    for _ in 0..<3 { m.stepBase(-1) }                // base = 2006
    m.clearBase()
    check("model still carries the cleared year", m.baseReleaseYear == 2006 && !m.hasBaseReleaseYear)
    m.releaseYear = 2026; m.enforceReleaseYearOrder()
    check("placeholder reads 2025 after the release year moves", m.baseYearLabel == .year(2025))
    m.stepBase(+1)
    check("re-activation commits 2025, not the stale 2006",
          m.baseReleaseYear == 2025, m.describe)
}

print("")
if failures == 0 { print("✅ ALL TESTS PASSED"); exit(0) }
print("❌ \(failures) FAILED"); exit(1)
