# Poster-Load Ordering Harness

Standalone proof that the right sidebar's `Header` poster loading publishes the
**current** film's poster no matter what order the disk answers in.

Run with `./run.sh`. Builds via `swiftc` alone — no Xcode project, no app target,
touches no data. Expect `✅ ALL TESTS PASSED`.

## What it covers

`Header.loadImageFromCache(_:)` in `24.11 Header.swift`. The harness holds a copy of
the **old** implementation alongside the current one and drives both through a stub
poster cache whose loads suspend until the test explicitly releases them — so
completion order is chosen, not timed, and every run is deterministic.

## The defect

On a cache miss the old implementation started an unstored, uncanceled `Task`:

```swift
Task {
    let image = await PosterCache.shared.getImageAsync(for: uid)
    guard film?.posterUID == uid else { return }
    displayedImage = image
    lastLoadedPosterUID = uid
}
```

`getImageAsync` genuinely awaits disk I/O, so two rapid film changes that both miss
the cache leave two loads in flight with no guarantee about which finishes first. If
the **older** one finishes last it paints the previous film's poster and stamps
`lastLoadedPosterUID` with its UID — and because reloads are driven by
`onChange(of: film?.posterUID)`, nothing fires again to correct it until the UID
changes once more.

## The one thing the harness does not assert

Whether the old guard worked at all depends on what `@Environment` returns when read
from inside an escaping closure — a closure captures a *copy* of the `View` struct,
and SwiftUI does not document what that copy sees. The harness runs the old model
under both readings rather than picking one:

| | old implementation | new implementation |
|---|---|---|
| `captured-snapshot` — the copy sees the environment frozen at request time, so the guard compares `uid` to itself and can never fail | **wrong poster displayed** | correct |
| `live-read` — the read observes the current environment, so the guard rejects a superseded load | correct | correct |

That is the argument for the change even if `live-read` turns out to be what SwiftUI
does: the old code's correctness rested on an undocumented implementation detail,
while the new code depends only on `@State`, whose behavior in an escaping closure is
defined. The fix also cancels the superseded load rather than letting it run to
completion and discarding the result, which the old code did under either reading.

## The fix being verified

Two pieces of `@State` — `requestedPosterUID` (the newest request, recorded
synchronously before any suspension) and `posterLoadTask` (the in-flight load) — plus
an unconditional `cancel()` at the top of every request, including the cache-hit and
no-poster paths, since either can supersede a miss.

## Re-sync

Re-run this whenever `loadImageFromCache(_:)`, its `@State`, or `PosterCache`'s
sync/async contract changes. `HeaderModel` in `Harness.swift` mirrors that function's
structure by hand; a branch added to the app but not to the model silently stops
being covered.

Distinct from the in-app scenario harness (`-FTDebugHarness`), which runs the real
application against a throwaway database but does not drive sidebar UI paths.
