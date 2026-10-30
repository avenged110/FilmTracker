// MARK: - FilmObj.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Defines the primary data model for a single film entry in the user's library.

import Foundation
import CoreData

// MARK: - Special Sorting Vocabulary
/// The stored vocabulary for `Film.specialSorting`, plus the combination rules that govern
/// which tags may coexist.
///
/// The values are plain `String`s in the model (persisted verbatim, exported to XML
/// backups, read back by `SafeValueParser`), so this is a namespace of constants and pure
/// data rather than a `RawRepresentable` case set — an unknown value arriving from a legacy
/// backup must round-trip untouched rather than fail to decode. Same reasoning as
/// `ReleaseIndependence` and the other release vocabularies in ReleaseObj.swift.
///
/// # ⚠️ THESE ARE NOT `SmartListType.rawValue`
///
/// `SmartListType` (SmartLists.swift) and the sorting-family variants it exposes both
/// carry cases that LOOK like these tags but are **smart-list display names**, and they
/// differ in capitalization:
///
///     stored tag (here)        SmartListType.rawValue
///     ─────────────────        ──────────────────────
///     "Waiting for edit"       "Waiting for Edit"        ← capital E
///     "Temporarily on hold"    "Temporarily On Hold"     ← capital O
///     "Indefinitely on hold"   "Indefinitely On Hold"    ← capital O
///     "Ignore"                 "Ignore"                  ← identical
///     "Blacklisted"            "Blacklisted"             ← identical
///
/// The last two matching is what makes the trap: the pattern reads as interchangeable
/// right up until it silently is not. Substituting a raw value for a stored tag writes a
/// case-mismatched string that no membership check will ever match, and the film drops out
/// of its own smart list with no error anywhere. NEVER use one for the other; convert
/// through this namespace instead.
///
/// # Combination rules
///
/// The two independent tags are freely combinable with each other and with one member of
/// the exclusive group, so a film carries at most three tags at once. The exclusive group
/// is kept exclusive by the FilmSheet UI (`SpecialSortingMenu` clears the siblings on
/// select), not by the schema — a hand-edited backup could present two, and every consumer
/// here tolerates that by testing membership independently rather than switching on one
/// value.
enum FilmSpecialSorting {
    static let waitingForEdit      = "Waiting for edit"
    static let temporarilyOnHold   = "Temporarily on hold"
    static let indefinitelyOnHold  = "Indefinitely on hold"
    static let ignore              = "Ignore"
    static let blacklisted         = "Blacklisted"

    /// Freely and independently combinable with each other and with the exclusive group.
    static let independentOptions = [waitingForEdit, temporarilyOnHold]

    /// Mutually exclusive among themselves — selecting one clears the other two, matching
    /// the toggle-within-group pattern GalleryFilterMenu's watched/color/purchase pairs
    /// use.
    static let exclusiveOptions = [indefinitelyOnHold, ignore, blacklisted]

    /// Canonical display/output order for the combined option set. Used whenever the
    /// `Set<String>` selection needs to be flattened to a deterministic array (DTO
    /// assembly, display strings), since `Set` iteration order is not guaranteed.
    static let canonicalOrder = independentOptions + exclusiveOptions
}

// MARK: - Digital Source Vocabulary
/// The stored vocabulary for `Film.digitalSource`, plus the encoding that folds the
/// "remastered" flag into the same field.
///
/// Open vocabulary, as with every other stored string in this app: values are persisted
/// verbatim, exported to XML backups, and read back with no membership check, so an
/// unrecognized value must round-trip untouched.
///
/// # The composite encoding
///
/// There is no separate "remastered" column. A remastered source is stored by PREFIXING
/// the value with `remasteredPrefix` — trailing space included — giving
/// `"Remastered Blu-ray disc"`. That convention was previously spelled out at three
/// separate sites, twice as a `hasPrefix` test paired with a `dropFirst(_:)` whose count
/// came from a second hand-typed copy of the same literal on the line above it. A single
/// dropped space in any one of them would have silently stopped the flag round-tripping.
///
/// `compose` and `decompose` are exact inverses and are the ONLY supported way to cross
/// between the stored form and the (source, remastered) pair. Neither trims: whitespace
/// policy belongs to the caller, and the right sidebar deliberately trims before decoding
/// while the FilmSheet deliberately does not.
enum FilmDigitalSource {
    // MARK: Disc sources
    static let blurayDisc = "Blu-ray disc"
    static let dvd        = "DVD"

