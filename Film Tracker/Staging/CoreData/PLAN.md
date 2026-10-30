# Core Data Replacement: Plan

Replace SwiftData with Core Data throughout Film Tracker. This is a clean replacement, not a
store migration: the Core Data build opens a new, empty store, and the library comes back
by restoring a backup into it. The `.ftbackup` format does not change, so every existing
backup restores, and backups written by the Core Data build restore into the SwiftData
build too.

## Status (2026-10-29)

**Integrated into the real project** (uncommitted). It was built in the test copy
(`Xcode projects/Film Tracker - Core Data Test`), which is now only a reference. See
INTEGRATION.md for what was verified. On-screen testing is still to do.

## 1. Why

Measured on your real library (Staging/CoreDataBench): bulk writes are 6–16× faster, list
edits 14–60× faster, and the full load is 7.6× faster. That takes the biggest bulk edit
from 4.3 s to 0.27 s, well inside the 10 s quit timeout.

## 2. Architecture

| SwiftData | Core Data replacement |
|---|---|
| `@Model` classes | `NSManagedObject` subclasses with the same names, properties and Swift types (`Int`, `Bool`, `[String]`, `Int?`, `Bool?` …), so call sites and snapshots don't change |
| `Schema([...])` | `LibraryModel.shared`: one `NSManagedObjectModel`, built in code (no .xcdatamodeld) |
| `ModelContainer` | `NSPersistentContainer` (`LibraryStore.makeContainer`) |
| `ModelContext` | `NSManagedObjectContext` |
| `container.mainContext` | `container.viewContext` |
| `@ModelActor` | An actor whose executor is its own private-queue context (`ContextExecutor`), the pattern SwiftData's `DefaultSerialModelExecutor` uses internally. Actor code runs inside the context's queue, so bodies don't need `perform {}` |
| `FetchDescriptor` + `#Predicate` | `NSFetchRequest` built by `Model.request(_:sortedBy:limit:)`; predicates through small helpers (`.in("id", ids)`, `.equals("id", id)`) |
| `PersistentIdentifier` | `NSManagedObjectID` |
| `ModelContext.didSave` notifications | `NSManagedObjectContextDidSave` |

- **Store file:** `FilmTracker.sqlite` in Application Support (sandbox: `<sandbox>/FilmTracker.sqlite`). The old `default.store` is never opened or deleted, so the SwiftData build still works as a rollback until you remove the file by hand.
- **Arrays:** `[String]` attributes are transformable through `NSSecureUnarchiveFromData` with `NSArray`. This is the fastest variant measured. There's no JSON wrapper (that was SwiftData's encoding).
- **Change history:** off. Nothing reads it.
- **Merge policy:** the view context merges background saves automatically (`automaticallyMergesChangesFromParent`), as SwiftData's mainContext did.
- **Indexes:** Film.id, ListObject.listID and SavedSearchObject.searchID, as now.
- **SettingsObject.snapshotID:** not unique-constrained. The coordinator already removes duplicate settings rows.
- **Relationships:** cascade and nullify rules match the current model. To-many sides are optional, which Core Data's batch delete needs. Inverses are reliable in Core Data, so the explicit inverse repairs become no-ops and are kept for now; removing them is a follow-up.
- **`ReleaseObj`'s `@Attribute(originalName:)`:** dropped. It only existed for SwiftData migration.

## 2a. Restore: staged store, swapped in at launch (2026-10-29)

The first port erased the live store in place while the app still had it open. The review
showed a late write from the old session then landed in the restored library (proven with
a standalone probe), and the harness crashed on it. Restores now never touch the open store:

1. **Stage.** DBRestorer stages the backup's posters in `FilmTracker-restore-Posters`, then
   fills `FilmTracker-restore.sqlite` (single-file journal) beside the live store. Before
   saving, it removes memberships or releases missing their film or list and clears release
   links that cross films or run too deep. After saving, it checks that every inserted row
   landed. The whole stage is tried twice, from an empty store each time.
2. **Commit.** It takes a digest of what it built (`StoreInspection`: per entity, row count
   plus a SHA-256 over every attribute and to-one relationship). It closes the staged store
   and runs `PRAGMA integrity_check`. Then it reopens the store in a fresh container, which
   must match that digest with no structural problem. Last, it writes the
   `FilmTracker.pending-restore` marker with the digest, the model hash and the file's
   SHA-256. A failure before this deletes the staged store, and the library is untouched:
   the alert just says OK. After this, a restart is required.
