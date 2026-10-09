// MARK: - Snapshots.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Canonical Sendable value-type DTOs (FilmSnapshot, ReleaseSnapshot, FilmChangeset,
// SettingsSnapshot) used by MemoryStore and all read paths. SwiftData @Model objects
// are confined to DataManager and are never exposed beyond the persistence layer.
// NOTE: FilmSnapshot, ReleaseSnapshot, and SettingsSnapshot must be kept in sync with
// their corresponding @Model counterparts whenever properties are added or renamed.

import Foundation

// MARK: - FilmSnapshot
// A Sendable struct that captures all Film properties — including its Release snapshots —
// for safe use in MemoryStore and across actor boundaries.
//
// Properties are 'var' so that DataCoordinator can create mutated copies via simple
// value-copy-and-assign without constructing an entirely new snapshot. Swift's value
// semantics guarantee each copy is independent, preserving Sendable safety.
//
// The 'id' property is intentionally 'let' because a snapshot's identity never changes.
//
// KEY INVARIANT: 'releases' is always kept in sync with the persisted Release records.
// DataCoordinator is responsible for rebuilding and re-storing the FilmSnapshot in
// MemoryStore after any release mutation (create / update / delete) commits to mainContext.

struct FilmSnapshot: Sendable, Codable, Equatable {
    // MARK: - Identity (immutable)
    let id: UUID

    // MARK: - Properties (mutable for in-place snapshot update via value copy)
    var posterUID: String
    var name: String
    var releaseYear: String
    var userRating: Int
    var lastWatched: String
    var rotationThresholdOverride: Int?
    var duration: String
    var viewCount: Int
    var calendarTable: [String]
    var autoAddToQueueOnRotation: Int?
    var digitalSource: String
    var digitalVersion: String
    var subtitles: String
    var notes: String
    var numberOfDiscs: String
    var aspectRatio: String
    var color: Bool
    var edited: Bool
    var editedDuration: String
    var frameRate: Double
    var tags: [String]
    var externalIdentifiers: [String]
    var dateAdded: String
    var lastModified: String
    var watched: Bool
    var specialSorting: [String]
    var alternateTitle: [String]
    var hofPosition: Int
    var infoComplete: Bool
    var comments: String
    var genre: String
    var releaseDate: String
    var descriptionText: String
    var rating: String
    var studio: [String]
    var cast: [String]
    var directors: [String]
    var producers: [String]
    var executiveProducers: [String]
    var screenwriters: [String]
    var encodingTool: [String]
    var libraryHBRFValue: Int
    var composer: [String]
    var sortName: String
    var releaseUsed: String
    var tools: [String]
    var editedHBRFValue: Int
    var editDate: String
    var warning: [String]
    var descriptionNotes: String
    var notesOnAudioTiming: [String]
    var specialAudioNotes: [String]
    var notesArray: [String]
    var handbrakeFrames: [String]
    var correspondingTimecodes: [String]

    // MARK: - Release Snapshots
    /// Snapshot of every Release associated with this Film.
    /// Updated by DataCoordinator after any release mutation commits to mainContext.
    var releases: [ReleaseSnapshot]

    // MARK: - Computed Properties

    /// The runtime the film actually plays at, as the stored millisecond string:
    /// `editedDuration` when the film is marked edited AND that field is a positive whole
    /// number of milliseconds, otherwise `duration`. The `edited` test matters on its own:
    /// FilmSheet blanks `editedDuration` on save when the film is not edited, but an older
    /// or imported record can still carry a stale value.
    ///
    /// The one definition of the rule. The gallery sort and its duration bands
    /// (MetadataCache), the list view's duration column, and the viewing popover's
    /// runtime, "Ends:" readout and calendar event all read it here; the popover used to
    /// accept any non-empty edited value, so an edited "0" would have given it a zero-length
    /// event while the gallery used the regular runtime.
    var effectiveDuration: String {
        if edited, let ms = Int(editedDuration), ms > 0 { return editedDuration }
        return duration
    }

    /// Effective rotation threshold: the per-film override if set, otherwise the global default.
    /// Mirrors Film.rotationThreshold without requiring a live @Model object.
    var rotationThreshold: Int {
        rotationThresholdOverride ?? Preferences.defaultRotationThreshold
    }

    /// True when at least one Notes tab field has a saved, non-default value.
    /// Used by RightSidebar to disable the Notes tab (and its MenuBar item / keyboard
    /// shortcut) when the film has no notes content yet.
    var hasNotesContent: Bool {
        !releaseUsed.isEmpty          ||
        !tools.isEmpty                ||
        editedHBRFValue != 0          ||
        !editDate.isEmpty             ||
        !warning.isEmpty              ||
        !descriptionNotes.isEmpty     ||
        !notesOnAudioTiming.isEmpty   ||
        !specialAudioNotes.isEmpty    ||
        !notesArray.isEmpty           ||
        !handbrakeFrames.isEmpty      ||
        !correspondingTimecodes.isEmpty
    }

    // MARK: - Initialization from Film
    /// Creates a snapshot from a Film @Model object, capturing all scalar properties
    /// and converting its Release relationships to ReleaseSnapshot value types.
    /// Must be called on MainActor where the Film and its context live.
    @MainActor
    init(from film: Film) {
        self.id = film.id
        self.posterUID = film.posterUID
        self.name = film.name
        self.releaseYear = film.releaseYear
        self.userRating = film.userRating
        self.lastWatched = film.lastWatched
        self.rotationThresholdOverride = film.rotationThresholdOverride
        self.duration = film.duration
        self.viewCount = film.viewCount
        self.calendarTable = film.calendarTable
        self.autoAddToQueueOnRotation = film.autoAddToQueueOnRotation
        self.digitalSource = film.digitalSource
        self.digitalVersion = film.digitalVersion
        self.subtitles = film.subtitles
        self.notes = film.notes
        self.numberOfDiscs = film.numberOfDiscs
        self.aspectRatio = film.aspectRatio
        self.color = film.color
        self.edited = film.edited
        self.editedDuration = film.editedDuration
        self.frameRate = film.frameRate
        self.tags = film.tags
        self.externalIdentifiers = film.externalIdentifiers
        self.dateAdded = film.dateAdded
        self.lastModified = film.lastModified
        self.watched = film.watched
        self.specialSorting = film.specialSorting
        self.alternateTitle = film.alternateTitle
        self.hofPosition = film.hofPosition
        self.infoComplete = film.infoComplete
        self.comments = film.comments
        self.genre = film.genre
        self.releaseDate = film.releaseDate
        self.descriptionText = film.descriptionText
        self.rating = film.rating
        self.studio = film.studio
        self.cast = film.cast
        self.directors = film.directors
        self.producers = film.producers
        self.executiveProducers = film.executiveProducers
        self.screenwriters = film.screenwriters
        self.encodingTool = film.encodingTool
        self.libraryHBRFValue = film.libraryHBRFValue
        self.composer = film.composer
        self.sortName = film.sortName
        self.releaseUsed = film.releaseUsed
        self.tools = film.tools
        self.editedHBRFValue = film.editedHBRFValue
        self.editDate = film.editDate
        self.warning = film.warning
        self.descriptionNotes = film.descriptionNotes
        self.notesOnAudioTiming = film.notesOnAudioTiming
        self.specialAudioNotes = film.specialAudioNotes
        self.notesArray = film.notesArray
        self.handbrakeFrames = film.handbrakeFrames
        self.correspondingTimecodes = film.correspondingTimecodes
        // Capture all Release relationships as value-type snapshots, with the parent→child
        // side of the hierarchy rebuilt from the authoritative child→parent pointers.
        // See ReleaseSnapshot.reconcilingHierarchy(_:).
        self.releases = ReleaseSnapshot.reconcilingHierarchy(film.releases)
    }

