import Foundation
import SwiftData
import CoreData

@Model final class Film {
    #Index<Film>([\.id])
    @Relationship(deleteRule: .cascade, inverse: \ListMembership.film) var memberships: [ListMembership] = []
    @Relationship(deleteRule: .cascade, inverse: \Release.film) var releases: [Release] = []
    var id: UUID = UUID()
    var posterUID: String = ""
    var name: String = ""
    var releaseYear: String = ""
    var userRating: Int = 0
    var lastWatched: String = ""
    var duration: String = ""
    var viewCount: Int = 0
    var calendarTable: [String] = []
    var autoAddToQueueOnRotation: Int? = nil
    var rotationThresholdOverride: Int? = nil
    var digitalSource: String = ""
    var digitalVersion: String = ""
    var subtitles: String = ""
    var notes: String = ""
    var numberOfDiscs: String = ""
    var aspectRatio: String = ""
    var color: Bool = false
    var edited: Bool = false
    var editedDuration: String = ""
    var frameRate: Double = 0
    var tags: [String] = []
    var externalIdentifiers: [String] = []
    var dateAdded: String = ""
    var lastModified: String = ""
    var watched: Bool = false
    var specialSorting: [String] = []
    var alternateTitle: [String] = []
    var hofPosition: Int = 0
    var infoComplete: Bool = false
    var comments: String = ""
    var genre: String = ""
    var releaseDate: String = ""
    var descriptionText: String = ""
    var rating: String = ""
    var studio: [String] = []
    var cast: [String] = []
    var directors: [String] = []
    var producers: [String] = []
    var executiveProducers: [String] = []
    var screenwriters: [String] = []
    var encodingTool: [String] = []
    var libraryHBRFValue: Int = 0
    var composer: [String] = []
    var sortName: String = ""
    var releaseUsed: String = ""
    var tools: [String] = []
    var editedHBRFValue: Int = 0
    var editDate: String = ""
    var warning: [String] = []
    var descriptionNotes: String = ""
    var notesOnAudioTiming: [String] = []
    var specialAudioNotes: [String] = []
    var notesArray: [String] = []
    var handbrakeFrames: [String] = []
    var correspondingTimecodes: [String] = []
    init() {}
}
@Model final class Release {
    var film: Film?
    @Relationship(deleteRule: .nullify, inverse: \Release.childReleases) var parentRelease: Release?
    @Relationship(deleteRule: .nullify) var childReleases: [Release] = []
    var id: UUID = UUID()
    var studio: String = ""
    var releaseDate: String = ""
    var baseReleaseYear: String = ""
    var purchased: Bool = false
    var wishlist: Int = 0
    var format: String = ""
    var includedVersions: [String] = []
    var independence: String = ""
    var videoFormat: String = ""
    var releaseAspectRatio: [String] = []
    var scanningMethod: String = ""
    var audioFormat: String = ""
    var audioChannels: String = ""
    var hasSubtitles: Bool = false
    var numberOfDiscs: Int = 0
    var discMultiPack: Bool = false
    var hasArtwork: String = ""
    var remastered: Bool = false
    var nationalOrigin: String = ""
    var replicationType: String = ""
    var discCapacity: [String] = []
    var hasHDR: String = ""
    var masterType: String = ""
    var regionLock: String = ""
    var regionLockBypass: Bool = false
    var marketAvailability: [String] = []
    var numberOfCopies: Int = 0
    var cost: Double = 0
    var amountSpent: Double = 0
    var purchaseDate: String = ""
    var lowestPrice: Double = 0
    var lowestPriceDate: String = ""
    var condition: String = ""
    var notes: String = ""
    var dateAdded: Date = Date()
    var sortOrder: Int = 0
    init() {}
}
@Model final class ListObject {
    #Index<ListObject>([\.listID])
    var listID: UUID = UUID()
    var listName: String = ""
    var viewStyle: String = ""
    var sortFilterOptions: [String] = []
    var displayOrder: Int = 0
    @Relationship(deleteRule: .cascade, inverse: \ListMembership.list) var memberships: [ListMembership] = []
    init() {}
}
@Model final class ListMembership {
    var id: UUID = UUID()
    var dateAdded: Date = Date()
    var sortOrder: Int = 0
    var film: Film?
    var list: ListObject?
    init(film: Film, list: ListObject, sortOrder: Int) { self.film = film; self.list = list; self.sortOrder = sortOrder }
}