3. **Swap at launch.** `FilmTrackerApp.init` runs this after the instance lock and before the
   container opens (`PendingRestore.applyIfPending`).
   - Before anything is touched, the staged store must pass `PRAGMA integrity_check` and
     still hash to the commit's SHA-256.
   - It copies the live store to `FilmTracker-pre-restore.sqlite`, the rollback (only the
     latest is kept). A store Core Data cannot copy is moved there instead, all or none.
     The marker records this before the move starts.
   - It copies the staged store over the live one (`replacePersistentStore`). Then it opens
     the live store as the app will and checks it against the commit's digest. If the model
     changed in between, only row counts are compared. The restored settings row is read
     in the same pass.
   - On any failure the previous library is put back (moved back, or copied back from the
     rollback; removed if there was none), and the user gets an alert before the window
     opens.
   - On success the posters move into place, the settings are applied to Preferences, and
     the Up for Rotation baseline is cleared. Then the marker is deleted first and the
     staged files after it, so a marker never outlives its store.
   - Each step can be repeated after an interruption.

"Create New Library" uses the same path with an empty staged store. The UI is unchanged:
the same locked progress sheet and the same Quit and Restart button. The only new alert is
the launch-time "Restoration Could Not Be Completed".

## 3. File by file

| Area | Files | Work |
|---|---|---|
| Stack | new `11.05 LibraryStore.swift` | Container, model, executor, request and predicate helpers |
| Models | 61–67 | Rewritten as NSManagedObject subclasses; the inits keep their signatures |
| Persistence actor | 11.10 DataManager | Context actor; every fetch, predicate and insert ported. DirectStoreReader later removed: the dictionary fetch it stood in for is ~4 ms under Core Data |
| Launch load | 11.20 MemoryStore, 11.21 MemStoreCache | The cache-miss load reads through a context. Moving it to a background context is a follow-up (SwiftData forced the main thread) |
| Coordinator, app | 11.00 DataCoordinator, 10.00 FilmTrackerApp | Container creation, the in-memory fallback, the settings singleton |
| Backup | 83.00 DBExporter, 83.20 DBReader | Read from a fresh context. BackgroundExportReader becomes a context actor. The Mirror-based default extractor is dropped (every model has its own) |
| Restore | 84.00 DBRestorer, 11.05 LibraryStore (PendingRestore) | Builds the restored library in a staged store beside the live one, checks it, and commits it with a marker; the next launch swaps it in before the store opens (see §2a). Format and parsing logic unchanged |
| Imports | 28.10 ImportProgress, 28.20 ImportHistory, 28.00 ImportsView | Context and save notifications |
| Settings UI, other | 40.00, 43.00, 44.00, 20.00 MainView, 95.00 | Type names only |
| Harness | 99.10–99.57 | Ported so the DEBUG build compiles and the store checks still run |
| Leftover `import SwiftData` | 23.00, 23.60, 23.70, 23.71, 24.15, 25.00, 70.00, 72.00 | Removed |

## 4. Cutover (for you, once integrated)

1. With the current build, make a manual backup (Settings ▸ Export). Auto-backups also work.
2. Install the Core Data build. It opens an empty `FilmTracker.sqlite`.
3. Restore that backup (Settings ▸ Restore), then relaunch.
4. Check the library. `default.store` stays put as a rollback; delete it when you're satisfied.

Safety in step 2: the empty library skips the poster pruner (an existing guard declines an
empty valid-UID set) and the launch auto-backup (added at integration). Auto-backups keep
only the 3 newest; without that guard, a few empty launches would have replaced every real
auto-backup with an empty one. Manual backups are never pruned.

Deleting the app's container instead (a clean start) also deletes its `Backups` and
`PosterImages` folders, so restore from a backup kept outside it.

## 5. Testing

- **Builds:** the test copy builds clean in Debug and Release under Swift 6.
- **Parity hooks** (real project, by name only): `parity-export` and `parity-restore`
  (FT_PARITY_PACKAGE); compare stores with an independent script.
- **Self-check hook** (test copy only, `-FTCoreDataSelfCheck`, sandbox only): restores your newest auto-backup into the sandbox's fresh Core Data store with the real DBRestorer, exports it with the real DBExporter, and compares the two XML files object by object and property by property. It also runs the DataManager operations against the restored store and times them.
- **Harness (ask first):** `all` in a sandbox, then `full`.
- **On screen (you):** a test-build launch in a sandbox with your restored library.

## 6. Open questions

1. First launch with no Core Data store: show the empty library and leave restoring to you (planned), or offer to restore the newest auto-backup automatically?
2. Remove the SwiftData-era workarounds (explicit membership deletes, detached DataManager calls) after the harness confirms Core Data's behavior? The inverse repairs in DataManager and DBRestorer are already gone: Set-typed relationships can't append, and Core Data maintains inverses.
