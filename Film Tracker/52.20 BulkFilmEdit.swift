// MARK: - BulkFilmEdit.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// What the MultiFilmSheet changes, as one value, and the pure rules that turn it into each
// film's new fields, the list and Hall of Fame changes, and the capacity checks. Nothing
// here reads app state: callers hand in what a rule needs, so the rules run without the
// app (Staging/BulkEdit/Rig).

import Foundation

// MARK: - BulkField

/// One field of a bulk edit: left alone, or set to one value for every film.
///
/// A control the user has not changed shows what the films share (BulkSharedValue), or
/// blank when they differ, and either way means "leave each film as it is" — while a value
/// the user sets can itself be empty or off (no lists, unchecked, "Use Default"). Two cases
/// keep those apart where an optional could not: `BulkField<Int?>.set(nil)` is "Use
/// Default", `.unchanged` is "don't touch".
enum BulkField<Value: Sendable & Equatable>: Sendable, Equatable {
    case unchanged
    case set(Value)

    var isSet: Bool {
        if case .set = self { return true }
        return false
    }

    /// The value, or nil while unchanged. For an optional `Value`, nil is ambiguous — switch
    /// on the case instead.
    var value: Value? {
        if case .set(let value) = self { return value }
        return nil
    }
}

/// Hashable for a segmented control's tags (the Queue Membership picker's).
extension BulkField: Hashable where Value: Hashable {}

// MARK: - BulkSharedValue

/// What the selected films hold for one field: one value they all share, or a mix.
///
/// The sheet opens each control to the shared value, if there is one, and to its blank (or,
/// for a checkbox, mixed) state otherwise. Choosing the shared value again is no change,
/// which is what `field(for:)` encodes.
enum BulkSharedValue<Value: Sendable & Equatable>: Sendable, Equatable {
    case mixed
    case same(Value)

    /// The shared value of `values`; `.mixed` when any two differ, or when there are none.
    init(_ values: some Sequence<Value>) {
        var shared: Value?
        var first = true
        for value in values {
            if first {
                shared = value
                first = false
            } else if shared != value {
                self = .mixed
                return
            }
        }
        if first { self = .mixed } else if let shared { self = .same(shared) } else { self = .mixed }
    }

    var isMixed: Bool { self == .mixed }

    /// Setting `value`: no change when every film already holds it.
    func field(for value: Value) -> BulkField<Value> {
        if case .same(let shared) = self, shared == value { return .unchanged }
        return .set(value)
    }

    /// What a control shows for `field`: the value it is set to, else the shared value;
    /// nil when it is unchanged over a mix. For an optional `Value`, nil is ambiguous —
    /// switch on `shown(_:)`'s source instead.
    func shown(_ field: BulkField<Value>) -> Value? {
        if case .set(let value) = field { return value }
        if case .same(let shared) = self { return shared }
        return nil
    }
}

// MARK: - Fields

/// The scalar film fields a bulk edit can write. Raw values are FilmField's (the property
/// names), which is how the app turns them into the fields DataManager writes. Not
/// lastModified: the app stamps that itself (DataCoordinator.applyBulkFieldEdit).
enum BulkScalarField: String, Sendable {
    case genre, rating, watched, edited, editedDuration, infoComplete, specialSorting
    case rotationThresholdOverride, autoAddToQueueOnRotation, notes, tags
}

/// What a bulk edit reads and writes on a film. FilmSnapshot conforms as it stands.
protocol BulkEditableFilm {
    var id: UUID { get }
    var genre: String { get set }
    /// The MPAA rating ("PG-13"), not the user's.
    var rating: String { get set }
    var watched: Bool { get set }
    var edited: Bool { get set }
    var editedDuration: String { get set }
    var infoComplete: Bool { get set }
    var specialSorting: [String] { get set }
    var rotationThresholdOverride: Int? { get set }
    var autoAddToQueueOnRotation: Int? { get set }
    var notes: String { get set }
    var tags: [String] { get set }
}

