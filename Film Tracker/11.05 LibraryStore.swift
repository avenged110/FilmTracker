// MARK: - LibraryStore.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The Core Data stack: the library's managed object model (built in code), the persistent
// container, the context-backed executor that the persistence actors run on, and the fetch
// and predicate helpers the rest of the app uses.

import Foundation
import CoreData
import SQLite3
import CryptoKit

// MARK: - Store Location

enum LibraryStore: Loggable {
    nonisolated static let logTag = "[LibraryStore]"

    /// The store file's name. Deliberately not SwiftData's `default.store`: the Core Data
    /// build starts from an empty store and the library comes back by restoring a backup, so
    /// the store beside it is never opened, migrated or deleted — it stays a
    /// rollback until the user removes it.
    static let storeFileName = "FilmTracker.sqlite"

    /// Where the store lives: the debug sandbox's folder when one is active, otherwise
    /// Application Support (Preferences.dataFolderURL, which the sandbox also redirects).
    static var storeURL: URL? {
        if let sandbox = DebugSandbox.storeURL { return sandbox }
        return Preferences.dataFolderURL?.appendingPathComponent(storeFileName)
    }

    /// Opens a container on the store at `url`, or an in-memory one when `url` is nil.
    /// Every container shares `LibraryModel.shared`, so two of them in one process (the app's
    /// and a restore's) never register the classes twice.
    ///
    /// `singleFile` opens the store with SQLite's rollback journal instead of its WAL, so a
    /// closed store is one file with no -wal/-shm beside it. The staged restore store uses it
    /// (see PendingRestore); the library's own store keeps the default WAL.
    static func makeContainer(at url: URL?, readOnly: Bool = false,
                              singleFile: Bool = false) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "FilmTracker", managedObjectModel: LibraryModel.shared.model)
        let description = url.map { NSPersistentStoreDescription(url: $0) } ?? {
            let d = NSPersistentStoreDescription(); d.type = NSInMemoryStoreType; return d }()
        description.shouldAddStoreAsynchronously = false
        description.isReadOnly = readOnly
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        if singleFile {
            description.setOption(["journal_mode": "DELETE"] as NSDictionary, forKey: NSSQLitePragmasOption)
        }
        container.persistentStoreDescriptions = [description]

        // A fresh container has no Application Support folder yet. Core Data would recover by
        // creating it after a failed open; creating it first keeps that out of the log.
        if let url, !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }

        var loadError: (any Error)?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }

        // The view context is what SwiftData's mainContext was: main-queue, merging every
        // background save as it lands, no undo manager.
        let view = container.viewContext
        view.automaticallyMergesChangesFromParent = true
        view.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        view.undoManager = nil
        return container
    }

    /// Erases the store at `url` in place (all three SQLite files), the way Core Data wants
    /// it done: through a coordinator, which also handles a store another coordinator in the
    /// process still has open.
    static func destroyStore(at url: URL) throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: LibraryModel.shared.model)
        try coordinator.destroyPersistentStore(at: url, type: .sqlite)
    }

    /// Copies the store at `source` over the store at `destination` (creating it if absent),
    /// through Core Data, which carries each side's -wal/-shm with it.
    static func replaceStore(at destination: URL, withStoreAt source: URL) throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: LibraryModel.shared.model)
        try coordinator.replacePersistentStore(at: destination, withPersistentStoreFrom: source, type: .sqlite)
    }

    /// The store file at `url` and its SQLite sidecars.
    static func storeFiles(_ url: URL) -> [URL] {
        ["", "-wal", "-shm", "-journal"].map { URL(fileURLWithPath: url.path(percentEncoded: false) + $0) }
    }
}

// MARK: - Staged Restore

/// A restore never writes into the library's store while the app has it open. It builds the
/// restored library in a separate store beside it (`stagedStoreURL`), checks it, and leaves
/// a marker; the next launch swaps it in before anything opens the store
/// (`applyIfPending`, called from FilmTrackerApp.createModelContainer).
///
/// So nothing in the running session can reach the restored store: a late write from it
/// lands in the old store, which the swap sets aside as `rollbackStoreURL`. A restore that
/// fails before `commit` leaves the library exactly as it was.
///
/// The swap is safe to interrupt and repeat: the marker records whether the rollback copy is
/// already taken, the staged store is copied (not moved) into place, and only once that has
/// succeeded is the staged store deleted, then the marker.
enum PendingRestore: Loggable {
    nonisolated static let logTag = "[PendingRestore]"

