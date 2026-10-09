# Release-Year Ordering Harness

Standalone proof that the two release-year Steppers on a FilmSheet release card can
never produce a state violating `baseReleaseYear < releaseYear`, and — the point of
the change this harness was written for — that no click on the **base**-year Stepper
ever rewrites the release year.

Not part of the app target; builds with `swiftc` alone and touches no data, no
database, and no preferences.

## Run it

```bash
./run.sh
```

Expect `✅ ALL TESTS PASSED` and exit 0.

## The rule it covers

`baseReleaseYear` names the earliest permutation a release reissues, so it inherently
precedes `releaseYear`. The release year is the field the user configures first, so it
is authoritative: the base year is the subservient field, and it is the one sacrificed
to keep the relationship true.

- Up: the base-year Stepper's range is capped at `releaseYear - 1`, so incrementing at
  the cap wraps back to the range floor instead of pushing the release year up.
- Down: stepping the release year down drags a committed base year down with it, and
  clears it outright once the release year lands on the range floor — the same blank,
  unactivated state the Delete key produces.
- Placeholder: because the base year can only ever activate at that cap, its un-activated
  placeholder shows the cap rather than the current calendar year, tracks the release-year
  Stepper live, and is the exact value the activating click commits.

## What it checks

| Test | Assertion |
|---|---|
| 1 | The base-year Stepper cycles `floor ... releaseYear - 1` and wraps at both ends, leaving the release year untouched |
| 2 | Decrementing the release year walks the base year down, then clears it at the floor |
| 3 | Exhaustive walk of every click sequence of length ≤ 7 over four card shapes (~1.34M states): no illegal state is reachable, and the release year changes only as the direct result of a release-year click |
| 4 | A combo-pack child (release year inherited, its Stepper disabled) behaves identically, including a parent sync onto the child's floor |
| 5 | Repair paths no Stepper range can reach: an inverted stored pair, a film release year raised onto the release year, a degenerate one-year range, a future film year |
| 6 | The placeholder tracks the release-year Stepper click for click, reverts to dashes when the field disables, and activation commits exactly the year it displayed — checked for every release year 2007…2026 |
| 7 | A year left in the model behind a cleared base-year field cannot leak through a later activation in place of the placeholder |

## Caveat

`Harness.swift` **transcribes** three shipped sources rather than importing them — they
live inside SwiftUI views and an `@Observable` app target that `swiftc` cannot build
alone, the same compromise the ReleaseCardStateEquivalence harness makes:

- `ReleaseCardModel.enforceReleaseYearOrder()` — `33.00 FSTabReleases.swift`
- `_ReleaseYearRow`'s computed Stepper ranges and `baseYearAvailable` — `33.20 ReleaseCard.swift`
- `CustomDatePicker.steppedYear(from:by:)`, `displayYear`, and
  `shouldActivateInsteadOfIncrement()` — `91.00 InputUtilities.swift`

Re-run it, and mirror any edit to those three, whenever the ordering rule or either
Stepper's range changes.
