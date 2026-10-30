# Bulk Edit: Integration

Integrating is one command. Everything it does is listed below, so it can also be done by
hand or reviewed first.

## 1. Before

- Make sure the test build is current: `Tools/sync_from_test_copy.sh` refreshes `App/` and
  `Patches/` from it and reruns the rig.
- Commit or stash anything in the real repo you want to keep separate. The patch is made
  against the working tree as of 2026-10-28 (uncommitted changes included) and was checked
  with `git apply --check` then.
- No schema change and no new preference, so no migration and no backup-format change.

## 2. Integrate

```bash
"/Users/user/Documents/IDE and software projects/Xcode projects/Film Tracker/Film Tracker/Staging/BulkEdit/Tools/integrate.sh" "/Users/user/Documents/IDE and software projects/Xcode projects/Film Tracker"
```

The script refuses to run if any part of the patch doesn't apply, or if any of the four new
files already exists. It:

1. applies `Patches/existing-files.patch` (10 files, listed in §3);
2. copies `App/30.25 FSSharedFields.swift`, `52.00 MultiFilmSheet.swift`,
   `52.10 MultiFilmSheetView.swift` and `52.20 BulkFilmEdit.swift` into `Film Tracker/`;
3. runs `Tools/add_to_pbxproj.py`, which adds the four files to the source group and the
   Sources phase, right after `30.20` and `51.00` (IDs `B0E0ED…`).

Then build. The same steps were dry-run on a copy of the real repo, and it built clean.

## 3. What the patch changes

| File | Change |
|---|---|
| `31.10 DetailsView.swift` | Removes the private `FilmQueuePicker`, `menuFieldChrome`, `ListMembershipMenu`, `SpecialSortingMenu`, `RotationThresholdPicker` and the `rotationLine` alignment (now in 30.25). The inline auto-add row becomes `AutoAddToQueueRow`, and the section items table goes with it. Nothing else in the tab changes. |
| `10.10 SheetHostView.swift` | `SheetContent.multiFilm(MultiFilmSheet)`, `AppSheet.multiFilm` (id `"multiFilm"`), its display name and content. `handleEditFilm` sends a selection of more than one film to the new `handleEditFilms`, which orders the films as the gallery shows them (any not shown follow, by title). |
| `10.30 KeyboardManager.swift` | ⌘I and ⌥⌘E accept any non-empty selection. The Return intercept goes through `returnConfirmAction(for:)`, which covers the FilmSheet and the MultiFilmSheet. |
| `12.00 MenuBar.swift` | Edit Metadata… is enabled for any non-empty selection. |
| `11.00 DataCoordinator.swift` | `applyBulkFieldEdit(_:filmIDs:alsoTouched:explicitQueueFilmIDs:)` and the batch `addToHallOfFame(_: [UUID])`. |
| `11.10 DataManager.swift` | `applyFilmFields(_:fields:)`: one transaction that writes only the given `FilmField`s. |
| `11.20 MemoryStore.swift` | The batch `addToHallOfFame(_: [UUID]) -> [UUID]`: ranks in order and rebuilds once. |
| `29.00 FilmQueue.swift` | `addConfirmationMessage(adding:flagged:)`, the multi-film Queue confirmation text. |
| `10.20 AlertHostView.swift` | Uses that shared text instead of building its own (same wording). |
| `30.30 FSStringList.swift` | `ReorderableStringList.maxItems` becomes internal, so `BulkFilmEdit.tagLimit` can be asserted against it. |

The test build carries two more changes that are **not** in the patch: the sandbox guard in
`10.00 FilmTrackerApp.swift`, and the `MultiFilmSheetTestHooks` call in
`11.00 DataCoordinator.swift`, with its implementation at the end of the test copy's
`52.10` (snapshots and the self-check). `sync_from_test_copy.sh` strips both.

## 4. Check after integrating

On screen, with a few films selected (try it in the test build first):

- ⌘E, ⌘I, ⌥⌘E and Film ▸ Edit Metadata… open **Edit N Films**. With one film they open
  the FilmSheet, and ⌘R is unchanged.
- Every field starts blank. Changing one shows its marker, and the marker reverts it.
- Tab walks the fields. Return saves when no text field is active. Escape cancels.
- The List Membership and Special Sorting menus open and toggle. The Tags popover adds and
  edits entries. The Queue confirmation, the Replace Notes? prompt and the capacity alerts
  appear over the sheet.
- The FilmSheet's Details tab looks and behaves as before (the automatic-queueing row in
  particular).

## 5. Afterward

- **Docs:** merge `Docs/UserGuide — Editing Several Films.html` (placement notes are in the
  file), then rebuild the PDFs. The doc check runs the guide-sync harness, so it needs your
  go-ahead.
- **Harness (optional, ask first):** a `bulk-edit` scenario built from the test build's
  self-check (`MultiFilmSheetTestHooks.selfCheck`), plus a timing run of a 300-film save.
- Delete `Staging/BulkEdit` and the test build when you're done with them.