    /// The library's store, as LibraryStore resolves it.
    private static var liveStoreURL: URL? { LibraryStore.storeURL }
    private static var folderURL: URL? { liveStoreURL?.deletingLastPathComponent() }

    /// Where a restore builds the replacement library.
    static var stagedStoreURL: URL? { folderURL?.appendingPathComponent("FilmTracker-restore.sqlite") }
    /// Where the swap keeps the library it replaced: the most recent one only.
    static var rollbackStoreURL: URL? { folderURL?.appendingPathComponent("FilmTracker-pre-restore.sqlite") }
    private static var markerURL: URL? { folderURL?.appendingPathComponent("FilmTracker.pending-restore") }

    private struct Marker: Codable {
        var stagedAt: Date
        /// True once the old store is copied to the rollback location, so a repeated swap
        /// never overwrites that copy with the restored library.
        var rollbackSaved: Bool
        /// True when the old store could not be copied and its files were moved instead, so
        /// a failed swap knows the rollback files are this library's and puts them back.
        /// Optional so a marker written before it existed still decodes.
        var rollbackMoved: Bool?
    }

    enum Failure: Error, LocalizedError {
        case noStoreLocation
        case verificationFailed(String)
        var errorDescription: String? {
            switch self {
            case .noStoreLocation: "Could not resolve the library folder."
            case .verificationFailed(let detail): "The restored library failed its check: \(detail)"
            }
        }
    }

    // MARK: Restore Side

    /// A fresh, empty store at the staging location, discarding anything a previous attempt
    /// left there. Single-file, so `commit` can verify it with nothing in a WAL.
    static func makeStagingContainer() throws -> NSPersistentContainer {
        guard let staged = stagedStoreURL else { throw Failure.noStoreLocation }
        discard()
        return try LibraryStore.makeContainer(at: staged, singleFile: true)
    }

    /// Closes the staged store, checks it, and writes the marker that has the next launch
    /// swap it in. From here on the restore is committed: the session must relaunch.
    static func commit(_ container: NSPersistentContainer) throws {
        guard let staged = stagedStoreURL, let marker = markerURL else { throw Failure.noStoreLocation }
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores { try coordinator.remove(store) }

        let result = integrityCheck(staged)
        guard result == "ok" else { throw Failure.verificationFailed(result) }

        let data = try JSONEncoder().encode(Marker(stagedAt: Date(), rollbackSaved: false))
        try data.write(to: marker, options: .atomic)
        log("Staged restore committed; it is swapped in at the next launch")
    }

    /// Deletes the staged store and the marker: a restore that failed before committing, or
    /// leftovers from one that never will.
    static func discard() {
        let fm = FileManager.default
        if let staged = stagedStoreURL {
            for file in LibraryStore.storeFiles(staged) where fm.fileExists(atPath: file.path(percentEncoded: false)) {
                try? fm.removeItem(at: file)
            }
        }
        if let marker = markerURL { try? fm.removeItem(at: marker) }
    }

    /// Whether a committed restore is waiting for the next launch.
    static var isPending: Bool {
        guard let marker = markerURL else { return false }
        return FileManager.default.fileExists(atPath: marker.path(percentEncoded: false))
    }

    // MARK: Launch Side

    enum Outcome: Equatable {
        case nothingPending
        case swapped
        /// The swap failed and the previous library was kept; the message says why.
        case failed(String)
    }

