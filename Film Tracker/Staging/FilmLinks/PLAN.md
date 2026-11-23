# Film links: database plan

Status: database side and memory layer implemented and verified on a copy of the real
library (see "Verification" and "Memory layer"). No UI yet.

## Goal

Let one film be recorded as related to another ("Film 2 is a remake of Film 1",
"Film 4 is a sequel to Film 3"), so the relation lives in the store, survives edits,
goes away with either film, and makes the round trip through a backup.

## Model

A new entity, `FilmLink` (`64.10 FilmLinkObj.swift`), shaped like `ListMembership`:

| Property      | Kind                  | Notes                                                   |
|---------------|-----------------------|---------------------------------------------------------|
| `id`          | UUID, unique          | Same uniqueness constraint every entity has.            |
| `kind`        | String                | Open vocabulary, `FilmLinkKind` (Sequel, Prequel, Remake, Reboot, Spin-off). An unknown value round-trips untouched, like every other stored vocabulary. |
| `dateAdded`   | Date                  | Picks the survivor when the startup cleanup finds two links on one pair. |
| `sourceFilm`  | to-one Film, nullify  | The film the sentence is about: "**source** is a *kind* of target". |
| `targetFilm`  | to-one Film, nullify  | The film it relates to.                                 |

On `Film`: `outgoingLinks` (inverse of `sourceFilm`) and `incomingLinks` (inverse of
`targetFilm`), both to-many, both **cascade**. Deleting either film deletes the link; deleting
a link touches neither film. The reverse sentence ("Film 1 was remade as Film 2") is derived
when shown, never stored, so the two sides can never disagree.

Columns: `ZFILMLINK` with `ZID`, `ZKIND`, `ZDATEADDED`, `ZSOURCEFILM`, `ZTARGETFILM`.

## Rules (the invariants)

1. **No self-links.** A film is never linked to itself.
2. **At most one link per film pair**, in either direction and of any kind. Setting a link on a
   pair that already has one replaces it (new kind or new direction). This rules out
   contradictions such as "A is a sequel of B" together with "B is a sequel of A", and two
   rows saying the same thing.
3. **No cycles within one kind.** "A sequel of B, B sequel of C, C sequel of A" is refused:
   chains of one kind are always finite, so a later "walk the series" UI cannot loop.
   Different kinds may form loops (they are different statements).
4. **Both ends exist.** A link without either film is an orphan and is removed.

Rules 1, 2 and 3 are enforced by the one write path (`DataManager.setFilmLink`), by the restore,
and (1, 2, 4) by the launch cleanup. `StoreInspection` reports a link breaking 1, 2 or 4 as a
structural problem, so a staged restore holding one is refused.

## Write API (DataManager, background context, one commit per call)

- `saveFilmLink(_ snapshot)`: see below. Throws `FilmLinkError` for a self-link, a missing
  film, an empty kind or a cycle; the store is unchanged when it throws.
- `removeFilmLinks(between:and:)`.
- `cleanupFilmLinks() -> FilmLinkCleanup`: runs at launch, after the membership cleanup, as a
  tracked DataCoordinator operation.
- Debug only, for the harness: `fetchFilmLinks()`, `fetchFilmLinks(for:)`,
  `setFilmLink(source:target:kind:)` (built on `saveFilmLink`, reusing the pair's oldest ID
  and date) and `removeFilmLink(id:)`. The app writes only through DataCoordinator.

`FilmLinkSnapshot` (Sendable, Codable value: id, kind, sourceID, targetID, dateAdded) is what
memory holds and the UI reads, through DataCoordinator (see "Memory layer").

`saveFilmLink(_ snapshot)` is the write DataCoordinator sends: it makes the store's pair hold
exactly that link, ID and date included (creating the row, moving it off another pair, deleting
any other link on the pair), validated against the store as it is.
`cleanupFilmLinks` returns the counts, the removed IDs and, when it removed any, every link kept.

## Paths that had to learn about links

| Path | Change |
|------|--------|
| `LibraryModel` | Entity + two relationships. |
| `StoreDeduplicator` | `ZFILMLINK.ZID` deduplicated; `ZSOURCEFILM`/`ZTARGETFILM` repointed when a repeated film ID is removed. |
| `StoreInspection` | Structural problems for orphan, self and repeated-pair links. Digest covers the entity automatically. |
| `DataManager.deleteFilms` | Nothing: the refresh-before-delete it already does covers both new relationships, and the cascade removes the links. |
| `DBExporter.allModelTypes` | `FilmLink` added. Exported as properties `id, kind, dateAdded, dateAddedExact` (the exact date as seconds since 2001; backup dates are otherwise whole seconds), `sourceFilmID, targetFilmID`. |
| `DBRestorer` | Second pass creates links after films exist; drops links to films not in the backup, self-links, empty kinds, repeated IDs, repeated pairs and same-kind cycles (logged). `repairStructure` removes any orphan. The first pass no longer logs the join entities as "unknown". |
| Harness | `film-links` (new, in the store suite); `backup-schema-coverage`, `backup-graph-roundtrip` and `backup-integrity` seed and check one link. |
| Launch | `cleanupFilmLinks()` after the membership cleanup. |

