// MARK: - FilmLinkObj.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// Join model recording that one film is related to another (a sequel, a remake…).

import Foundation
import CoreData

// MARK: - Link Kind Vocabulary
/// The stored vocabulary for `FilmLink.kind`. Open, like every stored vocabulary in this app:
/// the value is persisted verbatim and an unknown one (a newer build's, a hand-edited backup's)
/// round-trips untouched, so this is a namespace of constants, not a case set.
///
/// A link reads as one sentence: "**source** is a *kind* of **target**". "Remake" on
/// (Film 2 → Film 1) says Film 2 is a remake of Film 1. The reverse reading ("remade as") is
/// worked out when shown and never stored.
enum FilmLinkKind {
    static let sequel  = "Sequel"
    static let prequel = "Prequel"
    static let remake  = "Remake"
    static let reboot  = "Reboot"
    static let spinOff = "Spin-off"

    /// Canonical order, for a picker.
    static let all = [sequel, prequel, remake, reboot, spinOff]

    /// The kind as the store keeps it: surrounding whitespace removed. Empty means none.
    static func normalized(_ kind: String) -> String { kind.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The form two kinds are compared in: trimmed and case-folded, so a hand-edited "sequel"
    /// joins the chain a picker's "Sequel" starts (the cycle rule works per kind).
    static func key(_ kind: String) -> String {
        normalized(kind).folding(options: [.caseInsensitive], locale: nil)
    }

    /// A kind's place in a sorted list: the picker's kinds in `all` order, then any other kind
    /// alphabetically by key.
    static func sortRank(_ kind: String) -> (Int, String) {
        let k = key(kind)
        if let index = allKeys.firstIndex(of: k) { return (index, "") }
        return (allKeys.count, k)
    }
    private static let allKeys = all.map(key)
}

// MARK: - Rules
/// The invariants every film link obeys, as pure functions over plain values, so the write
/// path, the restore and the launch cleanup cannot disagree about them:
///
///   1. no film is linked to itself;
///   2. at most one link per film pair, in either direction and of any kind;
///   3. no cycle among links of one kind ("A sequel of B, B of C, C of A"), so a chain of
///      one kind always ends;
///   4. both films exist (orphans are removed; see DataManager.cleanupFilmLinks).
enum FilmLinkRules {
    /// The pair a link occupies, regardless of direction.
    struct Pair: Hashable {
        let low: UUID, high: UUID
        init(_ a: UUID, _ b: UUID) {
            if !FilmLinkRules.uuidPrecedes(b, a) { low = a; high = b } else { low = b; high = a }
        }
    }

    /// Whether `lhs` sorts before `rhs` by their 16 bytes, which is the order their
    /// `uuidString`s sort in (fixed-width uppercase hex with the hyphens in the same places),
    /// without building either string: `Pair` is formed for every link a rule check reads.
    static func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        let l = lhs.fingerprintHalves, r = rhs.fingerprintHalves
        return l.0 != r.0 ? l.0 < r.0 : l.1 < r.1
    }

    /// One existing link, as the rules need it.
    struct Edge {
        let source: UUID, target: UUID, kind: String
    }

    /// Links by kind, as adjacency lists, for the cycle test. Built up one link at a time, so
    /// the sieve's cost grows with the links one kind's chain actually reaches, not with
    /// rebuilding the whole graph for every link.
    struct Graph {
        private var next: [String: [UUID: [UUID]]] = [:]

        init(_ edges: [Edge] = []) { for edge in edges { add(edge) } }

        mutating func add(_ edge: Edge) {
            next[FilmLinkKind.key(edge.kind), default: [:]][edge.source, default: []].append(edge.target)
        }

        /// Whether adding `source → target` of `kind` would close a cycle of that kind: whether
        /// `source` is already reachable from `target` along links of the same kind. A
        /// self-link is a cycle of length one.
        ///
        /// A link already on the pair is left out (setting a pair replaces its link): a direct
        /// `target → source` link is not followed, and `source → target` never is (the walk
        /// stops on reaching `source`). So a graph of every live link answers for any pair,
        /// and one graph can answer for every film a picker offers.
        func closesCycle(source: UUID, target: UUID, kind: String) -> Bool {
            if source == target { return true }
            guard let next = next[FilmLinkKind.key(kind)] else { return false }
            var stack = [target], seen: Set<UUID> = [target]
            while let film = stack.popLast() {
                for following in next[film] ?? [] {
                    if film == target, following == source { continue }
                    if following == source { return true }
                    if seen.insert(following).inserted { stack.append(following) }
                }
            }
            return false
        }
    }

