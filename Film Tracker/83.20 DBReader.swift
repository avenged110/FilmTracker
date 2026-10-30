// MARK: - DBReader.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Reads NSManagedObjectContext contents and exposes a normalized export structure.
//
// Usage summary:
//   1. Make your model types conform to `ExportableModel` (examples below).
//   2. Create DBReader and call exportAll(types:progress:).

import Foundation
import CoreData

// Shared ISO 8601 style ("2026-09-27T12:34:56Z", UTC) — reused by AnyCodable and DBReader.
// A Sendable value, so it is usable from Codable's nonisolated requirements with no escape.
private let sharedISO8601Style = Date.ISO8601FormatStyle(timeZoneSeparator: .colon)

// MARK: - Export Types
/// A normalized representation of an exported object.
public struct ExportedObject: Codable {
    public let exportID: String // stable id for cross-references during export
    public let entityName: String
    public let properties: [String: AnyCodable] // scalar properties
    public let relationships: [String: [String]] // relationshipName -> [exportIDs]

    /// Property name → the model's DECLARED type, for the properties whose type cannot be
    /// recovered from the written text.
    ///
    /// Only `"string"` is recorded, and only for values the reader saw as a Swift `String`.
    /// The backup format is untyped: every value is written as text, and DBImporter guesses
    /// the type back from the shape of that text. That guess is correct for the numeric,
    /// boolean and array fields it was designed around, and wrong for a STRING field whose
    /// content happens to look like one of them — `numberOfDiscs = "007"` came back as the
    /// integer 7, `aspectRatio = "2.00"` as the double 2, `notes = "true"` as a boolean, and
    /// `notes = "[\"a\",\"b\"]"` as an array. The restore then converted the misread value
    /// back to a String as best it could ("7", "2") or, for the boolean and array cases,
    /// could not and substituted an empty string — silently erasing the field.
    ///
    /// Marking the declared type removes the guess for exactly the cases where it is unsafe,
    /// and is compatible in both directions: an older build ignores an attribute it does not
    /// know, and a backup written without it still parses through the original inference
    /// path. Arrays are deliberately NOT marked — they must keep being reconstructed as
    /// arrays, and their JSON encoding already identifies them unambiguously.
    public let propertyTypes: [String: String]

    public init(exportID: String, entityName: String,
                properties: [String: AnyCodable],
                relationships: [String: [String]],
                propertyTypes: [String: String] = [:]) {
        self.exportID = exportID
        self.entityName = entityName
        self.properties = properties
        self.relationships = relationships
        self.propertyTypes = propertyTypes
    }
}

/// Container for the whole export
public struct ExportPackage: Codable {
    public let format: String // FilmTrackerXML
    public let version: Int
    public let createdISO8601: String
    public let appVersion: String?
    public let manifest: [String: Int] // entityName -> count
    public let objects: [ExportedObject]
}

// Small wrapper to allow encoding heterogenous property values
public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        // decode as null / basic types
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            self.value = b
        } else if let i = try? container.decode(Int64.self) {
            self.value = i
        } else if let d = try? container.decode(Double.self) {
            self.value = d
        } else if let s = try? container.decode(String.self) {
            self.value = s
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let b as Bool:
            try container.encode(b)
        case let i as Int:
            try container.encode(Int64(i))
        case let i as Int64:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let s as String:
            try container.encode(s)
        case let date as Date:
            // encode dates as ISO8601 strings
            try container.encode(sharedISO8601Style.format(date))
        default:
            // fallback to description
            try container.encode(String(describing: value))
        }
    }
}

extension AnyCodable: @unchecked Sendable {}
extension ExportedObject: @unchecked Sendable {}
extension ExportPackage: @unchecked Sendable {}

// MARK: - ExportableModel protocol
/// Types must provide a fetch method and property extraction.
public protocol ExportableModel: AnyObject, SendableMetatype {
    static var entityName: String { get }
    /// Fetch all objects of this type from the supplied NSManagedObjectContext.
    ///
    /// Nonisolated and synchronous, so it runs wherever the context lives: on the
    /// MainActor for a manual export, on `BackgroundExportReader`'s own executor for the
    /// automatic one. NSManagedObjectContext is not Sendable, so the caller must be the context's
    /// own isolation — which a synchronous call from that isolation always is.
    static func fetchAll(in context: NSManagedObjectContext) throws -> [Self]
    /// Extract properties (scalars) and relationships (names -> [related objects]) for an instance.
    /// Conforming types can implement a custom extractor; a Mirror-based default extractor is provided.
    func extractExportValues() -> (properties: [String: Any], relationships: [String: [Any]])
    /// Try to return a stable id string for this object. If nil, exporter will assign one.
    func exportStableID() -> String?
}

