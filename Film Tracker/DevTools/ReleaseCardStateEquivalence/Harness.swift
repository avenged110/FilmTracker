// MARK: - Harness.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Standalone equivalence harness — NOT part of the app target.
import Foundation

struct ReleaseCardState: Equatable, Hashable {
    // MARK: - Sentinels for unset optional fields
    //
    // What `snapshot()` records for an optional field whose has-value flag is false, in place
    // of the placeholder the model carries. Constants are the point: two states with the field
    // unset must compare equal no matter what each placeholder had drifted to. The values are
    // ones no real field can hold, so a sentinel can never be mistaken for data.
    static let unsetYear = 0
    static let unsetDate = Date.distantPast

    let id: UUID
    var studio: String
    var releaseYear: Int
    var hasReleaseYear: Bool
    var baseReleaseYear: Int
    var hasBaseReleaseYear: Bool
    var purchased: Bool
    var wishlist: Int  // position (0 = not on wishlist, ≥1 = display order)
    var format: String
    var includedVersions: [String]
    var independence: String
    var videoFormat: String
    var releaseAspectRatio: [String]
    var scanningMethod: String
    var audioFormat: String
    var audioChannels: String
    var hasSubtitles: Bool
    var numberOfDiscs: Int
    var discMultiPack: Bool
    var hasArtwork: String
    var remastered: Bool
    var nationalOrigin: String
    var replicationType: String
    var discCapacity: [String]
    var hasHDR: String
    var masterType: String
    var regionLock: String
    var regionLockBypass: Bool
    var marketAvailability: [String]
    var numberOfCopies: Int
    var cost: Double
    var amountSpent: Double
    var purchaseDate: Date
    var hasPurchaseDate: Bool
    var lowestPrice: Double
    var lowestPriceDate: Date
    var hasLowestPriceDate: Bool
    var condition: String
    var notes: String
    var sortOrder: Int
    let dateAdded: Date

    func differingFields(from other: ReleaseCardState) -> [String] {
        var fields: [String] = []
        func check<V: Equatable>(_ name: String, _ lhs: V, _ rhs: V) {
            if lhs != rhs { fields.append("\(name) (\(lhs) ≠ \(rhs))") }
        }
        check("studio",             studio,             other.studio)
        check("releaseYear",        releaseYear,        other.releaseYear)
        check("hasReleaseYear",     hasReleaseYear,     other.hasReleaseYear)
        check("baseReleaseYear",    baseReleaseYear,    other.baseReleaseYear)
        check("hasBaseReleaseYear", hasBaseReleaseYear, other.hasBaseReleaseYear)
        check("purchased",          purchased,          other.purchased)
        check("wishlist",           wishlist,           other.wishlist)
        check("format",             format,             other.format)
        check("includedVersions",   includedVersions,   other.includedVersions)
        check("independence",       independence,       other.independence)
        check("videoFormat",        videoFormat,        other.videoFormat)
        check("releaseAspectRatio", releaseAspectRatio, other.releaseAspectRatio)
        check("scanningMethod",     scanningMethod,     other.scanningMethod)
        check("audioFormat",        audioFormat,        other.audioFormat)
        check("audioChannels",      audioChannels,      other.audioChannels)
        check("hasSubtitles",       hasSubtitles,       other.hasSubtitles)
        check("numberOfDiscs",      numberOfDiscs,      other.numberOfDiscs)
        check("discMultiPack",      discMultiPack,      other.discMultiPack)
        check("hasArtwork",         hasArtwork,         other.hasArtwork)
        check("remastered",         remastered,         other.remastered)
        check("nationalOrigin",     nationalOrigin,     other.nationalOrigin)
        check("replicationType",    replicationType,    other.replicationType)
        check("discCapacity",       discCapacity,       other.discCapacity)
        check("hasHDR",             hasHDR,             other.hasHDR)
        check("masterType",         masterType,         other.masterType)
        check("regionLock",         regionLock,         other.regionLock)
        check("regionLockBypass",   regionLockBypass,   other.regionLockBypass)
        check("marketAvailability", marketAvailability, other.marketAvailability)
        check("numberOfCopies",     numberOfCopies,     other.numberOfCopies)
        check("cost",               cost,               other.cost)
        check("amountSpent",        amountSpent,        other.amountSpent)
        check("purchaseDate",       purchaseDate,       other.purchaseDate)
        check("hasPurchaseDate",    hasPurchaseDate,    other.hasPurchaseDate)
        check("lowestPrice",        lowestPrice,        other.lowestPrice)
        check("lowestPriceDate",    lowestPriceDate,    other.lowestPriceDate)
        check("hasLowestPriceDate", hasLowestPriceDate, other.hasLowestPriceDate)
        check("condition",          condition,          other.condition)
        check("notes",              notes,              other.notes)
        check("sortOrder",          sortOrder,          other.sortOrder)
        return fields
    }