@objc(CDFilm) final class CDFilm: NSManagedObject {
    @NSManaged var memberships: NSSet
    @NSManaged var releases: NSSet
    @NSManaged var id: UUID
    @NSManaged var posterUID: String
    @NSManaged var name: String
    @NSManaged var releaseYear: String
    @NSManaged var userRating: Int
    @NSManaged var lastWatched: String
    @NSManaged var duration: String
    @NSManaged var viewCount: Int
    @NSManaged var calendarTable: [String]
    @NSManaged var autoAddToQueueOnRotation: NSNumber?
    @NSManaged var rotationThresholdOverride: NSNumber?
    @NSManaged var digitalSource: String
    @NSManaged var digitalVersion: String
    @NSManaged var subtitles: String
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
    @NSManaged var lastModified: String
    @NSManaged var watched: Bool
    @NSManaged var specialSorting: [String]
    @NSManaged var alternateTitle: [String]
    @NSManaged var hofPosition: Int
    @NSManaged var infoComplete: Bool
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
}
@objc(CDRelease) final class CDRelease: NSManagedObject {
    @NSManaged var film: CDFilm?
    @NSManaged var parentRelease: CDRelease?
    @NSManaged var childReleases: NSSet
    @NSManaged var id: UUID
    @NSManaged var studio: String
    @NSManaged var releaseDate: String
    @NSManaged var baseReleaseYear: String
    @NSManaged var purchased: Bool
    @NSManaged var wishlist: Int
    @NSManaged var format: String
    @NSManaged var includedVersions: [String]
    @NSManaged var independence: String
    @NSManaged var videoFormat: String
    @NSManaged var releaseAspectRatio: [String]
    @NSManaged var scanningMethod: String
    @NSManaged var audioFormat: String
    @NSManaged var audioChannels: String
    @NSManaged var hasSubtitles: Bool
    @NSManaged var numberOfDiscs: Int
    @NSManaged var discMultiPack: Bool
    @NSManaged var hasArtwork: String
    @NSManaged var remastered: Bool
    @NSManaged var nationalOrigin: String
    @NSManaged var replicationType: String
    @NSManaged var discCapacity: [String]
    @NSManaged var hasHDR: String
    @NSManaged var masterType: String
    @NSManaged var regionLock: String
    @NSManaged var regionLockBypass: Bool
    @NSManaged var marketAvailability: [String]
    @NSManaged var numberOfCopies: Int
    @NSManaged var cost: Double
    @NSManaged var amountSpent: Double
    @NSManaged var purchaseDate: String
    @NSManaged var lowestPrice: Double
    @NSManaged var lowestPriceDate: String
    @NSManaged var condition: String
    @NSManaged var notes: String
    @NSManaged var dateAdded: Date
    @NSManaged var sortOrder: Int
}
@objc(CDListObject) final class CDListObject: NSManagedObject {
    @NSManaged var listID: UUID
    @NSManaged var listName: String
    @NSManaged var viewStyle: String
    @NSManaged var sortFilterOptions: [String]
    @NSManaged var displayOrder: Int
    @NSManaged var memberships: NSSet
}
@objc(CDListMembership) final class CDListMembership: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var dateAdded: Date
    @NSManaged var sortOrder: Int
    @NSManaged var film: CDFilm?
    @NSManaged var list: CDListObject?
}

