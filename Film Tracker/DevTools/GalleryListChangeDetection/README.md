# Gallery List Change-Detection Harness

Standalone proof for the three decision procedures `DraggableListView.updateNSView` runs
on every pass in `23.30 GalleryListView.swift`:

1. **Whether to rebuild the row model at all** — `filmsChanged || sectionInputsChanged ||
   queueBandsNotDerivableFromFilms`. Before this gate existed the list rebuilt
   unconditionally, on every ancestor re-render, paying an O(films) sectioning scan the
   grid has never paid.
2. **Whether to take a full `reloadData()`** — `isViewSwitch || idSequenceChanged ||
   rowModelChanged`, which replaced a count/first/last heuristic that was blind to an
   interior reorder.
3. **The scroll clamp** — `NSScrollView.maxVerticalScrollOffset(forContentHeight:)`, which
   now accounts for `contentInsets.bottom`.

Not part of the app target; builds with `swiftc` alone and touches no data, no database,
and no preferences.

## Run it

```bash
./run.sh
```

Expect `✅ ALL TESTS PASSED` and exit 0.

## The properties it covers

**Skip soundness (test 1)** — the load-bearing one. Whenever the gate declines to rebuild,
the row model it *would* have produced is identical to the one already held. Checked
exhaustively over every films arrangement of length ≤ 2 across two ids, crossed with every
section-input combination (215,168 cases), then over 400,000 seeded-random draws from the
full space. A failure here means a stale divider band on screen.

**The Film Queue "All" opt-out (test 2)** — that tab bands from
`DataCoordinator.filmQueueSection(forFilm:)`, i.e. MemoryStore *list membership*, which no
`FilmSnapshot` field mirrors. Promoting the first "Soon" film to "Up Next" leaves it at the
same array index with every snapshot byte-identical while deleting a band, so neither
`filmsChanged` nor `sectionInputs` can see it. The test constructs exactly that transition
and asserts the tab rebuilds anyway. Every other view's bands are sort-derived from
MetadataCache values that are themselves derived from snapshot fields, so the skip is sound
there — the test also confirms the sort-derived counterpart *does* move a snapshot field.

**Reload superset (tests 3 and 4)** — the new predicate reloads whenever the predicate it
replaced did (486,098 cases), and strictly more often in exactly the interior-reorder cases
the old one missed. Test 3's main sweep tops out at three films, which cannot express an
interior reorder at all (with the first and last pinned there is one element between them),
so the strictly-more property gets its own space: all 576 ordered pairs of four-film
permutations, over which *every* reordering must force a reload.

**Metadata-only edits (test 5)** — a renamed film with no reorder and no re-band must still
re-assign `films` (or the visible-row refresh renders stale data) while still avoiding a
full reload. This is why the gate uses deep array equality rather than an ID-sequence
comparison.

**No-op soundness (test 8)** — the visible-row refresh is gated on `filmsChanged`. Whenever
a pass takes neither the full reload nor that refresh, every row the table would draw
(dividers, and each film row resolved to its film) must equal what it already shows.
Exhaustive over two-film sets crossed with section inputs, queue maps and view switches,
then randomized over three-film sets with half the draws reusing the old films (the shape
of a selection or status-bar pass). Also pins the two measured passes: a selection change
refreshes nothing, a metadata edit refreshes the visible rows.

**CoW short-circuit (test 6)** — `Array ==` returns on buffer identity, so the gate costs
zero element comparisons on a no-op pass. Measured at 100,000 elements.

**Scroll clamp (test 7)** — the one test that is *not* a transcription: it builds real
`NSScrollView`s over a flipped document view and checks
`max(0, contentHeight + contentInsets.bottom - contentView.bounds.height)` against
`NSClipView.constrainBoundsRect` across 30 viewport/content/inset combinations. It also
asserts the expression this replaced (`contentHeight - documentVisibleRect.height`)
disagrees with AppKit whenever a bottom inset is present and the content overflows — i.e.
that the bug was real. A 1000pt document in a 400pt viewport constrains to 600 with no
insets and to 629 with the 29pt StatusBar inset.

## Keeping it honest

The model types and the three decision procedures are **transcribed**, not imported: the
shipped code lives inside an `NSViewRepresentable` coordinator in an `@Observable` app
target that cannot be built with `swiftc` alone. Any edit to the originals must be mirrored
here — these tests are only evidence about the code they copy. Re-run after any change to
the Change Detection block, to `rebuildRowModel()`, or to the scroll clamps.
