// MARK: - Country of Origin Vocabulary
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Every country a release can be from, and everything the app says about each one.
///
/// THE single source of truth for national origin. Before this existed the same list was
/// written out three times — as the card's picker menu (`ReleaseCard`), as the sidebar's
/// demonym switch (`RSBHelpers`), and as the PDF's import-note switch (`PDFReport`) —
/// plus a fourth partial copy as the Region A set below, plus the literal "United States"
/// spelled at half a dozen "is this an import?" sites. Adding a country meant finding all
/// of them. Now a country is one row here, and the picker order, both display forms, the
/// region rule, and the domestic test all derive from it.
///
/// - `name`: the stored `nationalOrigin` value, verbatim. Persisted as-is and never
///   validated on read, so the picker tolerates a stored value not in this list (see
///   `TaggedPicker`); everything else treats an unknown name as its own display form.
/// - `demonym`: the adjective a reader would use — "German import", "German Blu-ray".
/// - `shortForm`: the compact spelling the sidebar's Source for Viewing field uses in
///   place of the demonym, where width is scarce. `nil` means the demonym is short enough.
/// - `isRegionA`: Blu-ray region for discs pressed there; everything else is Region B.
struct ReleaseOrigin: Sendable {
    let name: String
    let demonym: String
    let shortForm: String?
    let isRegionA: Bool

    /// Rows in picker order. `domestic` is first because it is the default.
    static let all: [ReleaseOrigin] = [
        ReleaseOrigin(name: "United States", demonym: "American",   shortForm: "U.S.", isRegionA: true),
        ReleaseOrigin(name: "England",       demonym: "English",    shortForm: nil,    isRegionA: false),
        ReleaseOrigin(name: "Canada",        demonym: "Canadian",   shortForm: nil,    isRegionA: true),
        ReleaseOrigin(name: "Germany",       demonym: "German",     shortForm: nil,    isRegionA: false),
        ReleaseOrigin(name: "Australia",     demonym: "Australian", shortForm: "AU",   isRegionA: false),
        ReleaseOrigin(name: "Japan",         demonym: "Japanese",   shortForm: nil,    isRegionA: true),
        ReleaseOrigin(name: "France",        demonym: "French",     shortForm: nil,    isRegionA: false),
        ReleaseOrigin(name: "New Zealand",   demonym: "New Zealand", shortForm: "NZ",  isRegionA: false),
        ReleaseOrigin(name: "Italy",         demonym: "Italian",    shortForm: nil,    isRegionA: false),
        ReleaseOrigin(name: "Finland",       demonym: "Finnish",    shortForm: nil,    isRegionA: false),
        ReleaseOrigin(name: "Sweden",        demonym: "Swedish",    shortForm: nil,    isRegionA: false),
        ReleaseOrigin(name: "Spain",         demonym: "Spanish",    shortForm: nil,    isRegionA: false),
    ]

    /// The stored names in picker order — what the card's menu offers.
    static let names: [String] = all.map(\.name)

    /// The one origin that is not an import: the library's home market, and the default
    /// for a new release.
    static let domestic = "United States"

    private static let byName: [String: ReleaseOrigin] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    /// The row for a stored name, or nil for a name this list does not know.
    static func lookup(_ name: String) -> ReleaseOrigin? { byName[name] }

    /// True for a release from anywhere but `domestic`. An EMPTY origin is the unset
    /// state, not a foreign one, and says nothing either way — every consumer of this
    /// question had written that clause out by hand, identically.
    static func isImport(_ name: String) -> Bool {
        !name.isEmpty && name != domestic
    }

    /// The adjective for a stored name. An unknown name comes back unchanged, so a
    /// restored record with a country not in the list degrades to "Norway import" rather
    /// than to nothing.
    static func demonym(for name: String) -> String {
        byName[name]?.demonym ?? name
    }

    /// The compact form for the sidebar: the short form where one is defined, else the
    /// demonym, else the unknown name unchanged.
    static func shortForm(for name: String) -> String {
        guard let row = byName[name] else { return name }
        return row.shortForm ?? row.demonym
    }
}