    /// Swaps a committed restore into place. Called once at launch, before any container
    /// opens the library's store, so no connection can be holding either file.
    ///
    /// `target` replaces the library's store as the destination. DEBUG harness only: it
    /// swaps into a store no connection has open, since the running app has the real one
    /// open and the launch never does.
    @discardableResult
    static func applyIfPending(into target: URL? = nil) -> Outcome {
        guard let markerURL, let live = target ?? liveStoreURL, let staged = stagedStoreURL,
              let rollback = rollbackStoreURL,
              let data = try? Data(contentsOf: markerURL) else { return .nothingPending }
        let fm = FileManager.default

        guard var marker = try? JSONDecoder().decode(Marker.self, from: data) else {
            log("WARNING: Unreadable pending-restore marker — discarding the staged restore")
            discard()
            return .failed("The restore's record could not be read.")
        }
        guard fm.fileExists(atPath: staged.path(percentEncoded: false)) else {
            // The swap already finished and only the marker's removal was interrupted.
            log("Staged store already swapped in; removing the marker")
            try? fm.removeItem(at: markerURL)
            return .swapped
        }
        // Checked again here, not only at commit: replacePersistentStore copies whatever file
        // it is given, so a staged store damaged since (disk error, a file touched by hand)
        // would otherwise replace a healthy library with one that cannot open.
        let check = integrityCheck(staged)
        guard check == "ok" else {
            log("ERROR: The staged store failed its check at launch (\(check)) — keeping the current library")
            discard()
            return .failed(Failure.verificationFailed(check).localizedDescription)
        }

        do {
            if !marker.rollbackSaved {
                if fm.fileExists(atPath: live.path(percentEncoded: false)) {
                    marker.rollbackMoved = !saveRollback(of: live, to: rollback)
                }
                marker.rollbackSaved = true
                try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
            }
            try LibraryStore.replaceStore(at: live, withStoreAt: staged)
        } catch {
            log("ERROR: Could not swap in the restored library: \(error)")
            // saveRollback moves the old files when it cannot copy them; put them back, so
            // the previous library is what opens. Only when this swap moved them: rollback
            // files from an earlier restore describe an older library, not this one.
            if marker.rollbackMoved == true,
               !fm.fileExists(atPath: live.path(percentEncoded: false)),
               fm.fileExists(atPath: rollback.path(percentEncoded: false)) {
                for (from, to) in zip(LibraryStore.storeFiles(rollback), LibraryStore.storeFiles(live))
                where fm.fileExists(atPath: from.path(percentEncoded: false)) {
                    try? fm.moveItem(at: from, to: to)
                }
            }
            discard()
            return .failed(error.localizedDescription)
        }

        discard()
        log("Restored library swapped in (staged \(marker.stagedAt))")
        return .swapped
    }

    /// Copies the store about to be replaced to the rollback location, best effort: a store
    /// Core Data cannot read (the one a "Create New Library" replaces, say) is moved there
    /// as raw files instead. Nothing has either file open at launch, so moving is safe.
    /// Returns false when it had to move the files.
    @discardableResult
    private static func saveRollback(of live: URL, to rollback: URL) -> Bool {
        let fm = FileManager.default
        for file in LibraryStore.storeFiles(rollback) { try? fm.removeItem(at: file) }
        do {
            try LibraryStore.replaceStore(at: rollback, withStoreAt: live)
            log("Previous library kept at \(rollback.lastPathComponent)")
            return true
        } catch {
            log("WARNING: Could not copy the previous library (\(error.localizedDescription)) — moving its files instead")
            for (from, to) in zip(LibraryStore.storeFiles(live), LibraryStore.storeFiles(rollback))
            where fm.fileExists(atPath: from.path(percentEncoded: false)) {
                try? fm.moveItem(at: from, to: to)
            }
            return false
        }
    }

    /// SQLite's `PRAGMA integrity_check` on a closed store file: "ok", or what it found.
    private static func integrityCheck(_ url: URL) -> String {
        var db: OpaquePointer?
        defer { unsafe sqlite3_close(db) }
        guard unsafe sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return "could not open the staged store"
        }
        var statement: OpaquePointer?
        defer { unsafe sqlite3_finalize(statement) }
        guard unsafe sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
              unsafe sqlite3_step(statement) == SQLITE_ROW,
              let text = unsafe sqlite3_column_text(statement, 0) else { return "the check did not run" }
        return unsafe String(cString: text)
    }
}

extension NSPersistentContainer {
    /// The SQLite file behind this container, or nil for an in-memory one.
    var storeURL: URL? {
        guard let store = persistentStoreCoordinator.persistentStores.first,
              store.type == NSSQLiteStoreType else { return nil }
        return store.url
    }

