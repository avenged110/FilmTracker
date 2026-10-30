// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Logic checks for BulkFilmEdit (52.20). Run with run.sh.

import Foundation

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failures: [String] = []

func check(_ condition: Bool, _ name: String, line: Int = #line) {
    if condition { passed += 1 } else { failures.append("line \(line): \(name)") }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String, line: Int = #line) {
    if actual == expected { passed += 1 } else {
        failures.append("line \(line): \(name) — got \(actual), expected \(expected)")
    }
}

struct TestFilm: BulkEditableFilm, Equatable {
    let id = UUID()
    var genre = ""
    var rating = ""
    var watched = true
    var edited = false
    var editedDuration = ""
    var infoComplete = false
    var specialSorting: [String] = []
    var rotationThresholdOverride: Int? = nil
    var autoAddToQueueOnRotation: Int? = nil
    var notes = ""
    var tags: [String] = []
    var hofPosition = 0
    var lastModified = "2026.01.01"
}

let bl = FilmSpecialSorting.blacklisted
let ignore = FilmSpecialSorting.ignore
let waiting = FilmSpecialSorting.waitingForEdit
let upNext = FilmQueueSection.upNext.listID
let soon = FilmQueueSection.soon.listID
let later = FilmQueueSection.later.listID

// MARK: BulkField and the edit as a whole

do {
    let none = BulkField<Int?>.unchanged
    let useDefault = BulkField<Int?>.set(nil)
    check(!none.isSet, "unchanged is not set")
    check(useDefault.isSet, "set(nil) is set")
    check(none != useDefault, "set(nil) differs from unchanged")
    checkEqual(BulkField<Bool>.set(false).value, false, "value of set(false)")
    checkEqual(BulkField<Bool>.unchanged.value, nil, "value of unchanged")

    var edit = BulkFilmEdit()
    check(edit.isEmpty, "a new edit is empty")
    checkEqual(edit.changeCount, 0, "no changes")
    edit.watched = .set(false)
    edit.rotationThresholdOverride = .set(nil)
    edit.tagsToAppend = ["a", "b"]
    checkEqual(edit.changeCount, 3, "tags count once")
    edit.tagsToAppend = ["  ", ""]
    checkEqual(edit.changeCount, 2, "blank tags are no change")
    edit.tagsToAppend = [" Noir ", "Noir", "", "Heist", "Noir"]
    checkEqual(edit.appendedTags, ["Noir", "Heist"], "tags trimmed, deduplicated, ordered")
}

// MARK: Scalar fields

do {
    var film = TestFilm(watched: true, edited: true, editedDuration: "5400000", infoComplete: false)
    var edit = BulkFilmEdit()
    edit.watched = .set(false)
    edit.infoComplete = .set(true)
    let changed = edit.applyFields(to: &film)
    checkEqual(changed, [.watched, .infoComplete], "only the set fields that differ change")
    check(!film.watched && film.infoComplete, "values written")
    checkEqual(film.editedDuration, "5400000", "edited duration untouched while Edited is unset")
    checkEqual(film.lastModified, "2026.01.01", "lastModified is the caller's")

    let again = edit.applyFields(to: &film)
    check(again.isEmpty, "re-applying changes nothing")
}

do {
    var edit = BulkFilmEdit()
    edit.edited = .set(false)
    var cut = TestFilm(edited: true, editedDuration: "5400000")
    checkEqual(edit.applyFields(to: &cut), [.edited, .editedDuration], "Edited off clears the edited duration")
    checkEqual(cut.editedDuration, "", "edited duration cleared")
    var plain = TestFilm(edited: false, editedDuration: "")
    check(edit.applyFields(to: &plain).isEmpty, "Edited off on an unedited film changes nothing")

    edit.edited = .set(true)
    var withDuration = TestFilm(edited: false, editedDuration: "100")
    checkEqual(edit.applyFields(to: &withDuration), [.edited], "Edited on keeps the duration")
    checkEqual(withDuration.editedDuration, "100", "duration kept")
}