public enum DBReaderError: Error {
    case fetchFailed(entity: String, underlying: any Error)
}

/// Default implementation: every row of the entity, unsorted. Every model supplies its own
/// `extractExportValues()` and `exportStableID()`.
extension ExportableModel where Self: LibraryObject {
    static func fetchAll(in context: NSManagedObjectContext) throws -> [Self] {
        try context.fetch(Self.request())
    }
}

// MARK: - DBReader

/// DBReader is responsible for exporting model objects into an `ExportPackage`.
///
/// Not bound to any actor: `exportAll` runs in whatever isolation calls it (its `isolation`
/// parameter), which must be the isolation that owns `context`. A manual export calls it
/// from the MainActor with a main-thread context; the automatic backup calls it from
/// `BackgroundExportReader`, a context actor (ContextExecutor), so the whole read —
/// the fetches and every object's conversion — stays off the main thread.
public final class DBReader {
    private let context: NSManagedObjectContext

    public init(context: NSManagedObjectContext) {
        self.context = context
    }

    /// Whether every store behind `context` supports query generations: SQLite, writable,
    /// and in WAL mode (Core Data's default unless a journal_mode pragma says otherwise).
    private static func canPinQueryGeneration(_ context: NSManagedObjectContext) -> Bool {
        guard let stores = context.persistentStoreCoordinator?.persistentStores, !stores.isEmpty else { return false }
        return stores.allSatisfy { store in
            guard store.type == NSSQLiteStoreType, !store.isReadOnly else { return false }
            let pragmas = store.options?[NSSQLitePragmasOption] as? [String: Any]
            return ((pragmas?["journal_mode"] as? String) ?? "WAL").uppercased() == "WAL"
        }
    }

