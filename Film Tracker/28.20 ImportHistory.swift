// MARK: - ImportHistory.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The Imports view's in-memory copy of every ImportSession, as values, kept current from
// Core Data's save notifications.
//
// Why it exists: ImportsView used to read its sessions through `@Query`, which fetches every
// ImportSession of every type each time the view is built — on every visit and every
// Metadata ⟷ Ratings switch — and SwiftData materialized each one in full, JSON-decoding
// its four title arrays, on the main thread. Measured by `imports-switch-perf` (99.55): 129 ms
// for 1,000 sessions, whatever the predicate, and `propertiesToFetch` saved nothing. The view
// now reads this index instead, which costs nothing to read; the only fetch is one full load
// in the background after launch.
//
// How it stays current: every ImportSession write in the app is saved, and every save posts
// `NSManagedObjectContext.didSaveObjectIDsNotification` with the object IDs it touched.
//   • Saves on the main context — ImportProgress creating, updating, canceling and completing
//     its session; the harness seeding — are applied synchronously, inside the notification,
//     from the very objects saved (still registered in the main context, under the permanent
//     IDs the notification names). So by the time `save()` returns, the index already says
//     what the store says: nothing that reads it afterward (ImportsView showing a
//     just-canceled session, say) can see an older copy.
//   • Deletions from any context (DataManager's "Clear This Item" / "Clear All") are removed
//     by identifier.
//   • Anything else — an insert or update saved by another context, which nothing in the app
//     does today, or a save that invalidated every identifier — reloads the whole index in
//     the background, and changes saved while that load runs are replayed over its result.
// A restore replaces the store and relaunches the app, so there is never a container swap
// to follow.

import Foundation
import CoreData

// MARK: - Import Session Record

/// One ImportSession as the Imports view draws it — every field a card or its Details popover
/// reads — as a value, so the view never touches the model object (or the context behind it).
struct ImportSessionRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The model's store identity, which deletion notifications name it by. nil only for
    /// a stand-in that was never stored (ImportCardShape's measuring template).
    let persistentID: NSManagedObjectID?
    let sessionDate: Date
    let importType: String
    let totalItems: Int
    let successCount: Int
    let errorCount: Int
    let duplicateCount: Int
    let updatedCount: Int
    let notFoundCount: Int
    let errorFileNames: [String]
    let addedTitles: [String]
    let updatedTitles: [String]
    let duplicateTitles: [String]
    let isCompleted: Bool
    let isCanceled: Bool

    var dateFormatted: String { ImportSession.formattedDate(sessionDate) }
    var timeFormatted: String { ImportSession.formattedTime(sessionDate) }
}

extension ImportSessionRecord {
    init(_ session: ImportSession) {
        id = session.id
        persistentID = session.objectID
        sessionDate = session.sessionDate
        importType = session.importType
        totalItems = session.totalItems
        successCount = session.successCount
        errorCount = session.errorCount
        duplicateCount = session.duplicateCount
        updatedCount = session.updatedCount
        notFoundCount = session.notFoundCount
        errorFileNames = session.errorFileNames
        addedTitles = session.addedTitles
        updatedTitles = session.updatedTitles
        duplicateTitles = session.duplicateTitles
        isCompleted = session.isCompleted
        isCanceled = session.isCanceled
    }
}

// MARK: - Import History

@MainActor
@Observable
final class ImportHistory: Loggable {
    nonisolated static let logTag = "[ImportHistory]"
    static let shared = ImportHistory()

    /// Bumped whenever the records change. `records(for:in:)` reads it, so a view that shows
    /// them is invalidated exactly when they change.
    private var revision = 0

    @ObservationIgnored private var container: NSPersistentContainer?
    @ObservationIgnored private var saveObservers: [any NSObjectProtocol] = []
    /// Newest first, keyed by `importType`. nil until the first load lands.
    @ObservationIgnored private var byType: [String: [ImportSessionRecord]]?
    /// Changes saved while a full load is in flight, replayed over its result (which may or may
    /// not already include them; every change is idempotent). nil when no load is in flight.
    @ObservationIgnored private var changesDuringLoad: [Change]?
    /// Identifies the newest load; a load that finishes after a newer one began is dropped.
    @ObservationIgnored private var loadGeneration = 0

    private enum Change {
        case upsert(ImportSessionRecord)
        case delete(NSManagedObjectID)
    }

    nonisolated private static let entityName = ImportSession.entityName