    func differingFieldsNew(from other: ReleaseCardState) -> [String] {
        var fields: [String] = []
        for (mine, theirs) in zip(Mirror(reflecting: self).children,
                                  Mirror(reflecting: other).children) {
            guard let name = mine.label, name != "id", name != "dateAdded" else { continue }
            let differs: Bool
            if let lhs = mine.value as? AnyHashable, let rhs = theirs.value as? AnyHashable {
                differs = lhs != rhs
            } else {
                differs = String(describing: mine.value) != String(describing: theirs.value)
            }
            if differs { fields.append("\(name) (\(mine.value) ≠ \(theirs.value))") }
        }
        return fields
    }

}

final class ReleaseCardModel {
    let id: UUID
    var studio: String
    var releaseYear: Int
    var hasReleaseYear: Bool
    var baseReleaseYear: Int
    var hasBaseReleaseYear: Bool
    var purchased: Bool
    var wishlist: Int  // position (0 = not on wishlist, ≥1 = display order)
    var format: String
    var includedVersions: [String]
    var independence: String
    var videoFormat: String
    var releaseAspectRatio: [String]
    var scanningMethod: String
    var audioFormat: String
    var audioChannels: String
    var hasSubtitles: Bool
    var numberOfDiscs: Int
    var discMultiPack: Bool
    var hasArtwork: String
    var remastered: Bool
    var nationalOrigin: String
    var replicationType: String
    var discCapacity: [String]
    var hasHDR: String
    var masterType: String
    var regionLock: String
    var regionLockBypass: Bool
    var marketAvailability: [String]
    var numberOfCopies: Int
    var cost: Double
    var amountSpent: Double
    var purchaseDate: Date
    var hasPurchaseDate: Bool
    var lowestPrice: Double
    var lowestPriceDate: Date
    var hasLowestPriceDate: Bool
    var condition: String
    var notes: String
    var sortOrder: Int
    // Preserved from the persistent store; only used when updating an existing release.
    let dateAdded: Date

    func snapshot() -> ReleaseCardState {
        ReleaseCardState(
            id:                 id,
            studio:             studio,
            releaseYear:        hasReleaseYear ? releaseYear : ReleaseCardState.unsetYear,
            hasReleaseYear:     hasReleaseYear,
            baseReleaseYear:    hasBaseReleaseYear ? baseReleaseYear : ReleaseCardState.unsetYear,
            hasBaseReleaseYear: hasBaseReleaseYear,
            purchased:          purchased,
            wishlist:           wishlist,
            format:             format,
            includedVersions:   includedVersions,
            independence:       independence,
            videoFormat:        videoFormat,
            releaseAspectRatio: releaseAspectRatio,
            scanningMethod:     scanningMethod,
            audioFormat:        audioFormat,
            audioChannels:      audioChannels,
            hasSubtitles:       hasSubtitles,
            numberOfDiscs:      numberOfDiscs,
            discMultiPack:      discMultiPack,
            hasArtwork:         hasArtwork,
            remastered:         remastered,
            nationalOrigin:     nationalOrigin,
            replicationType:    replicationType,
            discCapacity:       discCapacity,
            hasHDR:             hasHDR,
            masterType:         masterType,
            regionLock:         regionLock,
            regionLockBypass:   regionLockBypass,
            marketAvailability: marketAvailability,
            numberOfCopies:     numberOfCopies,
            cost:               cost,
            amountSpent:        amountSpent,
            purchaseDate:       hasPurchaseDate ? purchaseDate : ReleaseCardState.unsetDate,
            hasPurchaseDate:    hasPurchaseDate,
            lowestPrice:        lowestPrice,
            lowestPriceDate:    hasLowestPriceDate ? lowestPriceDate : ReleaseCardState.unsetDate,
            hasLowestPriceDate: hasLowestPriceDate,
            condition:          condition,
            notes:              notes,
            sortOrder:          sortOrder,
            dateAdded:          dateAdded
        )
    }