Untouched, checked: film edits (`updateFilm`, `applyFilmFields` including the batch-update path,
`applyFilmChangeset`), imports (insert new films only), list operations. None of them write a
Film relationship other than releases and memberships.

## Compatibility

- **Upgrading a store:** inferred lightweight migration, the same mechanism the settings
  columns added since the Core Data move use (the code-built model is cached in
  `Z_MODELCACHE`). Adding an entity and two optional to-many relationships is an additive change.
- **Old backups:** have no `FilmLink` objects or manifest entry; they restore with no links
  (tested with a real pre-links backup, `real-old-backup/*`).
- **A restore an older build staged, swapped in by this one:** migrated at the swap and checked
  by row counts (tested, `old-staged/*`).
- **New backup into an older build:** the restorer skips an unknown entity type
  ("forward compatibility" branch) and checks only what it inserted, so it restores without the
  links.
- **Older build opening a migrated store:** inferred migration would drop the `ZFILMLINK`
  table (links lost, everything else kept). Only relevant if you go back to an older build.

## Memory layer

The UI reads links from memory, never from the store, like everything else.

| Piece | What it does |
|-------|--------------|
| `MemoryStore.filmLinks` + `filmToLinks` | Links by ID and a reverse index from each film (either end). A link is **live** while both films are in memory; every reader sees live links only. |
| Readers | `allFilmLinks()` (oldest first), `filmLinkRelations(forFilm:)` (`FilmLinkRelation`: the link read from one film's side, `isSource`, `otherFilmID`; ordered by kind, own sentences first, oldest), `filmLink(between:and:)`, `linkedFilmIDs(connectedTo:)` (cycle-safe walk, any kind), `filmLinkProblem(source:target:kind:)` (the rule check DataManager runs, for a UI to refuse a choice up front; answers from a rule graph cached until memory changes, so a picker can ask for every film: 1,400 checks against 302 links in about 5.5 ms in Debug), `filmLink(id:)`, `filmLinkCount`. |
| Loading | Fast path: from the snapshot cache (format v7 carries `links`). Slow path: read with the films and sieved oldest first exactly as the launch cleanup sieves the store, so memory never holds a link the cleanup removes. |
| Snapshot cache | Payload `links` (live links only). Fingerprint `linkCount` + `linkFingerprint` (`FilmLinkLayerDigest`: ID, both ends, kind and date chained through the SplitMix finalizer, kind hashed with FNV-1a so it is stable across launches, XOR across links). The live side reads it with one column-only fetch (no objects, no film faults). A cache can therefore hit only when memory's links equal the store's exactly. |
| `DataCoordinator` | `setFilmLink` (throws `FilmLinkError`; keeps the pair's ID and date on a rewrite; an identical write dispatches nothing), `removeFilmLink(between:and:)`, `removeFilmLink(id:)`, the readers above, and `filmLinksRevision`, an observed counter every reader touches, moved by `MemoryStore.filmLinksDidChange`. |
| Failed writes | Each write states a pair's whole content, so a per-write rollback would be wrong when two writes to one pair are queued. The coordinator keeps, per pair with writes pending, the content last known to be stored; when the pair's last pending write settles, memory is set to it. Covers fail-then-succeed, succeed-then-fail and fail-twice. |
| Film deletes | Memory keeps a deleted film's links, unseen. A failed delete puts the film back and its links are live again as the store still holds them, even when the film at the other end was deleted by a later operation that also failed. Once the operation queue drains, the unseen ones are pruned (every delete has then persisted, so the store cascaded them). |
| Launch cleanup | Runs as a tracked operation, in the same queue as link writes, and brings memory into line with what the store kept (normally nothing to do). A failure is logged, not alerted. |

Not in this phase: search tokens, smart lists, MetadataCache, any view.

## Verification

Scaffolding: `DebugHarness/99.63 DHFilmLinks.swift` (scenario `film-links`) plus
`Staging/FilmLinks/compare_stores.py` (SQL-level comparison of a store before and after
migration, matching rows by ID so internal row numbers don't matter).

1. Copy the live library with SQLite's backup API into two sandboxes (pristine + run).
2. Launch the Debug build on the run sandbox: the open performs the migration.
3. `compare_stores.py` pristine vs migrated: every pre-existing table identical row for row
   (attributes and relationships, by ID); `ZFILMLINK` present and empty.
4. `film-links` scenario on the migrated real copy, against the real films. See the scenario's
   header for the full case list.
5. Data-layer regression scenarios (store, pipelines, backup) on a fresh real copy.

Results are recorded in `RESULTS.md` beside this file.
