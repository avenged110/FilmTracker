# ReleaseCardState Equivalence Harness

Standalone proof that the release-card change-detection refactor in
`33.00 FSTabReleases.swift` is behavior-preserving. Not part of the app target;
builds with `swiftc` alone and touches no data, no database, and no preferences.

## Run it

```bash
./run.sh
```

Expect `✅ ALL TESTS PASSED` and exit 0.

## What it is for

`ReleaseCardModel` and `ReleaseCardState` used to state the same ~39-field list in
six places. Three of those were hand-written and unchecked by the compiler
(`matches()`, `contentHash`, `differingFields()`), so a field added to one and
missed in another silently stopped being change-tracked — with no build error and
no test to catch it.

Those three now derive from `snapshot()` + `ReleaseCardState`'s synthesized
`==`/`hash(into:)`. This harness is the evidence that deriving them changed
nothing. It carries the OLD hand-written implementations alongside the CURRENT
shipped ones and fuzzes them against each other.

## What it checks

| Test | Assertion |
|---|---|
| 1 | `matches(state)` ≡ `snapshot() == state` — 200,000 random pairs, mixed has-flag states, matching and differing `id`/`dateAdded` |
| 2 | `contentHash` per-field sensitivity identical across all 39 fields (400 trials each) |
| 3 | `contentHash` equality *relation* identical — 100,000 random pairs |
| 4 | `differingFields` old ≡ Mirror-based — identical strings, identical order, 200,000 pairs |
| 5a | Preserved edge case: `cost` 0.0 → -0.0 must still signal (old hashed `bitPattern`; `==` does not distinguish these) |
| 5b | Preserved edge case: an inactive optional field's placeholder drift must still signal, even though `snapshot()` normalizes it away |
| 6 | Benchmark: `matches()` vs `snapshot() !=` on the 150 ms debounce path |

Tests 5a/5b are why `contentHash` keeps seven explicit `h.combine` calls after
`h.combine(snapshot())`. That is a CLOSED set — it does not grow when a field is
added — and removing any of them changes observable behavior.

## Result of record (2026-09-01)

```
TEST 1 (matches ≡ snapshot==)              0 failures
TEST 2 (contentHash per-field sensitivity) 0 failures
TEST 3 (contentHash relation)              0 failures
TEST 4 (differingFields)                   0 failures
5a  cost 0.0 -> -0.0 : old changed=true, new changed=true
5b  inactive releaseYear drift : old changed=true, new changed=true
TEST 6  20 releases: matches()=8.82µs/tick  snapshot()!==13.67µs/tick
```

Test 6 is why `matches()` was deleted rather than kept as a fast path: it saved
~4.9µs per 150 ms tick across 20 releases (0.003% of the interval) and cost an
invariant the compiler could not check.

## Re-syncing it after the field list changes

`Harness.swift` embeds copies of the real code. The OLD side is a historical
record and should be left alone. The CURRENT side — `contentHashNew` and
`differingFieldsNew` — must be re-pasted from `33.00 FSTabReleases.swift` if
those methods change:

1. Copy `var contentHash` → paste over `var contentHashNew`, rename it.
2. Copy `func differingFields(from:)` → paste over `differingFieldsNew(from:)`, rename it.
3. Add any new field to `ReleaseCardState`'s and `ReleaseCardModel`'s property
   lists here, to the `init`, to `randomModel(...)`, and to `mutators` in
   `main.swift` — the last one is what makes Test 2 cover it.
4. `./run.sh`

If a new field is added to the app but NOT to this harness, the harness still
passes — it simply stops covering that field. That is the one gap; step 3 is the
mitigation.