    /// A new, empty main-queue context: for a MainActor read that must see the store as it
    /// is now rather than what the view context has registered (a manual export). Merges
    /// like every other context, which SettingsObject's uniqueness constraint needs.
    func makeMainContext() -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = persistentStoreCoordinator
        context.undoManager = nil
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        return context
    }

    /// A new private-queue context on this container, configured for the persistence actors.
    func makeBackgroundContext() -> NSManagedObjectContext {
        let context = newBackgroundContext()
        context.undoManager = nil
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        return context
    }
}

// MARK: - Context Executor

/// Runs an actor's jobs on its managed object context's private queue — what SwiftData's
/// `DefaultSerialModelExecutor` did for `@ModelActor`. Because every job runs inside
/// `perform`, the actor's methods use its context directly, with no `perform` of their own,
/// and the queue confinement Core Data requires holds by construction.
final class ContextExecutor: SerialExecutor, @unchecked Sendable {
    /// @unchecked Sendable: `context` is a let, and it is only ever touched on its own
    /// queue — by the jobs this executor runs there.
    let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) { self.context = context }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = unsafe asUnownedSerialExecutor()
        context.perform { unsafe job.runSynchronously(on: executor) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor { unsafe UnownedSerialExecutor(ordinary: self) }
}

// MARK: - Model Base Class

/// The base of every library entity: entity lookup by class name and typed fetch requests.
class LibraryObject: NSManagedObject {
    /// The entity this class is mapped to; the model names each entity after its class.
    class var entityName: String { String(describing: self) }

    /// A new object of this class, not yet in any context. `context.insert(_:)` adds it,
    /// exactly as SwiftData's model inits worked. Every model init starts here.
    ///
    /// Labeled, never a bare `init()`: Swift resolves `Film()` to the zero-argument init with
    /// the fewest defaulted parameters, so a bare one here would win over a model's
    /// all-defaults init and skip its defaults. A model whose init is all defaults declares
    /// its own `init()` forwarding to it, which also hides NSObject's.
    convenience init(detached: Void) {
        self.init(entity: LibraryModel.shared.entity(Self.entityName), insertInto: nil)
    }

    /// A required UUID attribute (every entity's ID). The model marks UUIDs optional, so a
    /// row can hold none — a damaged store, or one a failed write left behind. An
    /// `@NSManaged` UUID would trap reading it; this reads it as a UUID derived from the
    /// row's object ID instead, stable for that row, and logs it.
    final func requiredUUID(_ key: String) -> UUID {
        if let id = value(forKey: key) as? UUID { return id }
        let digest = Insecure.MD5.hash(data: Data((objectID.uriRepresentation().absoluteString + key).utf8))
        let id = unsafe digest.withUnsafeBytes { unsafe UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        LibraryStore.log("WARNING: \(entity.name ?? "?").\(key) is empty — reading it as \(id)", level: .warning)
        return id
    }

    // Optional scalars, stored as NSNumber/NSString, read and written as Swift optionals.
    final func optionalInt(_ key: String) -> Int? { (value(forKey: key) as? NSNumber)?.intValue }
    final func setOptionalInt(_ value: Int?, _ key: String) { setValue(value.map { NSNumber(value: $0) }, forKey: key) }
    final func optionalBool(_ key: String) -> Bool? { (value(forKey: key) as? NSNumber)?.boolValue }
    final func setOptionalBool(_ value: Bool?, _ key: String) { setValue(value.map { NSNumber(value: $0) }, forKey: key) }
}

/// Typed fetch requests for every LibraryObject subclass. A protocol, because only a
/// protocol extension can return `NSFetchRequest<Self>` for a class hierarchy.
protocol LibraryEntity: LibraryObject {}
extension LibraryObject: LibraryEntity {}

extension LibraryEntity {
    /// `NSFetchRequest` for this class: SwiftData's `FetchDescriptor`.
    static func request(_ predicate: NSPredicate? = nil, sortedBy sort: [NSSortDescriptor] = [],
                        limit: Int = 0) -> NSFetchRequest<Self> {
        let request = NSFetchRequest<Self>(entityName: entityName)
        request.predicate = predicate
        request.sortDescriptors = sort.isEmpty ? nil : sort
        request.fetchLimit = limit
        return request
    }
}

extension NSPredicate {
    /// `key == value`
    static func equals(_ key: String, _ value: UUID) -> NSPredicate {
        NSPredicate(format: "%K == %@", key, value as NSUUID)
    }

