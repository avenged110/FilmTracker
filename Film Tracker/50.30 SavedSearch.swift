// MARK: - SavedSearch.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// A search the user has named and kept: its value type, the form it is stored in, the
// rules its name must meet, and the #list references between saved searches.
//
// Pure Foundation — no SwiftUI, Core Data or app singletons — so it compiles alongside
// 50.10 SearchToken.swift alone and can be tested without the app.

import Foundation

// MARK: - Saved Search Query

/// What a saved search searches for: the pills and the freeform text beside them. Also
/// what a recent search records (SearchController.RecentSearch is this type).
///
/// Only what this build can run. A stored rule this build cannot read (one a newer version
/// wrote) is left out when the search loads, and the search needs review until it is saved
/// again (SavedSearchStore.needsReview).
struct SavedSearchQuery: Hashable, Sendable {
    var tokens: [SearchToken]
    var text: String

    init(tokens: [SearchToken], text: String) {
        self.tokens = tokens
        self.text = text.trimmingCharacters(in: .whitespaces)
    }

    /// Nothing to search for. A query of nothing but punctuation is empty too: it
    /// normalizes to "" and narrows nothing (SearchController.applyFilters).
    var isEmpty: Bool { tokens.isEmpty && SearchText.key(text).isEmpty }

    /// The one-line form the store logs and the recent searches show: the pill labels, then
    /// the quoted text.
    var label: String {
        let pills = tokens.map(\.displayName)
        return (pills + (text.isEmpty ? [] : ["\u{201C}\(text)\u{201D}"])).joined(separator: ", ")
    }
}

// MARK: - Saved Search

/// A named, kept search: a row in the sidebar's Saved Searches section and a gallery view
/// of its own (ViewIdentifier.savedSearch). Values only — SavedSearchStore owns the list
/// and SavedSearchObject is its stored form.
struct SavedSearch: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var query: SavedSearchQuery
    var displayOrder: Int
    let dateCreated: Date
    var dateModified: Date

    init(id: UUID = UUID(), name: String, query: SavedSearchQuery, displayOrder: Int,
         dateCreated: Date = Date(), dateModified: Date? = nil) {
        self.id = id
        self.name = name
        self.query = query
        self.displayOrder = displayOrder
        self.dateCreated = dateCreated
        self.dateModified = dateModified ?? dateCreated
    }
}

// MARK: - Stored Form

/// One token as it is stored. The field is kept as SearchField's raw value, a string, so a
/// field this build does not know still decodes — into SavedSearchCodec.Decoded.dropped,
/// for the log to name.
///
/// Decoded leniently: a missing `value`, `not` or `or` takes its default, so a newer
/// version that leaves out a default value is still read. A token with no readable field
/// decodes with an empty one, which no SearchField has, so it is dropped.
struct StoredToken: Codable, Hashable, Sendable {
    let field: String
    let value: String
    let not: Bool
    let or: Bool

    init(field: String, value: String, not: Bool, or: Bool) {
        self.field = field
        self.value = value
        self.not = not
        self.or = or
    }

    init(_ token: SearchToken) {
        self.init(field: token.field.rawValue, value: token.value, not: token.isInverted, or: token.isOr)
    }

    private enum CodingKeys: String, CodingKey { case field, value, not, or }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = (try? c.decodeIfPresent(String.self, forKey: .field)) ?? ""
        value = (try? c.decodeIfPresent(String.self, forKey: .value)) ?? ""
        not = (try? c.decodeIfPresent(Bool.self, forKey: .not)) ?? false
        or = (try? c.decodeIfPresent(Bool.self, forKey: .or)) ?? false
    }

    /// Stands in for a stored token that is not a JSON object at all, so it is dropped and
    /// logged like any other unreadable rule.
    static let unreadable = StoredToken(field: "", value: "", not: false, or: false)

    /// The token, or nil when this build has no such field.
    var token: SearchToken? {
        SearchField(rawValue: field).map { SearchToken(field: $0, value: value, isInverted: not, isOr: or) }
    }

    /// The token as it would be typed ("/!#field value"), for the log.
    var syntax: String {
        guard !field.isEmpty else { return "(an unreadable rule)" }
        return (or ? "/" : "") + (not ? "!" : "") + "#\(field) \(value)"
    }
}