    // MARK: - Manual Initialization
    /// Creates a snapshot from individual values. Used by FilmSheet.confirm() to build a
    /// FilmChangeset from tab form data without requiring a live Film @Model object.
    /// All parameters match Film model properties exactly.
    /// `releases` defaults to empty; populate separately when known.
    init(
        id: UUID,
        posterUID: String,
        name: String,
        releaseYear: String,
        userRating: Int,
        lastWatched: String,
        rotationThresholdOverride: Int?,
        duration: String,
        viewCount: Int,
        calendarTable: [String],
        autoAddToQueueOnRotation: Int?,
        digitalSource: String,
        digitalVersion: String,
        subtitles: String,
        notes: String,
        numberOfDiscs: String,
        aspectRatio: String,
        color: Bool,
        edited: Bool,
        editedDuration: String,
        frameRate: Double,
        tags: [String],
        externalIdentifiers: [String],
        dateAdded: String,
        lastModified: String,
        watched: Bool,
        specialSorting: [String],
        alternateTitle: [String],
        hofPosition: Int,
        infoComplete: Bool,
        comments: String,
        genre: String,
        releaseDate: String,
        descriptionText: String,
        rating: String,
        studio: [String],
        cast: [String],
        directors: [String],
        producers: [String],
        executiveProducers: [String],
        screenwriters: [String],
        encodingTool: [String],
        libraryHBRFValue: Int,
        composer: [String],
        sortName: String,
        releaseUsed: String,
        tools: [String],
        editedHBRFValue: Int,
        editDate: String,
        warning: [String],
        descriptionNotes: String,
        notesOnAudioTiming: [String],
        specialAudioNotes: [String],
        notesArray: [String],
        handbrakeFrames: [String],
        correspondingTimecodes: [String],
        releases: [ReleaseSnapshot] = []
    ) {
        self.id = id
        self.posterUID = posterUID
        self.name = name
        self.releaseYear = releaseYear
        self.userRating = userRating
        self.lastWatched = lastWatched
        self.rotationThresholdOverride = rotationThresholdOverride
        self.duration = duration
        self.viewCount = viewCount
        self.calendarTable = calendarTable
        self.autoAddToQueueOnRotation = autoAddToQueueOnRotation
        self.digitalSource = digitalSource
        self.digitalVersion = digitalVersion
        self.subtitles = subtitles
        self.notes = notes
        self.numberOfDiscs = numberOfDiscs
        self.aspectRatio = aspectRatio
        self.color = color
        self.edited = edited
        self.editedDuration = editedDuration
        self.frameRate = frameRate
        self.tags = tags
        self.externalIdentifiers = externalIdentifiers
        self.dateAdded = dateAdded
        self.lastModified = lastModified
        self.watched = watched
        self.specialSorting = specialSorting
        self.alternateTitle = alternateTitle
        self.hofPosition = hofPosition
        self.infoComplete = infoComplete
        self.comments = comments
        self.genre = genre
        self.releaseDate = releaseDate
        self.descriptionText = descriptionText
        self.rating = rating
        self.studio = studio
        self.cast = cast
        self.directors = directors
        self.producers = producers
        self.executiveProducers = executiveProducers
        self.screenwriters = screenwriters
        self.encodingTool = encodingTool
        self.libraryHBRFValue = libraryHBRFValue
        self.composer = composer
        self.sortName = sortName
        self.releaseUsed = releaseUsed
        self.tools = tools
        self.editedHBRFValue = editedHBRFValue
        self.editDate = editDate
        self.warning = warning
        self.descriptionNotes = descriptionNotes
        self.notesOnAudioTiming = notesOnAudioTiming
        self.specialAudioNotes = specialAudioNotes
        self.notesArray = notesArray
        self.handbrakeFrames = handbrakeFrames
        self.correspondingTimecodes = correspondingTimecodes
        self.releases = releases
    }

    // MARK: - Apply to Film
    /// Applies scalar snapshot values to an existing Film @Model object — every
    /// `FilmField`, so a field added there is written here too.
    /// Called within DataManager's actor context after fetching the film by ID.
    /// NOTE: Does NOT apply releases — release mutations are handled separately
    /// via their own ReleaseSnapshot operations.
    func apply(to film: Film) {
        for field in FilmField.allCases { field.apply(self, to: film) }
    }

    // MARK: - Create New Film
    /// Creates a new Film @Model object from this snapshot's scalar properties.
    /// Used for insert operations where no existing film exists in the target context.
    /// NOTE: Does NOT attach releases — those are created separately by DataManager.
    func toFilm() -> Film {
        let film = Film(id: id)
        apply(to: film)
        return film
    }
}

// MARK: - ReleaseSnapshot
/// A Sendable struct that captures all Release properties for safe transfer across actor
/// boundaries. Analogous to FilmSnapshot but for Release objects.
///
/// SwiftData @Model classes are not Sendable because they are reference types tied to a
/// specific ModelContext. ReleaseSnapshot allows Release data to be packaged as a value
/// type, transferred to the background actor, where a new Release is either created or an
/// existing one is fetched by ID and updated.

struct ReleaseSnapshot: Sendable, Codable, Equatable {

    // MARK: - Properties (must match Release model)
    let id: UUID
    let studio: String
    let releaseYear: String
    let baseReleaseYear: String
    let purchased: Bool
    /// Wishlist position (0 = not on wishlist, ≥1 = wishlist display order). Mirrors Release.wishlist.
    /// `private(set) var` rather than `let` only so `withWishlist(_:)` can copy-and-replace.
    private(set) var wishlist: Int
    let format: String
    let includedVersions: [String]
    let independence: String
    let videoFormat: String
    let releaseAspectRatio: [String]
    let scanningMethod: String
    let audioFormat: String
    let audioChannels: String
    let hasSubtitles: Bool
    let numberOfDiscs: Int
    let discMultiPack: Bool
    let hasArtwork: String
    let remastered: Bool
    let nationalOrigin: String
    let replicationType: String
    let discCapacity: [String]
    let hasHDR: String
    let masterType: String
    let regionLock: String
    let regionLockBypass: Bool
    let marketAvailability: [String]
    let numberOfCopies: Int
    let cost: Double
    let amountSpent: Double
    let purchaseDate: String
    let lowestPrice: Double
    let lowestPriceDate: String
    let condition: String
    let notes: String
    let dateAdded: Date
    let sortOrder: Int

    // MARK: - Release Hierarchy
    // Flat UUID references — avoids circular nesting while keeping the snapshot Sendable/Codable.
    // parentReleaseID: nil when this release has no parent (it is top-level).
    // childReleaseIDs: empty when this release has no children.
    // These are read-only descriptors; hierarchy mutations are applied to the @Model layer
    // exclusively through DataCoordinator and DataManager.
    let parentReleaseID: UUID?
    /// `private(set) var` rather than `let` only so `withChildReleaseIDs(_:)` can
    /// copy-and-replace.
    private(set) var childReleaseIDs: [UUID]

    // MARK: - Computed Properties

    /// True when this snapshot represents a combo-pack child release (the Blu-ray that is
    /// auto-created beneath a 4K "Combo-pack" parent). Mirrors Release.isChild.
    ///
    /// A parent 4K release and its Blu-ray child are a single acquisition. The child is
    /// excluded from library aggregations where it would otherwise double-count a single
    /// product or its money — specifically the wishlist, the purchase/expense tracker, and
    /// the RPTabDataViz statistics. It is *kept* everywhere the bundled Blu-ray is a real,
    /// distinct disc: the FilmSheet, the RightSidebar ReleasesTable catalog, per-film disc
    /// counts, the Watch Details "Source" field, smart lists, and format-based search.
    var isChild: Bool { parentReleaseID != nil }