do {
    var edit = BulkFilmEdit()
    edit.specialSorting = .set([bl, waiting])
    var film = TestFilm(specialSorting: ["Something old", ignore])
    let changed = edit.applyFields(to: &film)
    checkEqual(film.specialSorting, [waiting, bl], "canonical order, unknown value dropped")
    check(changed.contains(.specialSorting), "special sorting changed")
    checkEqual(film.rotationThresholdOverride, 60, "becoming blacklisted forces 60")
    check(changed.contains(.rotationThresholdOverride), "threshold reported")

    // Blacklisted before and after: threshold kept, even with a threshold in the edit.
    edit.rotationThresholdOverride = .set(24)
    var stays = TestFilm(specialSorting: [bl], rotationThresholdOverride: 60)
    let staysChanged = edit.applyFields(to: &stays)
    checkEqual(stays.rotationThresholdOverride, 60, "still blacklisted keeps its threshold")
    check(!staysChanged.contains(.rotationThresholdOverride), "threshold not reported")

    // Un-blacklisting hands back the edit's threshold, or "Use Default".
    edit.specialSorting = .set([ignore])
    var leaving = TestFilm(specialSorting: [bl], rotationThresholdOverride: 60)
    edit.applyFields(to: &leaving)
    checkEqual(leaving.rotationThresholdOverride, 24, "un-blacklisting takes the edit's threshold")
    edit.rotationThresholdOverride = .unchanged
    var leavingDefault = TestFilm(specialSorting: [bl], rotationThresholdOverride: 60)
    edit.applyFields(to: &leavingDefault)
    checkEqual(leavingDefault.rotationThresholdOverride, nil, "un-blacklisting without a threshold resets to default")

    // Special sorting untouched: blacklisted films skip the edit's threshold, others take it.
    var thresholdOnly = BulkFilmEdit()
    thresholdOnly.rotationThresholdOverride = .set(nil)
    var listed = TestFilm(specialSorting: [bl], rotationThresholdOverride: 60)
    var normal = TestFilm(rotationThresholdOverride: 36)
    check(thresholdOnly.applyFields(to: &listed).isEmpty, "blacklisted film skips the threshold")
    checkEqual(listed.rotationThresholdOverride, 60, "blacklisted keeps 60")
    checkEqual(thresholdOnly.applyFields(to: &normal), [.rotationThresholdOverride], "others take it")
    checkEqual(normal.rotationThresholdOverride, nil, "Use Default written")

    // Clearing special sorting entirely.
    var clear = BulkFilmEdit()
    clear.specialSorting = .set([])
    var flagged = TestFilm(specialSorting: [waiting])
    checkEqual(clear.applyFields(to: &flagged), [.specialSorting], "empty set clears")
    checkEqual(flagged.specialSorting, [], "cleared")
    checkEqual(clear.resultingSpecialSorting(of: [ignore]), [], "resulting sorting for a cleared edit")
    checkEqual(BulkFilmEdit().resultingSpecialSorting(of: [ignore]), [ignore], "unchanged keeps the film's")
}

do {
    var edit = BulkFilmEdit()
    edit.autoAddToQueueOnRotation = .set(nil)
    var on = TestFilm(autoAddToQueueOnRotation: 1)
    checkEqual(edit.applyFields(to: &on), [.autoAddToQueueOnRotation], "auto-add turned off")
    checkEqual(on.autoAddToQueueOnRotation, nil, "off is nil")
    edit.autoAddToQueueOnRotation = .set(2)
    edit.applyFields(to: &on)
    checkEqual(on.autoAddToQueueOnRotation, 2, "auto-add to Later")

    var notes = BulkFilmEdit()
    notes.notes = .set("Restored 4K")
    var film = TestFilm(notes: "old")
    checkEqual(notes.applyFields(to: &film), [.notes], "notes overwritten")
    checkEqual(film.notes, "Restored 4K", "notes value")
}

// MARK: Tags