    /// `Graph(edges).closesCycle(…)`, for a single question.
    static func closesCycle(source: UUID, target: UUID, kind: String, in edges: [Edge]) -> Bool {
        Graph(edges).closesCycle(source: source, target: target, kind: kind)
    }

    /// Why `sieve` refused a link.
    enum Rejection: String, Sendable {
        case orphan = "without both films"
        case selfLink = "from a film to itself"
        case emptyKind = "with no kind"
        case repeatedID = "repeating a kept link's ID"
        case repeatedPair = "on a pair of films already linked"
        case cycle = "closing a cycle of one kind"
    }

    /// Keeps the links that obey every rule, taking `items` in the order given: an earlier
    /// link wins over a later one that repeats its pair or would close a cycle with it. The
    /// launch cleanup and the restore both pass their links oldest first (`ordersBefore`),
    /// so they keep the same ones. `ends` is nil for an orphan. With `id`, a link whose ID a
    /// kept link already has is refused too (a backup can repeat one; the store cannot), and
    /// only a KEPT link claims its ID, so a broken first copy does not shadow a valid second.
    static func sieve<T>(_ items: [T], ends: (T) -> (source: UUID, target: UUID)?,
                         kind: (T) -> String, id: ((T) -> UUID)? = nil) -> (kept: [T], rejected: [(T, Rejection)]) {
        var kept: [T] = [], rejected: [(T, Rejection)] = []
        var pairs: Set<Pair> = []
        var keptIDs: Set<UUID> = []
        var graph = Graph()
        for item in items {
            guard let (source, target) = ends(item) else { rejected.append((item, .orphan)); continue }
            let itemKind = kind(item)
            if source == target { rejected.append((item, .selfLink)); continue }
            if FilmLinkKind.normalized(itemKind).isEmpty { rejected.append((item, .emptyKind)); continue }
            if let id, keptIDs.contains(id(item)) { rejected.append((item, .repeatedID)); continue }
            if pairs.contains(Pair(source, target)) { rejected.append((item, .repeatedPair)); continue }
            if graph.closesCycle(source: source, target: target, kind: itemKind) {
                rejected.append((item, .cycle)); continue
            }
            pairs.insert(Pair(source, target))
            if let id { keptIDs.insert(id(item)) }
            graph.add(Edge(source: source, target: target, kind: itemKind))
            kept.append(item)
        }
        return (kept, rejected)
    }

    /// The order `sieve` is given links in: oldest first, then by ID, so the choice is the same
    /// on every run.
    static func ordersBefore(_ lhs: (date: Date, id: UUID), _ rhs: (date: Date, id: UUID)) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return uuidPrecedes(lhs.id, rhs.id)
    }
}

// MARK: - Snapshot
/// A link as plain values: what MemoryStore holds, what the snapshot cache writes (Codable),
/// and what every read off the data actor returns.
struct FilmLinkSnapshot: Sendable, Hashable, Identifiable, Codable {
    let id: UUID
    let kind: String
    let sourceID: UUID
    let targetID: UUID
    let dateAdded: Date

    /// The pair of films the link occupies, regardless of direction (rule 2: one link per pair).
    var pair: FilmLinkRules.Pair { FilmLinkRules.Pair(sourceID, targetID) }

    /// The link as `FilmLinkRules` reads it.
    var edge: FilmLinkRules.Edge { FilmLinkRules.Edge(source: sourceID, target: targetID, kind: kind) }
}

// MARK: - Relation
/// One film's side of a link, for showing it from that film: "this film is a Remake of
/// `otherFilmID`" when `isSource`, "`otherFilmID` is a Remake of this film" otherwise. How the
/// reverse reads ("Remade as") is the UI's choice; the store keeps one sentence per link.
struct FilmLinkRelation: Sendable, Hashable, Identifiable {
    let link: FilmLinkSnapshot
    /// The film this relation is read from.
    let filmID: UUID