// MARK: - BulkFilmEdit

struct BulkFilmEdit: Sendable, Equatable {
    /// `.set("")` clears it, as the FilmSheet's "Select Genre…" row does.
    var genre: BulkField<String> = .unchanged
    /// The MPAA rating; `.set("")` clears it.
    var rating: BulkField<String> = .unchanged
    /// `.set(nil)` takes the films out of the Queue ("None").
    var queueSection: BulkField<FilmQueueSection?> = .unchanged
    /// `.set(nil)` turns automatic queueing off; 0/1/2 as FSTabDetails stores it.
    var autoAddToQueueOnRotation: BulkField<Int?> = .unchanged
    /// The user lists every film ends up in, exactly: lists left out are left.
    var userListIDs: BulkField<Set<UUID>> = .unchanged
    var watched: BulkField<Bool> = .unchanged
    var edited: BulkField<Bool> = .unchanged
    var inHallOfFame: BulkField<Bool> = .unchanged
    var infoComplete: BulkField<Bool> = .unchanged
    var specialSorting: BulkField<Set<String>> = .unchanged
    /// `.set(nil)` is "Use Default".
    var rotationThresholdOverride: BulkField<Int?> = .unchanged
    /// `.set("")` only when the films all shared notes the user cleared: otherwise an empty
    /// Notes field means no change (see MultiFilmSheet.notesEdit).
    var notes: BulkField<String> = .unchanged
    /// Added after each film's own tags; the one field that does not overwrite.
    var tagsToAppend: [String] = []

    /// The override a blacklisted film carries, as the FilmSheet's Special Sorting row sets
    /// it (60 months).
    static let blacklistedThreshold = 60

    /// The most tags a film holds — ReorderableStringList.maxItems, which the FilmSheet's
    /// Tags list enforces.
    static let tagLimit = 30

    /// Hall of Fame capacity — MemoryStore.hallOfFameCapacity, which the MultiFilmSheet
    /// asserts it matches.
    static let hallOfFameCapacity = 200

    /// How many fields the edit sets; the tags count as one.
    var changeCount: Int {
        [genre.isSet, rating.isSet, queueSection.isSet, autoAddToQueueOnRotation.isSet, userListIDs.isSet, watched.isSet,
         edited.isSet, inHallOfFame.isSet, infoComplete.isSet, specialSorting.isSet,
         rotationThresholdOverride.isSet, notes.isSet, !appendedTags.isEmpty]
            .filter { $0 }.count
    }

    var isEmpty: Bool { changeCount == 0 }