    /// True when this snapshot is a top-level release (no parent). Used as the inclusion
    /// predicate by the aggregations that exclude combo-pack children (see `isChild`).
    var isTopLevel: Bool { parentReleaseID == nil }

    /// Combined audio format and channel string, mirroring Release.audio.
    var audio: String {
        if audioFormat.isEmpty { return "" }
        if audioChannels.isEmpty { return audioFormat }
        return "\(audioFormat) \(audioChannels)"
    }

    /// Weighted quality score used to select the best release when differentiating
    /// among multiple purchased releases of the same format.
    ///
    /// Weight rationale (descending priority):
    ///   remastered       +500  — strongest single differentiator
    ///   lossless audio   +200  — significantly better playback experience
    ///   5.1 channels     +100  — surround vs. stereo
    ///   multi-version    + 50  — additional versions on disc
    ///   has subtitles    + 25  — accessibility / completeness bonus
    ///   video format     +20/10/0  — AVC > VC-1 > MPEG2 / other
    ///   newer year       + 1 per year — tiebreaker favoring newer pressings
    ///
    /// All factors are additive so that, e.g., a lossless-audio non-remastered release
    /// can out-score a remastered Dolby-Digital release when other factors align.
    var qualityScore: Int {
        var score = 0

        // Remastered — highest-priority factor.
        if remastered { score += 500 }

        // Lossless audio formats.
        if ReleaseAudioFormat.isLossless(audioFormat) { score += 200 }

        // 5.1 channels are better than 2.0.
        if audioChannels.hasPrefix("5.1") { score += 100 }

        // More than one included version.
        if includedVersions.count > 1 { score += 50 }

        // Has subtitles.
        if hasSubtitles { score += 25 }

        // Video format: AVC > VC-1 > everything else.
        switch videoFormat {
        case ReleaseVideoFormat.avc: score += 20
        case ReleaseVideoFormat.vc1: score += 10
        default:     break
        }

        // Year as tiebreaker — each year of recency adds 1 point.
        if let year = Int(releaseYear) { score += year }

        return score
    }

    // MARK: - Copy Helpers

    /// Returns a copy of this snapshot with `wishlist` replaced by `position`.
    /// Used by `DataCoordinator.reorderWishlist` to update position values
    /// without mutating the immutable struct in place.
    func withWishlist(_ position: Int) -> ReleaseSnapshot {
        var copy = self
        copy.wishlist = position
        return copy
    }

    /// Returns a copy of this snapshot with `childReleaseIDs` replaced.
    /// Used by `reconcilingHierarchy(_:)`, which rebuilds the parent side of the
    /// hierarchy from the child side.
    ///
    /// Both helpers copy `self` and replace one field. They used to rebuild the snapshot
    /// through the memberwise init, restating all 39 fields; since every init parameter
    /// has a default, a field added to the struct but missed there would have compiled
    /// and silently reset to its default on every wishlist reorder or hierarchy rebuild.
    func withChildReleaseIDs(_ ids: [UUID]) -> ReleaseSnapshot {
        var copy = self
        copy.childReleaseIDs = ids
        return copy
    }

    // MARK: - Static Helpers