    // MARK: Download tiers
    static let download360p  = "360p download"
    static let download480p  = "480p download"
    static let download540p  = "540p download"
    static let download720p  = "720p download"
    static let download1080p = "1080p download"
    static let download4K    = "4K download"

    /// The marker that folds the remastered flag into the stored value. The trailing
    /// space is part of the tag, not formatting — `compose` relies on it to separate the
    /// prefix from the source, and `decompose` strips exactly this many characters.
    static let remasteredPrefix = "Remastered "

    /// The FilmSheet picker's option list. The leading "" is the unset row.
    ///
    /// Ascending by quality, which is NOT the order the Reports tab charts these in — see
    /// `RPTabDataViz`'s source distribution, which lists them descending and composes the
    /// remastered forms. Two orderings over one vocabulary is exactly why the vocabulary
    /// lives here rather than inside either of them.
    static let pickerOptions: [String] = [
        "", blurayDisc, dvd,
        download360p, download480p, download540p, download720p, download1080p, download4K,
    ]

    /// The stored form of a (source, remastered) pair.
    ///
    /// An empty source is never prefixed: "Remastered " on its own would be a claim about
    /// a source that was never named, and it would then decompose to an empty source with
    /// the flag set — a state the picker cannot produce and no consumer expects.
    static func compose(source: String, remastered: Bool) -> String {
        guard remastered, !source.isEmpty else { return source }
        return remasteredPrefix + source
    }

    /// The (source, remastered) pair a stored value encodes — the exact inverse of
    /// `compose`. A value carrying no prefix decodes to itself with the flag clear, which
    /// is the correct reading of both an unset field and any legacy value.
    static func decompose(_ stored: String) -> (source: String, remastered: Bool) {
        guard stored.hasPrefix(remasteredPrefix) else { return (stored, false) }
        return (String(stored.dropFirst(remasteredPrefix.count)), true)
    }
}

// MARK: - Subtitles Vocabulary
/// The stored vocabulary for `Film.subtitles` — whether the copy the user holds carries
/// subtitles, and if so where they come from. Open vocabulary, as everywhere else.
///
/// Distinct from `Release.hasSubtitles`, which is a `Bool` describing one physical disc.
/// This field describes the user's viewing copy, which may be a rip.
///
/// The Reports tab compares these LOWERCASED, against a value it lowercases first, so its
/// comparisons are case-insensitive while the picker writes the canonical casing here.
/// `matches(_:_:)` is the single expression of that rule, so a consumer cannot accidentally
/// compare a lowercased field against a canonical tag and silently never match.
enum FilmSubtitles {
    static let yes             = "Yes"
    static let no              = "No"
    static let onDiscOnly      = "On-disc only"
    static let digitalRipOnly  = "Digital rip only"

    /// The picker's option list. The leading "" is the unset row.
    static let pickerOptions: [String] = ["", yes, onDiscOnly, digitalRipOnly, no]

    /// The tags that affirm subtitles are present in some form.
    static let affirmativeTags: Set<String> = [yes, onDiscOnly, digitalRipOnly]

    /// Case-insensitive equality against a stored tag. The Reports tab reads this field
    /// from data that may predate the picker's current casing, so it compares loosely;
    /// this is that comparison's one definition.
    static func matches(_ stored: String, _ tag: String) -> Bool {
        stored.caseInsensitiveCompare(tag) == .orderedSame
    }

    /// True when `stored` affirms subtitles are present, compared case-insensitively.
    static func isAffirmative(_ stored: String) -> Bool {
        affirmativeTags.contains { matches(stored, $0) }
    }
}