do {
    var edit = BulkFilmEdit()
    edit.tagsToAppend = ["Noir", "Heist", "Noir "]
    var film = TestFilm(tags: ["Heist", "1940s"])
    checkEqual(edit.applyFields(to: &film), [.tags], "tags appended")
    checkEqual(film.tags, ["Heist", "1940s", "Noir"], "existing tag skipped, order kept")
    check(edit.applyFields(to: &film).isEmpty, "appending again changes nothing")

    let full = (1...29).map { "t\($0)" }
    let result = edit.tags(appendedTo: full)
    checkEqual(result.tags.count, 30, "fills to the limit")
    checkEqual(result.tags.last, "Noir", "first new tag fits")
    checkEqual(result.dropped, 1, "the rest is counted as dropped")
    let atLimit = (1...30).map { "t\($0)" }
    checkEqual(edit.tags(appendedTo: atLimit).dropped, 2, "nothing fits a full film")
    checkEqual(edit.tags(appendedTo: atLimit + ["Noir"]).dropped, 1, "a tag already held is not dropped")
}

// MARK: Lists

let a = UUID(), b = UUID(), c = UUID()
let gone = UUID()
let f1 = UUID(), f2 = UUID(), f3 = UUID()

do {
    var edit = BulkFilmEdit()
    edit.userListIDs = .set([a, gone])
    let changes = edit.membershipChanges(
        filmIDs: [f1, f2, f3],
        userListsByFilm: [f1: [a], f2: [b], f3: [a, b, c]],
        queueListsByFilm: [:],
        existingUserLists: [a, b, c])
    checkEqual(changes.additions, [a: [f2]], "only missing memberships added; deleted list skipped")
    checkEqual(changes.removals, [b: [f2, f3], c: [f3]], "memberships outside the set removed")
    check(changes.queueAddition == nil, "queue untouched")
    checkEqual(changes.films, [f2, f3], "films whose memberships change")

    edit.userListIDs = .set([])
    let cleared = edit.membershipChanges(filmIDs: [f1, f2], userListsByFilm: [f1: [a], f2: []],
                                         queueListsByFilm: [:], existingUserLists: [a, b])
    checkEqual(cleared.removals, [a: [f1]], "no lists removes every user membership")
    check(cleared.additions.isEmpty, "nothing added")

    let untouched = BulkFilmEdit().membershipChanges(filmIDs: [f1], userListsByFilm: [f1: [a]],
                                                     queueListsByFilm: [f1: [soon]], existingUserLists: [a])
    check(untouched.isEmpty, "an empty edit changes no memberships")
}

// MARK: Queue

do {
    var edit = BulkFilmEdit()
    edit.queueSection = .set(nil)
    let none = edit.membershipChanges(filmIDs: [f1, f2, f3],
                                      userListsByFilm: [:],
                                      queueListsByFilm: [f1: [upNext], f2: [soon, later], f3: []],
                                      existingUserLists: [])
    checkEqual(none.removals, [upNext: [f1], soon: [f2], later: [f2]], "None removes every Queue membership")
    checkEqual(none.queueFilms(queueListIDs: [upNext, soon, later]), [f1, f2], "explicit-queue films")

    edit.queueSection = .set(.soon)
    let move = edit.membershipChanges(filmIDs: [f1, f2, f3],
                                      userListsByFilm: [:],
                                      queueListsByFilm: [f1: [soon], f2: [soon, later], f3: []],
                                      existingUserLists: [])
    checkEqual(move.queueAddition?.section, .soon, "target section")
    checkEqual(move.queueAddition?.films, [f2, f3], "a film in two sections is healed; one already there is not")
    check(move.removals.isEmpty, "the move's removals are FilmManager's")

    edit.queueSection = .set(.later)
    let settled = edit.membershipChanges(filmIDs: [f1], userListsByFilm: [:],
                                         queueListsByFilm: [f1: [later]], existingUserLists: [])
    check(settled.queueAddition == nil, "all already there: no queue change")

    checkEqual(edit.filmsNewlyQueued(in: .upNext, filmIDs: [f1, f2, f3],
                                     queueListsByFilm: [f1: [upNext], f2: [soon]]),
               [f2, f3], "films newly queued keep order")
}

// MARK: Hall of Fame