/// A query's stored form: a JSON string in SavedSearchObject.queryJSON, and so in every
/// backup as a plain string property — no relationship, no Codable attribute for Core Data
/// to migrate. Keys are sorted so one query always encodes to the same bytes.
///
/// `version` is written for a future change of shape. Nothing reads it yet: version 1 is
/// the only one, and a later version is still decoded as far as its keys allow — every key
/// is optional, and anything present but unreadable counts as a dropped rule, so the search
/// is flagged rather than quietly changed.
enum SavedSearchCodec {
    static let currentVersion = 1

    private struct Stored: Codable {
        var version: Int
        var text: String
        var tokens: [StoredToken]
        /// Stored parts this build could not read: an element of `tokens` that is not an
        /// object, or a `text` or `tokens` of the wrong type. Never encoded.
        var unreadable: [StoredToken] = []

        private enum CodingKeys: String, CodingKey { case version, text, tokens }

        init(version: Int, text: String, tokens: [StoredToken]) {
            self.version = version
            self.text = text
            self.tokens = tokens
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? SavedSearchCodec.currentVersion
            if let text = try? c.decodeIfPresent(String.self, forKey: .text) {
                self.text = text
            } else {
                text = ""
                if c.contains(.text) { unreadable.append(.unreadable) }
            }
            tokens = []
            if c.contains(.tokens) {
                if var items = try? c.nestedUnkeyedContainer(forKey: .tokens) {
                    while !items.isAtEnd {
                        if let token = try? items.decode(StoredToken.self) {
                            tokens.append(token)
                        } else {
                            // Not an object: skipped past, so the next element is read.
                            _ = try? items.decode(SkippedValue.self)
                            unreadable.append(.unreadable)
                        }
                    }
                } else if (try? c.decodeNil(forKey: .tokens)) != true {
                    unreadable.append(.unreadable)
                }
            }
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(version, forKey: .version)
            try c.encode(text, forKey: .text)
            try c.encode(tokens, forKey: .tokens)
        }
    }

    /// Any JSON value, read only to move past it.
    private struct SkippedValue: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    static func encode(_ query: SavedSearchQuery) -> String {
        let stored = Stored(version: currentVersion, text: query.text,
                            tokens: query.tokens.map(StoredToken.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding plain strings and booleans cannot fail.
        guard let data = try? encoder.encode(stored) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A decoded query, and the stored tokens left out of it because this build has no
    /// such field.
    struct Decoded {
        let query: SavedSearchQuery
        let dropped: [StoredToken]
    }

    /// The query, or nil when `json` is not a JSON object at all. Tokens keep their stored
    /// order; one this build cannot read — an unknown field, or no object — is left out,
    /// into `dropped`.
    static func decode(_ json: String) -> Decoded? {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: Data(json.utf8)) else { return nil }
        var tokens: [SearchToken] = []
        var dropped: [StoredToken] = stored.unreadable
        for item in stored.tokens {
            if let token = item.token {
                // A repeated pill cannot be typed (SearchController.addToken refuses it),
                // so one is dropped rather than shown twice.
                if !tokens.contains(token) { tokens.append(token) }
            } else {
                dropped.append(item)
            }
        }
        return Decoded(query: SavedSearchQuery(tokens: tokens, text: stored.text), dropped: dropped)
    }
}

// MARK: - #list Name Matching

/// How a `#list` value picks the lists it names: every name or alias whose key equals the
/// value's key, or — only when none does — every one whose key contains it.
///
/// The one copy of the rule. SearchController.filterByList resolves tokens with it, and
/// SavedSearchReferences follows the same references when it looks for cycles; two copies
/// would let a cycle the check missed reach the evaluator.
enum SearchListMatcher {
    /// The indices into `keys` the value names. `keys` are already in SearchText.key form.
    static func matches(_ value: String, keys: [String]) -> [Int] {
        let q = SearchText.key(value)
        let exact = keys.indices.filter { keys[$0] == q }
        if !exact.isEmpty { return exact }
        // fuzzyMatchCore's rule: an empty query is contained in everything.
        return keys.indices.filter { q.isEmpty || keys[$0].contains(q) }
    }
}

// MARK: - Names

/// The rules a saved search's name must meet.
///
/// A saved search's name is also a `#list` name (SearchListCatalog kind `.saved`), so it
/// shares one namespace with every other list a `#list` token can name. Two entries with
/// the same key would both answer the same token — "#list Nolan" would quietly union a
/// user list and a saved search — so a name is refused when its key matches any of them.
/// Keys rather than lowercased names, because keys are what the token matches by:
/// "Owned 4K!" and "owned 4k" are the same `#list` target.
enum SavedSearchName {
    enum ClaimKind: Equatable, Sendable {
        case smartList, filmQueue, recents, report, userList, savedSearch