    /// Starts following `container`: subscribes to its saves and loads the index in the
    /// background. Idempotent. Called once the app's main view is up.
    func attach(_ container: NSPersistentContainer) {
        guard self.container == nil else { return }
        self.container = container
        let mainContextID = ObjectIdentifier(container.viewContext)
        // queue: nil runs the block on the posting thread, synchronously inside `save()`. A
        // main-context save is posted on the main thread, so it is applied before `save()`
        // returns; other contexts' saves hop to the main actor.
        let didSave = NotificationCenter.default.addObserver(
            forName: NSManagedObjectContext.didSaveObjectIDsNotification, object: nil, queue: nil
        ) { [weak self] note in
            let event = SaveEvent(note, entityName: Self.entityName)
            guard event.isRelevant else { return }
            let isMainContext = (note.object as AnyObject?).map(ObjectIdentifier.init) == mainContextID
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.didSave(event, onMainContext: isMainContext) }
            } else {
                Task { @MainActor in self?.didSave(event, onMainContext: false) }
            }
        }
        saveObservers = [didSave]
        reload()
    }

    /// Every session of `category`'s type, newest first.
    ///
    /// Before the background load has landed (a visit within moments of launch), this loads
    /// synchronously from the main context instead, once. That mutates only unobserved
    /// storage, so it is safe from inside a view's body.
    func records(for category: ImportsCategory, in container: NSPersistentContainer) -> [ImportSessionRecord] {
        _ = revision
        if self.container == nil { attach(container) }
        if byType == nil {
            // Supersedes the background load: everything saved so far is in this fetch, and
            // every later change applies directly.
            loadGeneration += 1
            changesDuringLoad = nil
            byType = Self.group(Self.fetchRecords(container.viewContext) ?? [])
        }
        return byType?[category.rawValue] ?? []
    }

    // MARK: Saves

    /// The ImportSession object IDs one save touched. Sendable, so it can leave the posting
    /// thread.
    private struct SaveEvent: Sendable {
        var changed: [NSManagedObjectID] = []
        var deleted: [NSManagedObjectID] = []
        var invalidatedAll = false

        init(_ note: Notification, entityName: String) {
            let info = note.userInfo ?? [:]
            func ids(_ key: String) -> [NSManagedObjectID] {
                ((info[key] as? Set<NSManagedObjectID>) ?? []).filter { $0.entity.name == entityName }
            }
            changed = ids(NSInsertedObjectIDsKey) + ids(NSUpdatedObjectIDsKey)
            deleted = ids(NSDeletedObjectIDsKey)
            invalidatedAll = info[NSInvalidatedAllObjectsKey] != nil
        }

        var isRelevant: Bool { !changed.isEmpty || !deleted.isEmpty || invalidatedAll }
    }

    private func didSave(_ event: SaveEvent, onMainContext: Bool) {
        guard let container else { return }
        if event.invalidatedAll {
            reload()
            return
        }
        var changes = event.deleted.map(Change.delete)
        if !event.changed.isEmpty {
            // The main context's own objects, just saved and still registered there: reading
            // them is not a fetch.
            let models: [ImportSession]? = onMainContext
                ? event.changed.compactMap { container.viewContext.registeredObject(for: $0) as? ImportSession }
                : nil
            if let models, models.count == event.changed.count {
                changes += models.map { .upsert(ImportSessionRecord($0)) }
            } else {
                reload()
            }
        }
        apply(changes)
    }

    private func apply(_ changes: [Change]) {
        guard !changes.isEmpty else { return }
        changesDuringLoad?.append(contentsOf: changes)
        guard var map = byType else { return }
        for change in changes { Self.apply(change, to: &map) }
        byType = map
        revision += 1
    }

    private static func apply(_ change: Change, to map: inout [String: [ImportSessionRecord]]) {
        switch change {
        case .upsert(let record):
            for type in map.keys { map[type]?.removeAll { $0.id == record.id } }
            var list = map[record.importType] ?? []
            // Newest first; a session dated the same as others goes after them.
            let index = list.firstIndex { $0.sessionDate < record.sessionDate } ?? list.endIndex
            list.insert(record, at: index)
            map[record.importType] = list
        case .delete(let identifier):
            for type in map.keys { map[type]?.removeAll { $0.persistentID == identifier } }
        }
    }

    // MARK: Loading

    /// Loads every session in the background, from a context of its own.
    ///
    /// At user-interactive QoS, deliberately. Every context shares the store's one SQLite
    /// connection, and this fetch holds it while it runs: a save made meanwhile — the launch
    /// settings sync on the main thread, DataManager's launch bootstrap — waits for it. At
    /// a lower QoS that wait is a priority inversion (it was, at `.utility`: Xcode's thread
    /// performance checker flagged `saveSettings`' `context.save()`; `imports-qos` in 99.55
    /// reproduces it under libRPAC). The load is a single fetch, once per launch.
    private func reload() {
        guard let container else { return }
        loadGeneration += 1
        let generation = loadGeneration
        changesDuringLoad = []
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let records = Self.fetchRecords(container.makeBackgroundContext())
            Task { @MainActor in self?.finishLoad(records, generation: generation) }
        }
    }

    private func finishLoad(_ records: [ImportSessionRecord]?, generation: Int) {
        guard generation == loadGeneration else { return }
        defer { changesDuringLoad = nil }
        guard let records else {
            log("Background load failed; keeping the current records", level: .warning)
            return
        }
        var map = Self.group(records)
        for change in changesDuringLoad ?? [] { Self.apply(change, to: &map) }
        byType = map
        revision += 1
    }

    #if DEBUG
    /// Starts a full background load, as after a save that invalidated every identifier —
    /// for `imports-qos` (99.55), which saves on the main thread while it runs.
    func debugReload() { reload() }
    #endif

    nonisolated private static func fetchRecords(_ context: NSManagedObjectContext) -> [ImportSessionRecord]? {
        context.performAndWait {
            let descriptor = ImportSession.request(sortedBy: [NSSortDescriptor(key: "sessionDate", ascending: false)])
            return (try? context.fetch(descriptor))?.map(ImportSessionRecord.init)
        }
    }

    nonisolated private static func group(_ records: [ImportSessionRecord]) -> [String: [ImportSessionRecord]] {
        Dictionary(grouping: records, by: \.importType)
    }
}