    /// Snapshots a film's releases with the parent→child side of the hierarchy rebuilt
    /// from the child→parent side.
    ///
    /// WHY THIS EXISTS.
    ///
    /// The hierarchy is stored twice: as `Release.parentRelease` (the to-one side, which
    /// the export/restore pipeline writes and reads as `parentReleaseID`, and which
    /// `DataManager` step 6.5 assigns on save) and as `Release.childReleases` (the to-many
    /// side, which nothing ever assigns directly — it exists only as SwiftData's inverse of
    /// the first). Every writer in this project sets the child's pointer and trusts the
    /// inverse to follow. When it does not — a restored backup whose links were applied in
    /// bulk before a single `save()`, an inverse array that comes back empty on a later
    /// fetch — the two sides disagree in one specific direction: children still name their
    /// parent, but parents no longer claim their children.
    ///
    /// That asymmetry is invisible in most of the UI, because the RightSidebar's tables
    /// group on `parentReleaseID ?? id` and so read the surviving side. It is *not*
    /// invisible in the FilmSheet: `comboChildren(of:)` reads the parent's
    /// `childReleaseIDs`, so an empty array makes a parent look childless — which silently
    /// suppresses the combo-pack deletion confirmation (nothing appears to be at risk),
    /// suppresses the combined parent/child carousel card, and lets a combo-pack parent be
    /// retyped with its children left behind as locked, undeletable orphans.
    ///
    /// Deriving the parent side here, at the single boundary where @Model objects become
    /// snapshots, repairs every consumer at once and cannot drift: the child pointer is the
    /// only side that is actually written, so it is the only side that can be authoritative.
    ///
    /// Children are ordered by `sortOrder` with a UUID tiebreak, matching
    /// `FSTabReleases.comboChildren(of:)` so "the first child" means the same thing in both.
    /// A child naming a parent that is absent from this film, or naming a parent that is
    /// itself a child, contributes no link — the one-level-depth constraint is preserved.
    @MainActor
    static func reconcilingHierarchy(_ releases: [Release]) -> [ReleaseSnapshot] {
        let raw = releases.map { ReleaseSnapshot(from: $0) }
        guard raw.contains(where: { $0.parentReleaseID != nil })
                || raw.contains(where: { !$0.childReleaseIDs.isEmpty }) else { return raw }

        // Built by insertion rather than Dictionary(uniqueKeysWithValues:), which traps on
        // a duplicate key — a corrupt store with two releases sharing an ID must degrade,
        // not crash the snapshot path that every read in the app goes through.
        var byID = [UUID: ReleaseSnapshot](minimumCapacity: raw.count)
        for snapshot in raw { byID[snapshot.id] = snapshot }

        // A pointer is honored only when the named parent is present in this film and is
        // itself top-level. Evaluated against the raw set so ordering cannot matter.
        var childrenByParent: [UUID: [ReleaseSnapshot]] = [:]
        for snapshot in raw {
            guard let parentID = snapshot.parentReleaseID,
                  let parent = byID[parentID],
                  parent.parentReleaseID == nil,
                  parent.id != snapshot.id else { continue }
            childrenByParent[parentID, default: []].append(snapshot)
        }

        return raw.map { snapshot in
            let derived = (childrenByParent[snapshot.id] ?? [])
                .sorted { lhs, rhs in
                    if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                .map { $0.id }
            guard derived != snapshot.childReleaseIDs else { return snapshot }
            return snapshot.withChildReleaseIDs(derived)
        }
    }

    /// Returns the highest-quality release from `pool` according to `qualityScore`,
    /// or `nil` if `pool` is empty.
    static func best(from pool: [ReleaseSnapshot]) -> ReleaseSnapshot? {
        pool.max { $0.qualityScore < $1.qualityScore }
    }

    // MARK: - Initialization from Release
    /// Creates a snapshot from a Release @Model object.
    /// Must be called on MainActor where the Release lives.
    @MainActor
    init(from release: Release) {
        self.id = release.id
        self.studio = release.studio
        self.releaseYear = release.releaseYear
        self.baseReleaseYear = release.baseReleaseYear
        self.purchased = release.purchased
        self.wishlist = release.wishlist
        self.format = release.format
        self.includedVersions = release.includedVersions
        self.independence = release.independence
        self.videoFormat = release.videoFormat
        self.releaseAspectRatio = release.releaseAspectRatio
        self.scanningMethod = release.scanningMethod
        self.audioFormat = release.audioFormat
        self.audioChannels = release.audioChannels
        self.hasSubtitles = release.hasSubtitles
        self.numberOfDiscs = release.numberOfDiscs
        self.discMultiPack = release.discMultiPack
        self.hasArtwork = release.hasArtwork
        self.remastered = release.remastered
        self.nationalOrigin = release.nationalOrigin
        self.replicationType = release.replicationType
        self.discCapacity = release.discCapacity
        self.hasHDR = release.hasHDR
        self.masterType = release.masterType
        self.regionLock = release.regionLock
        self.regionLockBypass = release.regionLockBypass
        self.marketAvailability = release.marketAvailability
        self.numberOfCopies = release.numberOfCopies
        self.cost = release.cost
        self.amountSpent = release.amountSpent
        self.purchaseDate = release.purchaseDate
        self.lowestPrice = release.lowestPrice
        self.lowestPriceDate = release.lowestPriceDate
        self.condition = release.condition
        self.notes = release.notes
        self.dateAdded = release.dateAdded
        self.sortOrder = release.sortOrder
        self.parentReleaseID = release.parentRelease?.id
        self.childReleaseIDs = release.childReleases.map { $0.id }
    }

    // MARK: - Manual Initialization
    /// Creates a snapshot from individual values (used when building from UI form data).
    init(
        id: UUID = UUID(),
        studio: String = "",
        releaseYear: String = "",
        baseReleaseYear: String = "",
        purchased: Bool = false,
        wishlist: Int = 0,
        format: String = "",
        includedVersions: [String] = [],
        independence: String = "",
        videoFormat: String = "",
        releaseAspectRatio: [String] = [],
        scanningMethod: String = "",
        audioFormat: String = "",
        audioChannels: String = "",
        hasSubtitles: Bool = false,
        numberOfDiscs: Int = 1,
        discMultiPack: Bool = false,
        hasArtwork: String = "",
        remastered: Bool = false,
        nationalOrigin: String = "",
        replicationType: String = "",
        discCapacity: [String] = [],
        hasHDR: String = "",
        masterType: String = "",
        regionLock: String = "",
        regionLockBypass: Bool = false,
        marketAvailability: [String] = [],
        numberOfCopies: Int = 1,
        cost: Double = 0.0,
        amountSpent: Double = 0.0,
        purchaseDate: String = "",
        lowestPrice: Double = 0.0,
        lowestPriceDate: String = "",
        condition: String = "",
        notes: String = "",
        dateAdded: Date = Date(),
        sortOrder: Int = 0,
        parentReleaseID: UUID? = nil,
        childReleaseIDs: [UUID] = []
    ) {
        self.id = id
        self.studio = studio
        self.releaseYear = releaseYear
        self.baseReleaseYear = baseReleaseYear
        self.purchased = purchased
        self.wishlist = wishlist
        self.format = format
        self.includedVersions = includedVersions
        self.independence = independence
        self.videoFormat = videoFormat
        self.releaseAspectRatio = releaseAspectRatio
        self.scanningMethod = scanningMethod
        self.audioFormat = audioFormat
        self.audioChannels = audioChannels
        self.hasSubtitles = hasSubtitles
        self.numberOfDiscs = numberOfDiscs
        self.discMultiPack = discMultiPack
        self.hasArtwork = hasArtwork
        self.remastered = remastered
        self.nationalOrigin = nationalOrigin
        self.replicationType = replicationType
        self.discCapacity = discCapacity
        self.hasHDR = hasHDR
        self.masterType = masterType
        self.regionLock = regionLock
        self.regionLockBypass = regionLockBypass
        self.marketAvailability = marketAvailability
        self.numberOfCopies = numberOfCopies
        self.cost = cost
        self.amountSpent = amountSpent
        self.purchaseDate = purchaseDate
        self.lowestPrice = lowestPrice
        self.lowestPriceDate = lowestPriceDate
        self.condition = condition
        self.notes = notes
        self.dateAdded = dateAdded
        self.sortOrder = sortOrder
        self.parentReleaseID = parentReleaseID
        self.childReleaseIDs = childReleaseIDs
    }

    // MARK: - Apply to Release
    /// Applies snapshot values to an existing Release @Model object.
    /// Called within DataManager's actor context after fetching the release by ID.
    func apply(to release: Release) {
        release.studio = studio
        release.releaseYear = releaseYear
        release.baseReleaseYear = baseReleaseYear
        release.purchased = purchased
        release.wishlist = wishlist
        release.format = format
        release.includedVersions = includedVersions
        release.independence = independence
        release.videoFormat = videoFormat
        release.releaseAspectRatio = releaseAspectRatio
        release.scanningMethod = scanningMethod
        release.audioFormat = audioFormat
        release.audioChannels = audioChannels
        release.hasSubtitles = hasSubtitles
        release.numberOfDiscs = numberOfDiscs
        release.discMultiPack = discMultiPack
        release.hasArtwork = hasArtwork
        release.remastered = remastered
        release.nationalOrigin = nationalOrigin
        release.replicationType = replicationType
        release.discCapacity = discCapacity
        release.hasHDR = hasHDR
        release.masterType = masterType
        release.regionLock = regionLock
        release.regionLockBypass = regionLockBypass
        release.marketAvailability = marketAvailability
        release.numberOfCopies = numberOfCopies
        release.cost = cost
        release.amountSpent = amountSpent
        release.purchaseDate = purchaseDate
        release.lowestPrice = lowestPrice
        release.lowestPriceDate = lowestPriceDate
        release.condition = condition
        release.notes = notes
        release.dateAdded = dateAdded
        release.sortOrder = sortOrder
        // parentRelease and childReleases are NOT applied here — they are SwiftData object-graph
        // relationships that require live Release references. Hierarchy mutations are managed
        // exclusively by DataCoordinator / DataManager using the parentReleaseID / childReleaseIDs
        // UUID fields on this snapshot as lookup keys.
    }

    // MARK: - Create New Release
    /// Creates a new Release @Model object from this snapshot and links it to the given Film.
    /// Used by DataCoordinator (mainContext) and DataManager (background context) to
    /// materialize a new release into whatever context they're operating in.
    func toRelease(film: Film) -> Release {
        return Release(
            id: id,
            studio: studio,
            releaseYear: releaseYear,
            baseReleaseYear: baseReleaseYear,
            purchased: purchased,
            wishlist: wishlist,
            format: format,
            includedVersions: includedVersions,
            independence: independence,
            videoFormat: videoFormat,
            releaseAspectRatio: releaseAspectRatio,
            scanningMethod: scanningMethod,
            audioFormat: audioFormat,
            audioChannels: audioChannels,
            hasSubtitles: hasSubtitles,
            numberOfDiscs: numberOfDiscs,
            discMultiPack: discMultiPack,
            hasArtwork: hasArtwork,
            remastered: remastered,
            nationalOrigin: nationalOrigin,
            replicationType: replicationType,
            discCapacity: discCapacity,
            hasHDR: hasHDR,
            masterType: masterType,
            regionLock: regionLock,
            regionLockBypass: regionLockBypass,
            marketAvailability: marketAvailability,
            numberOfCopies: numberOfCopies,
            cost: cost,
            amountSpent: amountSpent,
            purchaseDate: purchaseDate,
            lowestPrice: lowestPrice,
            lowestPriceDate: lowestPriceDate,
            condition: condition,
            notes: notes,
            dateAdded: dateAdded,
            sortOrder: sortOrder,
            film: film)
    }
}

// MARK: - FilmChangeset
/// The complete set of changes produced by a FilmSheet save operation.
///
/// FilmChangeset is a Sendable value type that encodes every mutation the user made
/// during one FilmSheet editing session. It is the single transport container crossing
/// the MainActor → DataManager actor boundary.
///
/// DataCoordinator.saveFilmChangeset() consumes this struct in two ways:
///   1. Immediately applies scalar and relationship changes to MemoryStore (UI responsiveness).
///   2. Dispatches a copy to DataManager.applyFilmChangeset() for background persistence.
///
/// The derived values — `lastWatched`, `viewCount`, `lastModified`, `numberOfDiscs` —
/// are carried by `filmSnapshot` alone and must already be final there: FilmSheet
/// recomputes them from the merged calendar table and purchased releases before
/// building the changeset, so there is no second copy to disagree with the first.
///
/// The `filmSnapshot.releases` field carries release state for MemoryStore reconstruction
/// by DataCoordinator; it is not consumed for persistence. All release persistence is
/// handled exclusively by DataManager through the releasesToCreate / releasesToUpdate /
/// releasesToDelete delta arrays.

struct FilmChangeset: Sendable {
    /// The UUID of the Film being created or modified.
    let filmID: UUID

