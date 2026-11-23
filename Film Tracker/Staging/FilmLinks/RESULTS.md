# Film links: verification results (2026-11-22)

Source: the live library copied read-only with SQLite's backup API before this build ever
opened it (1,410 films, 12 lists, 213 memberships, 2,969 releases, 48 import sessions,
3 saved searches, 1 settings row). The live store was never opened by the new build and still
has no `ZFILMLINK` table.

## How to rerun

1. Copy the live store (Python `sqlite3` backup API, percent-encoded `file:` URI, `mode=ro`) to
   `DebugSandboxes/filmlinks-source/premigration.sqlite`, made read-only, and into a fresh
   `DebugSandboxes/filmlinks-run/FilmTracker.sqlite`. The app is sandboxed: the source must sit
   inside its container.
2. Run the Debug binary:
   `Film Tracker -FTDebugSandbox filmlinks-run -FTDebugHarness film-links -FTFilmLinksPremigration <…/premigration.sqlite>`
3. `python3 compare_stores.py <premigration.sqlite> <filmlinks-run/film-links-probe/migrated.sqlite>`

## Results

| Run | Result |
|-----|--------|
| `compare_stores.py`, pre-migration vs migrated | **PASS**: 4,656 rows across all 7 existing tables identical (attributes, and relationships compared by ID); `ZFILMLINK` new and empty. |
| `compare_stores.py` control (3 planted differences: a name, a release's film, a deleted membership) | All 3 reported. The comparison can fail. |
| `compare_stores.py`, store migrated by the sandbox launch itself | Identical apart from the settings row, which the sandbox launch overwrites with defaults (expected; not the migration). |
| `film-links` scenario | **48 / 48**: migration (about 155 ms to open including the migration, counts unchanged, columns, unique ID index), rules, pair rewrite, relaunch, edits, delete cascade (3 ways), remove, cleanup (all 5 kinds of damage, oldest kept, idempotent), every other entity untouched, backup round trip (8 links identical to the second), a hand-edited backup with 7 bad links (only the valid addition restored, structural check clean), deleting both linked films in one call, a damaged pair repaired by setting it, and the rule-checker at scale (5,000 links in 200 chains: 64 ms in Debug; one pathological 2,500-film chain: 1.4 s, quadratic, no real library has one). |
| Data-layer regression set (core, library orders, store, pipelines, backup: 38 scenarios incl. `film-links` and `datamanager-thread`) | **1,660 pass, 0 fail.** |
| Store metadata after migration | Store UUID kept, next-row counters (Z_MAX) kept, `integrity_check` ok. Core Data renumbers entity codes after Film (Release 5 → 6) and rewrites every row to match; nothing persists object IDs across launches, so this is invisible. |
| Debug and Release builds | Clean, no warnings. |

## Found and fixed while iterating

- The scenario's pre-migration reads failed silently: a WAL-mode copy can't be opened read-only
  without its `-shm`. It now reads the copy writable and refuses a vacuous pass.
- `backup-integrity` hard-coded the seeded graph's object count; it now counts the film link.
- The restorer logged every membership, release (and now link) as an "unknown entity type"
  during its first pass (about 3,200 lines for this library). The first pass now skips the
  three entities its second pass creates. Pre-existing; fixed because it was in the code touched.

## Adversarial review (same day)

- `setFilmLink` on a pair holding two links (only before the launch cleanup has run) left the
  second one and could refuse a valid link as a loop because of it. Now every link on the pair
  is left out of the loop test, the oldest is rewritten and the rest deleted.
- The restore claimed a repeated ID for its first copy before the rules ran, so a broken first
  copy hid a valid second one. Now only a kept link claims its ID (`sieve`'s `id`).
- The rule-checker rebuilt its graph for every link (quadratic in all links); it now builds it
  incrementally (`FilmLinkRules.Graph`) and compares kinds by one key (trimmed, case-folded).
- An earlier version of this file gave the migration as 3.3 s; the measured figure is about
  155 ms.
- Checked by reasoning and found sound: Film edits, imports and batch updates never write the
  link relationships; only `deleteFilms` deletes films, and it refreshes first; a staged restore
  from the old build swaps in with a counts-only check where a missing FilmLink counts as 0;
  `StoreDeduplicator` repoints link columns only where the table exists.

## Not covered

- An older build reading a new backup was checked by reading the code (it skips the unknown
  entity type), not by running an older build.
- An older build opening a migrated store was not tried (it would drop the links table).
- No UI exists yet, so nothing was checked on screen.

## Memory layer (2026-11-23)

Scenario `film-links-memory` (DebugHarness/99.64), on a fresh copy of the real library
(1,410 films), 114 checks, all pass:

- Isolated MemoryStore: relations from both ends, pair lookup, the rule check (the pair's own
  link left out), rewrite in place, one link per pair, an ID moved off another pair, removal,
  deleted films' links hidden / revived / pruned, a cycle-safe walk, change notifications, the
  reverse index rebuilt from scratch after every step.
- Snapshot cache: payload round trip exact (fractional and negative dates, non-ASCII kind);
  fingerprint order-independent and moved by every change a write can make (kind, kind case,
  ends swapped, other target, ID, removed, added, kinds traded); FNV-1a reference values.
- The sandbox's own coordinator against the real store: memory equals the store field for
  field and the live and stored fingerprints agree on the link layer after every case; writes,
  a refused cycle, an identical write dispatching nothing, a rewrite keeping ID and date,
  removal; injected persistence failures (single, fail-then-succeed, succeed-then-fail, fail
  twice, a failed removal); a linked film's delete rolled back, two linked films' deletes both
  rolled back, a delete that persists (links pruned); the launch cleanup with a self-link, an
  older second link on a pair (memory's link is the one removed) and an orphan injected into
  the store; the next launch in a second MemoryStore: fast path loads the links from the cache
  exactly, a store-only link forces the slow path (LINK-ONLY miss) which leaves it out.
- Live fingerprint with links: about 4.5 ms in all at 1,416 films (Debug).

Data-layer regression set, 41 scenarios (adds `film-links-memory`): **1,800 pass, 0 fail,
0 skip.** Debug and Release builds clean.

Found and fixed during the review:

- The launch cleanup and a user's link write could interleave on the data actor, so the
  cleanup's memory sync could undo a newer write. The cleanup now runs as a tracked operation.
- The live fingerprint read links as objects, faulting both films one query at a time on the
  fast-launch path; now one column-only fetch.
- Pruning scanned every link after every operation; it now runs only when a delete could have
  left something to prune.

First launch of this build on the real library: one slow launch (the cache format moves to v7
and the fingerprint file gains two fields, both read as a miss), then fast as before.

## Audit (2026-11-23)

Whole film link stack (rules, model, DataManager, StoreInspection, StoreDeduplicator, backup and
restore, MemoryStore, snapshot cache, DataCoordinator, launch). No correctness bug found in the
paths already shipped to memory; these were changed:

- **Picker-scale rule check.** `filmLinkProblem` rebuilt the whole rule graph, kind strings
  folded and pair IDs turned into strings, for every check: about 480 ms (optimized build) for a
  1,400-film picker against 300 links. It now answers from a graph cached until memory changes,
  and `FilmLinkRules.Graph.closesCycle` leaves the pair's own link out by not following a direct
  `target → source` link, so one graph serves every pair. 1,400 checks against 302 links: about
  5.5 ms in Debug. Checked equal to the uncached test for every pair of 8 films.
- **UUID order without strings.** `Pair` and the oldest-first tie-break compare the two 64-bit
  halves of each UUID, which is the order their uuidStrings sort in (checked on 2,000 random
  pairs and a byte-boundary case), without allocating two strings per link.
- **Date in the link fingerprint.** The date orders links (which one the rules keep, the order
  they are listed in), so a snapshot cache that differed from the store only in a date would
  have shown an order the store would not. The live side reads one more column. Exact bits
  carry through the store, memory and the cache's JSON; the live and stored fingerprints agree
  after every live case.
- **Simpler surface.** DataManager's `fetchFilmLinks`, `fetchFilmLinks(for:)`, `setFilmLink` and
  `removeFilmLink(id:)` are Debug-only (only the harness calls them); the unused
  `FilmLinkSnapshot.involves`, `says(sameAs:)` and `FilmLinkKind.same` are gone; the cleanup's
  cancellation check is gone (a tracked operation is never canceled, so it could not fire);
  the redundant SQL sort before the in-memory sort is gone; `removeFilmLink(id:)` looks the link
  up by ID instead of sorting every link.

Checked and left as is: every film delete goes through the one tracked `deleteFilms` (and the
new-film and import rollbacks, which hide links the same way); the pending count rises at
dispatch, so pruning cannot run while a delete is queued; shutdown drops new operations and
lets queued ones finish; the slow-path sieve and the launch cleanup read the same rows in the
same order; the restore normalizes kinds and sieves with IDs; StoreInspection's pair check;
cache decode drops links naming a missing film.

`film-links` 44/44 and `film-links-memory` 120/120 (11 new checks: graph staleness after a
write, removal, delete and put-back, pair link left out, cached equals uncached, UUID order,
picker timing; fingerprint moved by the date and by traded dates, each variant isolating one
change). Data-layer set, 41 scenarios as before: **1,811 pass, 0 fail, 0 skip** (1,800 + the 11
new). Debug and Release builds clean.

## Backup and restore review (2026-11-23)

Traced every path a link takes through a backup: export (DBReader, DBPackager, the export's
read-back verification), parse (DBImporter), restore (DBRestorer's passes, repairStructure, the
saved-row check), the staged commit and the launch swap (PendingRestore, StoreInspection,
StoreDeduplicator), and the restore preview. Restoring a backup that has no links is safe on
every path: the restorer creates none, the manifest check reads only the entities a backup
names, and the swap's row-count comparison treats a missing FilmLink entry as 0.

Changed:

- **Links dropped for a missing film are logged.** A link naming a film the backup does not
  restore was skipped without a word; the restore now logs how many, once.
- **Tests for what was only reasoned about** (`film-links`, 16 new checks):
  - `old-backup/*`: this run's export with every link object and the FilmLink manifest entry
    removed (exactly what an older build writes) restores every other row, no link, no
    structural problem, and the restored library takes a link that survives a relaunch and
    the launch cleanup.
  - `real-old-backup/*` (`-FTFilmLinksOldBackup <package>`; its XML is kept at
    `DebugSandboxes/filmlinks-source/pre-links-backup.ftbackup`): the same for your real auto-backup
    of 22 Nov 21:58 (app 1.1.0, before film links): all 1,410 films, 2,969 releases, 213
    memberships, 12 lists, 48 import sessions, 3 saved searches and the settings row restored
    at their manifest counts.
  - `old-staged/*`: a restore an older build staged and committed (old schema, rollback journal,
    a marker digest from the old model with no FilmLink entry) is migrated, checked by row
    counts and swapped in by this build's launch with every row kept; a control whose marker
    claims one film too many is refused, so the pass is the check passing.
  - `backup/bad-links-dropped` now includes the same-kind cycle its header claimed (it had
    none): a two-link chain is kept and its newer closing link dropped.

Checked and left as is:

- **Backup dates are whole seconds** (ISO 8601 without fractions, for every entity). For links
  this was fixed afterwards, at your request (below).
- **The restore preview** (Settings › Restore) counts films, lists, releases and saved searches,
  not links; restoring an older backup replaces a library's links with none and nothing says
  so. That belongs to the UI phase.
- **An older build reading a new backup** skips the links, logging one line per link.

Results: `film-links` 60/60 (pre-migration copy, real old backup passed in). Data-layer set,
41 scenarios on a fresh copy: **1,827 pass, 0 fail, 0 skip** (1,811 + the 16 new). Debug and
Release builds clean.

### Exact link dates (same day, follow-up)

A link now also exports `dateAddedExact` (seconds since 2001, written in Swift's shortest exact
form) beside the whole-second `dateAdded`. The restore uses it when it is within a second of
`dateAdded`, otherwise `dateAdded` (logged), so a hand-edited date still wins; a backup without
it restores as before. Builds before film links skip the whole entity, so no older reader sees
the new property. `backup/links-identical` now compares exact date bits (5 of the 9 source links
have sub-second dates, checked by `backup/source-has-fractional-dates`), and the hand-edited
cases exercise the fallback. `film-links` 61/61; data-layer set 1,827/0 before that one check was
added; Debug and Release builds clean.