    /// `key == value`
    static func equals(_ key: String, _ value: String) -> NSPredicate {
        NSPredicate(format: "%K == %@", key, value)
    }

    /// `key IN values`
    static func `in`<S: Sequence>(_ key: String, _ values: S) -> NSPredicate where S.Element == UUID {
        NSPredicate(format: "%K IN %@", key, values.map { $0 as NSUUID } as NSArray)
    }
}

extension NSManagedObjectContext {
    /// Saves, discarding every staged change if the save fails — see DataManager.commit().
    func commit() throws {
        guard hasChanges else { return }
        do {
            try save()
        } catch {
            rollback()
            throw error
        }
    }
}

// MARK: - Managed Object Model

/// The library's one `NSManagedObjectModel`, built in code from the tables below.
///
/// @unchecked Sendable: the model is immutable once built, and Core Data reads a model in
/// use from any thread.
final class LibraryModel: @unchecked Sendable {
    static let shared = LibraryModel()

    let model: NSManagedObjectModel

    func entity(_ name: String) -> NSEntityDescription {
        guard let entity = model.entitiesByName[name] else { fatalError("No entity named \(name)") }
        return entity
    }

    enum Kind {
        case string, int, bool, double, date, uuid
        /// `[String]`, archived as an NSArray of NSString.
        case strings
        case optionalInt, optionalBool, optionalString
    }
    typealias Attribute = (name: String, kind: Kind)

    private init() {
        func entity(_ name: String, _ attributes: [Attribute], indexed: [String] = []) -> NSEntityDescription {
            let entity = NSEntityDescription()
            entity.name = name
            entity.managedObjectClassName = name
            entity.properties = attributes.map(Self.attribute)
            entity.indexes = indexed.map { key in
                NSFetchIndexDescription(name: "\(name)_\(key)", elements: [
                    NSFetchIndexElementDescription(property: entity.propertiesByName[key]!, collationType: .binary)])
            }
            return entity
        }

        let film = entity("Film", Self.filmAttributes, indexed: ["id"])
        let list = entity("ListObject", Self.listObjectAttributes, indexed: ["listID"])
        let membership = entity("ListMembership", Self.listMembershipAttributes)
        let release = entity("Release", Self.releaseAttributes)
        let session = entity("ImportSession", Self.importSessionAttributes)
        let settings = entity("SettingsObject", Self.settingsObjectAttributes)
        let search = entity("SavedSearchObject", Self.savedSearchObjectAttributes, indexed: ["searchID"])
        // The SwiftData model's @Attribute(.unique): one settings row. Contexts that may
        // insert a second (the restore's) resolve it with mergeByPropertyObjectTrump.
        settings.uniquenessConstraints = [["snapshotID"]]

        // Relationships, with SwiftData's delete rules. Every to-many side is optional, as
        // Core Data expects (and as its batch delete requires).
        Self.relate(film, "memberships", toMany: true, .cascadeDeleteRule,
                    membership, "film", toMany: false, .nullifyDeleteRule)
        Self.relate(film, "releases", toMany: true, .cascadeDeleteRule,
                    release, "film", toMany: false, .nullifyDeleteRule)
        Self.relate(list, "memberships", toMany: true, .cascadeDeleteRule,
                    membership, "list", toMany: false, .nullifyDeleteRule)
        Self.relate(release, "parentRelease", toMany: false, .nullifyDeleteRule,
                    release, "childReleases", toMany: true, .nullifyDeleteRule)

        let model = NSManagedObjectModel()
        model.entities = [film, list, membership, release, session, settings, search]
        self.model = model
    }

