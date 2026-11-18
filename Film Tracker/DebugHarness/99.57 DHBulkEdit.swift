// MARK: - DHBulkEdit.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// DEBUG-only scenario for the MultiFilmSheet (52.00–52.20), the bulk editor. In the data-layer
/// suites (`all`, `store`).
///
/// `bulk-edit-check` drives real edits on five films it seeds itself through the sheet's own
/// confirm(): every field, the shared-value prefill, the mixed checkbox cycle, list membership,
/// the Queue, the Hall of Fame, both capacity refusals (when the library leaves less room than
/// the edit needs), the blacklist cascade and clearing shared notes — checking memory and a
/// fresh NSManagedObjectContext read of the store after each. It deletes its films at the end.

#if DEBUG

import AppKit
import SwiftUI
import CoreData

extension DebugHarness {

    static func runBulkEditScenario(_ scenario: String,
                                    coordinator: DataCoordinator) async -> HarnessScenarioResult? {
        switch scenario {
        case "bulk-edit-check": return await bulkEditCheckScenario(coordinator: coordinator)
        default: return nil
        }
    }

    // MARK: bulk-edit-check

    private static func bulkEditCheckScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "bulk-edit-check")
        func check(_ ok: Bool, _ what: String) { r.check("bulk-edit-check/\(what)", ok) }
        let queueIDs = FilmQueue.allListIDs
        let blacklisted = FilmSpecialSorting.blacklisted
        let waiting = FilmSpecialSorting.waitingForEdit

        /// Its own films, outside the Queue and the Hall of Fame, so it runs the same on an empty
        /// sandbox and a real-library copy and leaves either as found. The fifth carries notes,
        /// for the mixed-notes check.
        let candidates = (1...5).map { n -> FilmSnapshot in
            var film = makeSnapshot(name: "Bulk Check \(n)", calendarTable: n.isMultiple(of: 2) ? ["2020.01.01"] : [])
            film.tags = n == 1 ? ["Existing"] : []
            film.notes = n == 5 ? "Other notes" : ""
            return film
        }
        coordinator.importFilms(candidates)
        await coordinator.commitPendingWritesForExport()
        let ids = candidates.prefix(4).map(\.id)
        let originals = Dictionary(uniqueKeysWithValues: ids.compactMap { id in coordinator.getFilm(id).map { (id, $0) } })

        let listA = coordinator.createList(name: "Bulk Check A \(Int.random(in: 1000...9999))", displayOrder: 90_001)
        let listB = coordinator.createList(name: "Bulk Check B \(Int.random(in: 1000...9999))", displayOrder: 90_002)
        coordinator.addFilmsToList(filmIDs: [ids[0], ids[1]], listID: listB)
        await coordinator.commitPendingWritesForExport()

        /// Opens a sheet on `films`, configures it, confirms (agreeing to a notes prompt),
        /// and waits for the write. True when the sheet dismissed.
        func run(_ films: [UUID]? = nil, _ configure: (MultiFilmSheet) -> Void) async -> Bool {
            let sheet = MultiFilmSheet(coordinator: coordinator, filmIDs: films ?? ids)
            var dismissed = false
            sheet.dismissHandler = { dismissed = true }
            configure(sheet)
            sheet.confirm()
            switch sheet.pendingAlert {
            case .replaceNotes?, .clearNotes?: sheet.confirmNotesReplacement()
            default: break
            }
            await coordinator.commitPendingWritesForExport()
            return dismissed
        }

        /// The selection is mixed on lists (A/B membership) and opens blank there.
        let opened = MultiFilmSheet(coordinator: coordinator, filmIDs: ids)
        check(opened.shared.userListIDs == .mixed, "mixed list membership opens blank")
        check(!opened.canConfirm, "an untouched sheet cannot be saved")

        /// Edit 1: every field.
        let hofBefore = coordinator.getHallOfFameFilms().count
        let edit1 = await run { s in
            s.genre = .set("Drama")
            s.rating = .set("PG-13")
            s.queueSection = .set(.soon)
            s.userListIDs = .set([listA])
            s.watched = .set(false)
            s.edited = .set(false)
            s.infoComplete = .set(true)
            s.specialSorting = .set([waiting])
            s.rotationThresholdOverride = .set(24)
            s.autoAddToQueueOnRotation = .set(2)
            s.notes = "Bulk check notes"
            /// "bulkchecktag" and "EXISTING" repeat a tag in another spelling: skipped (BulkFilmEdit.appendedTags,
            /// tags(appendedTo:)), so a film already holding "Existing" keeps its one spelling.
            s.tags = ["BulkCheckTag", " BulkCheckTag ", "bulkchecktag", "Second", "EXISTING"]
        }
        check(edit1, "edit 1 saved and dismissed")
        for id in ids {
            guard let film = coordinator.getFilm(id), let original = originals[id] else {
                check(false, "film \(id) still exists"); continue
            }
            let name = film.name
            check(film.genre == "Drama" && film.rating == "PG-13", "\(name): genre and rating set")
            check(!film.watched && !film.edited && film.editedDuration.isEmpty, "\(name): watched/edited off, edited duration cleared")
            check(film.infoComplete, "\(name): complete data on")
            check(film.specialSorting == [waiting], "\(name): special sorting replaced")
            check(film.rotationThresholdOverride == 24, "\(name): threshold 2 years")
            check(film.autoAddToQueueOnRotation == 2, "\(name): auto-add to Later")
            check(film.notes == "Bulk check notes", "\(name): notes replaced")
            let held = Set(original.tags.map(SearchText.key))
            let expectedTags = original.tags + ["BulkCheckTag", "Second", "EXISTING"].filter { !held.contains(SearchText.key($0)) }
            check(film.tags == Array(expectedTags.prefix(BulkFilmEdit.tagLimit)), "\(name): tags appended once, in order")
            check(film.lastModified != original.lastModified, "\(name): stamped modified")
            let lists = coordinator.getListIDs(forFilm: id)
            check(lists.subtracting(queueIDs) == [listA], "\(name): user lists are exactly A")
            check(lists.intersection(queueIDs) == [FilmQueueSection.soon.listID], "\(name): in Soon only")
        }
        compareStore(ids, coordinator) { check($0, $1) }

        /// The same films now share every value: a fresh sheet opens to them, unchanged.
        let shared = MultiFilmSheet(coordinator: coordinator, filmIDs: ids)
        check(shared.shared.genre == .same("Drama") && shared.shared.rating == .same("PG-13"), "prefill: genre and rating")
        check(shared.shared.watched == .same(false) && shared.shared.infoComplete == .same(true), "prefill: flags")
        check(shared.shared.specialSorting == .same([waiting]), "prefill: special sorting")
        check(shared.shared.queueSection == .same(.soon), "prefill: queue section")
        check(shared.shared.userListIDs == .same([listA]), "prefill: list membership")
        check(shared.shared.rotationThresholdOverride == .same(24), "prefill: threshold")
        check(shared.shared.autoAddToQueueOnRotation == .same(2) && shared.autoAddShownEnabled == true
              && shared.autoAddShownSection == 2, "prefill: automatic queueing")
        check(shared.notes == "Bulk check notes" && !shared.notesEdit.isSet, "prefill: notes, unchanged")
        check(!shared.canConfirm, "a prefilled, untouched sheet cannot be saved")
        shared.assign(\.genre, "Drama", shared: shared.shared.genre)
        check(!shared.genre.isSet, "choosing the shared value is no change")
        shared.clickCheckbox(\.watched, shared: shared.shared.watched)
        check(shared.watched == .set(true), "shared checkbox: one click flips it")
        shared.clickCheckbox(\.watched, shared: shared.shared.watched)
        check(!shared.watched.isSet, "shared checkbox: a second click is no change again")

        /// Mixed checkbox cycle: mixed → checked → unchecked → mixed.
        var field = BulkField<Bool>.unchanged
        let cycle = (0..<3).map { _ -> BulkField<Bool> in
            field = BulkFilmEdit.checkboxClick(field, shared: .mixed)
            return field
        }
        check(cycle == [.set(true), .set(false), .unchanged], "mixed checkbox cycle")

        /// Capacity: an add that does not fit is refused whole, with its alert, and nothing
        /// is written — the Hall of Fame and "Up Next" alike.
        let hofRoom = BulkFilmEdit.hallOfFameCapacity - hofBefore
        let before = ids.compactMap { coordinator.getFilm($0) }
        if hofRoom < ids.count {
            let sheet = MultiFilmSheet(coordinator: coordinator, filmIDs: ids)
            var dismissed = false
            sheet.dismissHandler = { dismissed = true }
            sheet.watched = .set(true)
            sheet.inHallOfFame = .set(true)
            check(sheet.hallOfFameBlocked, "Hall of Fame checkbox disabled (room \(hofRoom) for \(ids.count))")
            sheet.confirm()
            if case .hallOfFameFull? = sheet.pendingAlert { check(true, "Hall of Fame overflow refused with its alert") }
            else { check(false, "Hall of Fame overflow refused with its alert") }
            check(!dismissed, "refused sheet stays open (Hall of Fame)")
        }
        let upNextRoom = FilmQueue.upNextVacancies(coordinator: coordinator)
        if upNextRoom < ids.count {
            let sheet = MultiFilmSheet(coordinator: coordinator, filmIDs: ids)
            var dismissed = false
            sheet.dismissHandler = { dismissed = true }
            sheet.queueSection = .set(.upNext)
            check(sheet.upNextBlocked, "Up Next segment disabled (room \(upNextRoom) for \(ids.count))")
            sheet.confirm()
            if case .upNextFull? = sheet.pendingAlert { check(true, "Up Next overflow refused with its alert") }
            else { check(false, "Up Next overflow refused with its alert") }
            check(!dismissed, "refused sheet stays open (Up Next)")
        }
        await coordinator.commitPendingWritesForExport()
        check(ids.compactMap { coordinator.getFilm($0) } == before, "refusals wrote nothing")

        /// Hall of Fame add, as many films as there is room for (at most 2), in sheet order.
        let adding = Array(ids.prefix(max(0, min(2, hofRoom))))
        if !adding.isEmpty {
            let added = await run(adding) { s in s.inHallOfFame = .set(true) }
            check(added, "Hall of Fame add saved")
            let ranks = adding.compactMap { coordinator.getFilm($0)?.hofPosition }
            check(ranks == Array((hofBefore + 1)...(hofBefore + adding.count)), "ranked next, in sheet order")
            compareStore(adding, coordinator) { check($0, $1) }
        }

        /// Edit 2: blacklist, and every removal.
        let edit2 = await run { s in
            s.specialSorting = .set([blacklisted])
            s.queueSection = .set(nil)
            s.userListIDs = .set([])
            s.inHallOfFame = .set(false)
            s.watched = .set(true)
        }
        check(edit2, "edit 2 saved and dismissed")
        for id in ids {
            guard let film = coordinator.getFilm(id) else { continue }
            check(film.specialSorting == [blacklisted] && film.rotationThresholdOverride == 60, "\(film.name): blacklisted at 60")
            check(film.watched, "\(film.name): watched back on")
            check(coordinator.getListIDs(forFilm: id).isEmpty, "\(film.name): in no list and not queued")
            check(film.hofPosition == 0, "\(film.name): out of the Hall of Fame")
            check(film.notes == "Bulk check notes", "\(film.name): notes untouched")
        }
        check(coordinator.getHallOfFameFilms().count == hofBefore, "Hall of Fame back to its size")

        /// All blacklisted: the threshold row opens locked at 60.
        let locked = MultiFilmSheet(coordinator: coordinator, filmIDs: ids)
        check(locked.rotationLocked, "all-blacklisted selection locks the threshold row")
        locked.specialSorting = .set([])
        check(!locked.rotationLocked && locked.rotationBaseline == .same(nil), "un-blacklisting shows the default threshold")

        /// Edit 3: a threshold alone leaves blacklisted films at 60; un-blacklisting resets.
        _ = await run { s in s.rotationThresholdOverride = .set(36) }
        check(ids.allSatisfy { coordinator.getFilm($0)?.rotationThresholdOverride == 60 }, "threshold alone skips blacklisted films")
        _ = await run { s in s.specialSorting = .set([]) }
        check(ids.allSatisfy { coordinator.getFilm($0)?.rotationThresholdOverride == nil }, "un-blacklisting resets to default")
        check(ids.allSatisfy { coordinator.getFilm($0)?.specialSorting.isEmpty == true }, "special sorting cleared")

        /// Edit 4: clearing notes every film shares clears them, after the Clear Notes prompt.
        let clearing = MultiFilmSheet(coordinator: coordinator, filmIDs: ids)
        var cleared = false
        clearing.dismissHandler = { cleared = true }
        clearing.notes = ""
        check(clearing.notesEdit == .set(""), "emptied shared notes is a clear")
        clearing.confirm()
        check(clearing.pendingAlert == .clearNotes(count: ids.count), "clearing asks first")
        clearing.confirmNotesReplacement()
        await coordinator.commitPendingWritesForExport()
        check(cleared && ids.allSatisfy { coordinator.getFilm($0)?.notes.isEmpty == true }, "shared notes cleared")
        /// Over a mix, an empty field is still no change.
        if let other = candidates.dropFirst(4).first(where: { !$0.notes.isEmpty }) {
            let mixedNotes = MultiFilmSheet(coordinator: coordinator, filmIDs: [ids[0], other.id])
            check(mixedNotes.shared.notes.isMixed && !mixedNotes.notesEdit.isSet, "empty notes over a mix is no change")
        }
        compareStore(ids, coordinator) { check($0, $1) }

        coordinator.deleteList(listID: listA)
        coordinator.deleteList(listID: listB)
        await coordinator.deleteFilms(withIDs: Set(candidates.map(\.id)))
        await coordinator.commitPendingWritesForExport()
        return r
    }

    /// The store as a fresh context reads it agrees with memory, field by field and
    /// membership by membership.
    private static func compareStore(_ ids: [UUID], _ coordinator: DataCoordinator,
                                     _ check: (Bool, String) -> Void) {
        let context = coordinator.persistentContainer.makeMainContext()
        let wanted = Set(ids)
        let films = (try? context.fetch(Film.request(.in("id", wanted)))) ?? []
        check(films.count == ids.count, "store holds all \(ids.count) films")
        let memberships = (try? context.fetch(ListMembership.request())) ?? []
        var mismatched: [String] = []
        for film in films {
            guard let memory = coordinator.getFilm(film.id) else { continue }
            let same = film.genre == memory.genre && film.rating == memory.rating
                && film.watched == memory.watched && film.edited == memory.edited
                && film.editedDuration == memory.editedDuration && film.infoComplete == memory.infoComplete
                && film.specialSorting == memory.specialSorting
                && film.rotationThresholdOverride == memory.rotationThresholdOverride
                && film.autoAddToQueueOnRotation == memory.autoAddToQueueOnRotation
                && film.notes == memory.notes && film.tags == memory.tags
                && film.hofPosition == memory.hofPosition && film.lastModified == memory.lastModified
            let stored = Set(memberships.filter { $0.film?.id == film.id }.compactMap { $0.list?.listID })
            if !same || stored != coordinator.getListIDs(forFilm: film.id) { mismatched.append(film.name) }
        }
        check(mismatched.isEmpty, "store matches memory for \(ids.count) film(s)\(mismatched.isEmpty ? "" : ": " + mismatched.prefix(5).joined(separator: ", "))")
    }
}

#endif
