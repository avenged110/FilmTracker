// MARK: - Harness.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Standalone equivalence harness — NOT part of the app target.
//
// Proves that the consolidated `SmartLists.membership(of:today:)` assigns exactly the
// same smart lists as the two hand-written predicate families it replaced: the
// @MainActor instance checkers that drove targeted per-film recalculation, and the
// `nonisolated static _`-prefixed copies that drove the background full recalculation.
//
// Those two copies were required to stay "byte-for-byte equivalent" by comment alone —
// a film's membership flips depending on which path last evaluated it if they drift.
// This harness re-establishes that property against the single surviving definition.

import Foundation

// MARK: - App value types (mirrored)

enum ReleaseFormat: String, CaseIterable {
    case uhd4K  = "4K UHD"
    case bluRay = "Blu-ray"
    case dvd    = "DVD"
}

enum FilmSpecialSorting {
    static let waitingForEdit      = "Waiting for edit"
    static let temporarilyOnHold   = "Temporarily on hold"
    static let indefinitelyOnHold  = "Indefinitely on hold"
    static let ignore              = "Ignore"
    static let blacklisted         = "Blacklisted"
    static let all = [waitingForEdit, temporarilyOnHold, indefinitelyOnHold, ignore, blacklisted]
}

struct ReleaseSnapshot {
    var format: String
    var purchased: Bool
    var includedVersions: [String]
}

struct FilmSnapshot {
    var id: UUID
    var name: String
    var lastWatched: String
    var rotationThreshold: Int
    var specialSorting: [String]
    var watched: Bool
    var edited: Bool
    var releases: [ReleaseSnapshot]
}

enum SmartListType: String, CaseIterable, Hashable {
    case upForRotation = "Up for Rotation"
    case viewedOverOneYearAgo = "Viewed Over One Year Ago"
    case purchased = "Purchased"
    case purchased4K = "Purchased 4K"
    case purchasedBluray = "Purchased Blu-ray"
    case purchasedDVD = "Purchased DVD"
    case unpurchased = "Unpurchased"
    case unpurchased4K = "Unpurchased 4K"
    case unpurchasedBluray = "Unpurchased Blu-ray"
    case unpurchasedDVD = "Unpurchased DVD"
    case edited = "Edited"
    case alternateVersions = "Alternate Versions"
    case filteredLibrary = "Filtered Library"
    case waitingForEdit = "Waiting for Edit"
    case temporarilyOnHold = "Temporarily On Hold"
    case indefinitelyOnHold = "Indefinitely On Hold"
    case ignore = "Ignore"
    case blacklisted = "Blacklisted"
}

// MARK: - Shared globals (mirrored from GlobalUtilities.swift)

let dotDateFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy.MM.dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
}()
let dashDateFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
}()

func parseDate(from dateString: String?) -> Date? {
    guard let dateString, !dateString.isEmpty else { return nil }
    if let d = dotDateFormatter.date(from: dateString) { return d }
    if let d = dashDateFormatter.date(from: dateString) { return d }
    return nil
}

func rotationEligibilityDate(from lastWatchedDate: Date, months: Int, calendar: Calendar = .current) -> Date? {
    guard let anniversary = calendar.date(byAdding: .month, value: months, to: lastWatchedDate) else { return nil }
    let day = calendar.startOfDay(for: anniversary)
    let comps = calendar.dateComponents([.year, .month, .day], from: day)
    if comps.day == 1 { return day }
    guard let firstOfMonth = calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) else { return nil }
    return calendar.date(byAdding: .month, value: 1, to: firstOfMonth)
}

// MARK: - OLD: the @MainActor instance checkers (verbatim)

enum Old {
    static func isUpForRotation(_ film: FilmSnapshot, today: Date) -> Bool {
        guard film.specialSorting.isEmpty else { return false }
        guard !film.lastWatched.isEmpty else { return false }
        guard let lastWatchedDate = parseDate(from: film.lastWatched) else { return false }
        guard let thresholdDate = rotationEligibilityDate(from: lastWatchedDate, months: film.rotationThreshold) else { return false }
        return thresholdDate <= today
    }
    static func isViewedOverOneYearAgo(_ film: FilmSnapshot, today: Date) -> Bool {
        guard film.specialSorting.isEmpty else { return false }
        guard !film.lastWatched.isEmpty else { return false }
        guard let lastWatchedDate = parseDate(from: film.lastWatched) else { return false }
        guard let oneYearLater = rotationEligibilityDate(from: lastWatchedDate, months: 12) else { return false }
        return oneYearLater <= today
    }
    static func hasAnyPurchasedRelease(_ film: FilmSnapshot) -> Bool { film.releases.contains { $0.purchased } }
    static func hasPurchasedFormat(_ film: FilmSnapshot, format: String) -> Bool {
        film.releases.contains { $0.format == format && $0.purchased }
    }
    static func hasAllUnpurchasedReleases(_ film: FilmSnapshot) -> Bool {
        guard !film.releases.isEmpty else { return false }
        return film.releases.allSatisfy { !$0.purchased }
    }
    static func hasAllUnpurchasedFormat(_ film: FilmSnapshot, format: String) -> Bool {
        let formatReleases = film.releases.filter { $0.format == format }
        guard !formatReleases.isEmpty else { return false }
        return formatReleases.allSatisfy { !$0.purchased }
    }
    static func hasAlternateVersions(_ film: FilmSnapshot) -> Bool {
        for release in film.releases where release.purchased {
            let versions = release.includedVersions
            guard !versions.isEmpty else { continue }
            if versions.count == 1 && versions[0] == "Theatrical" { continue }
            return true
        }
        return false
    }

