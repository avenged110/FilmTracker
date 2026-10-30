# Bulk Edit (MultiFilmSheet): Implementation Plan

Prepared 2026-10-28. Nothing in the real app target has changed. Everything is staged here,
in `Staging/BulkEdit/`, which sits outside the Xcode project. The project lists its files
explicitly, so nothing here gets compiled into the app. A full working copy lives in the
test build `Xcode projects/Film Tracker - Bulk Edit Test`, which is the source of truth
while we iterate (see its `TEST-BUILD-README.md`).

## Status (2026-10-29): integrated, first round of tweaks done

Integrated into the real project on 2026-10-28 (on top of commit `8d52e1c`), not yet
committed. The real project is now the source of truth. `App/`, `Patches/`, `Tools/` and the
test build `Film Tracker - Bulk Edit Test` are historical: don't re-run `integrate.sh` or
`sync_from_test_copy.sh`. `Rig/run.sh` now compiles the app's own `52.20 BulkFilmEdit.swift`
(94 checks). The test build's snapshot and self-check hooks are now DEBUG harness scenarios in
`DebugHarness/99.57 DHBulkEdit.swift`: `bulk-edit-shots`, `bulk-edit-check` (106 checks) and
`bulk-edit-perf`. None is in a suite; run them by name, on a sandbox.

**Round 1 (from the user, 2026-10-29):**
1. Two tabs through CustomTabs: **Details** (`square.text.square`) and **Selected Films**
   (`film.stack`). The description band is fixed under the tab bar on both. ⌥1/⌥2 and
   ⌘↑/⌘↓ switch tabs, as in the FilmSheet (KeyboardManager sets `selectedTab` directly).
   Tabs are built on first visit and kept hidden, with the FilmSheet's `TabEventShield`.
2. A **Genre / Rating** row at the top, with the FilmSheet's two pop-ups. Their own
   "Select Genre…" / "Select MPAA Rating…" rows clear the value.