struct FilmRow {
    var id: UUID
    var posterUID: String
    var name: String
    var releaseYear: String
    var userRating: Int
    var lastWatched: String
    var duration: String
    var viewCount: Int
    var calendarTable: [String]
    var autoAddToQueueOnRotation: Int?
    var rotationThresholdOverride: Int?
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
}
extension Film { var row: FilmRow { FilmRow(id: id, posterUID: posterUID, name: name, releaseYear: releaseYear, userRating: userRating, lastWatched: lastWatched, duration: duration, viewCount: viewCount, calendarTable: calendarTable, autoAddToQueueOnRotation: autoAddToQueueOnRotation, rotationThresholdOverride: rotationThresholdOverride, digitalSource: digitalSource, digitalVersion: digitalVersion, subtitles: subtitles, notes: notes, numberOfDiscs: numberOfDiscs, aspectRatio: aspectRatio, color: color, edited: edited, editedDuration: editedDuration, frameRate: frameRate, tags: tags, externalIdentifiers: externalIdentifiers, dateAdded: dateAdded, lastModified: lastModified, watched: watched, specialSorting: specialSorting, alternateTitle: alternateTitle, hofPosition: hofPosition, infoComplete: infoComplete, comments: comments, genre: genre, releaseDate: releaseDate, descriptionText: descriptionText, rating: rating, studio: studio, cast: cast, directors: directors, producers: producers, executiveProducers: executiveProducers, screenwriters: screenwriters, encodingTool: encodingTool, libraryHBRFValue: libraryHBRFValue, composer: composer, sortName: sortName, releaseUsed: releaseUsed, tools: tools, editedHBRFValue: editedHBRFValue, editDate: editDate, warning: warning, descriptionNotes: descriptionNotes, notesOnAudioTiming: notesOnAudioTiming, specialAudioNotes: specialAudioNotes, notesArray: notesArray, handbrakeFrames: handbrakeFrames, correspondingTimecodes: correspondingTimecodes) } }
extension CDFilm { var row: FilmRow { FilmRow(id: id, posterUID: posterUID, name: name, releaseYear: releaseYear, userRating: userRating, lastWatched: lastWatched, duration: duration, viewCount: viewCount, calendarTable: calendarTable, autoAddToQueueOnRotation: autoAddToQueueOnRotation?.intValue, rotationThresholdOverride: rotationThresholdOverride?.intValue, digitalSource: digitalSource, digitalVersion: digitalVersion, subtitles: subtitles, notes: notes, numberOfDiscs: numberOfDiscs, aspectRatio: aspectRatio, color: color, edited: edited, editedDuration: editedDuration, frameRate: frameRate, tags: tags, externalIdentifiers: externalIdentifiers, dateAdded: dateAdded, lastModified: lastModified, watched: watched, specialSorting: specialSorting, alternateTitle: alternateTitle, hofPosition: hofPosition, infoComplete: infoComplete, comments: comments, genre: genre, releaseDate: releaseDate, descriptionText: descriptionText, rating: rating, studio: studio, cast: cast, directors: directors, producers: producers, executiveProducers: executiveProducers, screenwriters: screenwriters, encodingTool: encodingTool, libraryHBRFValue: libraryHBRFValue, composer: composer, sortName: sortName, releaseUsed: releaseUsed, tools: tools, editedHBRFValue: editedHBRFValue, editDate: editDate, warning: warning, descriptionNotes: descriptionNotes, notesOnAudioTiming: notesOnAudioTiming, specialAudioNotes: specialAudioNotes, notesArray: notesArray, handbrakeFrames: handbrakeFrames, correspondingTimecodes: correspondingTimecodes) } }
func fill(_ x: Film, _ i: Int) {
    x.posterUID = "posterUID value for item \(i)"
    x.name = "name value for item \(i)"
    x.releaseYear = "releaseYear value for item \(i)"
    x.userRating = i % 7
    x.lastWatched = "lastWatched value for item \(i)"
    x.duration = "duration value for item \(i)"
    x.viewCount = i % 7
    x.calendarTable = ["calendarTable one \(i)", "calendarTable two", "calendarTable three"]
    x.digitalSource = "digitalSource value for item \(i)"
    x.digitalVersion = "digitalVersion value for item \(i)"
    x.subtitles = "subtitles value for item \(i)"
    x.notes = "notes value for item \(i)"
    x.numberOfDiscs = "numberOfDiscs value for item \(i)"
    x.aspectRatio = "aspectRatio value for item \(i)"
    x.editedDuration = "editedDuration value for item \(i)"
    x.frameRate = Double(i) / 3
    x.tags = ["tags one \(i)", "tags two", "tags three"]
    x.externalIdentifiers = ["externalIdentifiers one \(i)", "externalIdentifiers two", "externalIdentifiers three"]
    x.dateAdded = "dateAdded value for item \(i)"
    x.lastModified = "lastModified value for item \(i)"
    x.specialSorting = ["specialSorting one \(i)", "specialSorting two", "specialSorting three"]
    x.alternateTitle = ["alternateTitle one \(i)", "alternateTitle two", "alternateTitle three"]
    x.hofPosition = i % 7
    x.comments = "comments value for item \(i)"
    x.genre = "genre value for item \(i)"
    x.releaseDate = "releaseDate value for item \(i)"
    x.descriptionText = "descriptionText value for item \(i)"
    x.rating = "rating value for item \(i)"
    x.studio = ["studio one \(i)", "studio two", "studio three"]
    x.cast = ["cast one \(i)", "cast two", "cast three"]
    x.directors = ["directors one \(i)", "directors two", "directors three"]
    x.producers = ["producers one \(i)", "producers two", "producers three"]
    x.executiveProducers = ["executiveProducers one \(i)", "executiveProducers two", "executiveProducers three"]
    x.screenwriters = ["screenwriters one \(i)", "screenwriters two", "screenwriters three"]
    x.encodingTool = ["encodingTool one \(i)", "encodingTool two", "encodingTool three"]
    x.libraryHBRFValue = i % 7
    x.composer = ["composer one \(i)", "composer two", "composer three"]
    x.sortName = "sortName value for item \(i)"
    x.releaseUsed = "releaseUsed value for item \(i)"
    x.tools = ["tools one \(i)", "tools two", "tools three"]
    x.editedHBRFValue = i % 7
    x.editDate = "editDate value for item \(i)"
    x.warning = ["warning one \(i)", "warning two", "warning three"]
    x.descriptionNotes = "descriptionNotes value for item \(i)"
    x.notesOnAudioTiming = ["notesOnAudioTiming one \(i)", "notesOnAudioTiming two", "notesOnAudioTiming three"]
    x.specialAudioNotes = ["specialAudioNotes one \(i)", "specialAudioNotes two", "specialAudioNotes three"]
    x.notesArray = ["notesArray one \(i)", "notesArray two", "notesArray three"]
    x.handbrakeFrames = ["handbrakeFrames one \(i)", "handbrakeFrames two", "handbrakeFrames three"]
    x.correspondingTimecodes = ["correspondingTimecodes one \(i)", "correspondingTimecodes two", "correspondingTimecodes three"]
}
struct ReleaseRow {
    var id: UUID
    var studio: String
    var releaseDate: String
    var baseReleaseYear: String
    var purchased: Bool
    var wishlist: Int
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
    var purchaseDate: String
    var lowestPrice: Double
    var lowestPriceDate: String
    var condition: String
    var notes: String
    var dateAdded: Date
    var sortOrder: Int
}
extension Release { var row: ReleaseRow { ReleaseRow(id: id, studio: studio, releaseDate: releaseDate, baseReleaseYear: baseReleaseYear, purchased: purchased, wishlist: wishlist, format: format, includedVersions: includedVersions, independence: independence, videoFormat: videoFormat, releaseAspectRatio: releaseAspectRatio, scanningMethod: scanningMethod, audioFormat: audioFormat, audioChannels: audioChannels, hasSubtitles: hasSubtitles, numberOfDiscs: numberOfDiscs, discMultiPack: discMultiPack, hasArtwork: hasArtwork, remastered: remastered, nationalOrigin: nationalOrigin, replicationType: replicationType, discCapacity: discCapacity, hasHDR: hasHDR, masterType: masterType, regionLock: regionLock, regionLockBypass: regionLockBypass, marketAvailability: marketAvailability, numberOfCopies: numberOfCopies, cost: cost, amountSpent: amountSpent, purchaseDate: purchaseDate, lowestPrice: lowestPrice, lowestPriceDate: lowestPriceDate, condition: condition, notes: notes, dateAdded: dateAdded, sortOrder: sortOrder) } }
extension CDRelease { var row: ReleaseRow { ReleaseRow(id: id, studio: studio, releaseDate: releaseDate, baseReleaseYear: baseReleaseYear, purchased: purchased, wishlist: wishlist, format: format, includedVersions: includedVersions, independence: independence, videoFormat: videoFormat, releaseAspectRatio: releaseAspectRatio, scanningMethod: scanningMethod, audioFormat: audioFormat, audioChannels: audioChannels, hasSubtitles: hasSubtitles, numberOfDiscs: numberOfDiscs, discMultiPack: discMultiPack, hasArtwork: hasArtwork, remastered: remastered, nationalOrigin: nationalOrigin, replicationType: replicationType, discCapacity: discCapacity, hasHDR: hasHDR, masterType: masterType, regionLock: regionLock, regionLockBypass: regionLockBypass, marketAvailability: marketAvailability, numberOfCopies: numberOfCopies, cost: cost, amountSpent: amountSpent, purchaseDate: purchaseDate, lowestPrice: lowestPrice, lowestPriceDate: lowestPriceDate, condition: condition, notes: notes, dateAdded: dateAdded, sortOrder: sortOrder) } }
func fill(_ x: Release, _ i: Int) {
    x.studio = "studio value for item \(i)"
    x.releaseDate = "releaseDate value for item \(i)"
    x.baseReleaseYear = "baseReleaseYear value for item \(i)"
    x.wishlist = i % 7
    x.format = "format value for item \(i)"
    x.includedVersions = ["includedVersions one \(i)", "includedVersions two", "includedVersions three"]
    x.independence = "independence value for item \(i)"
    x.videoFormat = "videoFormat value for item \(i)"
    x.releaseAspectRatio = ["releaseAspectRatio one \(i)", "releaseAspectRatio two", "releaseAspectRatio three"]
    x.scanningMethod = "scanningMethod value for item \(i)"
    x.audioFormat = "audioFormat value for item \(i)"
    x.audioChannels = "audioChannels value for item \(i)"
    x.numberOfDiscs = i % 7
    x.hasArtwork = "hasArtwork value for item \(i)"
    x.nationalOrigin = "nationalOrigin value for item \(i)"
    x.replicationType = "replicationType value for item \(i)"
    x.discCapacity = ["discCapacity one \(i)", "discCapacity two", "discCapacity three"]
    x.hasHDR = "hasHDR value for item \(i)"
    x.masterType = "masterType value for item \(i)"
    x.regionLock = "regionLock value for item \(i)"
    x.marketAvailability = ["marketAvailability one \(i)", "marketAvailability two", "marketAvailability three"]
    x.numberOfCopies = i % 7
    x.cost = Double(i) / 3
    x.amountSpent = Double(i) / 3
    x.purchaseDate = "purchaseDate value for item \(i)"
    x.lowestPrice = Double(i) / 3
    x.lowestPriceDate = "lowestPriceDate value for item \(i)"
    x.condition = "condition value for item \(i)"
    x.notes = "notes value for item \(i)"
    x.sortOrder = i % 7
}
func fill(_ x: CDFilm, _ i: Int) {
    x.id = UUID()
    x.posterUID = "posterUID value for item \(i)"
    x.name = "name value for item \(i)"
    x.releaseYear = "releaseYear value for item \(i)"
    x.userRating = i % 7
    x.lastWatched = "lastWatched value for item \(i)"
    x.duration = "duration value for item \(i)"
    x.viewCount = i % 7
    x.calendarTable = ["calendarTable one \(i)", "calendarTable two", "calendarTable three"]
    x.digitalSource = "digitalSource value for item \(i)"
    x.digitalVersion = "digitalVersion value for item \(i)"
    x.subtitles = "subtitles value for item \(i)"
    x.notes = "notes value for item \(i)"
    x.numberOfDiscs = "numberOfDiscs value for item \(i)"
    x.aspectRatio = "aspectRatio value for item \(i)"
    x.color = false
    x.edited = false
    x.editedDuration = "editedDuration value for item \(i)"
    x.frameRate = Double(i) / 3
    x.tags = ["tags one \(i)", "tags two", "tags three"]
    x.externalIdentifiers = ["externalIdentifiers one \(i)", "externalIdentifiers two", "externalIdentifiers three"]
    x.dateAdded = "dateAdded value for item \(i)"
    x.lastModified = "lastModified value for item \(i)"
    x.watched = false
    x.specialSorting = ["specialSorting one \(i)", "specialSorting two", "specialSorting three"]
    x.alternateTitle = ["alternateTitle one \(i)", "alternateTitle two", "alternateTitle three"]
    x.hofPosition = i % 7
    x.infoComplete = false
    x.comments = "comments value for item \(i)"
    x.genre = "genre value for item \(i)"
    x.releaseDate = "releaseDate value for item \(i)"
    x.descriptionText = "descriptionText value for item \(i)"
    x.rating = "rating value for item \(i)"
    x.studio = ["studio one \(i)", "studio two", "studio three"]
    x.cast = ["cast one \(i)", "cast two", "cast three"]
    x.directors = ["directors one \(i)", "directors two", "directors three"]
    x.producers = ["producers one \(i)", "producers two", "producers three"]
    x.executiveProducers = ["executiveProducers one \(i)", "executiveProducers two", "executiveProducers three"]
    x.screenwriters = ["screenwriters one \(i)", "screenwriters two", "screenwriters three"]
    x.encodingTool = ["encodingTool one \(i)", "encodingTool two", "encodingTool three"]
    x.libraryHBRFValue = i % 7
    x.composer = ["composer one \(i)", "composer two", "composer three"]
    x.sortName = "sortName value for item \(i)"
    x.releaseUsed = "releaseUsed value for item \(i)"
    x.tools = ["tools one \(i)", "tools two", "tools three"]
    x.editedHBRFValue = i % 7
    x.editDate = "editDate value for item \(i)"
    x.warning = ["warning one \(i)", "warning two", "warning three"]
    x.descriptionNotes = "descriptionNotes value for item \(i)"
    x.notesOnAudioTiming = ["notesOnAudioTiming one \(i)", "notesOnAudioTiming two", "notesOnAudioTiming three"]
    x.specialAudioNotes = ["specialAudioNotes one \(i)", "specialAudioNotes two", "specialAudioNotes three"]
    x.notesArray = ["notesArray one \(i)", "notesArray two", "notesArray three"]
    x.handbrakeFrames = ["handbrakeFrames one \(i)", "handbrakeFrames two", "handbrakeFrames three"]
    x.correspondingTimecodes = ["correspondingTimecodes one \(i)", "correspondingTimecodes two", "correspondingTimecodes three"]
}
func fill(_ x: CDRelease, _ i: Int) {
    x.id = UUID()
    x.studio = "studio value for item \(i)"
    x.releaseDate = "releaseDate value for item \(i)"
    x.baseReleaseYear = "baseReleaseYear value for item \(i)"
    x.purchased = false
    x.wishlist = i % 7
    x.format = "format value for item \(i)"
    x.includedVersions = ["includedVersions one \(i)", "includedVersions two", "includedVersions three"]
    x.independence = "independence value for item \(i)"
    x.videoFormat = "videoFormat value for item \(i)"
    x.releaseAspectRatio = ["releaseAspectRatio one \(i)", "releaseAspectRatio two", "releaseAspectRatio three"]
    x.scanningMethod = "scanningMethod value for item \(i)"
    x.audioFormat = "audioFormat value for item \(i)"
    x.audioChannels = "audioChannels value for item \(i)"
    x.hasSubtitles = false
    x.numberOfDiscs = i % 7
    x.discMultiPack = false
    x.hasArtwork = "hasArtwork value for item \(i)"
    x.remastered = false
    x.nationalOrigin = "nationalOrigin value for item \(i)"
    x.replicationType = "replicationType value for item \(i)"
    x.discCapacity = ["discCapacity one \(i)", "discCapacity two", "discCapacity three"]
    x.hasHDR = "hasHDR value for item \(i)"
    x.masterType = "masterType value for item \(i)"
    x.regionLock = "regionLock value for item \(i)"
    x.regionLockBypass = false
    x.marketAvailability = ["marketAvailability one \(i)", "marketAvailability two", "marketAvailability three"]
    x.numberOfCopies = i % 7
    x.cost = Double(i) / 3
    x.amountSpent = Double(i) / 3
    x.purchaseDate = "purchaseDate value for item \(i)"
    x.lowestPrice = Double(i) / 3
    x.lowestPriceDate = "lowestPriceDate value for item \(i)"
    x.condition = "condition value for item \(i)"
    x.notes = "notes value for item \(i)"
    x.dateAdded = Date()
    x.sortOrder = i % 7
}
let iso = ISO8601DateFormatter()
func load(_ x: Film, _ d: [String: Any]) {
    x.id = UUID(uuidString: d["id"] as? String ?? "") ?? UUID()
    x.posterUID = d["posterUID"] as? String ?? ""
    x.name = d["name"] as? String ?? ""
    x.releaseYear = d["releaseYear"] as? String ?? ""
    x.userRating = (d["userRating"] as? NSNumber)?.intValue ?? 0
    x.lastWatched = d["lastWatched"] as? String ?? ""
    x.duration = d["duration"] as? String ?? ""
    x.viewCount = (d["viewCount"] as? NSNumber)?.intValue ?? 0
    x.calendarTable = d["calendarTable"] as? [String] ?? []
    x.autoAddToQueueOnRotation = (d["autoAddToQueueOnRotation"] as? NSNumber)?.intValue
    x.rotationThresholdOverride = (d["rotationThresholdOverride"] as? NSNumber)?.intValue
    x.digitalSource = d["digitalSource"] as? String ?? ""
    x.digitalVersion = d["digitalVersion"] as? String ?? ""
    x.subtitles = d["subtitles"] as? String ?? ""
    x.notes = d["notes"] as? String ?? ""
    x.numberOfDiscs = d["numberOfDiscs"] as? String ?? ""
    x.aspectRatio = d["aspectRatio"] as? String ?? ""
    x.color = (d["color"] as? Bool) ?? false
    x.edited = (d["edited"] as? Bool) ?? false
    x.editedDuration = d["editedDuration"] as? String ?? ""
    x.frameRate = (d["frameRate"] as? NSNumber)?.doubleValue ?? 0
    x.tags = d["tags"] as? [String] ?? []
    x.externalIdentifiers = d["externalIdentifiers"] as? [String] ?? []
    x.dateAdded = d["dateAdded"] as? String ?? ""
    x.lastModified = d["lastModified"] as? String ?? ""
    x.watched = (d["watched"] as? Bool) ?? false
    x.specialSorting = d["specialSorting"] as? [String] ?? []
    x.alternateTitle = d["alternateTitle"] as? [String] ?? []
    x.hofPosition = (d["hofPosition"] as? NSNumber)?.intValue ?? 0
    x.infoComplete = (d["infoComplete"] as? Bool) ?? false
    x.comments = d["comments"] as? String ?? ""
    x.genre = d["genre"] as? String ?? ""
    x.releaseDate = d["releaseDate"] as? String ?? ""
    x.descriptionText = d["descriptionText"] as? String ?? ""
    x.rating = d["rating"] as? String ?? ""
    x.studio = d["studio"] as? [String] ?? []
    x.cast = d["cast"] as? [String] ?? []
    x.directors = d["directors"] as? [String] ?? []
    x.producers = d["producers"] as? [String] ?? []
    x.executiveProducers = d["executiveProducers"] as? [String] ?? []
    x.screenwriters = d["screenwriters"] as? [String] ?? []
    x.encodingTool = d["encodingTool"] as? [String] ?? []
    x.libraryHBRFValue = (d["libraryHBRFValue"] as? NSNumber)?.intValue ?? 0
    x.composer = d["composer"] as? [String] ?? []
    x.sortName = d["sortName"] as? String ?? ""
    x.releaseUsed = d["releaseUsed"] as? String ?? ""
    x.tools = d["tools"] as? [String] ?? []
    x.editedHBRFValue = (d["editedHBRFValue"] as? NSNumber)?.intValue ?? 0
    x.editDate = d["editDate"] as? String ?? ""
    x.warning = d["warning"] as? [String] ?? []
    x.descriptionNotes = d["descriptionNotes"] as? String ?? ""
    x.notesOnAudioTiming = d["notesOnAudioTiming"] as? [String] ?? []
    x.specialAudioNotes = d["specialAudioNotes"] as? [String] ?? []
    x.notesArray = d["notesArray"] as? [String] ?? []
    x.handbrakeFrames = d["handbrakeFrames"] as? [String] ?? []
    x.correspondingTimecodes = d["correspondingTimecodes"] as? [String] ?? []
}
func load(_ x: CDFilm, _ d: [String: Any]) {
    x.id = UUID(uuidString: d["id"] as? String ?? "") ?? UUID()
    x.posterUID = d["posterUID"] as? String ?? ""
    x.name = d["name"] as? String ?? ""
    x.releaseYear = d["releaseYear"] as? String ?? ""
    x.userRating = (d["userRating"] as? NSNumber)?.intValue ?? 0
    x.lastWatched = d["lastWatched"] as? String ?? ""
    x.duration = d["duration"] as? String ?? ""
    x.viewCount = (d["viewCount"] as? NSNumber)?.intValue ?? 0
    x.calendarTable = d["calendarTable"] as? [String] ?? []
    x.autoAddToQueueOnRotation = d["autoAddToQueueOnRotation"] as? NSNumber
    x.rotationThresholdOverride = d["rotationThresholdOverride"] as? NSNumber
    x.digitalSource = d["digitalSource"] as? String ?? ""
    x.digitalVersion = d["digitalVersion"] as? String ?? ""
    x.subtitles = d["subtitles"] as? String ?? ""
    x.notes = d["notes"] as? String ?? ""
    x.numberOfDiscs = d["numberOfDiscs"] as? String ?? ""
    x.aspectRatio = d["aspectRatio"] as? String ?? ""
    x.color = (d["color"] as? Bool) ?? false
    x.edited = (d["edited"] as? Bool) ?? false
    x.editedDuration = d["editedDuration"] as? String ?? ""
    x.frameRate = (d["frameRate"] as? NSNumber)?.doubleValue ?? 0
    x.tags = d["tags"] as? [String] ?? []
    x.externalIdentifiers = d["externalIdentifiers"] as? [String] ?? []
    x.dateAdded = d["dateAdded"] as? String ?? ""
    x.lastModified = d["lastModified"] as? String ?? ""
    x.watched = (d["watched"] as? Bool) ?? false
    x.specialSorting = d["specialSorting"] as? [String] ?? []
    x.alternateTitle = d["alternateTitle"] as? [String] ?? []
    x.hofPosition = (d["hofPosition"] as? NSNumber)?.intValue ?? 0
    x.infoComplete = (d["infoComplete"] as? Bool) ?? false
    x.comments = d["comments"] as? String ?? ""
    x.genre = d["genre"] as? String ?? ""
    x.releaseDate = d["releaseDate"] as? String ?? ""
    x.descriptionText = d["descriptionText"] as? String ?? ""
    x.rating = d["rating"] as? String ?? ""
    x.studio = d["studio"] as? [String] ?? []
    x.cast = d["cast"] as? [String] ?? []
    x.directors = d["directors"] as? [String] ?? []
    x.producers = d["producers"] as? [String] ?? []
    x.executiveProducers = d["executiveProducers"] as? [String] ?? []
    x.screenwriters = d["screenwriters"] as? [String] ?? []
    x.encodingTool = d["encodingTool"] as? [String] ?? []
    x.libraryHBRFValue = (d["libraryHBRFValue"] as? NSNumber)?.intValue ?? 0
    x.composer = d["composer"] as? [String] ?? []
    x.sortName = d["sortName"] as? String ?? ""
    x.releaseUsed = d["releaseUsed"] as? String ?? ""
    x.tools = d["tools"] as? [String] ?? []
    x.editedHBRFValue = (d["editedHBRFValue"] as? NSNumber)?.intValue ?? 0
    x.editDate = d["editDate"] as? String ?? ""
    x.warning = d["warning"] as? [String] ?? []
    x.descriptionNotes = d["descriptionNotes"] as? String ?? ""
    x.notesOnAudioTiming = d["notesOnAudioTiming"] as? [String] ?? []
    x.specialAudioNotes = d["specialAudioNotes"] as? [String] ?? []
    x.notesArray = d["notesArray"] as? [String] ?? []
    x.handbrakeFrames = d["handbrakeFrames"] as? [String] ?? []
    x.correspondingTimecodes = d["correspondingTimecodes"] as? [String] ?? []
}
func load(_ x: Release, _ d: [String: Any]) {
    x.id = UUID(uuidString: d["id"] as? String ?? "") ?? UUID()
    x.studio = d["studio"] as? String ?? ""
    x.releaseDate = d["releaseDate"] as? String ?? ""
    x.baseReleaseYear = d["baseReleaseYear"] as? String ?? ""
    x.purchased = (d["purchased"] as? Bool) ?? false
    x.wishlist = (d["wishlist"] as? NSNumber)?.intValue ?? 0
    x.format = d["format"] as? String ?? ""
    x.includedVersions = d["includedVersions"] as? [String] ?? []
    x.independence = d["independence"] as? String ?? ""
    x.videoFormat = d["videoFormat"] as? String ?? ""
    x.releaseAspectRatio = d["releaseAspectRatio"] as? [String] ?? []
    x.scanningMethod = d["scanningMethod"] as? String ?? ""
    x.audioFormat = d["audioFormat"] as? String ?? ""
    x.audioChannels = d["audioChannels"] as? String ?? ""
    x.hasSubtitles = (d["hasSubtitles"] as? Bool) ?? false
    x.numberOfDiscs = (d["numberOfDiscs"] as? NSNumber)?.intValue ?? 0
    x.discMultiPack = (d["discMultiPack"] as? Bool) ?? false
    x.hasArtwork = d["hasArtwork"] as? String ?? ""
    x.remastered = (d["remastered"] as? Bool) ?? false
    x.nationalOrigin = d["nationalOrigin"] as? String ?? ""
    x.replicationType = d["replicationType"] as? String ?? ""
    x.discCapacity = d["discCapacity"] as? [String] ?? []
    x.hasHDR = d["hasHDR"] as? String ?? ""
    x.masterType = d["masterType"] as? String ?? ""
    x.regionLock = d["regionLock"] as? String ?? ""
    x.regionLockBypass = (d["regionLockBypass"] as? Bool) ?? false
    x.marketAvailability = d["marketAvailability"] as? [String] ?? []
    x.numberOfCopies = (d["numberOfCopies"] as? NSNumber)?.intValue ?? 0
    x.cost = (d["cost"] as? NSNumber)?.doubleValue ?? 0
    x.amountSpent = (d["amountSpent"] as? NSNumber)?.doubleValue ?? 0
    x.purchaseDate = d["purchaseDate"] as? String ?? ""
    x.lowestPrice = (d["lowestPrice"] as? NSNumber)?.doubleValue ?? 0
    x.lowestPriceDate = d["lowestPriceDate"] as? String ?? ""
    x.condition = d["condition"] as? String ?? ""
    x.notes = d["notes"] as? String ?? ""
    x.dateAdded = (d["dateAdded"] as? String).flatMap { iso.date(from: $0) } ?? Date()
    x.sortOrder = (d["sortOrder"] as? NSNumber)?.intValue ?? 0
}
func load(_ x: CDRelease, _ d: [String: Any]) {
    x.id = UUID(uuidString: d["id"] as? String ?? "") ?? UUID()
    x.studio = d["studio"] as? String ?? ""
    x.releaseDate = d["releaseDate"] as? String ?? ""
    x.baseReleaseYear = d["baseReleaseYear"] as? String ?? ""
    x.purchased = (d["purchased"] as? Bool) ?? false
    x.wishlist = (d["wishlist"] as? NSNumber)?.intValue ?? 0
    x.format = d["format"] as? String ?? ""
    x.includedVersions = d["includedVersions"] as? [String] ?? []
    x.independence = d["independence"] as? String ?? ""
    x.videoFormat = d["videoFormat"] as? String ?? ""
    x.releaseAspectRatio = d["releaseAspectRatio"] as? [String] ?? []
    x.scanningMethod = d["scanningMethod"] as? String ?? ""
    x.audioFormat = d["audioFormat"] as? String ?? ""
    x.audioChannels = d["audioChannels"] as? String ?? ""
    x.hasSubtitles = (d["hasSubtitles"] as? Bool) ?? false
    x.numberOfDiscs = (d["numberOfDiscs"] as? NSNumber)?.intValue ?? 0
    x.discMultiPack = (d["discMultiPack"] as? Bool) ?? false
    x.hasArtwork = d["hasArtwork"] as? String ?? ""
    x.remastered = (d["remastered"] as? Bool) ?? false
    x.nationalOrigin = d["nationalOrigin"] as? String ?? ""
    x.replicationType = d["replicationType"] as? String ?? ""
    x.discCapacity = d["discCapacity"] as? [String] ?? []
    x.hasHDR = d["hasHDR"] as? String ?? ""
    x.masterType = d["masterType"] as? String ?? ""
    x.regionLock = d["regionLock"] as? String ?? ""
    x.regionLockBypass = (d["regionLockBypass"] as? Bool) ?? false
    x.marketAvailability = d["marketAvailability"] as? [String] ?? []
    x.numberOfCopies = (d["numberOfCopies"] as? NSNumber)?.intValue ?? 0
    x.cost = (d["cost"] as? NSNumber)?.doubleValue ?? 0
    x.amountSpent = (d["amountSpent"] as? NSNumber)?.doubleValue ?? 0
    x.purchaseDate = d["purchaseDate"] as? String ?? ""
    x.lowestPrice = (d["lowestPrice"] as? NSNumber)?.doubleValue ?? 0
    x.lowestPriceDate = d["lowestPriceDate"] as? String ?? ""
    x.condition = d["condition"] as? String ?? ""
    x.notes = d["notes"] as? String ?? ""
    x.dateAdded = (d["dateAdded"] as? String).flatMap { iso.date(from: $0) } ?? Date()
    x.sortOrder = (d["sortOrder"] as? NSNumber)?.intValue ?? 0
}
