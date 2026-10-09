// MARK: - main.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Proves ReleaseOrigin — the single country-of-origin table — reproduces, exactly, the
// four independent copies it replaced, plus the "is import?" clause that was written
// out by hand at five sites. Each "old" value below is the literal as it stood in the
// file it came from before the unification (2026-09-13), with the user's shortened
// sidebar forms ("AU", "NZ") applied.

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

// ── Old copy 1: ReleaseCard's picker menu, in order ────────────────────────────────
let oldPickerOrder = [
    "United States", "England", "Canada", "Germany", "Australia", "Japan",
    "France", "New Zealand", "Italy", "Finland", "Sweden", "Spain"
]

// ── Old copy 2: RSBHelpers.originDemonym (sidebar), after the user's AU/NZ edit ───
func oldSidebarDemonym(_ o: String) -> String {
    switch o {
    case "United States": return "U.S."
    case "England":       return "English"
    case "Canada":        return "Canadian"
    case "Germany":       return "German"
    case "Australia":     return "AU"
    case "Japan":         return "Japanese"
    case "France":        return "French"
    case "New Zealand":   return "NZ"
    case "Italy":         return "Italian"
    case "Finland":       return "Finnish"
    case "Sweden":        return "Swedish"
    case "Spain":         return "Spanish"
    default:              return o
    }
}

// ── Old copy 3: PDFReport.originDemonym (import notes; never sees "United States") ──
func oldPDFDemonym(_ o: String) -> String {
    switch o {
    case "England":     return "English"
    case "Canada":      return "Canadian"
    case "Germany":     return "German"
    case "Australia":   return "Australian"
    case "Japan":       return "Japanese"
    case "France":      return "French"
    case "New Zealand": return "New Zealand"
    case "Italy":       return "Italian"
    case "Finland":     return "Finnish"
    case "Sweden":      return "Swedish"
    case "Spain":       return "Spanish"
    default:            return o
    }
}

// ── Old copy 4: ReleaseRegionRules.regionAOnlyOrigins ─────────────────────────────
let oldRegionA: Set<String> = ["United States", "Canada", "Japan"]

// ── Old hand-written import clause (RSBHelpers, PDFReport, DataViz, Search, Card) ──
func oldIsImport(_ o: String) -> Bool { !o.isEmpty && o != "United States" }

// Probe every known name plus the two edge inputs every consumer must tolerate.
let probes = oldPickerOrder + ["", "Norway", "united states", "United States "]

check(ReleaseOrigin.names == oldPickerOrder, "picker order")
check(ReleaseOrigin.domestic == "United States", "domestic")
check(Set(ReleaseOrigin.all.filter(\.isRegionA).map(\.name)) == oldRegionA, "Region A set")
check(Set(ReleaseOrigin.all.map(\.name)).count == ReleaseOrigin.all.count, "names unique")

for p in probes {
    check(ReleaseOrigin.shortForm(for: p) == oldSidebarDemonym(p), "sidebar form for '\(p)'")
    check(ReleaseOrigin.isImport(p) == oldIsImport(p), "isImport for '\(p)'")
    if p != "United States" {
        // The PDF only ever asks about imports, so the domestic demonym is out of scope.
        check(ReleaseOrigin.demonym(for: p) == oldPDFDemonym(p), "PDF demonym for '\(p)'")
    }
    check((ReleaseOrigin.lookup(p) != nil) == oldPickerOrder.contains(p), "lookup for '\(p)'")
}

let total = 4 + probes.count * 4 - 1
print(failures == 0 ? "PASS — \(total) checks, 0 failures" : "FAIL — \(failures) of \(total) checks")
exit(failures == 0 ? 0 : 1)