3. A **focus sink** on each tab (`FilmSheetFocusSink`, now internal in 30.01).
4. **Change markers** moved to the end of each row, in a 22 pt slot that is always there
   (the Name row's help-button slot). They are now `ListCircleButton`s
   (`arrow.uturn.backward`, accent fill, glyph shadow).
5. **Shared values:** each field opens to the value every film shares
   (`BulkSharedValue`), still unchanged. Choosing the shared value again is no change.
   Notes shows shared notes, and emptying them clears them after a **Clear Notes?** prompt.
   Over differing notes, empty is still no change. Tags never prefill, since they append.
6. **Mixed checkboxes** (`MixedStateCheckbox`, 30.25) for Watched, Edited, Hall of Fame,
   Complete Data and the automatic-queueing box. Over a mix, a click goes mixed → checked →
   unchecked → mixed. Over a shared value, it flips between that value and its opposite.
   All-blacklisted selections open with Rotation Threshold locked at 5 years;
   un-blacklisting them shows "Use Default".

**Performance (bulk-edit-perf, Debug build, 1,600 films):**

| | Main thread (UI waits) | Background write |
|---|---|---|
| Open the sheet / lay out each tab | 10 ms / 40–70 ms | — |
| Keystroke (gutter + Update button) | 5 ms | — |
| Flags, genre, notes, tags, sorting | 190–540 ms | 0.7–2.3 s |
| List add / clear, Queue move / remove | ~530 ms | 7.7–8.7 s |
| Every field at once | ~570 ms | ~15.7 s |

- Fixed: `MemoryStore.updateFilms` (batch) replaced 1,600 `updateFilm` calls, about 10% of
  the main-thread time. What remains splits into ~330 ms building each film's
  `FilmMetadata` (search and sort keys, ~0.2 ms per film in Debug), ~120 ms of per-film
  `.film(.updated)` events (SmartLists recalculates each film) and ~40 ms for one gallery
  reload. `BulkSaveProbe` (DEBUG) records these phases for the scenario.
- Background writes are almost all SwiftData `commit()`, in the existing
  `moveFilmsBetweenLists` / `batchAdd…` / `batchRemove…` paths, the same ones a sidebar
  drop of 1,600 films uses. Fixing them belongs to those paths, not to this sheet.
- **Risk:** on quit the app waits at most 10 s for pending writes
  (`applicationShouldTerminate`). A 1,600-film list or Queue edit can take longer in Debug,
  so quitting right after one could cut the write off. Options: lengthen or remove the
  timeout while a write is in flight, show progress, or speed up the membership commits.
- Round 2 (2026-10-29, built, not yet measured): `MetadataCache.updateFilms` builds the
  entries across the cores (`buildEntriesNow`, `concurrentPerform`; the launch rebuild's
  `buildEntries` already relies on the same thread safety). Bulk update events now go out in
  reverse gallery order, so the gallery keeps the FIRST edited film in view (it keeps the
  last event's film), not the last. Before, a whole-library edit scrolled to the end.
- **Background writes, standalone SwiftData benchmark** (a minimal replica of the
  Film / List / Membership models, 1,600 films, scratchpad only):
  - Inserting N rows into one list scales with N²: 100 → 67 ms, 400 → 416 ms,
    800 → 1.3 s, 1,600 → 4.2 s. The same 1,600 spread over 16 lists: 1.2 s. Deleting
    1,600: ~3.1 s.
  - SwiftData maintains the list's inverse `memberships` array on every insert and delete
    (`first(where:)` / `removeAll(where:)` in the sample).
  - No effect: chunked saves (100/400), prefetching films, `-O` vs `-Onone` (it is
    framework code, so Release won't be faster).
  - Batch delete (`delete(model:where:)`) fails: the mandatory nullify inverse rejects it.
  - Can't parallelize: one ModelContext and one SQLite writer, and parallel contexts
    would conflict on the same list rows.
  - The only structural fix is a schema change that stops `ListObject` from holding
    the to-many inverse.
  - Field writes: 0.3 s for the replica vs 2.2 s in the app. The real Film model's
    size, not our code.
- **Quit timeout, what happens today:**
  - The MemoryStore cache is written from memory at quit, so it includes the edit.
  - On next launch its fingerprint (max lastModified, counts) doesn't match the
    database, so the app rebuilds from the database. Whatever didn't commit is
    silently lost.
  - `batchAdd…` / `batchRemove…` commit every 100 rows, so a cut-off can leave a
    list edit partly applied.

| Staged | What | State |
|---|---|---|
| `App/52.20 BulkFilmEdit.swift` | The edit as a value; pure rules for fields, lists, Queue, Hall of Fame, capacity | **Compiled + tested** (rig, 74 checks, Swift 6 strict) |
| `App/52.00 MultiFilmSheet.swift` | View model: blank fields, cascades, capacity, confirmations, save | **Built + run** (self-check, 97 checks on a library copy) |
| `App/52.10 MultiFilmSheetView.swift` | The sheet: header band, film table, fields, change markers, gutter | **Built + rendered** (offscreen PNGs) |
| `App/30.25 FSSharedFields.swift` | FilmSheet controls moved out of DetailsView, each with a blank state | **Built**; FilmSheet's Details tab re-rendered with them |
| `Patches/existing-files.patch` | All changes to 10 existing files | `git apply --check` passes on the real repo |
| `Tools/integrate.sh` | Applies the patch, copies the files, registers them in the project | **Dry run** on a copy of the real repo builds clean |
| `Tools/add_to_pbxproj.py` | Adds the four files to the target (idempotent) | Used by both builds |
| `Tools/sync_from_test_copy.sh` | Refreshes `App/` and `Patches/` from the test build, runs the rig | Used |
| `Rig/` | `run.sh`: logic checks against the staged file, with stub-drift guards | Passes |
| `Docs/UserGuide — Editing Several Films.html` | User Guide section draft, with placement notes | Draft |
| `INTEGRATION.md` | How to integrate, what each file change does, what to check | Ready |

---

## 1. What the user gets

**Opening it.** With more than one film selected, Edit Metadata… (⌘E), ⌘I and ⌥⌘E open
**Edit N Films** in place of the FilmSheet. With one film they open the FilmSheet exactly
as before. Edit Releases… (⌘R) stays single-film only.

**Layout.** The sheet is 600×600 with the FilmSheet's title strip and gutter. A fixed band
holds your description text and the selected films, in the gallery's order, shown in the
list gallery's table (the Saved Search builder's `UpNextResultsTable`, read-only, 3½ rows
tall so it's clear the table scrolls). Below the divider the fields scroll, in FilmSheet
order:

- **Queue Membership:** the segmented picker with no segment selected, then the
  "Add to [Select…] Queue when up for rotation" row.
- **List Membership:** the FilmSheet's menu, labeled "Select…".
- **Watched, Edited, Hall of Fame, Complete Data** (Complete Data only when that
  preference is on): unchecked checkboxes.
- **Special Sorting** ("Select…") and **Rotation Threshold** ("Select…", a hidden row, as in
  the Saved Search builder, because the FilmSheet's menu has no such option).
- **Notes** (empty) and **Tags** (the FilmSheet's reorderable list, empty).

**Changing a field.** Any field you change is written to every film. A blue
`arrow.uturn.backward.circle.fill` button appears in the margin beside its label. Clicking
it puts the field back to blank, meaning unchanged. The gutter reads "Change a field to
update every selected film." until something changes, then "N fields will change." The
button reads **Update N Films** and is disabled until a field changes. Return saves and
Escape cancels, as in the FilmSheet.

**Tags** are appended to each film's own tags in the order entered. A tag a film already
has is skipped (an exact match, the same rule the Tags list's own duplicate check uses).
A film is never taken past the Tags list's limit of 30. If any film can't take every tag,
the gutter says so.

## 2. Decisions (spec interpretations and edge cases)

Items marked ★ are my additions or readings of the spec. They're the ones to confirm (§4).

1. ★ **"Queue Membership block"** = the segmented picker plus the automatic-queueing row,
   the two controls between the Details tab's dividers. Its description reads "each film"
   rather than "this film".
2. ★ **A set value vs. a blank one.** Every control starts blank, but a value you set can
   also be empty or off: no lists, unchecked, "Use Default". The model keeps these apart
   with `BulkField.unchanged` / `.set(value)`. A checkbox you click once is set to checked.
   Click it again and it's set to *unchecked*, which differs from blank. The change marker
   is what shows the difference, and clicking it undoes the change. Without the marker,
   "uncheck Watched for every film" would look identical to "leave Watched alone".
3. ★ **Empty Notes means no change.** So the sheet can't clear every film's notes. That's
   the costliest accidental overwrite, and an emptied field can't be told apart from an
   untouched one. If you want bulk-clearing, it could be a "Clear Notes" checkbox.
4. ★ **Replace Notes? confirmation.** When Notes is set and some films have different notes
   of their own, Update asks first ("N of the selected films have notes of their own, which
   will be replaced. This can't be undone.").
5. **List Membership overwrites exactly:** the films end up in the checked lists and leave
   every other user list. To remove them from all lists, check a list and then uncheck it
   (the label reads "None", with the marker). A checked list deleted while the sheet is
   open is dropped.
6. **"Up Next" capacity** (8): if the selected films not already in "Up Next" exceed its
   open slots, the **Up Next segment is disabled**, and a note under the picker gives the
   numbers ("…has room for 1 more film, but 5 of the selected films are not in it…"). Films
   already in "Up Next" take no slot (`FilmQueue.upNextOverflow`'s rule). At save time the
   room is re-checked live, because the midnight auto-enqueue can fill it. If it no longer
   fits, the save is refused with the standard "Up Next" Queue Full alert and the sheet
   stays open. Adds are never partial, matching every other add path.
7. **Hall of Fame capacity** (200): same approach. The checkbox is disabled, with the
   FilmSheet's help button giving the numbers. There's a live re-check and refusal at save.
   Note: your library has 199 of 200 right now, so any selection with 2+ non-members shows
   it disabled. A side effect: while it's disabled you also can't bulk-*remove* (that takes
   check-then-uncheck). The existing Remove from Hall of Fame command still works.
8. **Special-sorting confirmation for the Queue:** choosing a section asks first, like the
   FilmSheet does, when the preference is on and any film being newly queued is flagged.
   The check uses the sheet's own Special Sorting value if one is set. The multi-film wording
   now lives in `FilmQueue.addConfirmationMessage(adding:flagged:)`, shared with
   AlertHostView's drop/menu alert so both read the same.
9. **Blacklisting cascade** (the FilmSheet's rule, per film):
   - becoming blacklisted forces the threshold to 60, and the Rotation Threshold row shows
     "5 years" and is disabled;
   - un-blacklisting hands back the sheet's threshold if one was set, otherwise "Use Default";
   - films already blacklisted keep 60 when only Rotation Threshold is changed, and the row
     says how many.
10. **Edited off clears the edited duration**, as `FSTabDetails.collectFilmFields` does.
11. **Special Sorting is written in canonical order**, which (as in the FilmSheet) drops a
    stored value outside the vocabulary.
12. **Last modified** is stamped on every film the edit actually changes, including
    membership- or Hall of Fame-only changes, as a FilmSheet save does. A film already
    matching every set value isn't stamped.
13. **Hall of Fame adds** take the next ranks in the order the films are listed (gallery
    order).
14. **Queue moves** go through `FilmManager.addFilmsToList`, which heals a film found in two
    sections. Films added to a section together get whatever order the existing multi-film
    adds give them (the same as a sidebar drop).

## 3. How it works

```
 MultiFilmSheetView ── binds ──► MultiFilmSheet (@Observable; one property per field)
                                    │ edit: BulkFilmEdit  (value; BulkField per field)
                                    │ confirm(): settle Tags popover → live capacity checks
                                    │            → Replace Notes? → save
                                    ▼
 save():  BulkFilmEdit.membershipChanges ──► FilmManager.addFilmsToList / removeFilmsFromLists
          (user lists + Queue)                (existing paths: exclusivity, Up Next cap, events)
          DataCoordinator.applyBulkFieldEdit ─► memory first, .film(.updated) per changed film
          (BulkFilmEdit.applyFields per film)   under explicitQueueChangeFilmIDs, one reload,
                                                one trackOperation → DataManager.applyFilmFields
                                                (one transaction, only the edited fields);
                                                rollback restores only those fields
          removeFromHallOfFame(Set) / addToHallOfFame([UUID])   (new batch add, one write)
```

- **Order** is saveFilmChangeset's: memberships first, so the field events see where the
  films now are. Then fields. Then the Hall of Fame, whose add reads the snapshots the field
  write just stored. That way it can't write back a stale `hofPosition` or stale fields.
- **The pattern is the ratings importer's** (`applyImportedRatingUpdates`): per-film events,
  since every subscriber resolves by film, one database transaction, and a field-only
  rollback.
- **Pure rules, tested apart.** `BulkFilmEdit` reads no app state. The rig compiles it with
  two stub types, and `run.sh` fails if their literals drift from the app's.
- **Shared controls.** `FilmQueuePicker` (now generic over its tag),
  `AutoAddToQueueRow` (new, lifted out of the Details tab body), `ListMembershipMenu`,
  `SpecialSortingMenu`, `RotationThresholdPicker`, plus the chrome and alignment they use,
  move from private types in DetailsView to `30.25 FSSharedFields.swift`. Each one gains an
  `isUnset` / tag-mapping hook that the FilmSheet never passes, so its rendering is unchanged.

## 4. Open questions for you

1. Is the **change marker** (★2) acceptable? Should the description text mention it?
   I left your description verbatim and put the explanation in the marker's tooltip.
2. **Notes:** keep "empty = no change" (★3), or add a way to clear notes in bulk?
3. Keep the **Replace Notes?** confirmation (★4)? Should List Membership also confirm before
   it removes films from lists?
4. **Gallery context menu:** with several films selected it has no Edit item today. Add
   "Edit Metadata…" there too?
5. **Menu title:** keep "Edit Metadata…" for multiple films, or switch to "Edit N Films…"?
6. The **"Up Next" room note** shows whenever the selection doesn't fit, which with your
   Queue at 7 of 8 is nearly always. Keep it, or show it only on hover over the disabled
   segment?
7. **Hall of Fame removal while blocked** (decision 7): acceptable?

## 5. Verification

Done:
- Rig: 74 logic checks (`Rig/run.sh`).
- Test build (Debug, Swift 6 strict) builds with no warnings in the new or changed code.
- Self-check on a sandbox copy of your library (1,400 films), 97 checks, all passed. Four
  real films go through the sheet's own `confirm()`: every field, append-once tags, exact
  list membership, Queue move then removal, blacklist cascade both ways, threshold skipped
  for blacklisted films, Hall of Fame add (rank 200) and removal, both capacity refusals
  writing nothing, and an untouched sheet that can't save. After each edit, a fresh
  `ModelContext` read of the store matched memory field by field and membership by
  membership.
- Offscreen renders: blank, filled, blacklisted and 300-film sheets, plus the FilmSheet's
  Details tab on the shared controls.
- Integration dry run: `integrate.sh` on a copy of the real repo, then a clean build.

Not done:
- **Driving the sheet by hand**: Tab order, Return/Escape, menus opening, the Tags popover,
  alerts appearing over the sheet. Try these in the test build.
- **Large saves**: one `.film(.updated)` per changed film. 300+ films is unmeasured.
  Measuring needs a harness scenario (ask before it runs).
- No pixel diff of the FilmSheet before and after the extraction (the code moved verbatim,
  and the re-render looks right).
- The User Guide draft isn't merged, and the PDFs aren't rebuilt (the doc check runs the
  harness).

## 6. Known limits

- **No undo**, like the rest of the app. The Replace Notes? prompt is the only guard beyond
  the sheet itself.
- **Not atomic across kinds.** Memberships, fields and the Hall of Fame are separate tracked
  writes. They run in order, but if one fails, its own rollback and alert cover only that
  part. The FilmSheet already splits off its Hall of Fame change the same way.
- **Tab** walks the sheet's controls through `FilmSheetKeyLoop.advance(inWindow:)`. A Tags
  popover is left to AppKit's own Tab handling.
