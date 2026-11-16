// MARK: - DHReleaseDuplicate.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
/// DEBUG-only scenario `release-duplicate`: "Add New Release" and "Duplicate This Release" as
/// the menu bar and the keyboard shortcuts reach them, against the real FilmSheet in an
/// on-screen window, from a fixture film it seeds and deletes again.
///
///   • shortcut/*     — AddReleaseRequest's bindings, as KeyboardManager matches them.
///   • off-tab/*      — from the Details tab: Duplicate is unavailable and does nothing; a format
///                      switches to the Releases tab (never built yet, so through the pending
///                      request and the carousel's hydration) and adds the release there.
///   • purchased/*    — a purchased Blu-ray copies everything above the card's divider and
///                      starts the purchase fields over; the copy lands to its right.
///   • unpurchased/*  — everything is copied but the Wishlist position.
///   • moving/*       — a duplicate asked for mid-jump is refused.
///   • combo/*        — a dual-BD combo pack, shown on its second disc, copies as a whole card
///                      with two discs of its own, wired to the copy.
///   • settle/*       — a Type change whose discs are still pending (~120 ms) is finished before
///                      the copy, so source and copy each get the disc the Type calls for.
///   • cap/*          — at ten cards nothing more is added, by request or directly.
///   • order/*        — card order is format-grouped and in sortOrder; sortOrders are unique.
///   • saved/*        — after Update, a reopened sheet shows the same cards, discs and links.
///
/// Not covered: the KeyboardManager key path itself (it acts only when a FilmSheet presented by
/// SheetCoordinator is the key sheet window, which a hosted window is not) and the tab's own
/// Menu button. Both end in the FilmSheet.requestAddRelease / FSTabReleases.perform calls made here.

#if DEBUG

import AppKit
import SwiftUI

extension DebugHarness {

