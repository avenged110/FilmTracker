# Harness: Known Failures

Failures that also occur on the current **SwiftData** build. They are not caused by the Core
Data migration. Found 2026-10-29 while verifying the Core Data test copy. These are candidates
to fix later. Each one says where it showed up, so it can be reproduced.

**How they were checked:** the SwiftData Debug build of the real project, run on two kinds of
sandbox:

- **Empty:** a fresh, empty sandbox.
- **Real:** a read-only copy of the live library (1,400 films), made with SQLite's backup API.

**Run names:**

- **"Alone":** a comma list of just the named scenarios.
- **"Full":** `-FTDebugHarness full`.

## Triage (2026-10-29, Core Data build)

Run alone on the integrated Core Data build:

| Failure | Verdict |
|---|---|
| `guide-sync` "not edited" | **Real (documentation).** SearchToken accepts "not edited" as an alias of `unedited`; the Search Guide's Editing row doesn't list it. |
| `backup-integrity` export 14 vs 13 | **Harness.** `seedFullGraph` now adds a saved search; the expected count wasn't updated. The export is correct. |
| `rollback-integrity` `hof-add` and `queue-exclusivity-move` `/dispatched-a-tracked-write` | **Harness.** They pass on an empty sandbox. On a real library the scenario adds 3 films to a Hall of Fame with one free slot (199 of 200) and a film to a full Up Next, so the app correctly refuses and nothing is written. |
| `sidebar-disclosure` `rows-accounted`, `expanded-children` | **Harness.** They pass on an empty sandbox. `rowTitles` doesn't know the Saved Searches section, which appears once a saved search exists. |
| Hall of Fame cluster on real data | The "two films at position 200" premise was wrong: the live library and its backups are dense 1–199. The setup problem above is the likely cause; not re-run in `full`. |

## Fail every time

| Scenario / check | Where | Detail |
|---|---|---|
| `guide-sync` / `guide-sync/is-term/not edited` | Empty and real, alone and full | The guide doesn't list the Is term "not edited" as `<code>not edited</code>`. Probably the guide was never updated when bulk edit added the term. |
| `backup-integrity` / `export-verification:written-file-describes-the-library` | Empty and real | "the produced file re-parses to 14 object(s), expected 13". The export has one more object than the check expects. Possibly the app's own settings sync adds a settings row, and the expected count doesn't allow for it. |
| `sidebar-disclosure` / `rows-accounted`, `expanded-children` | Alone (empty and real), full (real) | Sidebar row accounting doesn't match. It passed in a Core Data full run on an empty sandbox, so it may depend on scenario order or on the data. |
| `rollback-integrity` / `queue-exclusivity-move/dispatched-a-tracked-write` | Alone and full | "0 injected failure(s)": the case never reaches persistence, so it proves nothing. |
| `rollback-integrity` / `hof-add/dispatched-a-tracked-write` | Alone and full | Same as above. |

## Fail only in a full run on real data

| Scenario / check | Count | Detail |
|---|---|---|
| `rollback-integrity` / `*/hof-positions-dense` | 23 cases | Hall of Fame positions come back as `[1, 1, 2, …]`, which isn't dense. The live library has **two films at Hall of Fame position 200**, a data issue worth fixing in the app too. These pass when run alone. |
| `rollback-integrity` / `hof-remove`, `hof-reorder` `/dispatched-a-tracked-write` | 2 | "0 injected failure(s)", as above. |
| `rollback-integrity` / `hof-reorder/store-restored`, `wishlist-reorder/store-restored` | 2 | After the rollback, the store differs from before (a film's `hofPosition` is 198 instead of 2, and the reverse). |
| `rollback-integrity` / `hof-reorder/published-films-agree-with-store` | 1 | 199 of 1,605 published snapshots differ from the store. |
| `film-field-merge` / `e2e/hof/background-entered` | 1 | "position 0". |
| `restore-endtoend` / `restored-store-readable` | 1 | **SwiftData build only.** It passes on Core Data, where restores are staged. |

Seen 2026-10-30 in a 33-scenario data-layer comma list on real data. Each passes when its scenario runs alone on the same copy, so they come from state earlier scenarios leave behind:

| Scenario / check | Count | Detail |
|---|---|---|
| `bulk-edit-check` / `store holds all N films` | 3 | The films it picked are no longer all in the store. |
| `restore-endtoend` / `restore-cache/seeded-before-restore` | 1 | "cache files present: [false, false]": `saveImmediately()` wrote nothing, likely because cache persistence was still suspended. |
| `rollback-integrity` / `membership-persistence/queue-move-lands-in-exactly-one-section`, `…/queue-move-agrees-with-memory-store` | 2 | "persisted section(s): none". Probably Up Next is full on this library, as with the `dispatched-a-tracked-write` cases. |

The Hall of Fame failures most likely share one cause: the duplicate position at 200, plus
earlier scenarios in `full` changing the copy. Start there.

## Flaky (not compared on SwiftData)

| Scenario / check | Detail |
|---|---|
| `releases-settle` / `confirmed-settle/*` (4 checks) | Failed once in a long Core Data run ("attached sheet: false"), then passed alone. Probably window focus. |
| `report-gutter-deselect` / `row-click-still-selects` | Failed once in a long run, then passed alone. Probably focus. |

## Harness notes

- `backup-graph-roundtrip`'s old crash (DHBackup.swift:1104) was a Core Data port bug: it read
  objects whose context had been released. It's fixed in the test copy, so it isn't listed
  above.
- The harness report is written only at the end of a run, so a crash partway through loses
  every result.
- `bulk-edit-check` fails "four films outside the Queue and Hall of Fame" on an empty sandbox.
  That's a precondition: it needs a real library copy (see its header), where it passes.
