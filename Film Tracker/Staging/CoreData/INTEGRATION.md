# Core Data Replacement: Integration

**Integrated into the real project on 2026-10-29** (uncommitted). It was built in the test
copy, `Xcode projects/Film Tracker - Core Data Test`, which is now only a reference. The
real project had drifted from that copy's baseline only by the build number (54) and the
parity hooks, both merged.

Left out at integration: the test build's sandbox-only launch guard and its self-check
(`-FTCoreDataSelfCheck`, 99.95). The parity hooks replace the self-check.

## Fixes made at integration

| Fix | Why |
|---|---|
| No launch auto-backup of an empty library (`10.00`) | Auto-backups keep only the 3 newest. Before a first restore the library is empty, so a few launches would have replaced every real auto-backup with an empty one |
| The launch swap re-checks the staged store (`PRAGMA integrity_check`) before touching anything | `replacePersistentStore` copies whatever file it is given; probed with a damaged staged file, which replaced a healthy library |
| A failed swap moves rollback files back only when this swap moved them (`Marker.rollbackMoved`) | An older restore's rollback could otherwise have been put in place of a missing library |
| Quit and Restart waits for the old process to exit before `open` | `open` only activates an app that is still running |
| `makeContainer` creates the store's folder | A fresh container has none; Core Data recovered by itself, but only after a logged failure |
| Post-commit failure message reworded | The old text said the previous database "has already been replaced", which is no longer how restores work |
| Launch swap alert skipped in harness runs | A modal alert hangs a headless run |

## Persistence audit (2026-10-29, after integration)

| Change | Why |
|---|---|
| Exports pin their context to one query generation (`DBReader.exportAll`), on writable WAL stores only | Each entity is a separate fetch, so a write between two of them mixed two moments in one backup (true under SwiftData too). Probed: a pinned context ignores later saves. On a read-only store the pin is accepted but every later fetch fails, which `backup-repeatability` caught, hence the guard |
| `sandbox-integrity` checks the store, staged and rollback files are inside the sandbox; the production fingerprint watches `FilmTracker.sqlite` and the pending-restore marker | Both still named SwiftData's `default.store`, so after the cutover the leak detector watched a file that no longer exists. The first run in an existing sandbox reports the fingerprint as changed once (new file list) |

Reviewed and left as is, with reasons:
- DataManager's long-lived context is never reset, so objects linked both ways stay registered. Harmless: DataManager is the only writer of films, releases, lists and memberships; the view context writes only settings and import sessions, which DataManager never caches.
- View-context saves (settings, import sessions) don't roll back on failure. Keeping a failed settings change pending means the next save retries it, which is what SwiftData's autosave did.
- Only the newest rollback store is kept, so a second restore replaces the first rollback. The alerts already say a restore can't be undone; timestamped rollbacks would be an extension.

## Verification (2026-10-29, integrated build)

- **Builds:** Debug and Release clean, with no warnings. The Release binary links only Core Data.
- **Parity:** the 12:28 auto-backup was restored through the real path (stage, commit, real relaunch swap) under `-com.apple.CoreData.ConcurrencyDebug 1`.
  - Against a SwiftData restore of the same file, 4,431 records and 182,219 fields were identical. Only `lastSyncDate` differed, plus the JSON key order of the sort selections (the same 20 values).
  - The Core Data build's re-export matched the original `backup.xml`: 4,431 objects and 180,132 properties, with only `lastSyncDate` differing. All 1,400 posters were restored.
- **Harness, `full` on an empty sandbox (before the fixes above):** 2,938 passed, 2 failed (both known).
- **Harness, data-layer scenarios only (after the fixes), with concurrency assertions on:**
  - Empty sandbox: 1,460 passed, 2 failed (the known export check, and `bulk-edit-check`, which needs a real library).
  - Copy of the restored real library: 1,564 passed, 3 failed (all in HARNESS-KNOWN-FAILURES.md).