    var id: UUID { link.id }
    /// Whether the link's sentence is about this film ("this film is a `kind` of the other").
    var isSource: Bool { link.sourceID == filmID }
    /// The film at the other end.
    var otherFilmID: UUID { isSource ? link.targetID : link.sourceID }
    var kind: String { link.kind }

    /// The order relations are listed in: by kind (FilmLinkKind.all first, in that order, then
    /// any other kind by key), then the film's own sentences before the reverse ones, then
    /// oldest first. Total, so a list of them never reorders between calls.
    static func orderedBefore(_ lhs: FilmLinkRelation, _ rhs: FilmLinkRelation) -> Bool {
        let lk = FilmLinkKind.sortRank(lhs.kind), rk = FilmLinkKind.sortRank(rhs.kind)
        if lk != rk { return lk < rk }
        if lhs.isSource != rhs.isSource { return lhs.isSource }
        return FilmLinkRules.ordersBefore((lhs.link.dateAdded, lhs.link.id), (rhs.link.dateAdded, rhs.link.id))
    }
}

// MARK: - Model
@objc(FilmLink)
final class FilmLink: LibraryObject {
    /// Primary stable id for the link.
    var id: UUID { get { requiredUUID("id") } set { setValue(newValue, forKey: "id") } } /// See requiredUUID.

    // MARK: - Metadata
    /// See FilmLinkKind.
    @NSManaged var kind: String
    /// Picks the survivor when two links share a pair (DataManager.cleanupFilmLinks).
    @NSManaged var dateAdded: Date

    // MARK: - Relationships
    /// "sourceFilm is a `kind` of targetFilm". Both nullify on the link side; the film side
    /// (Film.outgoingLinks / Film.incomingLinks) cascades.
    @NSManaged var sourceFilm: Film?
    @NSManaged var targetFilm: Film?

    // MARK: - Initialization
    /// `source` and `target` must belong to the same context (or both to none): Core Data
    /// refuses a relationship across contexts. Every caller fetches both from one context.
    convenience init(id: UUID = UUID(), kind: String, source: Film, target: Film, dateAdded: Date = Date()) {
        self.init(detached: ())
        /// Joined to the film's context before the relationships are set: Core Data refuses a
        /// relationship between an object in a context and one in none.
        unsafe source.managedObjectContext?.insert(self)
        self.id = id
        self.kind = kind
        self.sourceFilm = source
        self.targetFilm = target
        self.dateAdded = dateAdded
    }

    /// The link as plain values, or nil for an orphan.
    var snapshot: FilmLinkSnapshot? {
        guard let source = sourceFilm?.id, let target = targetFilm?.id else { return nil }
        return FilmLinkSnapshot(id: id, kind: kind, sourceID: source, targetID: target, dateAdded: dateAdded)
    }
}

// MARK: - ExportableModel Conformance for FilmLink
extension FilmLink: ExportableModel {

    static func fetchAll(in context: NSManagedObjectContext) throws -> [FilmLink] {
        let desc = FilmLink.request(sortedBy: [NSSortDescriptor(key: "dateAdded", ascending: true)])
        return try context.fetch(desc) }

    func extractExportValues() -> (properties: [String: Any], relationships: [String: [Any]]) {
        var props: [String: Any] = [:]
        props["id"] = self.id
        props["kind"] = self.kind
        props["dateAdded"] = self.dateAdded
        /// The same date exactly, as seconds since 2001: a backup's dates are whole seconds,
        /// and the date orders links (the rules keep the oldest; lists show oldest first), so
        /// links made within one second would otherwise come back tied. Written as a Double,
        /// which the packager writes in its shortest exact form. Builds before film links skip
        /// the whole entity, so the extra property reaches no older reader.
        props["dateAddedExact"] = self.dateAdded.timeIntervalSinceReferenceDate

        /// The films by ID, for reconstruction during restore (as ListMembership does).
        props["sourceFilmID"] = self.sourceFilm?.id
        props["targetFilmID"] = self.targetFilm?.id

        let rels: [String: [Any]] = [:]
        return (properties: props, relationships: rels) }

    func exportStableID() -> String? { return self.id.uuidString }
}