    /// True if this changeset represents a brand-new Film (insert), false for an edit (update).
    let isNewFilm: Bool

    /// Complete snapshot of all scalar Film properties to apply.
    let filmSnapshot: FilmSnapshot

    /// Release snapshots for releases that need to be created (new releases added by the user).
    let releasesToCreate: [ReleaseSnapshot]

    /// Release snapshots for existing releases whose properties have been modified.
    let releasesToUpdate: [ReleaseSnapshot]

    /// UUIDs of existing releases to delete (removed by the user).
    let releasesToDelete: [UUID]

    /// List UUIDs to which this film should be added (new memberships).
    let listsToAdd: Set<UUID>

    /// List UUIDs from which this film should be removed (deleted memberships).
    let listsToRemove: Set<UUID>

    // MARK: - Delta

    /// The scalar Film fields DataManager writes, or `nil` to write every field.
    ///
    /// A FilmSheet edit sends the fields its three-way merge changed (see
    /// `FilmField.merge`), so a field the sheet did not change keeps whatever the store
    /// holds, including a value a background import or reorder committed while the sheet
    /// was open. A new film, and every harness caller that predates the delta, sends `nil`.
    /// The derived values (lastWatched, viewCount, lastModified, numberOfDiscs) travel in
    /// `filmSnapshot` like every other field: written whole with `nil`, and with a delta
    /// only when listed in it, since FilmSheet lists each one it changed.
    var changedFields: Set<FilmField>? = nil
}

// MARK: - FilmField
/// One scalar Film property, with the key paths that read and write it on a
/// `FilmSnapshot` and on a `Film` model.
///
/// `id` and `releases` are not fields here: identity never changes, and releases travel
/// as their own deltas. The `film-field-merge` harness scenario proves by reflection that
/// every other stored property of FilmSnapshot has exactly one case, so a property added
/// to the snapshot and forgotten here fails that check rather than silently never saving.
enum FilmField: String, CaseIterable, Sendable {
    case posterUID, name, releaseYear, userRating, lastWatched, rotationThresholdOverride
    case duration, viewCount, calendarTable, autoAddToQueueOnRotation, digitalSource
    case digitalVersion, subtitles, notes, numberOfDiscs, aspectRatio, color, edited
    case editedDuration, frameRate, tags, externalIdentifiers, dateAdded, lastModified
    case watched, specialSorting, alternateTitle, hofPosition, infoComplete, comments
    case genre, releaseDate, descriptionText, rating, studio, cast, directors, producers
    case executiveProducers, screenwriters, encodingTool, libraryHBRFValue, composer
    case sortName, releaseUsed, tools, editedHBRFValue, editDate, warning, descriptionNotes
    case notesOnAudioTiming, specialAudioNotes, notesArray, handbrakeFrames
    case correspondingTimecodes

    /// Receives the field's two key paths with their shared value type in scope, which is
    /// what lets one switch below drive comparing, copying and applying alike.
    fileprivate protocol Visitor {
        mutating func visit<T: Equatable>(_ snapshot: WritableKeyPath<FilmSnapshot, T>,
                                          _ film: ReferenceWritableKeyPath<Film, T>)
    }

    fileprivate func accept<V: Visitor>(_ v: inout V) {
        switch self {
        case .posterUID:                 v.visit(\.posterUID, \.posterUID)
        case .name:                      v.visit(\.name, \.name)
        case .releaseYear:               v.visit(\.releaseYear, \.releaseYear)
        case .userRating:                v.visit(\.userRating, \.userRating)
        case .lastWatched:               v.visit(\.lastWatched, \.lastWatched)
        case .rotationThresholdOverride: v.visit(\.rotationThresholdOverride, \.rotationThresholdOverride)
        case .duration:                  v.visit(\.duration, \.duration)
        case .viewCount:                 v.visit(\.viewCount, \.viewCount)
        case .calendarTable:             v.visit(\.calendarTable, \.calendarTable)
        case .autoAddToQueueOnRotation:  v.visit(\.autoAddToQueueOnRotation, \.autoAddToQueueOnRotation)
        case .digitalSource:             v.visit(\.digitalSource, \.digitalSource)
        case .digitalVersion:            v.visit(\.digitalVersion, \.digitalVersion)
        case .subtitles:                 v.visit(\.subtitles, \.subtitles)
        case .notes:                     v.visit(\.notes, \.notes)
        case .numberOfDiscs:             v.visit(\.numberOfDiscs, \.numberOfDiscs)
        case .aspectRatio:               v.visit(\.aspectRatio, \.aspectRatio)
        case .color:                     v.visit(\.color, \.color)
        case .edited:                    v.visit(\.edited, \.edited)
        case .editedDuration:            v.visit(\.editedDuration, \.editedDuration)
        case .frameRate:                 v.visit(\.frameRate, \.frameRate)
        case .tags:                      v.visit(\.tags, \.tags)
        case .externalIdentifiers:       v.visit(\.externalIdentifiers, \.externalIdentifiers)
        case .dateAdded:                 v.visit(\.dateAdded, \.dateAdded)
        case .lastModified:              v.visit(\.lastModified, \.lastModified)
        case .watched:                   v.visit(\.watched, \.watched)
        case .specialSorting:            v.visit(\.specialSorting, \.specialSorting)
        case .alternateTitle:            v.visit(\.alternateTitle, \.alternateTitle)
        case .hofPosition:               v.visit(\.hofPosition, \.hofPosition)
        case .infoComplete:              v.visit(\.infoComplete, \.infoComplete)
        case .comments:                  v.visit(\.comments, \.comments)
        case .genre:                     v.visit(\.genre, \.genre)
        case .releaseDate:               v.visit(\.releaseDate, \.releaseDate)
        case .descriptionText:           v.visit(\.descriptionText, \.descriptionText)
        case .rating:                    v.visit(\.rating, \.rating)
        case .studio:                    v.visit(\.studio, \.studio)
        case .cast:                      v.visit(\.cast, \.cast)
        case .directors:                 v.visit(\.directors, \.directors)
        case .producers:                 v.visit(\.producers, \.producers)
        case .executiveProducers:        v.visit(\.executiveProducers, \.executiveProducers)
        case .screenwriters:             v.visit(\.screenwriters, \.screenwriters)
        case .encodingTool:              v.visit(\.encodingTool, \.encodingTool)
        case .libraryHBRFValue:          v.visit(\.libraryHBRFValue, \.libraryHBRFValue)
        case .composer:                  v.visit(\.composer, \.composer)
        case .sortName:                  v.visit(\.sortName, \.sortName)
        case .releaseUsed:               v.visit(\.releaseUsed, \.releaseUsed)
        case .tools:                     v.visit(\.tools, \.tools)
        case .editedHBRFValue:           v.visit(\.editedHBRFValue, \.editedHBRFValue)
        case .editDate:                  v.visit(\.editDate, \.editDate)
        case .warning:                   v.visit(\.warning, \.warning)
        case .descriptionNotes:          v.visit(\.descriptionNotes, \.descriptionNotes)
        case .notesOnAudioTiming:        v.visit(\.notesOnAudioTiming, \.notesOnAudioTiming)
        case .specialAudioNotes:         v.visit(\.specialAudioNotes, \.specialAudioNotes)
        case .notesArray:                v.visit(\.notesArray, \.notesArray)
        case .handbrakeFrames:           v.visit(\.handbrakeFrames, \.handbrakeFrames)
        case .correspondingTimecodes:    v.visit(\.correspondingTimecodes, \.correspondingTimecodes)
        }
    }