    /// Export all provided types. `types` is an array of ExportableModel metatypes.
    /// The method is asynchronous and non-blocking. Progress closure gets called with values 0.0...1.0.
    /// When isBackgroundExport is true, processes one item at a time with 5ms sleeps to minimize UI impact.
    public func exportAll(types: [any ExportableModel.Type],
                          appVersion: String? = nil,
                          isBackgroundExport: Bool = false,
                          progress: ((Double) -> Void)? = nil,
                          isolation: isolated (any Actor)? = #isolation) async throws -> ExportPackage
    {
        let created = sharedISO8601Style.format(Date())
        var manifest: [String: Int] = [:]
        var exportedObjects: [ExportedObject] = []
        var assignedIDs: Set<String> = []

        // Single reusable JSON encoder for every [String] array property across all
        // objects. JSONEncoder allocation is not free, and the previous code created a
        // fresh encoder for each array field of each object — tens of thousands of
        // allocations on a large library. exportAll runs entirely on the MainActor, so
        // reusing one encoder across the loop is safe (no concurrent access).
        let jsonEncoder = JSONEncoder()

        // One moment for the whole backup. Each entity is a separate fetch, and a write
        // committed between two of them (a film added after the Film fetch, its releases
        // fetched after) would otherwise put two moments in one file. Pinning the context to
        // the store's current query generation makes every fetch read the same snapshot.
        // Both callers pass a fresh context used only for this read, so nothing else is
        // frozen. Only on a writable WAL store: on any other (read-only, rollback-journal,
        // in-memory) the pin is accepted but every fetch after it fails, so those read as
        // they always did.
        if Self.canPinQueryGeneration(context) {
            try? context.setQueryGenerationFrom(.current)
        }

        // Single pass: fetch all entities once and cache results.
        // Previously this was two passes (count then export), doubling database I/O.
        var totalObjectsToExport = 0
        var cachedFetches: [String: [any ExportableModel]] = [:]
        
        for t in types {
            // Cancellation is checked here and once per chunk below rather than only
            // between phases. The read is the longest MainActor stretch of an export and
            // the one the user is most likely to be looking at when they press Cancel, and
            // aborting inside it is completely clean: nothing has been written yet, so the
            // only cost of stopping is the work already done. `Task.yield()`, which is all
            // this loop used to do, never throws — so a canceled export used to read the
            // entire library out of the store before noticing at the phase boundary.
            try Task.checkCancellation()
            do {
                let fetched = try t.fetchAll(in: context)
                cachedFetches[t.entityName] = fetched
                totalObjectsToExport += fetched.count
            } catch {
                throw DBReaderError.fetchFailed(entity: t.entityName, underlying: error)
            }
            // Yield after each fetch to keep UI responsive
            await Task.yield()
        }

        if totalObjectsToExport == 0 {
            // return an empty package
            return ExportPackage(format: "FilmTrackerXML", version: 1, createdISO8601: created, appVersion: appVersion, manifest: [:], objects: [])
        }

        var exportedSoFar = 0
        
        // Foreground exports convert in chunks of 100 with a yield between them. Background
        // exports run off the main thread (BackgroundExportReader), so they no longer need
        // one-object chunks to keep the UI responsive; they instead work in short time
        // slices with a pause between, which keeps their CPU and store I/O footprint small
        // at low priority. Completion time is deliberately not a concern for them.
        let chunkSize = isBackgroundExport ? 25 : 100
        let backgroundSliceBudget: Duration = .milliseconds(2)
        let backgroundPause: Duration = .milliseconds(5)
        var sliceStart = ContinuousClock.now

        // Export from cached results (no second database fetch)
        for t in types {
            let entityName = t.entityName
            let fetched = cachedFetches[entityName] ?? []

            manifest[entityName] = fetched.count

            // Process objects in chunks to allow cooperative yielding
            for (_, chunk) in fetched.chunked(into: chunkSize).enumerated() {
                try Task.checkCancellation()
                for instance in chunk {
                    // unique export id
                    var exportID: String
                    if let stable = instance.exportStableID() {
                        exportID = "\(entityName)-\(stable)" // namespaced
                    } else {
                        // fallback: assign an UUID and ensure uniqueness
                        repeat { exportID = UUID().uuidString } while assignedIDs.contains(exportID)
                    }
                    assignedIDs.insert(exportID)

                    // extract properties & relationships
                    let (props, relsRaw) = instance.extractExportValues()

                    // transform properties -> AnyCodable-friendly map
                    var propsEncoded: [String: AnyCodable] = [:]
                    // Declared types for the values that need one. See ExportedObject.propertyTypes.
                    var propTypes: [String: String] = [:]
                    for (k,boxed) in props {
                        // An unset optional arrives boxed as `Optional.none` (FilmField's
                        // `value(of:)` keeps optionals boxed). Unwrapped here, so it is
                        // written as the empty value every reader takes as nil rather than
                        // falling through to `String(describing:)` and writing the text "nil".
                        let v = (boxed as? any OptionalBox).map { $0.unboxed ?? NSNull() } ?? boxed
                        if v is NSNull {
                            propsEncoded[k] = AnyCodable(NSNull())
                        } else if let d = v as? Date {
                            propsEncoded[k] = AnyCodable(sharedISO8601Style.format(d))
                        } else if let u = v as? UUID {
                            propsEncoded[k] = AnyCodable(u.uuidString)
                        } else if let arr = v as? [String] {
                            // Encode [String] arrays as JSON strings here rather than relying on
                            // AnyCodable (which has no [String] case and would fall through to
                            // String(describing:), producing output that is not valid JSON and
                            // breaks round-tripping for any element containing control characters).
                            // Illegal XML scalars are stripped before encoding (see
                            // strippingIllegalXMLScalars).
                            let sanitized = arr.map(\.strippingIllegalXMLScalars)
                            if let jsonData = try? jsonEncoder.encode(sanitized),
                               let jsonString = String(data: jsonData, encoding: .utf8) {
                                propsEncoded[k] = AnyCodable(jsonString)
                            } else {
                                propsEncoded[k] = AnyCodable("[]")
                            }
                        } else if let s = v as? String {
                            propsEncoded[k] = AnyCodable(s)
                            // The only branch that marks a type: this value IS a String in
                            // the model, whatever its text happens to look like.
                            propTypes[k] = "string"
                        } else if let b = v as? Bool {
                            propsEncoded[k] = AnyCodable(b)
                        } else if let i = v as? Int {
                            propsEncoded[k] = AnyCodable(Int64(i))
                        } else if let i64 = v as? Int64 {
                            propsEncoded[k] = AnyCodable(i64)
                        } else if let dbl = v as? Double {
                            propsEncoded[k] = AnyCodable(dbl)
                        } else {
                            // fallback to string representation
                            propsEncoded[k] = AnyCodable(String(describing: v))
                        }
                    }

                    // transform relationships into arrays of exportIDs
                    // Note: For Film, ListObject, ListMembership, and Release,
                    // relationships are exported via filmID/listID properties, not relationship arrays
                    var relsEncoded: [String: [String]] = [:]
                    for (relName, relElements) in relsRaw {
                        // Skip memberships and releases relationships - these are handled via ID properties
                        if relName == "memberships" || relName == "releases" {
                            relsEncoded[relName] = []
                            continue
                        }
                        
                        var ids: [String] = []
                        for element in relElements {
                            // If element is an ExportableModel instance.
                            if let target = element as? any ExportableModel {
                                if let targetStable = target.exportStableID() {
                                    ids.append("\(type(of: target).entityName)-\(targetStable)")
                                } else {
                                    // Can't guarantee stable mapping; Assign an ad-hoc ID later.
                                    // Create temporary placeholder and map it when/if encountered.
                                    let adHoc = UUID().uuidString
                                    ids.append(adHoc)
                                    // NOTE: This ad-hoc ID may not match later assigned exportIDs
                                    // for that object. To handle full graph consistency reliably,
                                    // make sure related objects are present in 'types' and will be
                                    // exported (then stable IDs can be used or implement explicit
                                    // relationship ID extraction).
                                }
                            } else if let uuid = element as? UUID {
                                ids.append(uuid.uuidString)
                            } else if let s = element as? String {
                                ids.append(s)
                            } else {
                                // fallback
                                ids.append(String(describing: element))
                            }
                        }
                        relsEncoded[relName] = ids
                    }

                    let exported = ExportedObject(exportID: exportID,
                                                  entityName: entityName,
                                                  properties: propsEncoded,
                                                  relationships: relsEncoded,
                                                  propertyTypes: propTypes)
                    exportedObjects.append(exported)

                    exportedSoFar += 1
                }
                
                // Report progress after each chunk
                progress?(Double(exportedSoFar) / Double(totalObjectsToExport))
                
                // Foreground: yield briefly after every chunk. Background: once a slice has
                // used its budget, pause before the next. Task.sleep throws on cancellation,
                // which stops a canceled export here rather than at the next chunk.
                if isBackgroundExport {
                    if ContinuousClock.now - sliceStart >= backgroundSliceBudget {
                        try await Task.sleep(for: backgroundPause)
                        sliceStart = ContinuousClock.now
                    }
                } else {
                    await Task.yield()
                }
            }
        }

        let pkg = ExportPackage(format: "FilmTrackerXML",
                                version: 1,
                                createdISO8601: created,
                                appVersion: appVersion,
                                manifest: manifest,
                                objects: exportedObjects)

        progress?(1.0)
        return pkg
    }
}

// MARK: - BackgroundExportReader

/// Runs `DBReader.exportAll` for the automatic backup on a background executor with its own
/// NSManagedObjectContext.
///
/// The context is created by the initializer, fresh and empty, so every fetch materializes
/// from the persistent store — the same guarantee the manual export gets from the fresh
/// main-queue context DBExporter creates for it. Its jobs run on that context's private
/// queue (ContextExecutor), wherever the actor was created.
actor BackgroundExportReader {
    // A context actor, as DataManager is: a fresh private-queue context whose queue runs
    // this actor's jobs (ContextExecutor).
    private nonisolated let executor: ContextExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { unsafe executor.asUnownedSerialExecutor() }

    init(persistentContainer: NSPersistentContainer) {
        executor = ContextExecutor(context: persistentContainer.makeBackgroundContext())
    }

    func exportAll(types: ExportModelTypes,
                   appVersion: String?,
                   progress: (@Sendable (Double) -> Void)?) async throws -> ExportPackage {
        try await DBReader(context: executor.context).exportAll(
            types: types.types, appVersion: appVersion, isBackgroundExport: true, progress: progress)
    }
}

/// The model types to export, carried across to `BackgroundExportReader`. Sendable as
/// checked: ExportableModel refines SendableMetatype, so its metatypes cross freely.
struct ExportModelTypes: Sendable {
    let types: [any ExportableModel.Type]
}

// MARK: - Optional Unboxing

/// Lets DBReader see through an `Optional` boxed in `Any`.
private protocol OptionalBox { var unboxed: Any? { get } }
extension Optional: OptionalBox { fileprivate var unboxed: Any? { map { $0 as Any } } }

// MARK: - XML 1.0 Character Set

extension String {
    /// This string with every scalar that is illegal in XML 1.0 removed. The spec only
    /// allows `#x9 | #xA | #xD | [#x20–#xD7FF] | [#xE000–#xFFFD] | [#x10000–#x10FFFF]`;
    /// C0 control characters (U+0001–U+001F except tab/LF/CR) and U+FFFE/U+FFFF would
    /// corrupt the backup file or fail to parse on restore, and removing them is
    /// preferable to writing an unreadable backup. Applied by DBReader to array elements
    /// and by DBPackager to every string it writes, entity-escaped or CDATA, so no value
    /// can smuggle an illegal scalar into the file.
    var strippingIllegalXMLScalars: String {
        unicodeScalars.filter { scalar in
            let v = scalar.value
            return (v == 0x09 || v == 0x0A || v == 0x0D) ||
                   (v >= 0x20 && v <= 0xD7FF) ||
                   (v >= 0xE000 && v <= 0xFFFD) ||
                   (v >= 0x10000 && v <= 0x10FFFF)
        }.reduce(into: "") { $0.unicodeScalars.append($1) }
    }
}
