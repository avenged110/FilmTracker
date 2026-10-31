// MARK: - SavedSearchRules.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The rule model behind the saved-search builder sheet: a query as a list of rules, each a
// field, an operator and that operator's values, under one "Match all / any" choice.
//
// Every rule is exactly one search token. A rule is built from a token by recognizing the
// value forms the builder itself writes ("last 3 months", ">2010", "8+"); any other value
// becomes a "matches" rule holding the value exactly as typed. So a query opened in the
// builder and saved again without edits finds the same films, and nothing a user typed in
// the search field is lost or reinterpreted.
//
// Pure Foundation, like 50.30, so it can be tested without the app.

import Foundation

// MARK: - Match Mode

/// How a rule set's positive rules combine. Rules that exclude films ("does not contain",
/// "is not") are exclusions whatever the mode — the engine applies NOT tokens after the
/// AND/OR set is built (SearchController.applyTokens) — and the sheet says so.
enum RuleMatchMode: String, CaseIterable, Hashable, Sendable {
    /// Every positive rule must hold: plain tokens.
    case all
    /// Any positive rule may hold: "/" (OR) tokens.
    case any
    /// Each rule says whether it is AND or OR — the shape of a search-field query that
    /// mixes plain and "/" pills, which neither of the other two can express.
    case custom

    var label: String {
        switch self {
        case .all: return "all of the following rules"
        case .any: return "any of the following rules"
        case .custom: return "the rules as combined below"
        }
    }
}

enum RuleConjunction: String, CaseIterable, Hashable, Sendable {
    case and, or
}

// MARK: - Operators

/// Every operator the builder offers, across all fields. Which ones a field offers, and in
/// what order, is `RuleOperator.options(for:)`.
enum RuleOperator: String, CaseIterable, Hashable, Sendable {
    // Text
    case contains, doesNotContain
    // Genre: one of the app's fixed genres
    case genreIs, genreIsNot
    // Year
    case yearIs, yearIsNot, yearAfter, yearBefore, yearBetween, yearNotBetween
    // Duration
    case durationAtLeast, durationLonger, durationShorter, durationBetween
    // Rating
    case ratingIs, ratingAtLeast, ratingAtMost, ratingBetween, ratingUnrated, ratingRated
    // Dates
    case inTheLast, notInTheLast, moreThanAgo, aboutAgo, dateAfter, dateBefore, dateOn, dateInYear,
         noDate, hasDate
    // List
    case inList, notInList
    // Is
    case flagIs, flagIsNot
    // Release
    case hasRelease, hasNoRelease
    // Rotation threshold
    case rotationIs, rotationIsNot
    // Any field: the value exactly as it would be typed after "#field ".
    case matches, doesNotMatch

    /// What the operator's values are edited with.
    enum Editor: Hashable, Sendable {
        case text, number, numberRange, amountUnit, day, year, none
        case listName, genreName, flagTerm, releaseKeyword, rotationValue, raw

        /// Edited with a menu, so a new row's value starts unchosen ("Select…").
        var isMenu: Bool {
            switch self {
            case .listName, .genreName, .flagTerm, .releaseKeyword, .rotationValue: return true
            default: return false
            }
        }
    }

    var label: String {
        switch self {
        case .contains: return "contains"
        case .doesNotContain: return "does not contain"
        case .yearIs, .ratingIs, .rotationIs, .flagIs, .genreIs, .inList: return "is"
        case .yearIsNot, .rotationIsNot, .flagIsNot, .genreIsNot, .notInList: return "is not"
        case .yearAfter: return "is after"
        case .yearBefore: return "is before"
        case .yearBetween, .durationBetween, .ratingBetween: return "is between"
        case .yearNotBetween: return "is not between"
        case .durationAtLeast: return "is at least"
        case .durationLonger: return "is longer than"
        case .durationShorter: return "is shorter than"
        case .ratingAtLeast: return "is at least"
        case .ratingAtMost: return "is at most"
        case .ratingUnrated: return "is not rated"
        case .ratingRated: return "is rated"
        case .inTheLast: return "is in the last"
        case .notInTheLast: return "is not in the last"
        case .moreThanAgo: return "is more than"
        case .aboutAgo: return "is about"
        case .dateAfter: return "is after"
        case .dateBefore: return "is before"
        case .dateOn: return "is on"
        case .dateInYear: return "is in the year"
        case .noDate: return "has no date"
        case .hasDate: return "has a date"
        case .hasRelease: return "has a release that is"
        case .hasNoRelease: return "has no release that is"
        case .matches: return "matches"
        case .doesNotMatch: return "does not match"
        }
    }