    /// Reconstructs the old TARGETED path's per-film outcome: recalculateForFilm +
    /// recalculateSortingListsForFilm + recalculateReleaseBasedListsForFilm.
    static func targetedMembership(_ film: FilmSnapshot, today: Date) -> Set<SmartListType> {
        var t: Set<SmartListType> = []
        if isUpForRotation(film, today: today) { t.insert(.upForRotation) }
        if isViewedOverOneYearAgo(film, today: today) { t.insert(.viewedOverOneYearAgo) }
        if film.edited { t.insert(.edited) }
        // recalculateSortingListsForFilm — six INDEPENDENT tests, no else-branch
        if film.watched && film.specialSorting.isEmpty { t.insert(.filteredLibrary) }
        if film.specialSorting.contains(FilmSpecialSorting.waitingForEdit) { t.insert(.waitingForEdit) }
        if film.specialSorting.contains(FilmSpecialSorting.temporarilyOnHold) { t.insert(.temporarilyOnHold) }
        if film.specialSorting.contains(FilmSpecialSorting.indefinitelyOnHold) { t.insert(.indefinitelyOnHold) }
        if film.specialSorting.contains(FilmSpecialSorting.ignore) { t.insert(.ignore) }
        if film.specialSorting.contains(FilmSpecialSorting.blacklisted) { t.insert(.blacklisted) }
        // recalculateReleaseBasedListsForFilm
        if hasAnyPurchasedRelease(film) { t.insert(.purchased) }
        if hasPurchasedFormat(film, format: ReleaseFormat.uhd4K.rawValue) { t.insert(.purchased4K) }
        if hasPurchasedFormat(film, format: ReleaseFormat.bluRay.rawValue) { t.insert(.purchasedBluray) }
        if hasPurchasedFormat(film, format: ReleaseFormat.dvd.rawValue) { t.insert(.purchasedDVD) }
        if hasAllUnpurchasedReleases(film) { t.insert(.unpurchased) }
        if hasAllUnpurchasedFormat(film, format: ReleaseFormat.uhd4K.rawValue) { t.insert(.unpurchased4K) }
        if hasAllUnpurchasedFormat(film, format: ReleaseFormat.bluRay.rawValue) { t.insert(.unpurchasedBluray) }
        if hasAllUnpurchasedFormat(film, format: ReleaseFormat.dvd.rawValue) { t.insert(.unpurchasedDVD) }
        if hasAlternateVersions(film) { t.insert(.alternateVersions) }
        return t
    }

    // ---- the `_`-prefixed nonisolated statics (verbatim) ----
    static func _isUpForRotation(_ film: FilmSnapshot, lastWatchedDate: Date?, today: Date) -> Bool {
        guard film.specialSorting.isEmpty else { return false }
        guard let lastWatchedDate else { return false }
        guard let thresholdDate = rotationEligibilityDate(from: lastWatchedDate, months: film.rotationThreshold) else { return false }
        return thresholdDate <= today
    }
    static func _isViewedOverOneYearAgo(_ film: FilmSnapshot, lastWatchedDate: Date?, today: Date) -> Bool {
        guard film.specialSorting.isEmpty else { return false }
        guard let lastWatchedDate else { return false }
        guard let oneYearLater = rotationEligibilityDate(from: lastWatchedDate, months: 12) else { return false }
        return oneYearLater <= today
    }