@objc(Film)
final class Film: LibraryObject {
    // Film.id is indexed (LibraryModel): it is the target of every predicate-based fetch
    // in DataManager, both equality lookups and multi-ID IN queries, which the index turns
    // from full-table scans into O(log n) lookups — most of all in batch operations.

    // Primary stable id for exports and restores.
    var id: UUID { get { requiredUUID("id") } set { setValue(newValue, forKey: "id") } } // See requiredUUID.

    // MARK: - Details
    @NSManaged var posterUID: String
    @NSManaged var name: String
    @NSManaged var releaseYear: String
    @NSManaged var userRating: Int
    @NSManaged var lastWatched: String
    @NSManaged var duration: String
    @NSManaged var viewCount: Int
    @NSManaged var calendarTable: [String]
    // Per-film flag governing whether this film should be automatically added to the
    // Film Queue when it next comes up for rotation. nil (default) means the feature is
    // disabled for this film; 0/1/2 means enabled, identifying the target section (Up
    // Next / Soon / Later, matching FilmQueueSection.queueOrder) it should be added to.
    // Set on a per-film basis via the FilmSheet Details tab's "Automatically add to…"
    // checkbox row. Mirrors the nil-means-unset convention used by rotationThresholdOverride.
    var autoAddToQueueOnRotation: Int? {
        get { optionalInt("autoAddToQueueOnRotation") }
        set { setOptionalInt(newValue, "autoAddToQueueOnRotation") }
    }

    // MARK: - Rotation Threshold Override System
    // Stores the user's per-film override value (nil means use global default).
    // Only the override is stored in the database; the effective value is computed.
    var rotationThresholdOverride: Int? {
        get { optionalInt("rotationThresholdOverride") }
        set { setOptionalInt(newValue, "rotationThresholdOverride") }
    }

    // MARK: - ListMembership Relationship
    @NSManaged var memberships: Set<ListMembership>

    // MARK: - Release Relationship
    @NSManaged var releases: Set<Release>

    // MARK: - Library Information
    @NSManaged var digitalSource: String // Composite; see FilmDigitalSource.compose/decompose.
    @NSManaged var digitalVersion: String
    @NSManaged var subtitles: String // See FilmSubtitles.
    @NSManaged var notes: String
    @NSManaged var numberOfDiscs: String
    @NSManaged var aspectRatio: String
    @NSManaged var color: Bool
    @NSManaged var edited: Bool
    @NSManaged var editedDuration: String
    @NSManaged var frameRate: Double

    @NSManaged var tags: [String]
    @NSManaged var externalIdentifiers: [String]
    @NSManaged var dateAdded: String

    // Empty string means "never modified since it entered the library" and is a deliberate
    // sentinel, not a missing value. Films created by MetaParser are stored with "" so the
    // UI can show a blank field rather than a date identical to dateAdded, which would make
    // the user compare two timestamps to answer "has this been touched since import?".
    // MetadataCache.getFormattedDate maps "" to nil so display and sorting treat it as
    // absent; DataCoordinator and MetaImporter write a real timestamp on first actual edit.
    //
    // CONSEQUENCE FOR THE SNAPSHOT CACHE — do not undo this without reading that code first.
    // Because an insert can carry a lastModified that is lexicographically LOWER than every
    // existing value, "newest lastModified in the library" cannot detect an insert. That
    // rules out validating the snapshot cache with a cheap (count, max-timestamp)
    // fingerprint: a balanced add-and-delete would leave both unchanged while the library's
    // contents differ, silently accepting a stale cache. Measured during startup profiling;
    // see DataManager.computeStoreFingerprint for the full reasoning and the alternatives
    // that were ruled out.
    @NSManaged var lastModified: String
    @NSManaged var watched: Bool
    @NSManaged var specialSorting: [String] // See FilmSpecialSorting.
    @NSManaged var alternateTitle: [String]
    @NSManaged var hofPosition: Int
    @NSManaged var infoComplete: Bool