    /// `tagsToAppend` trimmed, without empties or repeats, in order.
    var appendedTags: [String] {
        var seen: Set<String> = []
        return tagsToAppend
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: Scalar fields

    /// A film's special-sorting tags once the edit is applied.
    ///
    /// Written in `FilmSpecialSorting.canonicalOrder`, as FSTabDetails.collectFilmFields
    /// writes them — which, as there, drops a stored value outside the vocabulary.
    func resultingSpecialSorting(of current: [String]) -> [String] {
        guard case .set(let tags) = specialSorting else { return current }
        return FilmSpecialSorting.canonicalOrder.filter { tags.contains($0) }
    }

    /// `existing` with the edit's tags appended: each one the film does not already hold
    /// (an exact match, as the Tags list's own duplicate check compares), up to `tagLimit`.
    /// `dropped` counts the new tags that did not fit.
    func tags(appendedTo existing: [String]) -> (tags: [String], dropped: Int) {
        var result = existing
        var dropped = 0
        for tag in appendedTags where !result.contains(tag) {
            if result.count < Self.tagLimit {
                result.append(tag)
            } else {
                dropped += 1
            }
        }
        return (result, dropped)
    }

    /// Writes the edit onto `film` and returns the fields whose value changed. lastModified
    /// is not among them: the caller stamps it on every film the edit touched in any way.
    ///
    /// The FilmSheet's own couplings are kept, so a film reads the same as if each had been
    /// edited in its own sheet:
    ///   • "Edited" off clears the edited duration (FSTabDetails.collectFilmFields).
    ///   • Becoming blacklisted forces the rotation threshold to 60; ceasing to be hands
    ///     it back as the edit's threshold if one is set, else "Use Default" — what the
    ///     Special Sorting row does for a film that opens blacklisted.
    ///   • A film blacklisted before and after keeps its threshold, as the FilmSheet's
    ///     Rotation Threshold picker is disabled for it.
    @discardableResult
    func applyFields<Film: BulkEditableFilm>(to film: inout Film) -> Set<BulkScalarField> {
        var changed: Set<BulkScalarField> = []
        func write<T: Equatable>(_ keyPath: WritableKeyPath<Film, T>, _ value: T,
                                 _ field: BulkScalarField) {
            guard film[keyPath: keyPath] != value else { return }
            film[keyPath: keyPath] = value
            changed.insert(field)
        }

        if case .set(let genre) = genre { write(\.genre, genre, .genre) }
        if case .set(let rating) = rating { write(\.rating, rating, .rating) }
        if case .set(let watched) = watched { write(\.watched, watched, .watched) }
        if case .set(let edited) = edited {
            write(\.edited, edited, .edited)
            if !edited { write(\.editedDuration, "", .editedDuration) }
        }
        if case .set(let complete) = infoComplete { write(\.infoComplete, complete, .infoComplete) }

        let blacklisted = FilmSpecialSorting.blacklisted
        let wasBlacklisted = film.specialSorting.contains(blacklisted)
        let sorting = resultingSpecialSorting(of: film.specialSorting)
        write(\.specialSorting, sorting, .specialSorting)
        let isBlacklisted = sorting.contains(blacklisted)

        switch (wasBlacklisted, isBlacklisted) {
        case (false, true):
            write(\.rotationThresholdOverride, Self.blacklistedThreshold, .rotationThresholdOverride)
        case (true, true):
            break
        case (true, false):
            let handedBack: Int?
            if case .set(let threshold) = rotationThresholdOverride { handedBack = threshold } else { handedBack = nil }
            write(\.rotationThresholdOverride, handedBack, .rotationThresholdOverride)
        case (false, false):
            if case .set(let threshold) = rotationThresholdOverride {
                write(\.rotationThresholdOverride, threshold, .rotationThresholdOverride)
            }
        }

        if case .set(let section) = autoAddToQueueOnRotation {
            write(\.autoAddToQueueOnRotation, section, .autoAddToQueueOnRotation)
        }
        if case .set(let notes) = notes { write(\.notes, notes, .notes) }
        if !appendedTags.isEmpty { write(\.tags, tags(appendedTo: film.tags).tags, .tags) }
        return changed
    }

    // MARK: Checkboxes

    /// The field a click on a checkbox leaves, given what the films share.
    ///
    /// Over a mix the box cycles mixed → checked → unchecked → mixed, as AppKit's own
    /// mixed-state checkbox does, mixed being "unchanged". Over a shared value it flips
    /// between that value (unchanged) and its opposite.
    static func checkboxClick(_ field: BulkField<Bool>, shared: BulkSharedValue<Bool>) -> BulkField<Bool> {
        switch shared.shown(field) {
        case nil: return .set(true)
        case true?: return shared.field(for: false)
        case false?: return shared.isMixed ? .unchanged : shared.field(for: true)
        }
    }

    // MARK: Lists and the Queue

    /// The list memberships an edit adds and removes, grouped per list as
    /// FilmManager.addFilmsToList and removeFilmsFromLists take them.
    struct MembershipChanges: Sendable, Equatable {
        /// User-list additions: list → films.
        var additions: [UUID: Set<UUID>] = [:]
        /// User-list and Queue removals: list → films.
        var removals: [UUID: Set<UUID>] = [:]
        /// The Queue section the films move to, and the films that are not already there
        /// alone. FilmManager.addFilmsToList moves them out of any other section itself.
        var queueAddition: (section: FilmQueueSection, films: Set<UUID>)?

        /// Every film whose memberships change.
        var films: Set<UUID> {
            var all = queueAddition?.films ?? []
            for ids in additions.values { all.formUnion(ids) }
            for ids in removals.values { all.formUnion(ids) }
            return all
        }

        /// Films whose Queue membership changes — what saveFilmChangeset's
        /// explicitQueueChangeFilmIDs guard needs, so the field events of this same edit
        /// cannot re-queue a film the user just placed.
        func queueFilms(queueListIDs: Set<UUID>) -> Set<UUID> {
            var all = queueAddition?.films ?? []
            for (listID, ids) in removals where queueListIDs.contains(listID) { all.formUnion(ids) }
            return all
        }

        var isEmpty: Bool { additions.isEmpty && removals.isEmpty && queueAddition == nil }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.additions == rhs.additions && lhs.removals == rhs.removals
                && lhs.queueAddition?.section == rhs.queueAddition?.section
                && lhs.queueAddition?.films == rhs.queueAddition?.films
        }
    }