    private struct Differs: Visitor {
        let a: FilmSnapshot, b: FilmSnapshot
        var result = false
        mutating func visit<T: Equatable>(_ s: WritableKeyPath<FilmSnapshot, T>,
                                          _ f: ReferenceWritableKeyPath<Film, T>) {
            result = a[keyPath: s] != b[keyPath: s]
        }
    }

    private struct Copy: Visitor {
        let source: FilmSnapshot
        var target: FilmSnapshot
        mutating func visit<T: Equatable>(_ s: WritableKeyPath<FilmSnapshot, T>,
                                          _ f: ReferenceWritableKeyPath<Film, T>) {
            target[keyPath: s] = source[keyPath: s]
        }
    }

    private struct Apply: Visitor {
        let source: FilmSnapshot
        let film: Film
        mutating func visit<T: Equatable>(_ s: WritableKeyPath<FilmSnapshot, T>,
                                          _ f: ReferenceWritableKeyPath<Film, T>) {
            film[keyPath: f] = source[keyPath: s]
        }
    }

    private struct Read: Visitor {
        let film: Film
        var value: Any = ()
        mutating func visit<T: Equatable>(_ s: WritableKeyPath<FilmSnapshot, T>,
                                          _ f: ReferenceWritableKeyPath<Film, T>) {
            value = film[keyPath: f] as Any
        }
    }

    /// Whether this field holds different values in `a` and `b`.
    func differs(_ a: FilmSnapshot, _ b: FilmSnapshot) -> Bool {
        var v = Differs(a: a, b: b)
        accept(&v)
        return v.result
    }

    /// `target` with this field replaced by `source`'s value.
    func copy(from source: FilmSnapshot, into target: FilmSnapshot) -> FilmSnapshot {
        var v = Copy(source: source, target: target)
        accept(&v)
        return v.target
    }

    /// Writes this field of `snapshot` to `film`.
    func apply(_ snapshot: FilmSnapshot, to film: Film) {
        var v = Apply(source: snapshot, film: film)
        accept(&v)
    }

    /// This field's value on `film`, boxed as `Any`. An optional field stays boxed as an
    /// `Optional`, so an unset one is still present with a nil value.
    func value(of film: Film) -> Any {
        var v = Read(film: film)
        accept(&v)
        return v.value
    }

    // MARK: Three-way merge

    /// The outcome of merging a FilmSheet's fields with the film as it stands now.
    struct MergeResult: Sendable {
        /// `current` with the sheet's edits laid over it.
        let merged: FilmSnapshot
        /// The fields where `merged` differs from `current` — what the save must write.
        let changed: Set<FilmField>
    }

    /// Three-way merges a FilmSheet save with the film as MemoryStore holds it now.
    ///
    /// - Parameters:
    ///   - sheet: What the sheet's tabs collect at save time.
    ///   - loaded: What the same tabs collected when the sheet opened, before any edit.
    ///     Compared against `sheet`, it says which fields the user edited, free of the
    ///     normalization the tabs apply on load (a value the tabs reshape reads the same
    ///     in both).
    ///   - stored: The MemoryStore snapshot the sheet opened on.
    ///   - current: The MemoryStore snapshot now.
    ///
    /// Per field:
    ///   1. The user edited it (`sheet != loaded`): the sheet's value.
    ///   2. Otherwise, nothing else changed it (`current == stored`): the sheet's value.
    ///      When the tabs normalized the stored value on load this writes that repair,
    ///      exactly as the whole-object save did.
    ///   3. Otherwise someone else changed it while the sheet was open and the user did
    ///      not touch it: `current`'s value, so that change survives.
    ///
    /// Fields in one of the `coupled` groups count as edited together: editing any member
    /// takes every member from the sheet, so a pair the sheet derives one from the other
    /// is never split between the user's value and a background one.
    ///
    /// When nothing changed the film while the sheet was open, rules 1 and 2 cover every
    /// field and the result is `sheet` exactly — the whole-object save, unchanged.
    ///
    /// Derived and sheet-unowned fields are the caller's concern: pass them in `sheet`
    /// already resolved (see FilmSheet.confirm), and this treats them like any other.
    static func merge(sheet: FilmSnapshot, loaded: FilmSnapshot,
                      stored: FilmSnapshot, current: FilmSnapshot) -> MergeResult {
        // One visitor for all fields, so the four inputs are copied into it once rather
        // than once per field per comparison.
        var m = Merger(sheet: sheet, loaded: loaded, stored: stored, merged: current)
        for group in coupled where group.contains(where: { $0.differs(sheet, loaded) }) {
            m.editedTogether.formUnion(group)
        }
        for field in allCases {
            m.field = field
            field.accept(&m)
        }
        return MergeResult(merged: m.merged, changed: m.changed)
    }

    /// Fields the sheet keeps consistent with each other, so the merge must take them as
    /// a unit:
    ///   • releaseDate / releaseYear — the Details tab derives the year from the date.
    ///   • edited / editedDuration   — the tab blanks editedDuration when not edited.
    ///   • handbrakeFrames / correspondingTimecodes — one list of paired rows, padded to
    ///     equal length on load.
    /// (lastWatched / viewCount are derived from calendarTable after the merge instead;
    /// see FilmSheet.mergeWithCurrent.)
    static let coupled: [Set<FilmField>] = [
        [.releaseDate, .releaseYear],
        [.edited, .editedDuration],
        [.handbrakeFrames, .correspondingTimecodes],
    ]

    private struct Merger: Visitor {
        let sheet: FilmSnapshot, loaded: FilmSnapshot, stored: FilmSnapshot
        var merged: FilmSnapshot            // starts as `current`
        var changed = Set<FilmField>()
        var editedTogether = Set<FilmField>()
        var field = FilmField.posterUID

        init(sheet: FilmSnapshot, loaded: FilmSnapshot, stored: FilmSnapshot, merged: FilmSnapshot) {
            self.sheet = sheet; self.loaded = loaded; self.stored = stored; self.merged = merged
        }