    private static func attribute(_ spec: Attribute) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = spec.name
        // Required unless the Swift property is optional. A UUID has no meaningful default,
        // so it is optional in the model; every init assigns one.
        a.isOptional = false
        switch spec.kind {
        case .string: a.attributeType = .stringAttributeType; a.defaultValue = ""
        case .int: a.attributeType = .integer64AttributeType; a.defaultValue = 0
        case .bool: a.attributeType = .booleanAttributeType; a.defaultValue = false
        case .double: a.attributeType = .doubleAttributeType; a.defaultValue = 0.0
        case .date: a.attributeType = .dateAttributeType; a.defaultValue = Date(timeIntervalSinceReferenceDate: 0)
        case .uuid: a.attributeType = .UUIDAttributeType; a.isOptional = true
        case .strings:
            a.attributeType = .transformableAttributeType
            a.valueTransformerName = NSValueTransformerName.secureUnarchiveFromDataTransformerName.rawValue
            a.attributeValueClassName = NSStringFromClass(NSArray.self)
            a.defaultValue = NSArray()
        case .optionalInt: a.attributeType = .integer64AttributeType; a.isOptional = true
        case .optionalBool: a.attributeType = .booleanAttributeType; a.isOptional = true
        case .optionalString: a.attributeType = .stringAttributeType; a.isOptional = true
        }
        return a
    }

    private static func relate(_ a: NSEntityDescription, _ aName: String, toMany aMany: Bool, _ aRule: NSDeleteRule,
                               _ b: NSEntityDescription, _ bName: String, toMany bMany: Bool, _ bRule: NSDeleteRule) {
        func side(_ name: String, _ destination: NSEntityDescription, _ many: Bool, _ rule: NSDeleteRule) -> NSRelationshipDescription {
            let r = NSRelationshipDescription()
            r.name = name
            unsafe r.destinationEntity = destination
            r.minCount = 0
            r.maxCount = many ? 0 : 1
            r.deleteRule = rule
            r.isOptional = true
            return r
        }
        let forward = side(aName, b, aMany, aRule)
        let inverse = side(bName, a, bMany, bRule)
        unsafe forward.inverseRelationship = inverse
        unsafe inverse.inverseRelationship = forward
        a.properties.append(forward)
        b.properties.append(inverse)
    }

    // MARK: Attribute Tables
    // One row per stored property of each model class (61–67), in declaration order.

    static let filmAttributes: [Attribute] = [
        ("id", .uuid), ("posterUID", .string), ("name", .string),
        ("releaseYear", .string), ("userRating", .int), ("lastWatched", .string),
        ("duration", .string), ("viewCount", .int), ("calendarTable", .strings),
        ("autoAddToQueueOnRotation", .optionalInt), ("rotationThresholdOverride", .optionalInt), ("digitalSource", .string),
        ("digitalVersion", .string), ("subtitles", .string), ("notes", .string),
        ("numberOfDiscs", .string), ("aspectRatio", .string), ("color", .bool),
        ("edited", .bool), ("editedDuration", .string), ("frameRate", .double),
        ("tags", .strings), ("externalIdentifiers", .strings), ("dateAdded", .string),
        ("lastModified", .string), ("watched", .bool), ("specialSorting", .strings),
        ("alternateTitle", .strings), ("hofPosition", .int), ("infoComplete", .bool),
        ("comments", .string), ("genre", .string), ("releaseDate", .string),
        ("descriptionText", .string), ("rating", .string), ("studio", .strings),
        ("cast", .strings), ("directors", .strings), ("producers", .strings),
        ("executiveProducers", .strings), ("screenwriters", .strings), ("encodingTool", .strings),
        ("libraryHBRFValue", .int), ("composer", .strings), ("sortName", .string),
        ("releaseUsed", .string), ("tools", .strings), ("editedHBRFValue", .int),
        ("editDate", .string), ("warning", .strings), ("descriptionNotes", .string),
        ("notesOnAudioTiming", .strings), ("specialAudioNotes", .strings), ("notesArray", .strings),
        ("handbrakeFrames", .strings), ("correspondingTimecodes", .strings),
    ]

    static let listObjectAttributes: [Attribute] = [
        ("listID", .uuid), ("listName", .string), ("viewStyle", .string),
        ("sortFilterOptions", .strings), ("displayOrder", .int),
    ]