    // MARK: - Metadata
    @NSManaged var comments: String
    @NSManaged var genre: String
    @NSManaged var releaseDate: String
    @NSManaged var descriptionText: String
    @NSManaged var rating: String
    @NSManaged var studio: [String]
    @NSManaged var cast: [String]
    @NSManaged var directors: [String]
    @NSManaged var producers: [String]
    @NSManaged var executiveProducers: [String]
    @NSManaged var screenwriters: [String]
    @NSManaged var encodingTool: [String]
    @NSManaged var libraryHBRFValue: Int
    @NSManaged var composer: [String]
    @NSManaged var sortName: String

    // MARK: - Notes → Custom Edit Notes
    @NSManaged var releaseUsed: String
    @NSManaged var tools: [String]
    @NSManaged var editedHBRFValue: Int
    @NSManaged var editDate: String
    @NSManaged var warning: [String]
    @NSManaged var descriptionNotes: String
    @NSManaged var notesOnAudioTiming: [String]
    @NSManaged var specialAudioNotes: [String]
    @NSManaged var notesArray: [String]
    @NSManaged var handbrakeFrames: [String]
    @NSManaged var correspondingTimecodes: [String]

    // MARK: - Initialization
    /// Every default; see LibraryObject.init(detached:).
    convenience init() { self.init(id: UUID()) }

    convenience init(
        id: UUID = UUID(),
        posterUID: String = "",
        name: String = "",
        releaseYear: String = "",
        userRating: Int = 0,
        lastWatched: String = "",
        rotationThresholdOverride: Int? = nil,
        duration: String = "",
        viewCount: Int = 0,
        calendarTable: [String] = [],
        autoAddToQueueOnRotation: Int? = nil,
        digitalSource: String = "",
        digitalVersion: String = "",
        subtitles: String = "",
        notes: String = "",
        numberOfDiscs: String = "",
        aspectRatio: String = "",
        color: Bool = true,
        edited: Bool = false,
        editedDuration: String = "",
        frameRate: Double = 0.0,
        tags: [String] = [],
        externalIdentifiers: [String] = [],
        dateAdded: String = "",
        lastModified: String = "",
        watched: Bool = true,
        specialSorting: [String] = [],
        alternateTitle: [String] = [],
        hofPosition: Int = 0,
        infoComplete: Bool = false,
        comments: String = "",
        genre: String = "",
        releaseDate: String = "",
        descriptionText: String = "",
        rating: String = "",
        studio: [String] = [],
        cast: [String] = [],
        directors: [String] = [],
        producers: [String] = [],
        executiveProducers: [String] = [],
        screenwriters: [String] = [],
        encodingTool: [String] = [],
        libraryHBRFValue: Int = 0,
        composer: [String] = [],
        sortName: String = "",
        releaseUsed: String = "",
        tools: [String] = [],
        editedHBRFValue: Int = 0,
        editDate: String = "",
        warning: [String] = [],
        descriptionNotes: String = "",
        notesOnAudioTiming: [String] = [],
        specialAudioNotes: [String] = [],
        notesArray: [String] = [],
        handbrakeFrames: [String] = [],
        correspondingTimecodes: [String] = []
    ) {
        self.init(detached: ())
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
        self.correspondingTimecodes = correspondingTimecodes }
}

// MARK: - ExportableModel Conformance for Film
extension Film: ExportableModel {

    static func fetchAll(in context: NSManagedObjectContext) throws -> [Film] {
        let desc = Film.request(sortedBy: [NSSortDescriptor(key: "name", ascending: true)])
        return try context.fetch(desc) }

    func extractExportValues() -> (properties: [String: Any], relationships: [String : [Any]]) {
        var props: [String: Any] = [:]

        // Every stored scalar property: the id, then each FilmField under its own name.
        props["id"] = self.id
        for field in FilmField.allCases {
            props[field.rawValue] = field.value(of: self)
        }

        // Don't export list membership IDs as a property (handled by ListMembership entities).
        // Don't export release IDs as a property (handled by Release entities).

        // No relationship arrays - everything handled via join entities with IDs.
        let rels: [String: [Any]] = [:]
        return (properties: props, relationships: rels) }

    func exportStableID() -> String? { return self.id.uuidString }
}