do {
    var edit = BulkFilmEdit()
    let none = edit.hallOfFameChanges(filmIDs: [f1, f2], positions: [f1: 3])
    check(none.add.isEmpty && none.remove.isEmpty, "unchanged does nothing")
    edit.inHallOfFame = .set(true)
    let adding = edit.hallOfFameChanges(filmIDs: [f3, f1, f2], positions: [f1: 3])
    checkEqual(adding.add, [f3, f2], "non-members added in sheet order")
    edit.inHallOfFame = .set(false)
    let removing = edit.hallOfFameChanges(filmIDs: [f3, f1, f2], positions: [f1: 3, f2: 0])
    checkEqual(removing.remove, [f1], "only members removed")

    checkEqual(BulkFilmEdit.hallOfFameOverflow(adding: 2, memberCount: 198), 0, "fits exactly")
    checkEqual(BulkFilmEdit.hallOfFameOverflow(adding: 5, memberCount: 198), 3, "overflow")
    checkEqual(BulkFilmEdit.hallOfFameOverflow(adding: 0, memberCount: 205), 0, "nothing to add always fits")
}

// MARK: Shared values, genre and rating, checkboxes

do {
    checkEqual(BulkSharedValue([true, true, true]), .same(true), "all equal is shared")
    checkEqual(BulkSharedValue([true, false]), .mixed, "different is mixed")
    checkEqual(BulkSharedValue([Bool]()), .mixed, "no films is mixed")
    checkEqual(BulkSharedValue<Int?>([nil, nil]), .same(nil), "shared nil is a value")
    checkEqual(BulkSharedValue<Int?>([nil, 24]), .mixed, "nil and a value is mixed")
    checkEqual(BulkSharedValue<String>.same("Drama").field(for: "Drama"), .unchanged, "the shared value is no change")
    checkEqual(BulkSharedValue<String>.same("Drama").field(for: ""), .set(""), "clearing a shared value is a change")
    checkEqual(BulkSharedValue<String>.mixed.field(for: "Drama"), .set("Drama"), "any value over a mix is a change")
    checkEqual(BulkSharedValue<Int?>.same(nil).field(for: nil), .unchanged, "shared nil chosen again is no change")
    checkEqual(BulkSharedValue<Bool>.same(true).shown(.unchanged), true, "unchanged shows the shared value")
    checkEqual(BulkSharedValue<Bool>.mixed.shown(.unchanged), nil, "unchanged over a mix shows nothing")
    checkEqual(BulkSharedValue<Bool>.mixed.shown(.set(false)), false, "a set value shows itself")

    // Mixed: mixed → checked → unchecked → mixed.
    var field = BulkField<Bool>.unchanged
    var seen: [BulkField<Bool>] = []
    for _ in 0..<4 { field = BulkFilmEdit.checkboxClick(field, shared: .mixed); seen.append(field) }
    checkEqual(seen, [.set(true), .set(false), .unchanged, .set(true)], "mixed checkbox cycle")
    // Shared: flips between the shared value (unchanged) and its opposite.
    field = .unchanged
    seen = []
    for _ in 0..<3 { field = BulkFilmEdit.checkboxClick(field, shared: .same(true)); seen.append(field) }
    checkEqual(seen, [.set(false), .unchanged, .set(false)], "shared-true checkbox flips")
    checkEqual(BulkFilmEdit.checkboxClick(.unchanged, shared: .same(false)), .set(true), "shared-false checks")

    var edit = BulkFilmEdit()
    edit.genre = .set("Drama")
    edit.rating = .set("")
    checkEqual(edit.changeCount, 2, "genre and rating count")
    var film = TestFilm(genre: "Comedy", rating: "PG")
    let changed = edit.applyFields(to: &film)
    checkEqual(film.genre, "Drama", "genre written")
    checkEqual(film.rating, "", "rating cleared")
    checkEqual(changed, [.genre, .rating], "genre and rating reported")
    var same = TestFilm(genre: "Drama", rating: "")
    checkEqual(edit.applyFields(to: &same), [], "already matching: nothing changed")
}

// MARK: Report

if failures.isEmpty {
    print("BulkFilmEdit rig: all \(passed) checks passed")
} else {
    print("BulkFilmEdit rig: \(failures.count) FAILED, \(passed) passed")
    failures.forEach { print("  ✗ \($0)") }
    exit(1)
}