    static let releaseAttributes: [Attribute] = [
        ("id", .uuid), ("studio", .string), ("releaseDate", .string),
        ("baseReleaseYear", .string), ("purchased", .bool), ("wishlist", .int),
        ("format", .string), ("includedVersions", .strings), ("independence", .string),
        ("videoFormat", .string), ("releaseAspectRatio", .strings), ("scanningMethod", .string),
        ("audioFormat", .string), ("audioChannels", .string), ("hasSubtitles", .bool),
        ("numberOfDiscs", .int), ("discMultiPack", .bool), ("hasArtwork", .string),
        ("remastered", .bool), ("nationalOrigin", .string), ("replicationType", .string),
        ("discCapacity", .strings), ("hasHDR", .string), ("masterType", .string),
        ("regionLock", .string), ("regionLockBypass", .bool), ("marketAvailability", .strings),
        ("numberOfCopies", .int), ("cost", .double), ("amountSpent", .double),
        ("purchaseDate", .string), ("lowestPrice", .double), ("lowestPriceDate", .string),
        ("condition", .string), ("notes", .string), ("dateAdded", .date),
        ("sortOrder", .int),
    ]

    static let listMembershipAttributes: [Attribute] = [
        ("id", .uuid), ("dateAdded", .date), ("sortOrder", .int),
    ]

    static let importSessionAttributes: [Attribute] = [
        ("id", .uuid), ("sessionDate", .date), ("importType", .string),
        ("totalItems", .int), ("successCount", .int), ("errorCount", .int),
        ("duplicateCount", .int), ("updatedCount", .int), ("notFoundCount", .int),
        ("errorFileNames", .strings), ("addedTitles", .strings), ("updatedTitles", .strings),
        ("duplicateTitles", .strings), ("isCompleted", .bool), ("isCanceled", .bool),
    ]

    static let settingsObjectAttributes: [Attribute] = [
        ("snapshotID", .uuid), ("version", .int), ("lastSyncDate", .date),
        ("confirmGalleryDelete", .optionalBool), ("confirmListEdits", .optionalBool), ("listEditScope", .optionalInt),
        ("confirmReleaseDelete", .optionalBool), ("largeGalleryGrid", .optionalBool), ("showStatusBar", .optionalBool),
        ("rememberRightSidebarTab", .optionalBool), ("rememberRightSidebarReleasesFilter", .optionalBool), ("autoExpandRightSidebarTables", .optionalBool),
        ("additionalCalTableDetails", .optionalBool), ("showReleasesSummaryTable", .optionalBool), ("iCalIntegration", .optionalBool),
        ("manualExtQuery", .optionalBool), ("smartLists", .optionalBool), ("excludeQueuedFromUpForRotation", .optionalBool),
        ("maintainSelectionOnSearchExit", .optionalBool), ("showSearchSuggestions", .optionalBool), ("showRecentSearches", .optionalBool),
        ("showInfoComplete", .optionalBool), ("performBackupAtLaunch", .optionalBool), ("defaultRotationThreshold", .optionalInt),
        ("importScanSubfolders", .optionalBool), ("fuzzyImportMatching", .optionalBool), ("fuzzyImportYearMatching", .optionalBool),
        ("overrideSortNameField", .optionalBool), ("allowUpdatesForDuplicateImports", .optionalBool), ("allowUpdatesForDuplicateRatings", .optionalBool),
        ("exportPosterImages", .optionalBool), ("prunePosterImages", .optionalBool), ("exportUserSettings", .optionalBool),
        ("maintainScrollPositionOnViewSwitch", .optionalBool), ("rememberTabSelection", .optionalBool), ("tabRememberScope", .optionalInt),
        ("lastRecentsCategory", .optionalString), ("lastReportsCategory", .optionalString), ("rememberImportsTab", .optionalBool),
        ("lastImportsCategory", .optionalString), ("rememberSortFilterSelections", .optionalBool), ("confirmFilmQueueAdd", .optionalBool),
        ("notifyAboutNewReleases", .optionalBool), ("onlyNotifyForWishlisted", .optionalBool), ("queueIsDropTarget", .optionalBool),
        ("queueSectionOnDrop", .optionalInt), ("strictFramesTableChecking", .optionalBool), ("showWatchDetailsAnnotationGlyphs", .optionalBool),
        ("atvq", .optionalBool), ("loggingEnabled", .optionalBool), ("selectedSortOptionsJSON", .optionalString),
        ("ignoredDuplicatePairsJSON", .optionalString),
    ]

    static let savedSearchObjectAttributes: [Attribute] = [
        ("searchID", .uuid), ("name", .string), ("queryJSON", .string),
        ("displayOrder", .int), ("dateCreated", .date), ("dateModified", .date),
    ]

}
