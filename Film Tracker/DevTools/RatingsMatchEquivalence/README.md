# Ratings Match Equivalence

Standalone proof that the consolidated matching code in `81.00 RatingsImporter.swift`
places every incoming rating on exactly the same library film, and counts it in
exactly the same bucket, as the two hand-written passes it replaced.

Before the consolidation the detached matching task carried two near-identical
copies of the same logic — one keyed on each film's primary `name`, one on its
`alternateTitle` list — each with its own exact-dictionary lookup, its own fuzzy
(Levenshtein) fallback, and its own copy of the `existingRating` /
`allowUpdatesForDuplicateRatings` outcome ladder. Roughly 180 lines of the file
were the same decisions written twice, and any fix applied to one pass had to be
mirrored by hand into the other. There is one `findMatch` and one `recordMatch`
now, parameterized by a `MatchPass`.

The same commit also deleted `RatingsImporter`'s own private `yearsMatch` in favor
of `FilmComparison.yearsMatch(_:_:allowFuzzy:)`. The two were spelled differently
(one led with the both-empty/one-empty cases, the other with a plain `==`), so
their interchangeability is proved here rather than assumed.

## Running

```bash
./run.sh
```

Builds with `swiftc -O` and runs. No Xcode project, no app target, touches no data.

## What it checks

Both algorithms are transcribed into `Harness.swift` — `Old` from the pre-consolidation
source, `New` from the consolidated source — and run over the same corpora. Everything
that cannot affect *which* film a rating lands on is omitted (MainActor hops, the
100/50-rating sync cadence, progress throttling, cancellation). A run passes only if
the two agree on all four counters, all three title lists **in order**, and the exact
sequence of queued `(filmID, rating)` writes.

1. **Randomized corpora** — 2000 seeded corpora (1–24 films, 12 ratings each) crossed
   with all 8 combinations of `allowUpdatesForDuplicateRatings` × `fuzzyImportMatching`
   × `fuzzyImportYearMatching`. Titles are drawn from a pool seeded with genuine
   near-misses ("Alien"/"Aliens", "Leon"/"Léon", "Casino"/"Casino Royale",
   "The Ring"/"The Lord of the Rings") and then mutated by case change, one deletion,
   one insertion, or duplication, so exact hits, fuzzy hits and clean misses all fire.
   Years drift by −1/0/+1/+5 and include empty and non-numeric values.
2. **Degenerate corpora** — empty library, empty ratings list, and a film whose name,
   alternate title and year are all the empty string (the exact-match dictionary keys
   on `""` in both implementations, so both must match it).
3. **Order sensitivity** — three films with colliding names and alternate titles, run
   under all six orderings. Both implementations are first-match-wins over an
   unordered dictionary bucket and then over the film array, so a reordering that
   changed which of them wins would be caught here.
4. **`yearsMatch` interchangeability** — the deleted copy and `FilmComparison`'s, over
   every ordered pair of 12 year strings (empty, whitespace, out-of-range, non-numeric,
   5-digit, negative, spaced) × fuzzy on/off.

The run also asserts that all four outcome buckets (imported / updated / not-found /
duplicate-skipped) were actually reached, so a pass cannot come from comparing two
empty results.

## Re-run it when

Any change to the ratings matching order, the `MatchPass` shape, the outcome ladder in
`recordMatch`, or `FilmComparison.yearsMatch`.

## Result

```
Compared 16072 matching runs and 288 year-match pairs.
Outcome buckets exercised: duplicateSkipped, imported, notFound, updated
✅ PASS
```

Mutation-checked: inverting the outcome ladder's condition produces 7781 disagreements,
and flipping the fuzzy-year flag in one implementation produces 4911 — the harness fails
when it should.
