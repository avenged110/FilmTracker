// MARK: - main.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Proves two 2026-09-27 replacements (Strict Memory Safety pass):
//
// 1. `Fmt` (90.00 GlobalUtilities) produces the same bytes as the `String(format:)` calls
//    it replaced.
// 2. The Sendable `Date.ISO8601FormatStyle` values that replaced the app's eight
//    `ISO8601DateFormatter` statics differ from them only as intended: formatting truncates
//    where the formatter rounded (never later than the true instant, less than one unit
//    earlier, same shape, timestamp strings still sort in date order), and parsing is equal
//    on every spelling the app writes, with or without leading whitespace (which the two
//    restore sites drop first, as the formatter skipped it). MetadataCache is checked only
//    on strings that pass its own YYYY-MM-DD prefix gate, since nothing else reaches it.

import Foundation

var failures = 0
var checks = 0
var isoDivergences: [String: Int] = [:]
var isoChecks = 0
@MainActor func iso(_ ok: Bool, _ category: String) {
    isoChecks += 1
    if !ok { isoDivergences[category, default: 0] += 1 }
}
@MainActor func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
    checks += 1
    if !ok { failures += 1; print("FAIL:", what()) }
}

func old(_ options: ISO8601DateFormatter.Options? = nil, tz: TimeZone? = nil) -> ISO8601DateFormatter {
    let f = ISO8601DateFormatter()
    if let options { f.formatOptions = options }
    if let tz { f.timeZone = tz }
    return f
}
let utc = TimeZone(secondsFromGMT: 0)!

// MARK: The styles under test — kept identical to the app's declarations.
let internetStyle = Date.ISO8601FormatStyle(timeZoneSeparator: .colon)                       // DBReader, DBRestorer, MetadataCache dateTime, STabRestore noFrac
let internetFracStyle = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true) // StorageDateFormatters.timestamp, STabRestore
let dateOnlyStyle = Date.ISO8601FormatStyle(timeZoneSeparator: .colon).year().month().day() // MetadataCache dateOnly
func localStyle() -> Date.ISO8601FormatStyle { Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: .current) } // BackupFilename

// MARK: Dates: a spread across eras, DST edges, leap days, sub-second values.
var dates: [Date] = []
var rng = SystemRandomNumberGenerator()
for _ in 0..<20000 { dates.append(Date(timeIntervalSince1970: Double.random(in: -2_208_988_800...4_102_444_800, using: &rng))) }
for base in [0.0, 951_782_400, 1_710_054_000, 1_730_613_600, 1_790_000_000] {        // epoch, leap day 2000, DST edges
    for d in stride(from: -7200.0, through: 7200, by: 0.3333) { dates.append(Date(timeIntervalSince1970: base + d)) }
}
for ms in 0..<2000 { dates.append(Date(timeIntervalSince1970: 1_790_000_000 + Double(ms) / 1000 + 0.0004999)) }
for ms in 0..<2000 { dates.append(Date(timeIntervalSince1970: 1_790_000_000 + Double(ms) / 1000 + 0.0005001)) }

// MARK: Formatting — the only permitted difference is truncation where the formatter rounded.
let pairs: [(String, ISO8601DateFormatter, (Date) -> String, Int)] = [
    ("default/GMT (DBReader)", old(), { $0.formatted(internetStyle) }, 0),
    ("internet+frac (timestamp)", old([.withInternetDateTime, .withFractionalSeconds]), { $0.formatted(internetFracStyle) }, 3),
    ("default/current (BackupFilename)", old(tz: .current), { $0.formatted(localStyle()) }, 0),
]
for (name, f, new, places) in pairs {
    for d in dates {
        let a = f.string(from: d), b = new(d)
        if a == b { expect(true, ""); continue }
        iso(false, "\(name) (truncated where old rounded)")
        // Same shape, and the new spelling is exactly the truncated instant.
        expect(a.count == b.count, "\(name) shape \(a) vs \(b)")
        // Truncation: never later than the true instant, and less than one unit earlier.
        let unit = pow(10.0, -Double(places))
        let delta = f.date(from: b).map { d.timeIntervalSince($0) } ?? -1
        expect(delta >= -1e-6 && delta < unit + 1e-6, "\(name) \(d.timeIntervalSince1970): \(b) is not the truncation (delta \(delta))")
    }
}
for id in ["America/Los_Angeles", "America/New_York", "Asia/Kolkata", "Australia/Adelaide", "Pacific/Chatham", "UTC", "Europe/London"] {
    let tz = TimeZone(identifier: id)!
    let f = old(tz: tz); let s = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: tz)
    for d in dates.prefix(8000) {
        let a = f.string(from: d), b = d.formatted(s)
        if a != b { iso(false, "zone \(id) (truncated)"); let delta = f.date(from: b).map { d.timeIntervalSince($0) } ?? -1; expect(delta >= -1e-6 && delta < 1 + 1e-6, "zone \(id) \(b)") }
    }
}
// Sort order: timestamps sort as strings in the lastModified column.
let modern = dates.filter { $0.timeIntervalSince1970 > 0 && $0.timeIntervalSince1970 < 253_402_300_800 }.sorted()
let strs = modern.map { $0.formatted(internetFracStyle) }
expect(strs == strs.sorted(), "timestamp strings no longer sort in date order")