        mutating func visit<T: Equatable>(_ s: WritableKeyPath<FilmSnapshot, T>,
                                          _ f: ReferenceWritableKeyPath<Film, T>) {
            let mine = sheet[keyPath: s]
            let now = merged[keyPath: s]
            let takeSheet = editedTogether.contains(field)
                || mine != loaded[keyPath: s] || now == stored[keyPath: s]
            guard takeSheet, mine != now else { return }
            merged[keyPath: s] = mine
            changed.insert(field)
        }
    }
}

// MARK: - SettingsSnapshot
/// Sendable snapshot of user settings for safe actor boundary crossing.
/// Mirrors SettingsObject but is a simple struct that can be passed to DataManager.

struct SettingsSnapshot: Sendable, Equatable {
    // MARK: - Metadata
    let snapshotID: UUID
    let version: Int
    /// `var` only so `hasSameSettings(as:)` can line two snapshots' dates up.
    private(set) var lastSyncDate: Date

    // MARK: - General Preferences
    let confirmGalleryDelete: Bool?
    let confirmListEdits: Bool?
    let listEditScope: Int?
    let confirmReleaseDelete: Bool?
    let largeGalleryGrid: Bool?
    let showStatusBar: Bool?
    let rememberRightSidebarTab: Bool?
    let autoExpandRightSidebarTables: Bool?
    let additionalCalTableDetails: Bool?
    let showReleasesSummaryTable: Bool?
    let iCalIntegration: Bool?
    let manualExtQuery: Bool?
    let smartLists: Bool?
    let excludeQueuedFromUpForRotation: Bool?
    let maintainSelectionOnSearchExit: Bool?
    let showInfoComplete: Bool?
    let performBackupAtLaunch: Bool?
    let defaultRotationThreshold: Int?

    // MARK: - Import Preferences
    let importScanSubfolders: Bool?
    let fuzzyImportMatching: Bool?
    let fuzzyImportYearMatching: Bool?
    let overrideSortNameField: Bool?
    let allowUpdatesForDuplicateImports: Bool?
    let allowUpdatesForDuplicateRatings: Bool?

    // MARK: - Export Preferences
    let exportPosterImages: Bool?
    let prunePosterImages: Bool?
    let exportUserSettings: Bool?

    // MARK: - UI State Preferences
    let maintainScrollPositionOnViewSwitch: Bool?
    let rememberTabSelection: Bool?
    let tabRememberScope: Int?
    let lastRecentsCategory: String?
    let lastReportsCategory: String?
    let rememberImportsTab: Bool?
    let lastImportsCategory: String?
    let rememberSortFilterSelections: Bool?
    let confirmFilmQueueAdd: Bool?
    let queueIsDropTarget: Bool?
    let queueSectionOnDrop: Int?
    let strictFramesTableChecking: Bool?
    let showWatchDetailsAnnotationGlyphs: Bool?

    // MARK: - Advanced Preferences
    let loggingEnabled: Bool?

    // MARK: - Complex Preferences (stored as JSON strings)
    let selectedSortOptionsJSON: String?
    let ignoredDuplicatePairsJSON: String?

    // MARK: - Initialization
    init(snapshotID: UUID = SettingsObject.singletonID,
         version: Int = SettingsObject.currentVersion,
         lastSyncDate: Date = Date(),
         confirmGalleryDelete: Bool? = nil,
         confirmListEdits: Bool? = nil,
         listEditScope: Int? = nil,
         confirmReleaseDelete: Bool? = nil,
         largeGalleryGrid: Bool? = nil,
         showStatusBar: Bool? = nil,
         rememberRightSidebarTab: Bool? = nil,
         autoExpandRightSidebarTables: Bool? = nil,
         additionalCalTableDetails: Bool? = nil,
         showReleasesSummaryTable: Bool? = nil,
         iCalIntegration: Bool? = nil,
         manualExtQuery: Bool? = nil,
         smartLists: Bool? = nil,
         excludeQueuedFromUpForRotation: Bool? = nil,
         maintainSelectionOnSearchExit: Bool? = nil,
         showInfoComplete: Bool? = nil,
         performBackupAtLaunch: Bool? = nil,
         defaultRotationThreshold: Int? = nil,
         importScanSubfolders: Bool? = nil,
         fuzzyImportMatching: Bool? = nil,
         fuzzyImportYearMatching: Bool? = nil,
         overrideSortNameField: Bool? = nil,
         allowUpdatesForDuplicateImports: Bool? = nil,
         allowUpdatesForDuplicateRatings: Bool? = nil,
         exportPosterImages: Bool? = nil,
         prunePosterImages: Bool? = nil,
         exportUserSettings: Bool? = nil,
         maintainScrollPositionOnViewSwitch: Bool? = nil,
         rememberTabSelection: Bool? = nil,
         tabRememberScope: Int? = nil,
         lastRecentsCategory: String? = nil,
         lastReportsCategory: String? = nil,
         rememberImportsTab: Bool? = nil,
         lastImportsCategory: String? = nil,
         rememberSortFilterSelections: Bool? = nil,
         confirmFilmQueueAdd: Bool? = nil,
         queueIsDropTarget: Bool? = nil,
         queueSectionOnDrop: Int? = nil,
         strictFramesTableChecking: Bool? = nil,
         showWatchDetailsAnnotationGlyphs: Bool? = nil,
         loggingEnabled: Bool? = nil,
         selectedSortOptionsJSON: String? = nil,
         ignoredDuplicatePairsJSON: String? = nil) {
        self.snapshotID = snapshotID
        self.version = version
        self.lastSyncDate = lastSyncDate
        self.confirmGalleryDelete = confirmGalleryDelete
        self.confirmListEdits = confirmListEdits
        self.listEditScope = listEditScope
        self.confirmReleaseDelete = confirmReleaseDelete
        self.largeGalleryGrid = largeGalleryGrid
        self.showStatusBar = showStatusBar
        self.rememberRightSidebarTab = rememberRightSidebarTab
        self.autoExpandRightSidebarTables = autoExpandRightSidebarTables
        self.additionalCalTableDetails = additionalCalTableDetails
        self.showReleasesSummaryTable = showReleasesSummaryTable
        self.iCalIntegration = iCalIntegration
        self.manualExtQuery = manualExtQuery
        self.smartLists = smartLists
        self.excludeQueuedFromUpForRotation = excludeQueuedFromUpForRotation
        self.maintainSelectionOnSearchExit = maintainSelectionOnSearchExit
        self.showInfoComplete = showInfoComplete
        self.performBackupAtLaunch = performBackupAtLaunch
        self.defaultRotationThreshold = defaultRotationThreshold
        self.importScanSubfolders = importScanSubfolders
        self.fuzzyImportMatching = fuzzyImportMatching
        self.fuzzyImportYearMatching = fuzzyImportYearMatching
        self.overrideSortNameField = overrideSortNameField
        self.allowUpdatesForDuplicateImports = allowUpdatesForDuplicateImports
        self.allowUpdatesForDuplicateRatings = allowUpdatesForDuplicateRatings
        self.exportPosterImages = exportPosterImages
        self.prunePosterImages = prunePosterImages
        self.exportUserSettings = exportUserSettings
        self.maintainScrollPositionOnViewSwitch = maintainScrollPositionOnViewSwitch
        self.rememberTabSelection = rememberTabSelection
        self.tabRememberScope = tabRememberScope
        self.lastRecentsCategory = lastRecentsCategory
        self.lastReportsCategory = lastReportsCategory
        self.rememberImportsTab = rememberImportsTab
        self.lastImportsCategory = lastImportsCategory
        self.rememberSortFilterSelections = rememberSortFilterSelections
        self.confirmFilmQueueAdd = confirmFilmQueueAdd
        self.queueIsDropTarget = queueIsDropTarget
        self.queueSectionOnDrop = queueSectionOnDrop
        self.strictFramesTableChecking = strictFramesTableChecking
        self.showWatchDetailsAnnotationGlyphs = showWatchDetailsAnnotationGlyphs
        self.loggingEnabled = loggingEnabled
        self.selectedSortOptionsJSON = selectedSortOptionsJSON
        self.ignoredDuplicatePairsJSON = ignoredDuplicatePairsJSON
    }