    /// The token this operator writes is inverted ("#!field").
    var isInverted: Bool {
        switch self {
        case .doesNotContain, .genreIsNot, .yearIsNot, .yearNotBetween, .ratingRated, .notInTheLast, .hasDate,
             .notInList, .flagIsNot, .hasNoRelease, .rotationIsNot, .doesNotMatch:
            return true
        default:
            return false
        }
    }

    var editor: Editor {
        switch self {
        case .contains, .doesNotContain: return .text
        case .yearIs, .yearIsNot, .yearAfter, .yearBefore, .durationAtLeast, .durationLonger,
             .durationShorter, .ratingIs, .ratingAtLeast, .ratingAtMost:
            return .number
        case .yearBetween, .yearNotBetween, .durationBetween, .ratingBetween: return .numberRange
        case .ratingUnrated, .ratingRated, .noDate, .hasDate: return .none
        case .inTheLast, .notInTheLast, .moreThanAgo, .aboutAgo: return .amountUnit
        case .dateAfter, .dateBefore, .dateOn: return .day
        case .dateInYear: return .year
        case .inList, .notInList: return .listName
        case .genreIs, .genreIsNot: return .genreName
        case .flagIs, .flagIsNot: return .flagTerm
        case .hasRelease, .hasNoRelease: return .releaseKeyword
        case .rotationIs, .rotationIsNot: return .rotationValue
        case .matches, .doesNotMatch: return .raw
        }
    }

    /// The operators a field offers, in menu order. Every field ends with matches / does
    /// not match, the way to type anything the structured operators do not cover.
    static func options(for field: SearchField) -> [RuleOperator] {
        let specific: [RuleOperator]
        switch field {
        case .title, .crew, .cast, .directors, .producer, .executiveProducer, .screenwriter,
             .composer, .studio, .tags, .notes, .synopsis:
            specific = [.contains, .doesNotContain]
        case .genre:
            specific = [.genreIs, .genreIsNot]
        case .year:
            specific = [.yearIs, .yearIsNot, .yearAfter, .yearBefore, .yearBetween, .yearNotBetween]
        case .duration:
            specific = [.durationAtLeast, .durationLonger, .durationShorter, .durationBetween]
        case .rating:
            specific = [.ratingIs, .ratingAtLeast, .ratingAtMost, .ratingBetween, .ratingUnrated, .ratingRated]
        case .lastWatched, .dateAdded:
            specific = [.inTheLast, .notInTheLast, .moreThanAgo, .aboutAgo, .dateAfter, .dateBefore,
                        .dateOn, .dateInYear, .noDate, .hasDate]
        case .list:
            specific = [.inList, .notInList]
        case .flags:
            specific = [.flagIs, .flagIsNot]
        case .releases:
            specific = [.hasRelease, .hasNoRelease]
        case .rotationThreshold:
            specific = [.rotationIs, .rotationIsNot]
        }
        return specific + [.matches, .doesNotMatch]
    }
}

// MARK: - Values

enum RuleTimeUnit: String, CaseIterable, Hashable, Sendable {
    case days, weeks, months, years

    func label(_ amount: Int) -> String { amount == 1 ? String(rawValue.dropLast()) : rawValue }

    /// Every spelling the canonical parse accepts back: singular and plural only.
    static func from(_ word: String) -> RuleTimeUnit? {
        allCases.first { $0.rawValue == word || String($0.rawValue.dropLast()) == word }
    }
}