        var noun: String {
            switch self {
            case .smartList: return "a smart list"
            case .filmQueue: return "the Queue"
            case .recents: return "a Recents tab"
            case .report: return "a report"
            case .userList: return "a list"
            case .savedSearch: return "another saved search"
            }
        }
    }

    /// A name already in use, by whom.
    struct Claim: Equatable, Sendable {
        let key: String
        let name: String
        let kind: ClaimKind

        init(name: String, kind: ClaimKind) {
            self.key = SearchText.key(name)
            self.name = name
            self.kind = kind
        }
    }

    enum Problem: Equatable, Sendable {
        /// Nothing left once trimmed — or nothing a `#list` token could type, since a name
        /// of only punctuation has an empty key.
        case empty
        case taken(Claim)
    }

    /// Why `candidate` cannot be used, or nil when it can. `claims` must leave out the
    /// saved search being renamed, or its own name would refuse itself.
    static func problem(with candidate: String, claims: [Claim]) -> Problem? {
        let key = SearchText.key(candidate)
        guard !key.isEmpty else { return .empty }
        if let claim = claims.first(where: { $0.key == key }) { return .taken(claim) }
        return nil
    }

    /// The name the Save sheet offers: the query's tokens in words and its text (unquoted —
    /// a name is not a quotation), cut at a word boundary to fit a sidebar row, made unique with
    /// " 2", " 3"… as Finder does.
    static func suggestion(for query: SavedSearchQuery, claims: [Claim], maxLength: Int = 32) -> String {
        var base = (query.tokens.map(phrase) + (query.text.isEmpty ? [] : [query.text]))
            .joined(separator: ", ")
        if base.count > maxLength {
            let cut = base.prefix(maxLength)
            let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
            base = word.trimmingCharacters(in: CharacterSet(charactersIn: " ,:")) + "…"
        }
        if SearchText.key(base).isEmpty { base = "Saved Search" }
        return unique(base, claims: claims)
    }

    /// A token as a name would say it: the field's full name rather than the pill's
    /// abbreviation, no "/" (OR is not part of what a search is about), "not" for "!".
    /// A Title or Is token is its value alone ("owned 4k" says what it is).
    private static func phrase(_ token: SearchToken) -> String {
        let value = (token.isInverted ? "not " : "") + token.value
        switch token.field {
        case .title, .flags: return value
        default: return "\(token.field.displayName): \(value)"
        }
    }

    /// `name`, trimmed, when no claim has its key; else the first free "<name> 2",
    /// "<name> 3"…; "Saved Search" (made unique the same way) when it has no key at all.
    /// For a name a restore brings in, which nothing has checked (DBRestorer).
    static func available(_ name: String, claims: [Claim]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return unique(SearchText.key(trimmed).isEmpty ? "Saved Search" : trimmed, claims: claims)
    }

    /// The name Duplicate offers: "<name> copy", then "<name> copy 2"…
    static func duplicate(of name: String, claims: [Claim]) -> String {
        unique(name + " copy", claims: claims)
    }