    // MARK: - Initialization from SettingsObject
    /// Creates a snapshot from a SettingsObject.
    init(from object: SettingsObject) {
        self.snapshotID = object.snapshotID
        self.version = object.version
        self.lastSyncDate = object.lastSyncDate
        self.confirmGalleryDelete = object.confirmGalleryDelete
        self.confirmListEdits = object.confirmListEdits
        self.listEditScope = object.listEditScope
        self.confirmReleaseDelete = object.confirmReleaseDelete
        self.largeGalleryGrid = object.largeGalleryGrid
        self.showStatusBar = object.showStatusBar
        self.rememberRightSidebarTab = object.rememberRightSidebarTab
        self.autoExpandRightSidebarTables = object.autoExpandRightSidebarTables
        self.additionalCalTableDetails = object.additionalCalTableDetails
        self.showReleasesSummaryTable = object.showReleasesSummaryTable
        self.iCalIntegration = object.iCalIntegration
        self.manualExtQuery = object.manualExtQuery
        self.smartLists = object.smartLists
        self.excludeQueuedFromUpForRotation = object.excludeQueuedFromUpForRotation
        self.maintainSelectionOnSearchExit = object.maintainSelectionOnSearchExit
        self.showInfoComplete = object.showInfoComplete
        self.performBackupAtLaunch = object.performBackupAtLaunch
        self.defaultRotationThreshold = object.defaultRotationThreshold
        self.importScanSubfolders = object.importScanSubfolders
        self.fuzzyImportMatching = object.fuzzyImportMatching
        self.fuzzyImportYearMatching = object.fuzzyImportYearMatching
        self.overrideSortNameField = object.overrideSortNameField
        self.allowUpdatesForDuplicateImports = object.allowUpdatesForDuplicateImports
        self.allowUpdatesForDuplicateRatings = object.allowUpdatesForDuplicateRatings
        self.exportPosterImages = object.exportPosterImages
        self.prunePosterImages = object.prunePosterImages
        self.exportUserSettings = object.exportUserSettings
        self.maintainScrollPositionOnViewSwitch = object.maintainScrollPositionOnViewSwitch
        self.rememberTabSelection = object.rememberTabSelection
        self.tabRememberScope = object.tabRememberScope
        self.lastRecentsCategory = object.lastRecentsCategory
        self.lastReportsCategory = object.lastReportsCategory
        self.rememberImportsTab = object.rememberImportsTab
        self.lastImportsCategory = object.lastImportsCategory
        self.rememberSortFilterSelections = object.rememberSortFilterSelections
        self.confirmFilmQueueAdd = object.confirmFilmQueueAdd
        self.queueIsDropTarget = object.queueIsDropTarget
        self.queueSectionOnDrop = object.queueSectionOnDrop
        self.strictFramesTableChecking = object.strictFramesTableChecking
        self.showWatchDetailsAnnotationGlyphs = object.showWatchDetailsAnnotationGlyphs
        self.loggingEnabled = object.loggingEnabled
        self.selectedSortOptionsJSON = object.selectedSortOptionsJSON
        self.ignoredDuplicatePairsJSON = object.ignoredDuplicatePairsJSON
    }

    // MARK: - Apply to SettingsObject
    /// Applies snapshot values to a SettingsObject.
    func apply(to object: SettingsObject) {
        object.snapshotID = snapshotID
        object.lastSyncDate = lastSyncDate
        object.version = version
        object.confirmGalleryDelete = confirmGalleryDelete
        object.confirmListEdits = confirmListEdits
        object.listEditScope = listEditScope
        object.confirmReleaseDelete = confirmReleaseDelete
        object.largeGalleryGrid = largeGalleryGrid
        object.showStatusBar = showStatusBar
        object.rememberRightSidebarTab = rememberRightSidebarTab
        object.autoExpandRightSidebarTables = autoExpandRightSidebarTables
        object.additionalCalTableDetails = additionalCalTableDetails
        object.showReleasesSummaryTable = showReleasesSummaryTable
        object.iCalIntegration = iCalIntegration
        object.manualExtQuery = manualExtQuery
        object.smartLists = smartLists
        object.excludeQueuedFromUpForRotation = excludeQueuedFromUpForRotation
        object.maintainSelectionOnSearchExit = maintainSelectionOnSearchExit
        object.showInfoComplete = showInfoComplete
        object.performBackupAtLaunch = performBackupAtLaunch
        object.defaultRotationThreshold = defaultRotationThreshold
        object.importScanSubfolders = importScanSubfolders
        object.fuzzyImportMatching = fuzzyImportMatching
        object.fuzzyImportYearMatching = fuzzyImportYearMatching
        object.overrideSortNameField = overrideSortNameField
        object.allowUpdatesForDuplicateImports = allowUpdatesForDuplicateImports
        object.allowUpdatesForDuplicateRatings = allowUpdatesForDuplicateRatings
        object.exportPosterImages = exportPosterImages
        object.prunePosterImages = prunePosterImages
        object.exportUserSettings = exportUserSettings
        object.maintainScrollPositionOnViewSwitch = maintainScrollPositionOnViewSwitch
        object.rememberTabSelection = rememberTabSelection
        object.tabRememberScope = tabRememberScope
        object.lastRecentsCategory = lastRecentsCategory
        object.lastReportsCategory = lastReportsCategory
        object.rememberImportsTab = rememberImportsTab
        object.lastImportsCategory = lastImportsCategory
        object.rememberSortFilterSelections = rememberSortFilterSelections
        object.confirmFilmQueueAdd = confirmFilmQueueAdd
        object.queueIsDropTarget = queueIsDropTarget
        object.queueSectionOnDrop = queueSectionOnDrop
        object.strictFramesTableChecking = strictFramesTableChecking
        object.showWatchDetailsAnnotationGlyphs = showWatchDetailsAnnotationGlyphs
        object.loggingEnabled = loggingEnabled
        object.selectedSortOptionsJSON = selectedSortOptionsJSON
        object.ignoredDuplicatePairsJSON = ignoredDuplicatePairsJSON
    }
}

// MARK: - SettingsSnapshot Change Detection

extension SettingsSnapshot {
    /// Whether `other` carries the same persisted preferences — every field except
    /// `lastSyncDate`, which is stamped with `Date()` on every construction and would
    /// otherwise make two otherwise identical snapshots differ.
    ///
    /// Used by SettingsManager to skip the fetch/encode/`context.save()` round trip on the
    /// main context when a `preferencesChanged` event carries no actual change. `nil` and
    /// a value are distinguished (an unset optional is not the same as `false` or `""`),
    /// which matters because the restore path treats nil as "key absent in this backup".
    func hasSameSettings(as other: SettingsSnapshot) -> Bool {
        var aligned = other
        aligned.lastSyncDate = lastSyncDate
        return aligned == self
    }
}

#if DEBUG
/// Debug-only, for the `store-snapshot-mapping` harness scenario (99.11 DHStore.swift),
/// which reads the settings field list from the synthesized coding keys the way it already
/// does for FilmSnapshot and ReleaseSnapshot. Declared in this file because Swift only
/// synthesizes a conformance in the type's own file. Nothing in the app encodes settings
/// this way.
extension SettingsSnapshot: Codable {}
#endif
