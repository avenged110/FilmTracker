# Smart List Membership Equivalence

Standalone proof that the consolidated `SmartLists.membership(of:today:)`
(`71.10 SmartLists.swift`) assigns a film to exactly the same smart lists as the two
hand-written predicate families it replaced.

Before the consolidation there were two complete copies of all seven membership rules:

* the `@MainActor` instance checkers (`isUpForRotation`, `hasPurchasedFormat`, …) that
  drove targeted per-film recalculation, spread across `recalculateForFilm`,
  `recalculateSortingListsForFilm`, and `recalculateReleaseBasedListsForFilm`; and
* the `nonisolated static _`-prefixed copies (`_isUpForRotation`, …) that drove the
  background full recalculation inside `computeSmartListSets`.

Their own comments required them to stay "byte-for-byte equivalent", because a film's
membership otherwise flips depending on which path last evaluated it. That obligation is
gone — there is one definition now — and this harness is what establishes that the one
definition is the same rule both copies encoded.

## Running

```bash
./run.sh
```

Builds with `swiftc -O` and runs. No Xcode project, no app target, touches no data.

## What it checks

Each test compares three membership functions over the same `FilmSnapshot`: the
reconstructed old targeted path, the reconstructed old bulk path, and the new
`membership(of:today:)`. All three must agree exactly.

1. **Release × sorting × watched × edited** — exhaustive over every release list of
   length 0–2 drawn from all (format × purchased × included-versions) atoms, crossed with
   all 32 subsets of the five special-sorting tags (including combinations the FilmSheet
   UI makes mutually exclusive — the predicates assume nothing there, so neither does
   this) and both booleans. ~190k combinations.
2. **Date × threshold × sorting × watched** — exhaustive over watch dates probing the
   month-boundary rounding `rotationEligibilityDate` performs (day before / on / after the
   anniversary, at 0–36 month offsets, plus first/mid/last-of-month across two years),
   both supported date spellings, unparseable and empty dates, and all eight rotation
   thresholds. ~76k combinations.
3. **Randomized sweep** — 300k films of random shape across every dimension at once.
4. **Release-based scope** — that `releaseBasedLists`, now derived from
   `isPurchasedFormat || isUnpurchasedFormat || .alternateVersions`, is the same nine
   lists the old `recalculateReleaseBasedListsForFilm` updated by hand.
5. **Family tests** — that `isPurchasedFormat`, `isUnpurchasedFormat`, `isRotationVariant`,
   `isAlternateVersionsVariant` (and the deleted `isSortingVariant`), now one-liners over
   `sidebarParent`, agree with the exhaustive switches they replaced for all 18 cases.

`parseDate` and `rotationEligibilityDate` are mirrored here and shared by both sides, so
they are a fixed black box: the harness tests the membership rules, not the date helpers
(which have their own coverage via the release-year ordering harness and the app's
`date-semantics` scenario).

## Re-run it when

any smart list's membership rule changes, a smart list case is added or removed, or
`sidebarParent` is edited.