    private static func unique(_ base: String, claims: [Claim]) -> String {
        let taken = Set(claims.map(\.key))
        guard taken.contains(SearchText.key(base)) else { return base }
        var n = 2
        while taken.contains(SearchText.key("\(base) \(n)")) { n += 1 }
        return "\(base) \(n)"
    }
}

// MARK: - References Between Saved Searches

/// The saved searches each saved search reaches through its `#list` tokens, and the
/// cycles those references can form.
///
/// A saved search can name another with `#list`, which is the point: "Owned 4K backlog"
/// can be built on "Backlog". It can also name itself, directly or through others, and
/// evaluating that would never end. Two defenses, both needed:
///   • Saving or renaming is refused when it would close a cycle (`cycle(…)` below), so the
///     user is told which searches loop and why.
///   • SavedSearchStore.filmIDs(for:) still refuses to re-enter a search it is already
///     evaluating. The check above cannot catch everything: a partial `#list` value
///     ("#list fav") gains a match whenever any list is renamed or created — a user list
///     included — and that is not a saved-search edit.
///
/// Inverted references count: "!#list A" still needs A's films.
enum SavedSearchReferences {
    /// Every name a `#list` token can match, with the saved search it belongs to (nil for
    /// every other kind of list — those are leaves and never lead anywhere).
    private struct Name: Sendable {
        let key: String
        let savedSearchID: UUID?

        init(name: String, savedSearchID: UUID?) {
            self.key = SearchText.key(name)
            self.savedSearchID = savedSearchID
        }
    }

    /// The saved searches `query`'s `#list` tokens name.
    private static func references(of query: SavedSearchQuery, names: [Name]) -> Set<UUID> {
        let keys = names.map(\.key)
        var result: Set<UUID> = []
        for token in query.tokens where token.field == .list {
            for index in SearchListMatcher.matches(token.value, keys: keys) {
                if let id = names[index].savedSearchID { result.insert(id) }
            }
        }
        return result
    }

    /// The cycle saving `candidate` would close, as the IDs around it starting and ending
    /// at the candidate (["A", "B", "A"]), or nil when it closes none.
    ///
    /// `candidate` replaces the saved search with its ID in `searches` (or joins them, when
    /// new), under its own name and query: a rename can close a cycle as surely as an edit
    /// can, by giving some other search's partial `#list` value a new match. `otherNames`
    /// are the names of every list that is not a saved search.
    static func cycle(saving candidate: SavedSearch, among searches: [SavedSearch],
                      otherNames: [String]) -> [UUID]? {
        var all = searches.filter { $0.id != candidate.id }
        all.append(candidate)
        let names = otherNames.map { Name(name: $0, savedSearchID: nil) }
            + all.map { Name(name: $0.name, savedSearchID: $0.id) }
        var edges: [UUID: Set<UUID>] = [:]
        for search in all { edges[search.id] = references(of: search.query, names: names) }

        // Depth-first from the candidate, looking for a way back to it. Only a cycle
        // through the candidate is reported: one elsewhere already existed before this
        // save (the store's guard handles it) and is not this save's to refuse.
        var visited: Set<UUID> = []
        func walk(_ id: UUID, path: [UUID]) -> [UUID]? {
            for next in (edges[id] ?? []).sorted(by: { $0.uuidString < $1.uuidString }) {
                if next == candidate.id { return path + [next] }
                guard visited.insert(next).inserted else { continue }
                if let found = walk(next, path: path + [next]) { return found }
            }
            return nil
        }
        return walk(candidate.id, path: [candidate.id])
    }

    /// The message for a cycle: "“A” names “B”, which names “A”."
    static func message(for cycle: [UUID], names: [UUID: String]) -> String {
        let quoted = cycle.map { "\u{201C}\(names[$0] ?? "?")\u{201D}" }
        guard quoted.count > 1 else { return "" }
        if quoted.count == 2 { return "\(quoted[0]) would include itself through #list." }
        let middle = quoted.dropFirst().dropLast().map { "\($0), which names" }.joined(separator: " ")
        return "\(quoted[0]) names \(middle) \(quoted.last!) — a search cannot include itself."
    }
}