/// A calendar day, kept as its three numbers so a rule never shifts across time zones.
struct RuleDay: Hashable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    /// The form the date tokens accept for an exact day.
    var text: String {
        "\(year.zeroPadded(4)).\(month.zeroPadded(2)).\(day.zeroPadded(2))"
    }

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Noon on the day, for a DatePicker: far from either midnight, so no zone moves it.
    func date(calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    static func parse(_ text: String) -> RuleDay? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        return RuleDay(year: y, month: m, day: d)
    }
}

// MARK: - Rule

/// One row of the builder: one token.
struct QueryRule: Identifiable, Hashable, Sendable {
    let id: UUID
    var field: SearchField
    var op: RuleOperator
    /// AND or OR, read only in `.custom` mode and for inverted rules (see RuleSet.query).
    var conjunction: RuleConjunction
    var text: String
    var a: Int
    var b: Int
    var unit: RuleTimeUnit
    var day: RuleDay
    /// What a row added in the builder has yet to be given: each menu shows "Select…" until
    /// chosen, and the rule is left out of the query (and blocks Save) until all are.
    /// Rules read from a token have everything chosen.
    var isFieldChosen = true
    var isOperatorChosen = true
    /// Read only for the menu-valued editors (status, list, release, rotation).
    var isValueChosen = true
    /// Whether a menu-with-"Other…" row shows its text field: true once "Other…" is chosen,
    /// false once a listed value is, nil (decide from the text) for a rule read from a
    /// token. Kept rather than derived, so typing a value that happens to be one of the
    /// choices ("hdr" on the way to "hdr10") never closes the field mid-word.
    var otherChosen: Bool?

    init(id: UUID = UUID(), field: SearchField, op: RuleOperator? = nil, conjunction: RuleConjunction = .and,
         text: String = "", a: Int? = nil, b: Int? = nil, unit: RuleTimeUnit = .months, day: RuleDay? = nil) {
        self.id = id
        self.field = field
        self.op = op ?? RuleOperator.options(for: field)[0]
        self.conjunction = conjunction
        self.text = text
        let defaults = QueryRule.defaultNumbers(for: field)
        self.a = a ?? defaults.a
        self.b = b ?? defaults.b
        self.unit = unit
        self.day = day ?? RuleDay(Date())
    }

    /// A row with nothing chosen: what "+" adds.
    static func blank(conjunction: RuleConjunction = .and) -> QueryRule {
        var rule = QueryRule(field: .title, conjunction: conjunction)
        rule.isFieldChosen = false
        rule.isOperatorChosen = false
        rule.isValueChosen = false
        return rule
    }

    /// Whether every menu in the row has a choice.
    var isChosen: Bool {
        isFieldChosen && isOperatorChosen && (isValueChosen || !op.editor.isMenu)
    }

    /// Sensible starting values when a field is picked: a real range, not 0–0.
    static func defaultNumbers(for field: SearchField) -> (a: Int, b: Int) {
        switch field {
        case .year: return (2000, 2009)
        case .duration: return (90, 120)
        case .rating: return (8, 10)
        case .lastWatched, .dateAdded: return (1, 1)
        default: return (0, 0)
        }
    }

    /// The starting values for `op`'s editor: this year for a year, else the field's own.
    /// The date fields' defaults are amounts ("in the last 1 month"), not years.
    static func defaultNumbers(for field: SearchField, op: RuleOperator) -> (a: Int, b: Int) {
        guard op.editor == .year else { return defaultNumbers(for: field) }
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        return (year, year)
    }

    /// A new rule for `field`, its first operator and default values, keeping the row's
    /// identity and conjunction. What choosing another field in a row's first menu does.
    func changingField(to field: SearchField) -> QueryRule {
        // The condition and any menu value wait to be chosen for the new field.
        var rule = QueryRule(id: id, field: field, conjunction: conjunction)
        rule.isOperatorChosen = false
        rule.isValueChosen = false
        return rule
    }

