// Film Tracker: SwiftData vs Core Data benchmark (scratchpad only, synthetic data).
// Usage: bench seed-sd <store> <n> | seed-cd <store> <n> | sd <store> | cd <store> hist|nohist
import Foundation
import SwiftData
import CoreData

let args = CommandLine.arguments
let mode = args[1]
let url = URL(fileURLWithPath: args[2])
let native = ProcessInfo.processInfo.environment["BENCH_NATIVE"] == "1"
let listSizes = [75, 59, 42, 41, 19, 18, 17, 16, 15, 15, 12, 12, 11, 9, 7, 5, 4, 0]

func now() -> ContinuousClock.Instant { .now }
func ms(_ s: ContinuousClock.Instant) -> Double { let d = ContinuousClock.now - s; return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
func report(_ name: String, _ v: Double) { print(String(format: "%@\t%.1f", name, v)); fflush(stdout) }
func time(_ name: String, _ body: () throws -> Void) rethrows { let s = now(); try body(); report(name, ms(s)) }
func avg(_ name: String, _ count: Int, _ body: (Int) throws -> Void) rethrows {
    let s = now(); for i in 0..<count { try body(i) }; report(name + " (avg of \(count))", ms(s) / Double(count))
}

// MARK: - SwiftData

func sdContainer() throws -> ModelContainer {
    try ModelContainer(for: Film.self, Release.self, ListObject.self, ListMembership.self,
                       configurations: ModelConfiguration(url: url))
}

func sdSeed(_ n: Int) throws {
    var c: ModelContainer!
    try time("open (new store)") { c = try sdContainer() }
    let ctx = ModelContext(c); ctx.autosaveEnabled = false
    try time("seed \(n) films + \(2 * n) releases + lists") {
        var films: [Film] = []
        for i in 0..<n {
            let f = Film(); fill(f, i); ctx.insert(f); films.append(f)
            for k in 0..<2 { let r = Release(); fill(r, i * 2 + k); r.film = f; ctx.insert(r) }
            if i % 100 == 99 { try ctx.save() }
        }
        for (li, size) in listSizes.enumerated() {
            let l = ListObject(); l.listName = "List \(li)"; l.displayOrder = li; ctx.insert(l)
            for k in 0..<size { ctx.insert(ListMembership(film: films[(li * 37 + k * 11) % n], list: l, sortOrder: k)) }
        }
        try ctx.save()
    }
}

func sdRun() throws {
    var c: ModelContainer!
    try time("open container") { c = try sdContainer() }
    let ctx = ModelContext(c); ctx.autosaveEnabled = false
    try time("launch load: all films, releases, memberships to rows") {
        let f = try ctx.fetch(FetchDescriptor<Film>()).map(\.row)
        let r = try ctx.fetch(FetchDescriptor<Release>()).map(\.row)
        let m = try ctx.fetch(FetchDescriptor<ListMembership>()).map { ($0.film?.id, $0.list?.listID, $0.sortOrder) }
        precondition(!f.isEmpty && !r.isEmpty && !m.isEmpty)
    }
    let bigName = try ctx.fetch(FetchDescriptor<ListObject>()).max { $0.memberships.count < $1.memberships.count }!.listName
    let ids = try ctx.fetch(FetchDescriptor<Film>(sortBy: [SortDescriptor(\.name)])).map(\.id)
    func list(_ name: String) throws -> ListObject { try ctx.fetch(FetchDescriptor<ListObject>(predicate: #Predicate { $0.listName == name })).first! }
    func film(_ id: UUID) throws -> Film { try ctx.fetch(FetchDescriptor<Film>(predicate: #Predicate { $0.id == id })).first! }

    try avg("edit one film, save", 50) { i in
        let f = try film(ids[i]); f.notes = "edited \(i)"; f.lastModified = "\(i)"; try ctx.save()
    }
    try avg("add one film to a 75-film list, save", 50) { i in
        let l = try list(bigName); let maxSort = l.memberships.map(\.sortOrder).max() ?? -1
        ctx.insert(ListMembership(film: try film(ids[1000 + i]), list: l, sortOrder: maxSort + 1)); try ctx.save()
    }
    try avg("remove one film from that list, save", 50) { i in
        let l = try list(bigName); let id = ids[1000 + i]
        if let m = l.memberships.first(where: { $0.film?.id == id }) { ctx.delete(m) }; try ctx.save()
    }
    try time("reorder a 75-film list, save") {
        let ms = try list(bigName).memberships.sorted { $0.sortOrder < $1.sortOrder }
        for (k, m) in ms.reversed().enumerated() { m.sortOrder = k }; try ctx.save()
    }
    var newIDs: [UUID] = []
    try time("import 100 films + 200 releases, save") {
        for i in 0..<100 {
            let f = Film(); fill(f, 90_000 + i); ctx.insert(f); newIDs.append(f.id)
            for k in 0..<2 { let r = Release(); fill(r, k); r.film = f; ctx.insert(r) }
        }
        try ctx.save()
    }
    try time("delete those 100 films (cascade), save") {
        let set = Set(newIDs)
        for f in try ctx.fetch(FetchDescriptor<Film>(predicate: #Predicate { set.contains($0.id) })) { ctx.delete(f) }
        try ctx.save()
    }
    let all = Set(ids)
    try time("BULK: edit 3 fields on every film, save") {
        for f in try ctx.fetch(FetchDescriptor<Film>(predicate: #Predicate { all.contains($0.id) })) {
            f.notes = "bulk"; f.genre = "Drama"; f.lastModified = "now"
        }
        try ctx.save()
    }
    try time("BULK: add every film to an empty list (saves per 100)") {
        let l = try list("Bench Empty"); var k = 0
        for f in try ctx.fetch(FetchDescriptor<Film>(predicate: #Predicate { all.contains($0.id) })) {
            ctx.insert(ListMembership(film: f, list: l, sortOrder: k)); k += 1
            if k % 100 == 0 { try ctx.save() }
        }
        try ctx.save()
    }
    try time("BULK: remove every film from that list, save") {
        let l = try list("Bench Empty")
        for m in l.memberships where m.film.map({ all.contains($0.id) }) ?? false { ctx.delete(m) }
        try ctx.save()
    }
    try time("BULK: add every film to the 75-film list (skip dupes)") {
        let l = try list(bigName); let have = Set(l.memberships.compactMap { $0.film?.id })
        var k = (l.memberships.map(\.sortOrder).max() ?? -1) + 1, n = 0
        for f in try ctx.fetch(FetchDescriptor<Film>(predicate: #Predicate { all.contains($0.id) })) where !have.contains(f.id) {
            ctx.insert(ListMembership(film: f, list: l, sortOrder: k)); k += 1; n += 1
            if n % 100 == 0 { try ctx.save() }
        }
        try ctx.save()
    }
}

// MARK: - Core Data

func cdStack(history: Bool) throws -> NSPersistentStoreCoordinator {
    // The same entity model SwiftData builds from the @Model types, so both engines open one store format.
    ValueTransformer.setValueTransformer(SwiftDataArrayTransformer(), forName: SwiftDataArrayTransformer.name)
    let mom = NSManagedObjectModel.makeManagedObjectModel(for: [Film.self, Release.self, ListObject.self, ListMembership.self])!
    for e in mom.entities {
        e.managedObjectClassName = "CD" + e.name!
        // SwiftData names the Swift type ("Array<String>"), which the secure unarchiver can't resolve.
        // Arrays are stored as SwiftData writes them: JSON bytes inside a keyed-archived NSData.
        for a in e.attributesByName.values where a.attributeType == .transformableAttributeType {
            if native { a.valueTransformerName = "NSSecureUnarchiveFromData"; a.attributeValueClassName = "NSArray"; continue }
            a.valueTransformerName = SwiftDataArrayTransformer.name.rawValue; a.attributeValueClassName = "NSArray"
        }
    }
    let psc = NSPersistentStoreCoordinator(managedObjectModel: mom)
    try psc.addPersistentStore(type: .sqlite, at: url, options: [NSPersistentHistoryTrackingKey: history as NSNumber])
    return psc
}

/// Reads and writes `[String]` in SwiftData's on-disk format, so Core Data can share the existing store.
final class SwiftDataArrayTransformer: ValueTransformer {
    static let name = NSValueTransformerName("SwiftDataArrayTransformer")
    override class func allowsReverseTransformation() -> Bool { true }
    override class func transformedValueClass() -> AnyClass { NSArray.self }
    override func reverseTransformedValue(_ value: Any?) -> Any? {  // store -> object
        guard let blob = value as? Data,
              let json = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSData.self, from: blob) as Data? else { return nil }
        return try? JSONDecoder().decode([String].self, from: json)
    }
    override func transformedValue(_ value: Any?) -> Any? {  // object -> store
        guard let array = value as? [String], let json = try? JSONEncoder().encode(array) else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: json as NSData, requiringSecureCoding: true)
    }
}

func newContext(_ psc: NSPersistentStoreCoordinator) -> NSManagedObjectContext {
    let ctx = NSManagedObjectContext(.privateQueue); ctx.persistentStoreCoordinator = psc; ctx.undoManager = nil; return ctx
}

func ins<T: NSManagedObject>(_ t: T.Type, _ ctx: NSManagedObjectContext) -> T {
    NSEntityDescription.insertNewObject(forEntityName: String(describing: T.self).dropFirst(2).description, into: ctx) as! T
}
func fetch<T: NSManagedObject>(_ t: T.Type, _ ctx: NSManagedObjectContext, _ p: NSPredicate? = nil) throws -> [T] {
    let r = NSFetchRequest<T>(entityName: String(describing: T.self).dropFirst(2).description); r.predicate = p
    return try ctx.fetch(r)
}
func newMembership(_ ctx: NSManagedObjectContext, _ f: CDFilm, _ l: CDListObject, _ k: Int) {
    let m = ins(CDListMembership.self, ctx); m.id = UUID(); m.dateAdded = Date(); m.sortOrder = k; m.film = f; m.list = l
}
func members(_ l: CDListObject) -> [CDListMembership] { l.memberships.allObjects as! [CDListMembership] }

func cdSeed(_ n: Int) throws {
    var psc: NSPersistentStoreCoordinator!
    try time("open (new store)") { psc = try cdStack(history: false) }
    let ctx = newContext(psc)
    try ctx.performAndWait {
        try time("seed \(n) films + \(2 * n) releases + lists") {
            var films: [CDFilm] = []
            for i in 0..<n {
                let f = ins(CDFilm.self, ctx); fill(f, i); films.append(f)
                for k in 0..<2 { let r = ins(CDRelease.self, ctx); fill(r, i * 2 + k); r.film = f }
                if i % 100 == 99 { try ctx.save() }
            }
            for (li, size) in listSizes.enumerated() {
                let l = ins(CDListObject.self, ctx); l.listID = UUID(); l.listName = "List \(li)"; l.viewStyle = ""; l.sortFilterOptions = []; l.displayOrder = li
                for k in 0..<size { newMembership(ctx, films[(li * 37 + k * 11) % n], l, k) }
            }
            try ctx.save()
        }
    }
}

func cdRun(history: Bool) throws {
    var psc: NSPersistentStoreCoordinator!
    try time("open container") { psc = try cdStack(history: history) }
    let ctx = newContext(psc)
    try ctx.performAndWait {
        try time("launch load: all films, releases, memberships to rows") {
            let f = try fetch(CDFilm.self, ctx).map(\.row)
            let r = try fetch(CDRelease.self, ctx).map(\.row)
            let m = try fetch(CDListMembership.self, ctx).map { ($0.film?.id, $0.list?.listID, $0.sortOrder) }
            precondition(!f.isEmpty && !r.isEmpty && !m.isEmpty)
        }
        let bigName = try fetch(CDListObject.self, ctx).max { $0.memberships.count < $1.memberships.count }!.listName
        let byName = NSFetchRequest<CDFilm>(entityName: "Film"); byName.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        let ids = try ctx.fetch(byName).map(\.id)
        func list(_ name: String) throws -> CDListObject { try fetch(CDListObject.self, ctx, NSPredicate(format: "listName == %@", name)).first! }
        func film(_ id: UUID) throws -> CDFilm { try fetch(CDFilm.self, ctx, NSPredicate(format: "id == %@", id as CVarArg)).first! }

        try avg("edit one film, save", 50) { i in
            let f = try film(ids[i]); f.notes = "edited \(i)"; f.lastModified = "\(i)"; try ctx.save()
        }
        try avg("add one film to a 75-film list, save", 50) { i in
            let l = try list(bigName); let maxSort = members(l).map(\.sortOrder).max() ?? -1
            newMembership(ctx, try film(ids[1000 + i]), l, maxSort + 1); try ctx.save()
        }
        try avg("remove one film from that list, save", 50) { i in
            let l = try list(bigName); let id = ids[1000 + i]
            if let m = members(l).first(where: { $0.film?.id == id }) { ctx.delete(m) }; try ctx.save()
        }
        try time("reorder a 75-film list, save") {
            let ms = members(try list(bigName)).sorted { $0.sortOrder < $1.sortOrder }
            for (k, m) in ms.reversed().enumerated() { m.sortOrder = k }; try ctx.save()
        }
        var newIDs: [UUID] = []
        try time("import 100 films + 200 releases, save") {
            for i in 0..<100 {
                let f = ins(CDFilm.self, ctx); fill(f, 90_000 + i); newIDs.append(f.id)
                for k in 0..<2 { let r = ins(CDRelease.self, ctx); fill(r, k); r.film = f }
            }
            try ctx.save()
        }
        try time("delete those 100 films (cascade), save") {
            for f in try fetch(CDFilm.self, ctx, NSPredicate(format: "id IN %@", newIDs)) { ctx.delete(f) }
            try ctx.save()
        }
        let all = ids
        try time("BULK: edit 3 fields on every film, save") {
            for f in try fetch(CDFilm.self, ctx, NSPredicate(format: "id IN %@", all)) { f.notes = "bulk"; f.genre = "Drama"; f.lastModified = "now" }
            try ctx.save()
        }
        try time("BULK: add every film to an empty list (saves per 100)") {
            let l = try list("Bench Empty"); var k = 0
            for f in try fetch(CDFilm.self, ctx, NSPredicate(format: "id IN %@", all)) {
                newMembership(ctx, f, l, k); k += 1
                if k % 100 == 0 { try ctx.save() }
            }
            try ctx.save()
        }
        try time("BULK: remove every film from that list, save") {
            let set = Set(all)
            for m in members(try list("Bench Empty")) where m.film.map({ set.contains($0.id) }) ?? false { ctx.delete(m) }
            try ctx.save()
        }
        try time("BULK: add every film to the 75-film list (skip dupes)") {
            let l = try list(bigName); let have = Set(members(l).compactMap { $0.film?.id })
            var k = (members(l).map(\.sortOrder).max() ?? -1) + 1, n = 0
            for f in try fetch(CDFilm.self, ctx, NSPredicate(format: "id IN %@", all)) where !have.contains(f.id) {
                newMembership(ctx, f, l, k); k += 1; n += 1
                if n % 100 == 0 { try ctx.save() }
            }
            try ctx.save()
        }
        // Core Data-only store-level tools.
        try time("CD only: batch update 3 fields on every film + merge") {
            let r = NSBatchUpdateRequest(entityName: "Film")
            r.propertiesToUpdate = ["notes": "batch", "genre": "Comedy", "lastModified": "later"]
            r.resultType = .updatedObjectIDsResultType
            let res = try ctx.execute(r) as! NSBatchUpdateResult
            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSUpdatedObjectsKey: res.result as! [NSManagedObjectID]], into: [ctx])
        }
        do {
            try time("CD only: batch delete every film's row in the 75-film list + merge") {
                let r = NSBatchDeleteRequest(fetchRequest: {
                    let f = NSFetchRequest<NSFetchRequestResult>(entityName: "ListMembership"); f.predicate = NSPredicate(format: "list.listName == %@", bigName); return f }())
                r.resultType = .resultTypeObjectIDs
                let res = try ctx.execute(r) as! NSBatchDeleteResult
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: res.result as! [NSManagedObjectID]], into: [ctx])
            }
        } catch { print("CD only: batch delete\tFAILED: \(error.localizedDescription)") }
        // Check the stores agree on counts after the batch tools.
        print("check\tfilms \(try ctx.count(for: NSFetchRequest<CDFilm>(entityName: "Film"))), memberships \(try ctx.count(for: NSFetchRequest<CDListMembership>(entityName: "ListMembership")))")
    }
}

// MARK: - Restore from the backup (as JSON)

let backup: [String: [[String: Any]]] = mode.hasPrefix("restore")
    ? try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[3]))) as! [String: [[String: Any]]] : [:]
func uuid(_ d: [String: Any], _ k: String) -> UUID? { (d[k] as? String).flatMap(UUID.init(uuidString:)) }

func sdRestore() throws {
    let c = try sdContainer(); let ctx = ModelContext(c); ctx.autosaveEnabled = false
    try time("restore backup (\(backup["Film"]!.count) films)") {
        var films: [UUID: Film] = [:], rels: [UUID: Release] = [:], lists: [UUID: ListObject] = [:]
        for d in backup["Film"]! { let f = Film(); load(f, d); ctx.insert(f); films[f.id] = f }
        for d in backup["Release"]! { let r = Release(); load(r, d); r.film = uuid(d, "filmID").flatMap { films[$0] }; ctx.insert(r); rels[r.id] = r }
        for d in backup["Release"]! { if let p = uuid(d, "parentReleaseID"), let me = uuid(d, "id") { rels[me]?.parentRelease = rels[p] } }
        for d in backup["ListObject"]! {
            let l = ListObject(); l.listID = uuid(d, "listID")!; l.listName = d["listName"] as? String ?? ""; l.viewStyle = d["viewStyle"] as? String ?? ""
            l.sortFilterOptions = d["sortFilterOptions"] as? [String] ?? []; l.displayOrder = (d["displayOrder"] as? Int) ?? 0; ctx.insert(l); lists[l.listID] = l
        }
        let e = ListObject(); e.listName = "Bench Empty"; ctx.insert(e)
        for d in backup["ListMembership"]! {
            guard let f = uuid(d, "filmID").flatMap({ films[$0] }), let l = uuid(d, "listID").flatMap({ lists[$0] }) else { continue }
            let m = ListMembership(film: f, list: l, sortOrder: (d["sortOrder"] as? Int) ?? 0); m.dateAdded = iso.date(from: d["dateAdded"] as? String ?? "") ?? Date(); ctx.insert(m)
        }
        try ctx.save()
    }
}

func cdRestore() throws {
    let psc = try cdStack(history: !native); let ctx = newContext(psc)
    try ctx.performAndWait {
        try time("restore backup (\(backup["Film"]!.count) films)") {
            var films: [UUID: CDFilm] = [:], rels: [UUID: CDRelease] = [:], lists: [UUID: CDListObject] = [:]
            for d in backup["Film"]! { let f = ins(CDFilm.self, ctx); load(f, d); films[f.id] = f }
            for d in backup["Release"]! { let r = ins(CDRelease.self, ctx); load(r, d); r.film = uuid(d, "filmID").flatMap { films[$0] }; rels[r.id] = r }
            for d in backup["Release"]! { if let p = uuid(d, "parentReleaseID"), let me = uuid(d, "id") { rels[me]?.parentRelease = rels[p] } }
            func list(_ id: UUID, _ name: String, _ d: [String: Any]) -> CDListObject {
                let l = ins(CDListObject.self, ctx); l.listID = id; l.listName = name; l.viewStyle = d["viewStyle"] as? String ?? ""
                l.sortFilterOptions = d["sortFilterOptions"] as? [String] ?? []; l.displayOrder = (d["displayOrder"] as? Int) ?? 0; return l
            }
            for d in backup["ListObject"]! { let id = uuid(d, "listID")!; lists[id] = list(id, d["listName"] as? String ?? "", d) }
            _ = list(UUID(), "Bench Empty", [:])
            for d in backup["ListMembership"]! {
                guard let f = uuid(d, "filmID").flatMap({ films[$0] }), let l = uuid(d, "listID").flatMap({ lists[$0] }) else { continue }
                newMembership(ctx, f, l, (d["sortOrder"] as? Int) ?? 0)
            }
            try ctx.save()
        }
    }
}

switch mode {
case "restore-sd": try sdRestore()
case "restore-cd": try cdRestore()
case "seed-sd": try sdSeed(Int(args[3])!)
case "seed-cd": try cdSeed(Int(args[3])!)
case "sd": try sdRun()
case "cd": try cdRun(history: args[3] == "hist")
default: fatalError("bad mode")
}