    func matches(_ state: ReleaseCardState) -> Bool {
        id                 == state.id
        && studio             == state.studio
        && hasReleaseYear     == state.hasReleaseYear
        && (!hasReleaseYear     || releaseYear     == state.releaseYear)
        && hasBaseReleaseYear == state.hasBaseReleaseYear
        && (!hasBaseReleaseYear || baseReleaseYear == state.baseReleaseYear)
        && purchased          == state.purchased
        && wishlist           == state.wishlist
        && format             == state.format
        && includedVersions   == state.includedVersions
        && independence       == state.independence
        && videoFormat        == state.videoFormat
        && releaseAspectRatio == state.releaseAspectRatio
        && scanningMethod     == state.scanningMethod
        && audioFormat        == state.audioFormat
        && audioChannels      == state.audioChannels
        && hasSubtitles       == state.hasSubtitles
        && numberOfDiscs      == state.numberOfDiscs
        && discMultiPack      == state.discMultiPack
        && hasArtwork         == state.hasArtwork
        && remastered         == state.remastered
        && nationalOrigin     == state.nationalOrigin
        && replicationType    == state.replicationType
        && discCapacity       == state.discCapacity
        && hasHDR             == state.hasHDR
        && masterType         == state.masterType
        && regionLock         == state.regionLock
        && regionLockBypass   == state.regionLockBypass
        && marketAvailability == state.marketAvailability
        && numberOfCopies     == state.numberOfCopies
        && cost               == state.cost
        && amountSpent        == state.amountSpent
        && hasPurchaseDate    == state.hasPurchaseDate
        && (!hasPurchaseDate    || purchaseDate    == state.purchaseDate)
        && lowestPrice        == state.lowestPrice
        && hasLowestPriceDate == state.hasLowestPriceDate
        && (!hasLowestPriceDate || lowestPriceDate == state.lowestPriceDate)
        && condition          == state.condition
        && notes              == state.notes
        && sortOrder          == state.sortOrder
        && dateAdded          == state.dateAdded
    }

    var contentHash: Int {
        var h = Hasher()
        h.combine(studio)
        h.combine(releaseYear)
        h.combine(hasReleaseYear)
        h.combine(baseReleaseYear)
        h.combine(hasBaseReleaseYear)
        h.combine(purchased)
        h.combine(wishlist)
        h.combine(format)
        h.combine(includedVersions)
        h.combine(independence)
        h.combine(videoFormat)
        h.combine(releaseAspectRatio)
        h.combine(scanningMethod)
        h.combine(audioFormat)
        h.combine(audioChannels)
        h.combine(hasSubtitles)
        h.combine(numberOfDiscs)
        h.combine(discMultiPack)
        h.combine(hasArtwork)
        h.combine(remastered)
        h.combine(nationalOrigin)
        h.combine(replicationType)
        h.combine(discCapacity)
        h.combine(hasHDR)
        h.combine(masterType)
        h.combine(regionLock)
        h.combine(regionLockBypass)
        h.combine(marketAvailability)
        h.combine(numberOfCopies)
        h.combine(cost.bitPattern)
        h.combine(amountSpent.bitPattern)
        h.combine(purchaseDate)
        h.combine(hasPurchaseDate)
        h.combine(lowestPrice.bitPattern)
        h.combine(lowestPriceDate)
        h.combine(hasLowestPriceDate)
        h.combine(condition)
        h.combine(notes)
        h.combine(sortOrder)
        return h.finalize()
    }

    var contentHashNew: Int {
        var h = Hasher()
        h.combine(snapshot())
        h.combine(releaseYear)
        h.combine(baseReleaseYear)
        h.combine(purchaseDate)
        h.combine(lowestPriceDate)
        h.combine(cost.bitPattern)
        h.combine(amountSpent.bitPattern)
        h.combine(lowestPrice.bitPattern)
        return h.finalize()
    }


    init(id: UUID, studio: String, dateAdded: Date) {
        self.id = id; self.studio = studio; self.dateAdded = dateAdded
        releaseYear = 0; hasReleaseYear = false; baseReleaseYear = 0; hasBaseReleaseYear = false
        purchased = false; wishlist = 0; format = ""; includedVersions = []
        independence = ""; videoFormat = ""; releaseAspectRatio = []; scanningMethod = ""
        audioFormat = ""; audioChannels = ""; hasSubtitles = false; numberOfDiscs = 0
        discMultiPack = false; hasArtwork = ""; remastered = false; nationalOrigin = ""
        replicationType = ""; discCapacity = []; hasHDR = ""; masterType = ""
        regionLock = ""; regionLockBypass = false; marketAvailability = []
        numberOfCopies = 0; cost = 0; amountSpent = 0; purchaseDate = Date.distantPast
        hasPurchaseDate = false; lowestPrice = 0; lowestPriceDate = Date.distantPast
        hasLowestPriceDate = false; condition = ""; notes = ""; sortOrder = 0
    }
}
