// MARK: - DHBulkEdit.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// DEBUG-only scenarios for the MultiFilmSheet (52.00–52.20), the bulk editor. None is in a
// suite; run them by name, on a sandbox copy of a real library.
//
// `bulk-edit-shots` renders the sheet offscreen — both tabs, and the Details tab's fields at
// full height — for a mixed selection, a selection that shares its values, an edited sheet,
// a blacklisting one and a 300-film one, plus the FilmSheet's Details tab, to PNGs in
// `harness-reports/bulk-edit-shots/`. It asserts nothing; view the images.
//
// `bulk-edit-check` drives real edits on four films through the sheet's own confirm():
// every field, the shared-value prefill, the mixed checkbox cycle, list membership, the
// Queue, the Hall of Fame, both capacity refusals, the blacklist cascade and clearing
// shared notes — checking memory and a fresh NSManagedObjectContext read of the store after each.
//
// `bulk-edit-perf` times the sheet on the whole library, first topping it up to 1,600 films
// with copies (no releases, posters or identifiers) when it has fewer: opening the sheet,
// laying out both tabs, the per-keystroke gutter work, and saving each kind of edit, split
// into the synchronous part (what the user waits on) and the background write.

#if DEBUG

import AppKit
import SwiftUI
import CoreData

extension DebugHarness {

    static func runBulkEditScenario(_ scenario: String,
                                    coordinator: DataCoordinator) async -> HarnessScenarioResult? {
        switch scenario {
        case "bulk-edit-shots": return await bulkEditShotsScenario(coordinator: coordinator)
        case "bulk-edit-check": return await bulkEditCheckScenario(coordinator: coordinator)
        case "bulk-edit-perf":  return await bulkEditPerfScenario(coordinator: coordinator)
        default: return nil
        }
    }

    // MARK: Shared

    private static func filmsByName(_ coordinator: DataCoordinator) -> [FilmSnapshot] {
        coordinator.getAllFilms().sorted { $0.name.englishStandardCompare($1.name) == .orderedAscending }
    }