    /// The value as it goes after "#field " — what the token holds. Typed text is trimmed,
    /// as the search field trims a pill's value: the year, duration and rating filters
    /// read their value exactly, so "2000 " would match nothing.
    var value: String {
        switch op {
        case .contains, .doesNotContain, .genreIs, .genreIsNot, .inList, .notInList, .flagIs, .flagIsNot, .hasRelease,
             .hasNoRelease, .rotationIs, .rotationIsNot, .matches, .doesNotMatch:
            return text.trimmingCharacters(in: .whitespaces)
        case .yearIs, .yearIsNot, .durationAtLeast, .ratingIs: return "\(a)"
        case .yearAfter, .durationLonger: return ">\(a)"
        case .yearBefore, .durationShorter: return "<\(a)"
        case .yearBetween, .yearNotBetween, .durationBetween, .ratingBetween: return "\(a)-\(b)"
        case .ratingAtLeast: return "\(a)+"
        case .ratingAtMost: return "\(a)-"
        case .ratingUnrated, .ratingRated: return "0"
        case .inTheLast, .notInTheLast: return "last \(a) \(unit.label(a))"
        case .moreThanAgo: return "more than \(a) \(unit.label(a)) ago"
        case .aboutAgo: return "\(a) \(unit.label(a)) ago"
        case .dateAfter: return ">" + day.text
        case .dateBefore: return "<" + day.text
        case .dateOn: return day.text
        case .dateInYear: return a.zeroPadded(4)
        case .noDate, .hasDate: return "none"
        }
    }

    func token(isOr: Bool) -> SearchToken {
        SearchToken(field: field, value: value, isInverted: op.isInverted, isOr: isOr)
    }

    /// Why the rule cannot be saved yet, or nil. Shown under the rules; the Save button
    /// waits for every rule to be complete. Empty for a rule with no field yet: the blank
    /// menu already says why Save is disabled, so the gutter stays quiet.
    var problem: String? {
        if !isFieldChosen { return "" }
        if !isOperatorChosen { return "\(field.displayName): Choose a condition." }
        if op.editor.isMenu, !isValueChosen { return "\(field.displayName): Choose a value." }
        switch op.editor {
        case .text, .raw, .listName, .genreName, .releaseKeyword, .rotationValue, .flagTerm:
            return text.trimmingCharacters(in: .whitespaces).isEmpty
                ? "\(field.displayName): Enter a value." : nil
        case .numberRange:
            return a > b ? "\(field.displayName): The first number must not be larger than the second." : nil
        case .number:
            return a < 0 ? "\(field.displayName): Enter a number of zero or more." : nil
        case .amountUnit:
            return a < 1 ? "\(field.displayName): Enter an amount of one or more." : nil
        case .year, .day, .none:
            return nil
        }
    }

    // MARK: Reading a token