    /// - Parameters:
    ///   - userListsByFilm: Each film's user-list memberships (no Queue lists).
    ///   - queueListsByFilm: Each film's Queue-section list memberships.
    ///   - existingUserLists: The user lists that exist now; a chosen list deleted while the
    ///     sheet was open is skipped.
    func membershipChanges(filmIDs: [UUID],
                           userListsByFilm: [UUID: Set<UUID>],
                           queueListsByFilm: [UUID: Set<UUID>],
                           existingUserLists: Set<UUID>) -> MembershipChanges {
        var changes = MembershipChanges()

        if case .set(let chosen) = userListIDs {
            let target = chosen.intersection(existingUserLists)
            for film in filmIDs {
                let current = userListsByFilm[film] ?? []
                for list in target.subtracting(current) { changes.additions[list, default: []].insert(film) }
                for list in current.subtracting(target) { changes.removals[list, default: []].insert(film) }
            }
        }

        switch queueSection {
        case .unchanged:
            break
        case .set(nil):
            for film in filmIDs {
                for list in queueListsByFilm[film] ?? [] { changes.removals[list, default: []].insert(film) }
            }
        case .set(let section?):
            // Exactly [section] is already placed; anything else — elsewhere, nowhere, or in
            // two sections after a damaged restore — is moved (FilmQueueAssignment's test).
            let moving = filmIDs.filter { (queueListsByFilm[$0] ?? []) != [section.listID] }
            if !moving.isEmpty { changes.queueAddition = (section, Set(moving)) }
        }
        return changes
    }

    /// The films the edit would newly add to `section`, given each film's Queue lists.
    func filmsNewlyQueued(in section: FilmQueueSection, filmIDs: [UUID],
                          queueListsByFilm: [UUID: Set<UUID>]) -> [UUID] {
        filmIDs.filter { !(queueListsByFilm[$0] ?? []).contains(section.listID) }
    }

    // MARK: Hall of Fame

    /// The Hall of Fame changes: films to add, in `filmIDs` order (they take the next ranks
    /// in that order), and films to remove.
    func hallOfFameChanges(filmIDs: [UUID],
                           positions: [UUID: Int]) -> (add: [UUID], remove: Set<UUID>) {
        switch inHallOfFame {
        case .unchanged: return ([], [])
        case .set(true): return (filmIDs.filter { (positions[$0] ?? 0) == 0 }, [])
        case .set(false): return ([], Set(filmIDs.filter { (positions[$0] ?? 0) > 0 }))
        }
    }

    /// How many of `adding` new members would not fit; 0 when they fit.
    static func hallOfFameOverflow(adding: Int, memberCount: Int,
                                   capacity: Int = hallOfFameCapacity) -> Int {
        guard adding > 0 else { return 0 }
        return max(0, memberCount + adding - capacity)
    }
}