- **Launch swap probes:**
  - A damaged staged store with a healthy library: the library is kept and the marker is cleared.
  - A damaged staged store with no library and an older rollback present: the rollback is left alone and an empty library opens.
  - Inferred schema migration works with the code-built model (Core Data keeps the model in the store's Z_MODELCACHE).
- **Not verified:** anything on screen (the restore sheet, Quit and Restart, the launch alert, Create New Library); a crash midway through the copy itself.

## What changed, by area

| Area | Change |
|---|---|
| `11.05 LibraryStore.swift` (new) | The model in code (attribute tables per entity, relationships, indexes), container creation and store erase. Also `ContextExecutor`, the `LibraryObject` base class, typed `request(...)`, the predicate helpers and `context.commit()` |
| Models 61–67 | NSManagedObject subclasses with the same properties and Swift types. `Int?`/`Bool?` are computed over NSNumber; to-many relationships are `Set<…>`. The all-defaults models (Film, ListObject, SettingsObject) declare `init()` so `Film()` keeps its defaults |
| `11.10 DataManager` | A context actor. Fetches, predicates and count queries are ported. Inverse repairs are removed (Core Data maintains inverses). The fingerprint fallback is a dictionary fetch of 4 columns |
| `11.20 MemoryStore` | The cache-miss load runs on a background context instead of the main thread |
| `28.20 ImportHistory` | `didSaveObjectIDsNotification`. The willSave capture is no longer needed |
| `83.20 DBReader`, `83.00 DBExporter` | BackgroundExportReader is a context actor. The manual export reads a fresh main-queue context. The Mirror-based default extractor is removed |
| `84.00 DBRestorer` | Stages the restore in a separate store and commits it; the launch swaps it in (PLAN §2a). Settings apply from the staged store |
| `10.00 FilmTrackerApp` | Runs `PendingRestore.applyIfPending()` before the container opens; launch alert if the swap fails |
| `10.00 FilmTrackerApp`, `20.00 MainView` | The container comes from LibraryStore. The environment carries `\.managedObjectContext` |
| `60.00 Snapshots` | The `init(from:)` methods are no longer MainActor (they run on the context's queue) |
| Harness | Ported: container helpers, read-only verification opens, the schema coverage now reads LibraryModel. Its main-thread contexts are main-queue |
| Comments and logs | "SwiftData" now reads "the store" or "Core Data" wherever it named the persistence layer. Historical notes say "the SwiftData build" |

## Follow-ups (after the harness)

- Remove the SwiftData-era workarounds that Core Data makes unnecessary, if the harness agrees:
  - the explicit membership deletes before a cascade;
  - the detached tasks around DataManager calls;
  - the `DataManagerThreadProbe` expectations.
- Optionally use `NSBatchUpdateRequest` for bulk field edits. It needs no schema change, but the gain is small.
- Docs: replace "SwiftData" in the User Guide or README, if it's mentioned there.

## Follow-up work (2026-10-29, uncommitted)

- **Membership cascade proven** (`membership-cascade`, in the pipelines suite). Each case runs with the explicit deletes and with them off (`DataManager.cascadeOnlyForTesting`, or `-FTCascadeOnlyMemberships`), on its own on-disk store, audited after every step with raw SQL against a shadow model. There's a control that proves the audit catches orphans. The cases cover: same session, after relaunch, a film in many lists, changeset, move/re-add, a raw context (insert+delete in one save, faults, reset, rollback), a view-context merge, a foreign-context insert, 3 × 1,500-step fuzz, and the whole real library. All pass in both modes. The data-layer scenarios also pass with `-FTCascadeOnlyMemberships` under ConcurrencyDebug. The explicit deletes are still in place, pending the user's go-ahead.
- **Stale-relationship gap fixed:** deleteList (both modes) missed a membership another context saved after DataManager loaded the list's relationship. deleteFilms and deleteList now refresh the object before deleting it.
- **Uniqueness constraints** on Film.id, Release.id, ListObject.listID, ListMembership.id, ImportSession.id and SavedSearchObject.searchID replace the plain ID indexes. Core Data refuses to migrate a store that repeats an ID, so `StoreDeduplicator` repairs one in SQL before the container opens. It reads only tables missing their unique index, read-only, and never through Core Data: a metadata read on a store erased in place broke the harness. The restore keeps the first of a repeated ID (`keepFirst`). A duplicate insert now merges into the existing row (trump policy) and keeps its relationships.
- **Bulk edit batch path:** applyFilmFields uses one NSBatchUpdateRequest when every field is a scalar with one value across the films. 1,600 films × 1 field: 46 ms, against 403 ms for the object path (`-FTBulkEditObjectPath`). Afterwards only the registered objects are refreshed; mergeChanges(fromRemoteContextSave:) cost 250–330 ms on the main thread.