    /// The rule for `token`: a structured operator when the value is exactly a form the
    /// builder writes, otherwise "matches" with the value as typed.
    init(token: SearchToken) {
        self.init(field: token.field, conjunction: token.isOr ? .or : .and)
        let v = token.value
        let inv = token.isInverted
        // "matches" unless a structured form is recognized below.
        op = inv ? .doesNotMatch : .matches
        text = v

        switch token.field {
        case .title, .crew, .cast, .directors, .producer, .executiveProducer, .screenwriter,
             .composer, .studio, .tags, .notes, .synopsis:
            op = inv ? .doesNotContain : .contains

        case .genre:
            // One of the fixed genres, exactly as the menu writes it.
            if RuleValues.genres.contains(v) { op = inv ? .genreIsNot : .genreIs }

        case .list:
            op = inv ? .notInList : .inList

        case .releases:
            op = inv ? .hasNoRelease : .hasRelease

        case .rotationThreshold:
            op = inv ? .rotationIsNot : .rotationIs

        case .flags:
            // One known term, exactly as the menu writes it.
            if FilmFlag.terms.contains(where: { $0.display == v }) {
                op = inv ? .flagIsNot : .flagIs
            }

        case .year:
            if let n = Self.int(v) { op = inv ? .yearIsNot : .yearIs; a = n }
            else if !inv, let n = Self.int(v, prefix: ">") { op = .yearAfter; a = n }
            else if !inv, let n = Self.int(v, prefix: "<") { op = .yearBefore; a = n }
            else if let (x, y) = Self.range(v) { op = inv ? .yearNotBetween : .yearBetween; a = x; b = y }

        case .duration where !inv:
            if let n = Self.int(v) { op = .durationAtLeast; a = n }
            else if let n = Self.int(v, prefix: ">") { op = .durationLonger; a = n }
            else if let n = Self.int(v, prefix: "<") { op = .durationShorter; a = n }
            else if let (x, y) = Self.range(v) { op = .durationBetween; a = x; b = y }

        case .rating:
            if v == "0" { op = inv ? .ratingRated : .ratingUnrated }
            else if !inv, let n = Self.int(v) { op = .ratingIs; a = n }
            else if !inv, let n = Self.int(v, suffix: "+") { op = .ratingAtLeast; a = n }
            else if !inv, let n = Self.int(v, suffix: "-") { op = .ratingAtMost; a = n }
            else if !inv, let (x, y) = Self.range(v) { op = .ratingBetween; a = x; b = y }

        case .lastWatched, .dateAdded:
            if v == "none" { op = inv ? .hasDate : .noDate }
            else if let (n, u) = Self.amount(v, prefix: "last ", suffix: "") {
                op = inv ? .notInTheLast : .inTheLast; a = n; unit = u
            }
            else if !inv, let (n, u) = Self.amount(v, prefix: "more than ", suffix: " ago") { op = .moreThanAgo; a = n; unit = u }
            else if !inv, let (n, u) = Self.amount(v, prefix: "", suffix: " ago") { op = .aboutAgo; a = n; unit = u }
            else if !inv, v.hasPrefix(">"), let d = RuleDay.parse(String(v.dropFirst())) { op = .dateAfter; day = d }
            else if !inv, v.hasPrefix("<"), let d = RuleDay.parse(String(v.dropFirst())) { op = .dateBefore; day = d }
            else if !inv, let d = RuleDay.parse(v) { op = .dateOn; day = d }
            else if !inv, v.count == 4, let n = Self.int(v) { op = .dateInYear; a = n }

        default:
            break
        }
    }

    /// A whole number written with no sign, padding or leading zero (so it writes back
    /// identically), between an optional prefix and suffix.
    private static func int(_ v: String, prefix: String = "", suffix: String = "") -> Int? {
        guard v.hasPrefix(prefix), v.hasSuffix(suffix), v.count > prefix.count + suffix.count else { return nil }
        let digits = String(v.dropFirst(prefix.count).dropLast(suffix.count))
        guard digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              digits == "0" || !digits.hasPrefix("0"), let n = Int(digits) else { return nil }
        return n
    }

    private static func range(_ v: String) -> (Int, Int)? {
        let parts = v.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let x = int(String(parts[0])), let y = int(String(parts[1])) else { return nil }
        return (x, y)
    }

    private static func amount(_ v: String, prefix: String, suffix: String) -> (Int, RuleTimeUnit)? {
        guard v.hasPrefix(prefix), v.hasSuffix(suffix) else { return nil }
        let words = v.dropFirst(prefix.count).dropLast(suffix.count).split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 2, let n = int(String(words[0])), n >= 1,
              let unit = RuleTimeUnit.from(String(words[1])), unit.label(n) == String(words[1]) else { return nil }
        return (n, unit)
    }
}

// MARK: - Menu Values

/// The fixed choices the builder's value menus offer.
enum RuleValues {
    /// Release keywords, grouped as the Search Guide groups them. The first spelling of
    /// each keyword the guide lists.
    struct ReleaseKeyword: Hashable, Sendable {
        let keyword: String
        let group: String
    }