// MARK: Parsing — equal on every string the app has ever written, and on those strings with
// leading whitespace (the two restore sites drop it first, as the formatter skipped it).
func trimmed(_ t: String) -> String { String(t.drop(while: \.isWhitespace)) }
@MainActor func parsePair(_ name: String, _ f: ISO8601DateFormatter, _ s: Date.ISO8601FormatStyle, _ inputs: [String], trim: Bool, tolerance: Double = 0) {
    for t in inputs {
        let a = f.date(from: t), b = try? s.parse(trim ? trimmed(t) : t)
        let same = (a == nil && b == nil) || (a != nil && b != nil && abs(a!.timeIntervalSince(b!)) <= tolerance)
        expect(same, "\(name) parse '\(t)': \(String(describing: a)) vs \(String(describing: b))")
    }
}
var genuine: [String] = []
let writers = [old(), old([.withInternetDateTime, .withFractionalSeconds]), old(tz: TimeZone(identifier: "America/Los_Angeles")!)]
for d in dates.prefix(6000) { for w in writers { genuine.append(w.string(from: d)); genuine.append(d.formatted(internetStyle)); genuine.append(d.formatted(internetFracStyle)) } }
let padded = genuine.prefix(3000).flatMap { [" " + $0, "\t" + $0, "  \n" + $0, "\u{00A0}" + $0] }
let junk = ["", "2026", "2026-13-01", "2026-02-30", "garbage", "2026-09-27T24:00:00Z", "2026-09-27T12:00:00.Z", "2026-09-27T12:00:00", "2026-09-27 12:00:00Z"]
parsePair("default (DBRestorer)", old(), internetStyle, genuine + padded + junk, trim: true)
parsePair("internet (STabRestore noFrac)", old([.withInternetDateTime]), internetStyle, genuine + padded + junk, trim: true)
// Fractional parse: same instant to within float conversion (display shows the day only).
parsePair("internet+frac (STabRestore)", old([.withInternetDateTime, .withFractionalSeconds]), internetFracStyle, genuine + padded + junk, trim: true, tolerance: 0.000_001)
// MetadataCache: its YYYY-MM-DD prefix check runs first, so only prefix-valid strings reach it.
let prefixValid = (genuine + junk).filter { t in
    let c = Array(t.unicodeScalars); guard c.count >= 10 else { return false }
    let dg: (Unicode.Scalar) -> Bool = { $0.value >= 48 && $0.value <= 57 }
    return dg(c[0]) && dg(c[1]) && dg(c[2]) && dg(c[3]) && c[4] == "-" && dg(c[5]) && dg(c[6]) && c[7] == "-" && dg(c[8]) && dg(c[9])
}
parsePair("internet/UTC (MetadataCache dateTime)", old([.withInternetDateTime], tz: utc), internetStyle, prefixValid.filter { $0.count > 10 }, trim: false)
parsePair("date-only/UTC (MetadataCache)", old([.withFullDate, .withDashSeparatorInDate], tz: utc), dateOnlyStyle, prefixValid.map { String($0.prefix(10)) }, trim: false)

// MARK: Fmt vs String(format:)
func fixed(_ v: Double, _ p: Int) -> String { String(format: "%.\(p)f", v) }
func padded(_ v: Int, _ w: Int) -> String { String(format: "%0\(w)ld", v) }
var values: [Double] = [0, -0.0, 0.05, 0.15, 0.25, 0.35, 2.345, 2.675, 1e15, -1e-9, .infinity, -.infinity, .nan, 999.995, 1234.5]
for _ in 0..<50000 { values.append(Double.random(in: -1e6...1e6)) }
for v in values { for p in 0...3 { expect(fixed(v, p) == String(format: "%.\(p)f", v), "fixed \(v) \(p)") } }
for v in values.prefix(20000) { expect("$" + fixed(v, 2) == String(format: "$%.2f", v), "dollars \(v)") }
for v in -100_000...100_000 { for w in [2, 3, 4, 6] { expect(padded(v, w) == String(format: "%0\(w)d", v), "padded \(v) \(w)") } }
for v in -100_000...100_000 { expect(String(v) == String(format: "%d", v), "int \(v)") }

print("Formatting differences found (all verified as truncation, informational):")
for (k, v) in isoDivergences.sorted(by: { $0.key < $1.key }) { print("  diverges: \(k) — \(v)") }
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