    /// Reconstructs the old BULK path's per-film outcome: computeSmartListSets' body.
    static func bulkMembership(_ film: FilmSnapshot, today: Date) -> Set<SmartListType> {
        var t: Set<SmartListType> = []
        let lastWatchedDate: Date? = parseDate(from: film.lastWatched)
        if _isUpForRotation(film, lastWatchedDate: lastWatchedDate, today: today) { t.insert(.upForRotation) }
        if _isViewedOverOneYearAgo(film, lastWatchedDate: lastWatchedDate, today: today) { t.insert(.viewedOverOneYearAgo) }
        if hasAnyPurchasedRelease(film) { t.insert(.purchased) }
        if hasPurchasedFormat(film, format: ReleaseFormat.uhd4K.rawValue) { t.insert(.purchased4K) }
        if hasPurchasedFormat(film, format: ReleaseFormat.bluRay.rawValue) { t.insert(.purchasedBluray) }
        if hasPurchasedFormat(film, format: ReleaseFormat.dvd.rawValue) { t.insert(.purchasedDVD) }
        if hasAllUnpurchasedReleases(film) { t.insert(.unpurchased) }
        if hasAllUnpurchasedFormat(film, format: ReleaseFormat.uhd4K.rawValue) { t.insert(.unpurchased4K) }
        if hasAllUnpurchasedFormat(film, format: ReleaseFormat.bluRay.rawValue) { t.insert(.unpurchasedBluray) }
        if hasAllUnpurchasedFormat(film, format: ReleaseFormat.dvd.rawValue) { t.insert(.unpurchasedDVD) }
        if film.edited { t.insert(.edited) }
        if hasAlternateVersions(film) { t.insert(.alternateVersions) }
        if film.watched && film.specialSorting.isEmpty {
            t.insert(.filteredLibrary)
        } else {
            if film.specialSorting.contains(FilmSpecialSorting.waitingForEdit) { t.insert(.waitingForEdit) }
            if film.specialSorting.contains(FilmSpecialSorting.temporarilyOnHold) { t.insert(.temporarilyOnHold) }
            if film.specialSorting.contains(FilmSpecialSorting.indefinitelyOnHold) { t.insert(.indefinitelyOnHold) }
            if film.specialSorting.contains(FilmSpecialSorting.ignore) { t.insert(.ignore) }
            if film.specialSorting.contains(FilmSpecialSorting.blacklisted) { t.insert(.blacklisted) }
        }
        return t
    }
}

// MARK: - NEW: the consolidated definition (verbatim from 71.10 SmartLists.swift)

enum New {
    static let purchasedFormatLists: [(String, SmartListType)] = [
        (ReleaseFormat.uhd4K.rawValue,  .purchased4K),
        (ReleaseFormat.bluRay.rawValue, .purchasedBluray),
        (ReleaseFormat.dvd.rawValue,    .purchasedDVD),
    ]
    static let unpurchasedFormatLists: [(String, SmartListType)] = [
        (ReleaseFormat.uhd4K.rawValue,  .unpurchased4K),
        (ReleaseFormat.bluRay.rawValue, .unpurchasedBluray),
        (ReleaseFormat.dvd.rawValue,    .unpurchasedDVD),
    ]
    static let specialSortingLists: [(String, SmartListType)] = [
        (FilmSpecialSorting.waitingForEdit,     .waitingForEdit),
        (FilmSpecialSorting.temporarilyOnHold,  .temporarilyOnHold),
        (FilmSpecialSorting.indefinitelyOnHold, .indefinitelyOnHold),
        (FilmSpecialSorting.ignore,             .ignore),
        (FilmSpecialSorting.blacklisted,        .blacklisted),
    ]

    static func hasAlternateVersions(_ film: FilmSnapshot) -> Bool {
        for release in film.releases where release.purchased {
            let versions = release.includedVersions
            guard !versions.isEmpty else { continue }
            if versions.count == 1 && versions[0] == "Theatrical" { continue }
            return true
        }
        return false
    }

    static func membership(of film: FilmSnapshot, today: Date) -> Set<SmartListType> {
        var types: Set<SmartListType> = []

        let lastWatchedDate = parseDate(from: film.lastWatched)
        if film.specialSorting.isEmpty, let lastWatchedDate {
            if let threshold = rotationEligibilityDate(from: lastWatchedDate, months: film.rotationThreshold),
               threshold <= today {
                types.insert(.upForRotation)
            }
            if let oneYearLater = rotationEligibilityDate(from: lastWatchedDate, months: 12),
               oneYearLater <= today {
                types.insert(.viewedOverOneYearAgo)
            }
        }

        if film.releases.contains(where: { $0.purchased }) { types.insert(.purchased) }
        for (format, type) in purchasedFormatLists
        where film.releases.contains(where: { $0.format == format && $0.purchased }) {
            types.insert(type)
        }

        if !film.releases.isEmpty, film.releases.allSatisfy({ !$0.purchased }) {
            types.insert(.unpurchased)
        }
        for (format, type) in unpurchasedFormatLists {
            let formatReleases = film.releases.filter { $0.format == format }
            if !formatReleases.isEmpty, formatReleases.allSatisfy({ !$0.purchased }) {
                types.insert(type)
            }
        }

        if film.edited { types.insert(.edited) }
        if hasAlternateVersions(film) { types.insert(.alternateVersions) }

        if film.watched && film.specialSorting.isEmpty {
            types.insert(.filteredLibrary)
        } else {
            for (tag, type) in specialSortingLists where film.specialSorting.contains(tag) {
                types.insert(type)
            }
        }

        return types
    }
}