    static let releaseKeywords: [ReleaseKeyword] = [
        ("Ownership", ["purchased", "unpurchased"]),
        ("Date", ["upcoming"]),
        ("Format", ["4k", "blu-ray", "dvd"]),
        ("4K master", ["native 4k", "upscaled"]),
        ("HDR", ["hdr", "dolby vision", "hdr10", "hdr10+"]),
        ("Region", ["region a", "region b", "region free", "region 1", "region 2", "region 3", "region 4", "region 5"]),
        ("Other", ["imported", "remastered", "combo-pack", "standalone", "multi-pack"]),
    ].flatMap { group, words in words.map { ReleaseKeyword(keyword: $0, group: group) } }

    /// The app's fixed genres: the FilmSheet's genre menu, less its empty "Select" entry.
    static var genres: [String] { FSTabDetails.genreOptions.filter { !$0.isEmpty } }

    /// Rotation threshold values: the two override keywords, then the six real thresholds.
    static let rotationValues = ["default", "override", "12 months", "18 months", "24 months",
                                 "36 months", "48 months", "60 months"]
}

// MARK: - Rule Set

/// A whole query as the builder edits it.
struct RuleSet: Hashable, Sendable {
    var mode: RuleMatchMode
    var rules: [QueryRule]

    init(mode: RuleMatchMode = .all, rules: [QueryRule] = []) {
        self.mode = mode
        self.rules = rules
    }

    /// The rules for `query`. A multi-term Is pill that is a plain AND token is split into
    /// one rule per term — the same films, since every term must hold either way. The
    /// freeform text becomes a Title "contains" rule ANDed with the rest, which is what the
    /// engine does with it (the two match identically: SearchController.matchesTitle).
    init(query: SavedSearchQuery) {
        var rules: [QueryRule] = []
        for token in query.tokens {
            if token.field == .flags, !token.isOr, !token.isInverted,
               let terms = Self.splitPlainTerms(token.value), terms.count > 1 {
                rules += terms.map { QueryRule(token: SearchToken(field: .flags, value: $0)) }
            } else {
                rules.append(QueryRule(token: token))
            }
        }
        if !SearchText.key(query.text).isEmpty {
            rules.append(QueryRule(field: .title, op: .contains, conjunction: .and, text: query.text))
        }
        let positive = rules.filter { !$0.op.isInverted }
        let mode: RuleMatchMode
        if positive.allSatisfy({ $0.conjunction == .and }) { mode = .all }
        else if positive.allSatisfy({ $0.conjunction == .or }) { mode = .any }
        else { mode = .custom }
        self.init(mode: mode, rules: rules)
    }

    /// The terms of an Is value when each is exactly a known display term, else nil (the
    /// pill then stays one "matches" rule, as typed).
    private static func splitPlainTerms(_ value: String) -> [String]? {
        let terms = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard terms.allSatisfy({ term in FilmFlag.terms.contains { $0.display == term } }) else { return nil }
        return terms
    }

    /// Whether a positive rule is an OR token under the current mode. Inverted rules keep
    /// their own conjunction: the engine treats every inverted token as an exclusion
    /// either way, and keeping it makes an unedited query write back identically.
    private func isOr(_ rule: QueryRule) -> Bool {
        if rule.op.isInverted { return rule.conjunction == .or }
        switch mode {
        case .all: return false
        case .any: return true
        case .custom: return rule.conjunction == .or
        }
    }

    /// The query the rules make. No freeform text: a Title rule is a token.
    var query: SavedSearchQuery {
        var tokens: [SearchToken] = []
        for rule in rules where rule.isChosen {
            let token = rule.token(isOr: isOr(rule))
            if !tokens.contains(token) { tokens.append(token) }
        }
        return SavedSearchQuery(tokens: tokens, text: "")
    }

    /// The first rule's problem, or nil when every rule is complete.
    var problem: String? { rules.lazy.compactMap(\.problem).first }
}

// MARK: - Zero Padding

private extension Int {
    /// The number in at least `width` digits, as "%0*d" formats it — without String(format:),
    /// whose C variadic arguments strict memory safety flags as unsafe.
    func zeroPadded(_ width: Int) -> String {
        let digits = String(magnitude)
        let padding = String(repeating: "0", count: Swift.max(0, width - digits.count))
        return (self < 0 ? "-" : "") + padding + digits
    }
}