    static func releaseDuplicateScenario(coordinator: DataCoordinator) async -> HarnessScenarioResult {
        var r = HarnessScenarioResult(scenario: "release-duplicate")
        let uhd = ReleaseFormat.uhd4K.rawValue, bd = ReleaseFormat.bluRay.rawValue
        let dvd = ReleaseFormat.dvd.rawValue

        // MARK: shortcut bindings
        let bindings: [(String, Character, NSEvent.ModifierFlags, AddReleaseRequest?)] = [
            ("cmd-n-bluray", "n", .command, .format(.bluRay)),
            ("opt-cmd-n-4k", "n", [.option, .command], .format(.uhd4K)),
            ("shift-opt-cmd-n-dvd", "n", [.shift, .option, .command], .format(.dvd)),
            ("cmd-d-duplicate", "d", .command, .duplicateCurrent),
            ("shift-cmd-d-unbound", "d", [.shift, .command], nil),
            ("opt-cmd-d-unbound", "d", [.option, .command], nil),
            ("shift-cmd-n-unbound", "n", [.shift, .command], nil),
        ]
        for (name, key, modifiers, expected) in bindings {
            let got = AddReleaseRequest.matching(key: key, modifiers: modifiers)
            r.check("shortcut/\(name)", got == expected, "got \(String(describing: got))")
        }

        // MARK: fixture
        /// k1: 4K dual-BD combo pack with two discs. k2: plain 4K. b1, b2: Blu-rays. d1: DVD.
        /// Five cards, so the five additions below reach the ten-card cap exactly.
        let k1 = UUID(), c1 = UUID(), c2 = UUID(), k2 = UUID(), b1 = UUID(), b2 = UUID(), d1 = UUID()
        let bdDefaults = ReleaseFormat.newReleaseDefaults(for: bd)
        func child(_ id: UUID, _ sortOrder: Int, notes: String) -> ReleaseSnapshot {
            ReleaseSnapshot(id: id, studio: "Fixture Studio", releaseDate: "2015", format: bd,
                            includedVersions: bdDefaults.includedVersions,
                            independence: ReleaseIndependence.comboPack,
                            videoFormat: bdDefaults.videoFormat, audioFormat: bdDefaults.audioFormat,
                            audioChannels: bdDefaults.audioChannels, nationalOrigin: "United States",
                            replicationType: ReleaseReplicationType.pressed, regionLock: "A",
                            marketAvailability: [ReleaseMarketAvailability.comboPackOnly],
                            notes: notes, sortOrder: sortOrder, parentReleaseID: k1)
        }
        let film = makeSnapshot(name: "Duplicate Fixture", releases: [
            ReleaseSnapshot(id: k1, studio: "Fixture Studio", releaseDate: "2015", format: uhd,
                            independence: ReleaseIndependence.comboPackDualBD, nationalOrigin: "United States",
                            replicationType: ReleaseReplicationType.pressed, notes: "pack notes",
                            sortOrder: 0, childReleaseIDs: [c1, c2]),
            child(c1, 1, notes: "first disc"),
            child(c2, 2, notes: "second disc"),
            ReleaseSnapshot(id: k2, studio: "Fixture Studio", releaseDate: "2016", format: uhd,
                            independence: ReleaseIndependence.standalone, nationalOrigin: "United States",
                            replicationType: ReleaseReplicationType.pressed, sortOrder: 3),
            ReleaseSnapshot(id: b1, studio: "Criterion", releaseDate: "2017", format: bd,
                            independence: ReleaseIndependence.standalone, videoFormat: bdDefaults.videoFormat,
                            remastered: true, nationalOrigin: "United States",
                            replicationType: ReleaseReplicationType.pressed, regionLock: "A",
                            notes: "bought at the store", sortOrder: 4),
            ReleaseSnapshot(id: b2, studio: "Arrow", releaseDate: "2018", format: bd,
                            independence: ReleaseIndependence.standalone, nationalOrigin: "United Kingdom",
                            replicationType: ReleaseReplicationType.pressed, regionLock: "B",
                            lowestPrice: 14.5, notes: "watch for a sale", sortOrder: 5),
            ReleaseSnapshot(id: d1, studio: "Fixture Studio", releaseDate: "2005", format: dvd,
                            independence: ReleaseIndependence.standalone, sortOrder: 6),
        ])
        coordinator.importFilms([film])
        await drainPending(coordinator)

        // MARK: sheet in a real window
        let sheet = FilmSheet(coordinator: coordinator, filmID: film.id)
        guard let vm = sheet.releasesTab else {
            r.check("setup/view-model", false, "FilmSheet has no releases tab")
            await coordinator.deleteFilms(withIDs: [film.id]) {}
            return r
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: FilmSheetView(owner: sheet).frame(width: 900, height: 900))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 900)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: 20, y: 20))
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))

        /// Waits until no add is pending or animating and no navigation is mid-flight, then a
        /// little longer for the add sequence's teardown.
        func settle() async {
            for _ in 0..<200 where vm.pendingAddRequest != nil || vm.isTransitioning
                                 || vm.mountWindowTarget != nil {
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        func cardIndex(_ id: UUID) -> Int? { vm.carouselEntries.firstIndex { $0.id == id } }
        /// jumpToCard declines while an earlier step still holds the navigation lock, which
        /// outlasts everything settle() can see, so the jump is asked for until it lands.
        func show(_ id: UUID) async -> Bool {
            for _ in 0..<40 {
                guard let i = cardIndex(id) else { return false }
                if vm.currentCardIndex == i, vm.mountWindowTarget == nil, !vm.isTransitioning { return true }
                vm.jumpToCard(i)
                try? await Task.sleep(for: .milliseconds(100))
            }
            await settle()
            return cardIndex(id) == vm.currentCardIndex
        }
        func model(_ id: UUID) -> ReleaseCardModel? { vm.releases.first { $0.id == id } }
        /// What a copy may differ from its source in, besides identity and dateAdded.
        func differs(_ copy: ReleaseCardModel, _ source: ReleaseCardModel) -> Set<String> {
            copy.snapshot().differingFieldNames(from: source.snapshot())
        }
        let purchaseFields = ReleaseCardModel.purchaseOnlyFields
        let cardsAtStart = vm.carouselEntries.map(\.id)
        r.check("setup/five-cards", cardsAtStart == [k1, k2, b1, b2, d1], "\(cardsAtStart.count) cards")

        // MARK: off-tab
        do {
            let availability = sheet.addReleaseAvailability
            r.check("off-tab/details-tab", sheet.selectedTab == .details, "\(sheet.selectedTab)")
            r.check("off-tab/formats-available", availability.canAdd, "")
            r.check("off-tab/duplicate-unavailable", !availability.canDuplicate, "")
            let before = vm.releases.count
            sheet.requestAddRelease(.duplicateCurrent)
            await settle()
            r.check("off-tab/duplicate-does-nothing",
                    vm.releases.count == before && sheet.selectedTab == .details,
                    "releases \(before) → \(vm.releases.count), tab \(sheet.selectedTab)")

            let dvdsBefore = vm.releases.filter { $0.format == dvd }.count
            sheet.requestAddRelease(.format(.dvd))
            r.check("off-tab/switched-to-releases", sheet.selectedTab == .releases, "\(sheet.selectedTab)")
            await settle()
            try? await Task.sleep(for: .milliseconds(400))
            await settle()
            let dvds = vm.releases.filter { $0.format == dvd }
            r.check("off-tab/dvd-added-after-hydration", dvds.count == dvdsBefore + 1,
                    "\(dvdsBefore) → \(dvds.count) DVDs")
            r.check("off-tab/pending-cleared", vm.pendingAddRequest == nil, "")
            let shown = vm.carouselEntries.indices.contains(vm.currentCardIndex)
                ? vm.carouselEntries[vm.currentCardIndex].parent : nil
            r.check("off-tab/new-dvd-on-screen", shown?.format == dvd && shown?.id != d1,
                    "on screen: \(shown?.format ?? "nil")")
            r.check("off-tab/duplicate-now-available", sheet.addReleaseAvailability.canDuplicate, "")
        }

        // MARK: purchased
        r.check("purchased/source-on-screen", await show(b1), "index \(vm.currentCardIndex)")
        await settle()
        if let source = model(b1), let sourceIndex = cardIndex(b1) {
            source.purchased = true
            source.cost = 9.79
            source.amountSpent = 9.79
            source.purchaseDate = Date(timeIntervalSince1970: 1_604_649_600)
            source.hasPurchaseDate = true
            source.condition = ReleaseCondition.used
            source.hasArtwork = ReleaseArtwork.steelbook
            let order = vm.carouselEntries.map(\.id)
            sheet.requestAddRelease(.duplicateCurrent)
            await settle()
            let entries = vm.carouselEntries
            if entries.indices.contains(sourceIndex + 1) {
                let copy = entries[sourceIndex + 1].parent
                r.check("purchased/copy-to-the-right", copy.id != b1 && copy.format == bd, copy.format)
                r.check("purchased/copy-on-screen", vm.currentCardIndex == sourceIndex + 1,
                        "index \(vm.currentCardIndex), expected \(sourceIndex + 1)")
                let diff = differs(copy, source)
                r.check("purchased/only-purchase-fields-differ",
                        diff.subtracting(purchaseFields.union(["sortOrder", "wishlist"])).isEmpty,
                        diff.sorted().joined(separator: ", "))
                r.check("purchased/still-purchased", copy.purchased, "")
                r.check("purchased/purchase-fields-reset",
                        copy.cost == 0 && copy.amountSpent == 0 && !copy.hasPurchaseDate
                            && copy.condition == ReleaseCondition.new && copy.notes.isEmpty,
                        "cost \(copy.cost) spent \(copy.amountSpent) dated \(copy.hasPurchaseDate) \(copy.condition) notes '\(copy.notes)'")
                r.check("purchased/above-divider-copied",
                        copy.studio == "Criterion" && copy.remastered && copy.hasArtwork == ReleaseArtwork.steelbook
                            && copy.regionLock == source.regionLock,
                        "\(copy.studio) remastered \(copy.remastered) artwork \(copy.hasArtwork)")
                r.check("purchased/source-untouched", source.cost == 9.79 && source.notes == "bought at the store", "")
                var expected = order
                expected.insert(copy.id, at: sourceIndex + 1)
                r.check("purchased/others-keep-order", entries.map(\.id) == expected, "")
            } else {
                r.check("purchased/copy-to-the-right", false, "no card after the source")
            }
        } else {
            r.check("purchased/source", false, "b1 missing")
        }

        // MARK: unpurchased
        r.check("unpurchased/source-on-screen", await show(b2), "index \(vm.currentCardIndex)")
        await settle()
        if let source = model(b2), let sourceIndex = cardIndex(b2) {
            vm.handleWishlistToggle(releaseID: b2, isOn: true)
            let position = source.wishlist
            sheet.requestAddRelease(.duplicateCurrent)
            await settle()
            let entries = vm.carouselEntries
            if entries.indices.contains(sourceIndex + 1), entries[sourceIndex + 1].id != b2 {
                let copy = entries[sourceIndex + 1].parent
                let diff = differs(copy, source)
                r.check("unpurchased/only-position-and-wishlist-differ",
                        diff.subtracting(["sortOrder", "wishlist"]).isEmpty, diff.sorted().joined(separator: ", "))
                r.check("unpurchased/notes-and-price-copied",
                        copy.notes == "watch for a sale" && copy.lowestPrice == 14.5, "'\(copy.notes)' \(copy.lowestPrice)")
                r.check("unpurchased/not-wishlisted", copy.wishlist == 0 && source.wishlist == position && position > 0,
                        "copy \(copy.wishlist), source \(source.wishlist)")
                r.check("unpurchased/copy-on-screen", vm.currentCardIndex == sourceIndex + 1, "")
            } else {
                r.check("unpurchased/copy-to-the-right", false, "no copy after the source")
            }
        }

        // MARK: moving
        /// A duplicate asked for while the carousel travels to another card copies nothing.
        if let target = cardIndex(k1) {
            let releases = vm.releases.count
            vm.jumpToCard(target)
            vm.duplicateCurrentRelease()
            r.check("moving/duplicate-refused-mid-jump", vm.releases.count == releases,
                    "\(releases) → \(vm.releases.count)")
            await settle()
        }

        // MARK: combo
        r.check("combo/source-on-screen", await show(k1), "index \(vm.currentCardIndex)")
        await settle()
        if let source = model(k1), let sourceIndex = cardIndex(k1) {
            /// Shown on its second disc: the whole card is copied all the same.
            vm.selectedVariantByCard[k1] = 2
            let sourceChildren = vm.comboChildren(of: source)
            sheet.requestAddRelease(.duplicateCurrent)
            await settle()
            let entries = vm.carouselEntries
            if entries.indices.contains(sourceIndex + 1), entries[sourceIndex + 1].id != k1 {
                let entry = entries[sourceIndex + 1]
                let copy = entry.parent
                r.check("combo/copy-is-4k-pack",
                        copy.format == uhd && copy.independence == ReleaseIndependence.comboPackDualBD, copy.independence)
                r.check("combo/two-discs", entry.children.count == 2, "\(entry.children.count)")
                r.check("combo/discs-wired-to-copy",
                        entry.children.allSatisfy { $0.parentReleaseID == copy.id }
                            && Set(copy.childReleaseIDs) == Set(entry.children.map(\.id)),
                        "")
                r.check("combo/discs-are-new",
                        Set(entry.children.map(\.id)).isDisjoint(with: [c1, c2]), "")
                r.check("combo/source-keeps-its-discs",
                        Set(vm.comboChildren(of: source).map(\.id)) == [c1, c2]
                            && sourceChildren.count == 2, "")
                for (i, pair) in zip(entry.children, sourceChildren).enumerated() {
                    let diff = differs(pair.0, pair.1)
                    r.check("combo/disc-\(i + 1)-copied", diff.subtracting(["sortOrder", "wishlist"]).isEmpty,
                            diff.sorted().joined(separator: ", "))
                }
                r.check("combo/disc-notes-copied", entry.children.map(\.notes) == ["first disc", "second disc"],
                        "\(entry.children.map(\.notes))")
                r.check("combo/one-card-added", entries.count == 9, "\(entries.count) cards")
            } else {
                r.check("combo/copy-to-the-right", false, "no copy after the source")
            }
        }

        // MARK: settle
        r.check("settle/source-on-screen", await show(k2), "index \(vm.currentCardIndex)")
        await settle()
        if let source = model(k2), let sourceIndex = cardIndex(k2) {
            /// The Type change commits now and creates the disc ~120 ms later; the duplicate
            /// lands inside that window.
            vm.requestIndependenceChange(on: source, to: ReleaseIndependence.comboPack)
            r.check("settle/disc-still-pending", vm.comboChildren(of: source).isEmpty,
                    "\(vm.comboChildren(of: source).count) discs before the duplicate")
            sheet.requestAddRelease(.duplicateCurrent)
            await settle()
            let entries = vm.carouselEntries
            r.check("settle/source-has-its-disc", vm.comboChildren(of: source).count == 1,
                    "\(vm.comboChildren(of: source).count)")
            if entries.indices.contains(sourceIndex + 1), entries[sourceIndex + 1].id != k2 {
                let entry = entries[sourceIndex + 1]
                r.check("settle/copy-has-its-disc",
                        entry.parent.independence == ReleaseIndependence.comboPack && entry.children.count == 1,
                        "\(entry.parent.independence), \(entry.children.count) discs")
            } else {
                r.check("settle/copy-to-the-right", false, "no copy after the source")
            }
            try? await Task.sleep(for: .milliseconds(300))
            r.check("settle/no-late-extra-disc", vm.comboChildren(of: source).count == 1,
                    "\(vm.comboChildren(of: source).count) after the deferred task's time")
        }

        // MARK: cap
        do {
            let count = vm.carouselEntries.count
            r.check("cap/ten-cards", count == FSTabReleases.maxReleases, "\(count)")
            r.check("cap/unavailable", !sheet.addReleaseAvailability.canAdd, "")
            let releases = vm.releases.count
            sheet.requestAddRelease(.format(.bluRay))
            sheet.requestAddRelease(.duplicateCurrent)
            vm.duplicateCurrentRelease()
            await settle()
            r.check("cap/nothing-added", vm.releases.count == releases && vm.pendingAddRequest == nil,
                    "\(releases) → \(vm.releases.count)")
        }

        // MARK: order
        let finalCards = vm.carouselEntries.map(\.id)
        do {
            let ranks = vm.carouselEntries.map { ReleaseFormat.displayRank(for: $0.parent.format) }
            r.check("order/format-grouped", ranks == ranks.sorted(), "\(ranks)")
            let runsInOrder = zip(vm.carouselEntries, vm.carouselEntries.dropFirst()).allSatisfy { a, b in
                a.parent.format != b.parent.format || a.parent.sortOrder < b.parent.sortOrder
            }
            r.check("order/sort-order-within-format", runsInOrder, "")
            let orders = vm.releases.map(\.sortOrder)
            r.check("order/sort-orders-unique", Set(orders).count == orders.count, "\(orders.sorted())")
        }

        // MARK: saved
        do {
            var dismissed = false
            sheet.dismissHandler = { dismissed = true }
            sheet.confirm()
            for _ in 0..<250 where !dismissed && !sheet.showingSaveError {
                try? await Task.sleep(for: .milliseconds(20))
            }
            await drainPending(coordinator)
            r.check("saved/update", dismissed, sheet.saveErrorDetail ?? "")
            let reopened = FilmSheet(coordinator: coordinator, filmID: film.id)
            if let again = reopened.releasesTab {
                r.check("saved/same-cards-in-order", again.carouselEntries.map(\.id) == finalCards,
                        "\(again.carouselEntries.count) cards")
                let links = again.carouselEntries.map { $0.children.map(\.id) }
                let expected = vm.carouselEntries.map { $0.children.map(\.id) }
                r.check("saved/same-discs", links == expected, "")
                r.check("saved/no-unsaved-changes", !reopened.hasChanges, "")
            }
        }

        window.orderOut(nil)
        window.contentView = nil
        await coordinator.deleteFilms(withIDs: [film.id]) {}
        await drainPending(coordinator)
        return r
    }

    /// Waits for the coordinator's background writes, as the pipeline scenarios do.
    private static func drainPending(_ coordinator: DataCoordinator) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while coordinator.hasPendingOperations, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await Task.yield()
    }
}

#endif