    /// A borderless offscreen window hosting `view` at `size`, laid out and drawn once.
    private static func host(_ view: some View, size: NSSize) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSApp.effectiveAppearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        return (window, host)
    }

    private static func render(_ view: some View, size: NSSize, to url: URL,
                               configure: (@MainActor () -> Void)? = nil) async {
        let (window, host) = host(view, size: size)
        try? await Task.sleep(for: .seconds(1))
        if let configure {
            configure()
            try? await Task.sleep(for: .seconds(0.6))
        }
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }

    // MARK: bulk-edit-shots

    private static func bulkEditShotsScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "bulk-edit-shots")
        guard let dir = DebugSandbox.rootURL?.appendingPathComponent("harness-reports/bulk-edit-shots", isDirectory: true) else {
            r.check("bulk-edit-shots/sandbox", false, "no sandbox root")
            return r
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let byName = filmsByName(coordinator)
        let five = Array(byName.prefix(5)).map(\.id)
        let sheetSize = NSSize(width: 600, height: 600)
        let fieldsSize = NSSize(width: 600, height: 1060)
        func fields(_ sheet: MultiFilmSheet) -> some View {
            MultiFilmSheetView.fieldsForHarness(sheet)
                .frame(width: 600, height: 1060, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        func shoot(_ sheet: MultiFilmSheet, _ name: String) async {
            await render(MultiFilmSheetView(owner: sheet), size: sheetSize, to: dir.appendingPathComponent("\(name)-details.png"))
            await render(fields(sheet), size: fieldsSize, to: dir.appendingPathComponent("\(name)-fields.png"))
            let other = sheet
            await render(MultiFilmSheetView(owner: sheet), size: sheetSize,
                         to: dir.appendingPathComponent("\(name)-films.png")) { other.selectedTab = .films }
            other.selectedTab = .details
        }

        await shoot(MultiFilmSheet(coordinator: coordinator, filmIDs: five), "mixed")

        // Films that share a genre, MPAA rating, Watched, Edited and special sorting, so the
        // sheet opens to their values.
        let groups = Dictionary(grouping: byName) { film in
            "\(film.genre)|\(film.rating)|\(film.watched)|\(film.edited)|\(film.specialSorting.sorted())|\(film.rotationThresholdOverride ?? 0)"
        }
        let sharing = groups.values.filter { $0.count >= 4 && !$0[0].genre.isEmpty }
            .max { $0.count < $1.count }
        if let sharing {
            let sheet = MultiFilmSheet(coordinator: coordinator, filmIDs: sharing.prefix(4).map(\.id))
            await shoot(sheet, "shared")
            r.check("bulk-edit-shots/shared-genre", sheet.shared.genre == .same(sharing[0].genre))
        }

        let set = MultiFilmSheet(coordinator: coordinator, filmIDs: five)
        set.genre = .set("Drama")
        set.queueSection = .set(.soon)
        set.autoAddToQueueOnRotation = .set(1)
        set.userListIDs = .set(Set(coordinator.getAllLists().prefix(1).map(\.listID)))
        set.watched = .set(false)
        set.inHallOfFame = .set(true)
        set.specialSorting = .set([FilmSpecialSorting.waitingForEdit])
        set.rotationThresholdOverride = .set(24)
        set.notes = "Replaced for every film."
        set.tags = ["Noir", "Heist"]
        await shoot(set, "set")

        let blacklist = MultiFilmSheet(coordinator: coordinator, filmIDs: five)
        blacklist.rotationThresholdOverride = .set(24)
        blacklist.specialSorting = .set([FilmSpecialSorting.blacklisted])
        await render(fields(blacklist), size: fieldsSize, to: dir.appendingPathComponent("blacklist-fields.png"))

        let many = byName.filter { $0.hofPosition == 0 }.prefix(300).map(\.id)
        await shoot(MultiFilmSheet(coordinator: coordinator, filmIDs: Array(many)), "blocked")

        // The FilmSheet's Details tab, on the shared controls, with automatic queueing on.
        if let queued = byName.first(where: { $0.autoAddToQueueOnRotation != nil }) ?? byName.first {
            let filmSheet = FilmSheet(coordinator: coordinator, filmID: queued.id)
            await render(FilmSheetView(owner: filmSheet), size: sheetSize, to: dir.appendingPathComponent("filmsheet-details.png"))
        }
        r.check("bulk-edit-shots/written", true, dir.path)
        return r
    }

    // MARK: bulk-edit-check

    private static func bulkEditCheckScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "bulk-edit-check")
        func check(_ ok: Bool, _ what: String) { r.check("bulk-edit-check/\(what)", ok) }
        let queueIDs = FilmQueue.allListIDs
        let blacklisted = FilmSpecialSorting.blacklisted
        let waiting = FilmSpecialSorting.waitingForEdit

        let candidates = filmsByName(coordinator)
            .filter { $0.hofPosition == 0 && coordinator.filmQueueListIDs(forFilm: $0.id).isEmpty
                && !$0.specialSorting.contains(blacklisted) }
        guard candidates.count >= 4 else {
            check(false, "four films outside the Queue and Hall of Fame")
            return r
        }
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

        // The selection is mixed on lists (A/B membership) and opens blank there.
        let opened = MultiFilmSheet(coordinator: coordinator, filmIDs: ids)
        check(opened.shared.userListIDs == .mixed, "mixed list membership opens blank")
        check(!opened.canConfirm, "an untouched sheet cannot be saved")

        // Edit 1: every field.
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
            s.tags = ["BulkCheckTag", " BulkCheckTag ", "Second"]
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
            let expectedTags = original.tags + ["BulkCheckTag", "Second"].filter { !original.tags.contains($0) }
            check(film.tags == Array(expectedTags.prefix(BulkFilmEdit.tagLimit)), "\(name): tags appended once, in order")
            check(film.lastModified != original.lastModified, "\(name): stamped modified")
            let lists = coordinator.getListIDs(forFilm: id)
            check(lists.subtracting(queueIDs) == [listA], "\(name): user lists are exactly A")
            check(lists.intersection(queueIDs) == [FilmQueueSection.soon.listID], "\(name): in Soon only")
        }
        compareStore(ids, coordinator) { check($0, $1) }

        // The same films now share every value: a fresh sheet opens to them, unchanged.
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

        // Mixed checkbox cycle: mixed → checked → unchecked → mixed.
        var field = BulkField<Bool>.unchanged
        let cycle = (0..<3).map { _ -> BulkField<Bool> in
            field = BulkFilmEdit.checkboxClick(field, shared: .mixed)
            return field
        }
        check(cycle == [.set(true), .set(false), .unchanged], "mixed checkbox cycle")

        // Capacity: an add that does not fit is refused whole, with its alert, and nothing
        // is written — the Hall of Fame and "Up Next" alike.
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

        // Hall of Fame add, as many films as there is room for (at most 2), in sheet order.
        let adding = Array(ids.prefix(max(0, min(2, hofRoom))))
        if !adding.isEmpty {
            let added = await run(adding) { s in s.inHallOfFame = .set(true) }
            check(added, "Hall of Fame add saved")
            let ranks = adding.compactMap { coordinator.getFilm($0)?.hofPosition }
            check(ranks == Array((hofBefore + 1)...(hofBefore + adding.count)), "ranked next, in sheet order")
            compareStore(adding, coordinator) { check($0, $1) }
        }

        // Edit 2: blacklist, and every removal.
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

        // All blacklisted: the threshold row opens locked at 60.
        let locked = MultiFilmSheet(coordinator: coordinator, filmIDs: ids)
        check(locked.rotationLocked, "all-blacklisted selection locks the threshold row")
        locked.specialSorting = .set([])
        check(!locked.rotationLocked && locked.rotationBaseline == .same(nil), "un-blacklisting shows the default threshold")

        // Edit 3: a threshold alone leaves blacklisted films at 60; un-blacklisting resets.
        _ = await run { s in s.rotationThresholdOverride = .set(36) }
        check(ids.allSatisfy { coordinator.getFilm($0)?.rotationThresholdOverride == 60 }, "threshold alone skips blacklisted films")
        _ = await run { s in s.specialSorting = .set([]) }
        check(ids.allSatisfy { coordinator.getFilm($0)?.rotationThresholdOverride == nil }, "un-blacklisting resets to default")
        check(ids.allSatisfy { coordinator.getFilm($0)?.specialSorting.isEmpty == true }, "special sorting cleared")

        // Edit 4: clearing notes every film shares clears them, after the Clear Notes prompt.
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
        // Over a mix, an empty field is still no change.
        if let other = candidates.dropFirst(4).first(where: { !$0.notes.isEmpty }) {
            let mixedNotes = MultiFilmSheet(coordinator: coordinator, filmIDs: [ids[0], other.id])
            check(mixedNotes.shared.notes.isMixed && !mixedNotes.notesEdit.isSet, "empty notes over a mix is no change")
        }
        compareStore(ids, coordinator) { check($0, $1) }

        coordinator.deleteList(listID: listA)
        coordinator.deleteList(listID: listB)
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

    // MARK: bulk-edit-perf

    private static func bulkEditPerfScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "bulk-edit-perf")
        let clock = ContinuousClock()
        func ms(_ start: ContinuousClock.Instant) -> Double { milliseconds(clock.now - start) }

        // Top the library up to 1,600 films.
        let target = 1600
        let existing = filmsByName(coordinator)
        if existing.count < target, !existing.isEmpty {
            let copies = (0..<(target - existing.count)).map { i in
                perfCopy(of: existing[i % existing.count], number: i + 1)
            }
            let start = clock.now
            coordinator.importFilms(copies)
            await coordinator.commitPendingWritesForExport()
            r.metric("seed/copies", Double(copies.count), "films")
            r.metric("seed/import", ms(start), "ms")
        }
        let films = filmsByName(coordinator)
        let ids = films.map(\.id)
        r.metric("films", Double(ids.count), "films")
        r.check("bulk-edit-perf/1500-plus", ids.count >= 1500, "\(ids.count) films")

        // Opening: the model, then both tabs laid out in a window.
        var start = clock.now
        let sheet = MultiFilmSheet(coordinator: coordinator, filmIDs: ids)
        r.metric("open/model", ms(start), "ms")
        start = clock.now
        let (window, view) = host(MultiFilmSheetView(owner: sheet), size: NSSize(width: 600, height: 600))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        r.metric("open/details-layout", ms(start), "ms")
        try? await Task.sleep(for: .milliseconds(300))
        start = clock.now
        sheet.selectedTab = .films
        await Task.yield()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        r.metric("open/films-tab-layout", ms(start), "ms")
        sheet.selectedTab = .details
        await Task.yield()

        // Per keystroke: what the gutter and Update button re-read, with tags to append.
        sheet.tags = ["BulkPerfTag"]
        start = clock.now
        for _ in 0..<20 { _ = sheet.gutterNote; _ = sheet.canConfirm }
        r.metric("keystroke/gutter+canConfirm", ms(start) / 20, "ms")
        sheet.tags = []
        window.orderOut(nil)

        /// One save: the synchronous confirm(), then the background write.
        func timeSave(_ name: String, _ configure: (MultiFilmSheet) -> Void) async {
            let s = MultiFilmSheet(coordinator: coordinator, filmIDs: ids)
            var dismissed = false
            s.dismissHandler = { dismissed = true }
            configure(s)
            BulkSaveProbe.phases = []
            let start = clock.now
            s.confirm()
            switch s.pendingAlert {
            case .replaceNotes?, .clearNotes?: s.confirmNotesReplacement()
            default: break
            }
            let sync = ms(start)
            let writeStart = clock.now
            await coordinator.commitPendingWritesForExport()
            let write = ms(writeStart)
            // Let the main queue drain whatever the save scheduled (deferred reloads, events).
            let drainStart = clock.now
            for _ in 0..<5 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(50))
            r.metric("save/\(name)/sync", sync, "ms")
            for phase in BulkSaveProbe.phases {
                r.metric("save/\(name)/sync/\(phase.name)", phase.milliseconds, "ms")
            }
            r.metric("save/\(name)/write", write, "ms")
            r.metric("save/\(name)/drain", ms(drainStart) - 50, "ms")
            r.check("bulk-edit-perf/\(name)/saved", dismissed, s.pendingAlert.map { "alert: \($0.id)" } ?? "")
        }

        let mixedWatched = films.contains { $0.watched } && films.contains { !$0.watched }
        await timeSave("flags") { s in
            s.watched = .set(true)
            s.infoComplete = .set(true)
        }
        await timeSave("genre") { s in s.genre = .set("Drama") }
        await timeSave("notes") { s in s.notes = "Bulk performance notes" }
        await timeSave("tags") { s in s.tags = ["BulkPerfTag"] }
        await timeSave("blacklist") { s in s.specialSorting = .set([FilmSpecialSorting.blacklisted]) }
        await timeSave("unblacklist") { s in s.specialSorting = .set([]) }
        let list = coordinator.createList(name: "Bulk Perf \(Int.random(in: 1000...9999))", displayOrder: 90_010)
        await coordinator.commitPendingWritesForExport()
        await timeSave("list-add") { s in s.userListIDs = .set([list]) }
        await timeSave("list-clear") { s in s.userListIDs = .set([]) }
        await timeSave("queue-soon") { s in s.queueSection = .set(.soon) }
        await timeSave("queue-none") { s in s.queueSection = .set(nil) }
        await timeSave("everything") { s in
            s.genre = .set("Comedy")
            s.rating = .set("PG")
            s.watched = .set(false)
            s.edited = .set(true)
            s.specialSorting = .set([FilmSpecialSorting.waitingForEdit])
            s.rotationThresholdOverride = .set(36)
            s.autoAddToQueueOnRotation = .set(1)
            s.notes = "Everything at once"
            s.tags = ["BulkPerfTagTwo"]
            s.userListIDs = .set([list])
            s.queueSection = .set(.later)
        }
        r.check("bulk-edit-perf/watched-was-mixed", true, mixedWatched ? "mixed" : "shared")

        // The store agrees with memory after all of it.
        let start2 = clock.now
        compareStore(ids, coordinator) { ok, what in r.check("bulk-edit-perf/store/\(what)", ok) }
        r.metric("verify/store-compare", ms(start2), "ms")
        coordinator.deleteList(listID: list)
        await coordinator.commitPendingWritesForExport()
        return r
    }

    /// A copy of `film` for the perf library: a new identity, and nothing that belongs to the
    /// original alone — releases, poster, identifiers, Hall of Fame rank.
    private static func perfCopy(of film: FilmSnapshot, number: Int) -> FilmSnapshot {
        FilmSnapshot(
            id: UUID(), posterUID: "", name: "\(film.name) (Bulk Copy \(number))",
            releaseYear: film.releaseYear, userRating: film.userRating, lastWatched: film.lastWatched,
            rotationThresholdOverride: film.rotationThresholdOverride, duration: film.duration,
            viewCount: film.viewCount, calendarTable: film.calendarTable,
            autoAddToQueueOnRotation: film.autoAddToQueueOnRotation, digitalSource: film.digitalSource,
            digitalVersion: film.digitalVersion, subtitles: film.subtitles, notes: film.notes,
            numberOfDiscs: film.numberOfDiscs, aspectRatio: film.aspectRatio, color: film.color,
            edited: film.edited, editedDuration: film.editedDuration, frameRate: film.frameRate,
            tags: film.tags, externalIdentifiers: [], dateAdded: film.dateAdded,
            lastModified: film.lastModified, watched: film.watched, specialSorting: film.specialSorting,
            alternateTitle: film.alternateTitle, hofPosition: 0, infoComplete: film.infoComplete,
            comments: film.comments, genre: film.genre, releaseDate: film.releaseDate,
            descriptionText: film.descriptionText, rating: film.rating, studio: film.studio,
            cast: film.cast, directors: film.directors, producers: film.producers,
            executiveProducers: film.executiveProducers, screenwriters: film.screenwriters,
            encodingTool: film.encodingTool, libraryHBRFValue: film.libraryHBRFValue,
            composer: film.composer, sortName: "", releaseUsed: film.releaseUsed, tools: film.tools,
            editedHBRFValue: film.editedHBRFValue, editDate: film.editDate, warning: film.warning,
            descriptionNotes: film.descriptionNotes, notesOnAudioTiming: film.notesOnAudioTiming,
            specialAudioNotes: film.specialAudioNotes, notesArray: film.notesArray,
            handbrakeFrames: film.handbrakeFrames, correspondingTimecodes: film.correspondingTimecodes)
    }
}

#endif
